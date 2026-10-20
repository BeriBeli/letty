//! Native search orchestration and visible-only highlight cache. Ghostty owns
//! the search engines/history/results; ordinary screen.selection is untouched.
const std = @import("std");
const ghostty = @import("ghostty-vt");
pub const max_needle_bytes = 4096;
// The fixed upstream search stores a cloned page-chunk highlight per match.
// On Zig 0.17/aarch64, 88,771 single-page matches alone require >32 MiB
// (MultiArrayList chunk capacity plus result storage), before growth peaks.
// Keep a finite 64 MiB quota so the existing 100k-line/64 MiB history workload
// remains searchable, including active/viewport caches and temporary growth.
pub const max_search_bytes = 64 * 1024 * 1024;
pub const max_visible_cells = 1024 * 1024;
pub const ticks_per_call = 1;

pub const State = struct {
    engine: ?ghostty.search.Terminal = null,
    audit: Audit = .{},
    fed_revision: ?u64 = null,
    dirty: bool = true,
    running: bool = false,
    last_error: ?anyerror = null,
    mask: std.ArrayList(u8) = .empty,
    mask_revision: ?u64 = null,
    mask_cols: usize = 0,
    mask_rows: usize = 0,

    /// Context owns this State at a stable address: engine allocator.ptr refers
    /// to audit. Deinitialize before terminal, and never move an active State.
    pub fn deinit(self: *State, terminal: *ghostty.Terminal) void {
        if (self.engine) |*engine| engine.deinit(terminal);
        self.engine = null;
        if (self.audit.backing != null) self.mask.deinit(self.audit.allocator());
        self.mask = .empty;
        self.fed_revision = null;
        self.mask_revision = null;
        self.mask_cols = 0;
        self.mask_rows = 0;
        self.dirty = true;
        self.running = false;
        self.last_error = null;
        self.audit.failure = null;
    }
};

/// Upstream TerminalSearch.feed/tick log some allocation errors instead of
/// returning them. This bounded allocator records actual alloc failure, so
/// those paths cannot become false "search complete" success in the facade.
/// Failed resize/remap is not itself OOM: ArrayList may legitimately fall back
/// to allocate/copy. All owned search allocations count against one quota.
pub const Audit = struct {
    backing: ?std.mem.Allocator = null,
    live: usize = 0,
    limit: usize = max_search_bytes,
    failure: ?anyerror = null,
    pub fn allocator(self: *Audit) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = resize, .remap = remap, .free = free } };
    }
    fn allocate(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Audit = @ptrCast(@alignCast(raw));
        if (len > self.limit -| self.live) {
            self.failure = error.SearchMemoryLimit;
            return null;
        }
        const result = self.backing.?.rawAlloc(len, alignment, ra) orelse {
            self.failure = error.OutOfMemory;
            return null;
        };
        self.live += len;
        return result;
    }
    fn resize(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *Audit = @ptrCast(@alignCast(raw));
        if (len > memory.len and len - memory.len > self.limit -| self.live) return false;
        if (!self.backing.?.rawResize(memory, alignment, len, ra)) return false;
        self.live = self.live - memory.len + len;
        return true;
    }
    fn remap(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *Audit = @ptrCast(@alignCast(raw));
        if (len > memory.len and len - memory.len > self.limit -| self.live) return null;
        const result = self.backing.?.rawRemap(memory, alignment, len, ra) orelse return null;
        self.live = self.live - memory.len + len;
        return result;
    }
    fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Audit = @ptrCast(@alignCast(raw));
        self.backing.?.rawFree(memory, alignment, ra);
        self.live -= memory.len;
    }
};

pub fn clearLocked(self: anytype) void {
    self.search_state.deinit(&self.terminal);
}
pub fn close(self: anytype) void {
    if (!self.enter()) return;
    defer self.leave();
    clearLocked(self);
    self.changed();
}
pub fn set(self: anytype, needle: [*]const u8, len: usize) c_int {
    if (len > max_needle_bytes or !std.unicode.utf8ValidateSlice(needle[0..len])) return -2;
    if (!self.enter()) return -7;
    const result = setLocked(self, needle, len);
    self.leave();
    return if (self.fatal == null) result else -1;
}
fn setLocked(self: anytype, needle: [*]const u8, len: usize) c_int {
    const state = &self.search_state;
    if (len == 0) {
        clearLocked(self);
        self.changed();
        return 0;
    }
    state.audit.backing = self.gpa;
    state.audit.failure = null;
    // Construct before replacing: a rejected query never partially replaces
    // the old query or borrows bytes from configuration/GUI arenas.
    const replacement = ghostty.search.Terminal.init(state.audit.allocator(), needle[0..len]) catch |err| {
        state.last_error = state.audit.failure orelse err;
        return -1;
    };
    if (state.engine) |*engine| engine.deinit(&self.terminal);
    state.engine = replacement;
    state.fed_revision = null;
    state.mask_revision = null;
    state.dirty = true;
    state.running = true;
    state.last_error = null;
    self.changed();
    return 0;
}

fn verify(state: *State) !void {
    if (state.audit.failure) |err| {
        state.last_error = err;
        return err;
    }
    if (state.last_error) |err| return err;
}
fn syncLocked(self: anytype) !void {
    const state = &self.search_state;
    try verify(state);
    const engine = if (state.engine) |*value| value else return;
    if (state.dirty or state.fed_revision == null or state.fed_revision.? != self.revision) {
        engine.feed(&self.terminal, true);
        try verify(state);
        state.fed_revision = self.revision;
        state.dirty = false;
        state.mask_revision = null;
    } else if (engine.status() == .feed_required) {
        engine.feed(&self.terminal, false);
        try verify(state);
        state.mask_revision = null;
    }
}
const Info = struct { total: usize = 0, current: usize = 0, running: bool = false };
fn snapshot(state: *State) Info {
    if (state.last_error != null) return .{};
    const engine = if (state.engine) |*value| value else return .{};
    const screen = engine.activeScreenSearch() orelse return .{ .running = true };
    return .{ .total = screen.matchesLen(), .current = if (screen.selected) |selected| selected.idx + 1 else 0, .running = engine.status() != .complete or state.dirty };
}
pub fn info(self: anytype, output: anytype) void {
    var value = snapshot(&self.search_state);
    if (self.search_state.engine != null and self.search_state.last_error == null and self.search_state.fed_revision != self.revision) value.running = true;
    output.* = .{ .total = value.total, .current = value.current, .running = value.running };
}

