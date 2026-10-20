//! Native navigation and destructive-action coordination. The compatibility
//! clear policy remains distinct from reset and does not promise shell redraw.
const std = @import("std");
const ghostty = @import("ghostty-vt");
const selection = @import("selection.zig");
const search = @import("search.zig");

pub fn scroll(self: anytype, delta: c_int) void {
    move(self, .{ .delta = delta });
}
pub fn bottom(self: anytype) void {
    move(self, .bottom);
}
pub fn scrollTo(self: anytype, row: u64) void {
    move(self, .{ .row = @intCast(@min(row, std.math.maxInt(usize))) });
}
pub fn promptJump(self: anytype, delta: c_int) void {
    move(self, .{ .delta_prompt = delta });
}
fn move(self: anytype, request: ghostty.Terminal.ScrollViewport) void {
    if (!self.enter()) return;
    defer self.leave();
    self.terminal.scrollViewport(request);
    self.changed();
}
pub fn scrollInfo(self: anytype, output: anytype) void {
    const bar = self.terminal.screens.active.pages.scrollbar();
    output.* = .{ .total = bar.total, .offset = bar.offset, .len = bar.len, .alternate = self.terminal.screens.active_key == .alternate };
}
pub fn reset(self: anytype) void {
    if (!self.enter()) return;
    defer self.leave();
    selection.clearLocked(self);
    search.clearLocked(self);
    self.event_snapshot.at_prompt = false;
    self.event_snapshot.progress_state = 0;
    // Route RIS through the native handler so reset effects stay coherent.
    self.stream.nextSlice("\x1bc");
    self.mouse_last_cell = null;
    self.changed();
}
pub fn clearScreen(self: anytype) c_int {
    if (self.terminal.screens.active_key == .alternate) return -2;
    if (!self.enter()) return -7;
    selection.clearLocked(self);
    // Same baseline policy as the C adapter; preserve modes, clear contents
    // and history, home cursor. Existing search refreshes on the new revision.
    self.stream.nextSlice("\x1b[3J\x1b[2J\x1b[H");
    self.terminal.scrollViewport(.bottom);
    self.changed();
    self.leave();
    return if (self.fatal == null) 0 else -1;
}

pub const PromptClearPlan = enum { alternate_rejected, erase_above_cursor, shell_form_feed_required };
/// Evaluation only, not the default action. Fixed Ghostty Termio.clearScreen
/// uses eraseActive(cursor.y-1) away from prompts; at a prompt it calls
/// eraseDisplay(.complete) and queues FF (0x0c) for the shell to redraw. The
/// native types expose these primitives, but a real shell/PTY fixture is still
/// required before Letty adopts that distinct host transaction.
pub fn promptClearPlan(self: anytype) PromptClearPlan {
    if (self.terminal.screens.active_key == .alternate) return .alternate_rejected;
    return if (self.terminal.cursorIsAtPrompt()) .shell_form_feed_required else .erase_above_cursor;
}
