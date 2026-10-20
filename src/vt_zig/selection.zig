//! Native selection ownership. Only the anchor is ours; screen selection,
//! grapheme boundaries, soft-wrap formatting and pruning remain Ghostty's.
const std = @import("std");
const ghostty = @import("ghostty-vt");
pub const max_copy_bytes = 1024 * 1024;
const ScreenKey = @FieldType(@FieldType(ghostty.Terminal, "screens"), "active_key");
const Behavior = enum { cell, word, line };
// The fixed revision's C selection defaults, expressed as owned codepoints.
const boundaries = [_]u21{ 0, ' ', '\t', '\'', '"', '│', '`', '|', ':', ';', ',', '(', ')', '[', ']', '{', '}', '<', '>', '$' };

pub const State = struct {
    anchor: ?*ghostty.Pin = null,
    screen: ScreenKey = .primary,
    generation: usize = 0,
    behavior: Behavior = .cell,

    /// Must run while terminal is alive. A replaced screen has already freed
    /// its tracked-pin pool, so its stale pointer must never be dereferenced.
    pub fn deinit(self: *State, terminal: *ghostty.Terminal) void {
        if (self.anchor) |anchor| {
            if (terminal.screens.generation(self.screen) == self.generation) {
                if (terminal.screens.get(self.screen)) |screen| screen.pages.untrackPin(anchor);
            }
        }
        self.anchor = null;
        self.behavior = .cell;
    }
    fn validAnchor(self: *State, terminal: *ghostty.Terminal) ?*ghostty.Pin {
        if (self.screen != terminal.screens.active_key or terminal.screens.generation(self.screen) != self.generation) {
            self.deinit(terminal);
            return null;
        }
        const anchor = self.anchor orelse return null;
        if (anchor.garbage) {
            self.deinit(terminal);
            return null;
        }
        return anchor;
    }
};

/// Locked helpers are called from reset/clear/frame preparation, whose caller
/// already owns Context.enter. Public facade functions below acquire it once.
pub fn clearLocked(self: anytype) void {
    self.selection_state.deinit(&self.terminal);
    self.terminal.screens.active.clearSelection();
}
pub fn validateLocked(self: anytype) void {
    _ = self.selection_state.validAnchor(&self.terminal);
    if (self.terminal.screens.active.selection) |selection| {
        if (selection.start().garbage or selection.end().garbage) self.terminal.screens.active.clearSelection();
    }
}
pub fn clear(self: anytype) void {
    if (!self.enter()) return;
    defer self.leave();
    clearLocked(self);
    self.changed();
}
pub fn has(self: anytype) bool {
    if (self.fatal != null) return false;
    const selection = self.terminal.screens.active.selection orelse return false;
    return !selection.start().garbage and !selection.end().garbage;
}

/// Existing facade actions: 0=cell press, 1=drag, 2=word, 3=line. Coordinates
/// are inclusive VT cells, so no invented pixel threshold changes copying.
pub fn select(self: anytype, x: c_uint, y: c_uint, action: c_int) void {
    if (x >= self.terminal.cols or y >= self.terminal.rows or action < 0 or action > 3) return;
    if (!self.enter()) return;
    defer self.leave();
    const screen = self.terminal.screens.active;
    const pin = screen.pages.pin(.{ .viewport = .{ .x = @intCast(x), .y = @intCast(y) } }) orelse return;
    var result: ?ghostty.Selection = null;
    if (action != 1) {
        clearLocked(self);
        self.selection_state.anchor = screen.pages.trackPin(pin) catch |err| return self.fail(err);
        self.selection_state.screen = self.terminal.screens.active_key;
        self.selection_state.generation = self.terminal.screens.generation(self.selection_state.screen);
        self.selection_state.behavior = switch (action) {
            2 => .word,
            3 => .line,
            else => .cell,
        };
        result = switch (self.selection_state.behavior) {
            .cell => null,
            .word => screen.selectWord(pin, &boundaries),
            .line => screen.selectLine(.{ .pin = pin, .semantic_prompt_boundary = false }),
        };
    } else {
        const anchor = self.selection_state.validAnchor(&self.terminal) orelse return;
        result = switch (self.selection_state.behavior) {
            .cell => ghostty.Selection.init(anchor.*, pin, false),
            .word, .line => expand(screen, anchor.*, pin, self.selection_state.behavior),
        };
    }
    screen.select(result) catch |err| return self.fail(err);
    self.changed();
}

fn expand(screen: *ghostty.Screen, anchor: ghostty.Pin, pin: ghostty.Pin, behavior: Behavior) ?ghostty.Selection {
    const first = if (behavior == .word) screen.selectWord(anchor, &boundaries) else screen.selectLine(.{ .pin = anchor, .semantic_prompt_boundary = false });
    const last = if (behavior == .word) screen.selectWord(pin, &boundaries) else screen.selectLine(.{ .pin = pin, .semantic_prompt_boundary = false });
    const a = first orelse return last;
    const b = last orelse return first;
    return if (pin.before(anchor)) ghostty.Selection.init(b.start(), a.end(), false) else ghostty.Selection.init(a.start(), b.end(), false);
}

pub fn all(self: anytype) c_int {
    if (!self.enter()) return -7;
    const result = allLocked(self);
    // leave may discover an allocation failure swallowed by the native
    // engine. Evaluate success only after its failure audit has run.
    self.leave();
    return if (self.fatal == null) result else -1;
}
fn allLocked(self: anytype) c_int {
    clearLocked(self);
    const screen = self.terminal.screens.active;
    const selection = screen.selectAll() orelse return -1;
    screen.select(selection) catch |err| {
        self.fail(err);
        return -1;
    };
    self.changed();
    return 0;
}

/// Write directly to the caller's bounded buffer with the native formatter.
/// No allocating history mirror or temporary full selection string is made.
/// Partial bytes are never reported as a successful clipboard payload.
pub fn copy(self: anytype, output: [*]u8, capacity: usize, length: *usize) c_int {
    length.* = 0;
    if (!self.enter()) return -7;
    const result = copyLocked(self, output, capacity, length);
    self.leave();
    if (self.fatal != null) {
        length.* = 0;
        return -1;
    }
    return result;
}
fn copyLocked(self: anytype, output: [*]u8, capacity: usize, length: *usize) c_int {
    validateLocked(self);
    const screen = self.terminal.screens.active;
    const selection = screen.selection orelse return -1;
    var formatter: ghostty.formatter.ScreenFormatter = .init(screen, .{ .emit = .plain, .unwrap = true, .trim = true });
    formatter.content = .{ .selection = selection };
    var writer: std.Io.Writer = .fixed(output[0..@min(capacity, max_copy_bytes)]);
    formatter.format(&writer) catch return -2;
    length.* = writer.buffered().len;
    return 0;
}