/// One upstream bounded work unit per screen per call, matching the C API's
/// incremental tick contract. There is no timer/poller here; only a positive
/// return asks the host to schedule another search frame.
pub fn tick(self: anytype, total: *usize) c_int {
    total.* = 0;
    if (!self.enter()) return -7;
    const result = tickLocked(self, total);
    self.leave();
    if (self.fatal != null) {
        total.* = 0;
        return -1;
    }
    return result;
}
fn tickLocked(self: anytype, total: *usize) c_int {
    const state = &self.search_state;
    const before = snapshot(state);
    const was_dirty = state.dirty or state.fed_revision != self.revision;
    syncLocked(self) catch return -1;
    const engine = if (state.engine) |*value| value else return 0;
    for (0..ticks_per_call) |_| _ = engine.tick();
    verify(state) catch return -1;
    if (engine.activeScreenSearch()) |screen| {
        if (screen.matchesLen() > 0 and screen.selected == null) {
            _ = engine.select(&self.terminal, .next, .if_needed) catch |err| {
                state.last_error = err;
                return -1;
            };
            verify(state) catch return -1;
            state.dirty = true;
        }
    }
    const after = snapshot(state);
    total.* = after.total;
    state.running = after.running;
    if (was_dirty or before.running or after.running or before.total != after.total or before.current != after.current) {
        self.changed();
        state.mask_revision = null;
    }
    state.fed_revision = self.revision;
    return @intFromBool(after.running);
}
pub fn next(self: anytype, previous: bool) void {
    if (!self.enter()) return;
    defer self.leave();
    const state = &self.search_state;
    syncLocked(self) catch return;
    const engine = if (state.engine) |*value| value else return;
    _ = engine.select(&self.terminal, if (previous) .prev else .next, .if_needed) catch |err| {
        state.last_error = err;
        return;
    };
    verify(state) catch return;
    state.dirty = true;
    state.mask_revision = null;
    self.changed();
}

/// Call inside Context.enter, before RenderState.update. The mask owns only
/// visible flags; no terminal body/history or borrowed Pin survives this call.
pub fn prepareLocked(self: anytype) !void {
    const state = &self.search_state;
    errdefer {
        if (state.last_error == null) state.last_error = state.audit.failure orelse error.SearchPrepareFailed;
    }
    syncLocked(self) catch |err| return err;
    const engine = if (state.engine) |*value| value else return;
    const cols: usize = self.terminal.cols;
    const rows: usize = self.terminal.rows;
    if (cols * rows > max_visible_cells) {
        state.last_error = error.SearchViewportLimit;
        return error.SearchViewportLimit;
    }
    if (state.mask_revision == self.revision and state.mask_cols == cols and state.mask_rows == rows) return;
    try state.mask.resize(state.audit.allocator(), cols * rows);
    @memset(state.mask.items, 0);
    const matches = try engine.viewportMatches();
    try verify(state);
    for (matches) |match| mark(self, match, 32);
    if (engine.activeScreenSearch()) |screen| if (screen.selectedMatch()) |selected| mark(self, selected, 32 | 64);
    state.mask_cols = cols;
    state.mask_rows = rows;
    state.mask_revision = self.revision;
}
pub fn flags(self: anytype, x: usize, y: usize) c_uint {
    const state = &self.search_state;
    if (state.last_error != null or state.mask_revision != self.revision or x >= state.mask_cols or y >= state.mask_rows) return 0;
    return state.mask.items[y * state.mask_cols + x];
}
fn mark(self: anytype, flattened: ghostty.highlight.Flattened, flag: u8) void {
    if (flattened.chunks.len == 0) return;
    const screen = self.terminal.screens.active;
    const pages = &screen.pages;
    for (flattened.chunks.items(.node), flattened.chunks.items(.serial)) |node, serial| if (!pages.nodeIsValid(node, serial)) return;
    const span = flattened.untracked();
    const selection = ghostty.Selection.init(span.start, span.end, false);
    const start_point = pages.pointFromPin(.viewport, span.start);
    const end_point = pages.pointFromPin(.viewport, span.end);
    const first = if (start_point) |p| p.viewport.y < self.terminal.rows else false;
    const last = if (end_point) |p| p.viewport.y < self.terminal.rows else false;
    if (!first and !last) {
        const top = pages.pin(.{ .viewport = .{} }) orelse return;
        if (!selection.contains(screen, top)) return;
    }
    const start: ghostty.point.Coordinate = if (first) start_point.?.viewport else .{};
    const end: ghostty.point.Coordinate = if (last) end_point.?.viewport else .{ .x = self.terminal.cols - 1, .y = self.terminal.rows - 1 };
    var y: usize = start.y;
    while (y <= end.y) : (y += 1) {
        const left: usize = if (y == start.y) start.x else 0;
        const right: usize = @min(self.terminal.cols - 1, if (y == end.y) end.x else self.terminal.cols - 1);
        if (left > right) continue;
        for (left..right + 1) |x| self.search_state.mask.items[y * self.terminal.cols + x] |= flag;
    }
}
