//! Aggregate per-pane attention without adding an idle timer or OS service.
const ui = @import("nanoui").ui;
pub fn badge(s: anytype, ctx: *ui.Context, tab: usize) []const u8 {
    var bell = false;
    var done = false;
    var failed = false;
    for (s.sessions, 0..) |opt, slot| if (opt) |session| {
        if (!s.layout.contains(s.layout.roots[tab], @intCast(slot))) continue;
        if (session.events.progress_state != 0) return if (session.events.progress >= 0) ctx.print("{d}% · ", .{session.events.progress}) else "… · ";
        bell = bell or session.attention == .bell;
        done = done or session.attention == .done;
        failed = failed or session.attention == .failed;
    };
    return if (failed) "! · " else if (bell) "● · " else if (done) "✓ · " else "";
}
