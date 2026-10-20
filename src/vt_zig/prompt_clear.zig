//! Native clear policy from fixed Ghostty termio/Termio.zig:597. This is a
//! higher-level action than the legacy CSI-based clear used by C comparison.
//!
//! Host transaction contract (single session/main-thread operation):
//! 1. redrawRequired() determines whether a one-byte shell write is needed.
//! 2. Reserve TX capacity BEFORE mutating the terminal; reject if unavailable.
//! 3. clearForShell() finishes the VT operation and returns an owned bool.
//! 4. Only after it returns, enqueue exactly one 0x0c through Session.send when
//!    true. Never feed 0x0c to TerminalStream or write from a parser callback.
//!    TX preflight and enqueue must be serialized so the reservation cannot be
//!    consumed between them. Queue failure must be visible, not fake success.
//!
//! The caller retains history choice; ordinary clear uses history=true. This
//! does not reset modes, title, PWD, semantic counters or the shell process.
//! Search stays open and refreshes through the changed revision. Selection
//! and tracked anchor are cleared before any row/page removal.
//!
//! runFixtures() checks native primitives only. Real-shell acceptance still
//! requires an owned PTY with bash --noprofile --norc -i / zsh -f, isolated HOME,
//! INPUTRC and history, and OSC133 markers in its prompt. Type an unexecuted
//! command, move the editing cursor inside an argument, clear, insert a marker,
//! then execute and verify the resulting argument exactly. Repeat with CJK,
//! combining text and multiline/wrapped prompts, history=true/false, full TX,
//! resize, and alternate/raw TUI. Record current input, cursor, scrollback and
//! modes before/after; primitive success does not prove shell redraw worked.
const std = @import("std");
const selection = @import("selection.zig");

pub fn redrawRequired(self: anytype) anyerror!bool {
    if (self.fatal) |err| return err;
    if (self.busy) return error.ReentrantVt;
    if (self.terminal.screens.active_key == .alternate) return error.AlternateScreen;
    // Event counters can lag or describe a previous row. The terminal's own
    // semantic row/cursor state is the authoritative prompt predicate.
    return self.terminal.cursorIsAtPrompt();
}

/// Returns whether the HOST must send FF to the shell after this call ends.
/// No PTY bytes are sent here; alternate screen and existing fatal state fail
/// before any selection, graphics or terminal contents are changed.
pub fn clearForShell(self: anytype, history: bool) anyerror!bool {
    _ = try redrawRequired(self);
    if (!self.enter()) {
        if (self.fatal) |err| return err;
        return error.VtUnavailable;
    }
    defer self.leave();
    selection.clearLocked(self);
    if (history) self.terminal.eraseDisplay(.scrollback, false);

    const redraw = self.terminal.cursorIsAtPrompt();
    if (redraw) {
        // Ghostty deliberately delegates reconstruction of the live editing
        // buffer to the shell; terminal text alone cannot recover it.
        self.terminal.eraseDisplay(.complete, false);
    } else {
        const screen = self.terminal.screens.active;
        if (screen.cursor.y > 0) screen.eraseActive(screen.cursor.y - 1);
        // Fixed Ghostty clears all graphics on this screen on this branch,
        // rather than attempting to infer which images belong above cursor.
        if (comptime @hasDecl(@TypeOf(screen.kitty_images), "delete")) {
            screen.kitty_images.delete(self.terminal.io(), screen.alloc, &self.terminal, .{ .all = true });
        }
    }
    self.changed();
    selection.validateLocked(self);
    if (self.status() != 0) {
        if (self.fatal) |err| return err;
        return error.VtUnavailable;
    }
    return redraw;
}

fn check(ok: bool, label: []const u8, count: *usize) !void {
    std.debug.print("{s} PROMPT CLEAR {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.PromptClearMismatch;
    count.* += 1;
}
const Sink = struct {
    calls: usize = 0,
    fn receive(raw: ?*anyopaque, _: [*]const u8, _: usize) callconv(.c) void {
        const self: *Sink = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
    }
};
fn textEquals(self: anytype, expected: []const u8) bool {
    if (selection.all(self) != 0) return false;
    defer selection.clear(self);
    var buffer: [4096]u8 = undefined;
    var len: usize = 0;
    return selection.copy(self, &buffer, buffer.len, &len) == 0 and len <= buffer.len and std.mem.eql(u8, buffer[0..len], expected);
}
/// Root may call this from an isolated native main using DebugAllocator and
/// init.io. It opens no shell/window and never touches an OS clipboard.
pub fn runFixtures(gpa: std.mem.Allocator, io: std.Io) !usize {
    const context = @import("context.zig");
    var sink: Sink = .{};
    const v = try context.create(gpa, io, 20, 5, 128, 1024 * 1024, Sink.receive, &sink);
    defer context.destroy(v);
    var count: usize = 0;

    context.feed(v, "old\r\nkeep\r\nTAIL");
    try check(!try redrawRequired(v), "unmarked output does not request a shell redraw", &count);
    const x = v.terminal.screens.active.cursor.x;
    try check(!try clearForShell(v, false), "nonprompt clear returns no host write", &count);
    try check(v.terminal.screens.active.cursor.x == x and v.terminal.screens.active.cursor.y == 0 and textEquals(v, "TAIL"), "nonprompt clear removes rows above cursor and preserves its text and column", &count);
    try check(sink.calls == 0, "primitive clear emits no PTY replies", &count);

    context.feed(v, "\x1bcrow-zero");
    try check(!try clearForShell(v, false) and textEquals(v, "row-zero"), "nonprompt clear at row zero preserves current row", &count);
    context.feed(v, "\x1b[?1049h\x1b[HALT");
    const rejected = if (clearForShell(v, true)) |_| false else |err| err == error.AlternateScreen;
    try check(rejected and textEquals(v, "ALT"), "alternate screen is rejected without erasing application text", &count);
    context.feed(v, "\x1b[?1049l\x1bc\x1b[?2004h\x1b]133;A\x07$ \x1b]133;B\x07draft");
    try check(try redrawRequired(v), "OSC133 prompt and input state requires shell redraw", &count);
    const before_calls = sink.calls;
    try check(try clearForShell(v, true), "prompt clear returns an owned host-redraw request", &count);
    try check(sink.calls == before_calls and v.terminal.modes.get(.bracketed_paste) and !selection.has(v), "prompt clear preserves modes and never executes the shell write itself", &count);
    return count;
}
