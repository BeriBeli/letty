//! Read-only Inspector checks through actual VT cells and the Tester's UI.
const std = @import("std");
const ui = @import("nanoui").ui;
const vt = @import("vt.zig");
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI Inspector {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.InspectorUiCheck;
}
pub fn run(s: anytype) !void {
    const W = @TypeOf(s.*);
    const h = s.host;
    const old_active = h.active_id;
    defer if (h.find(old_active) != null) {
        h.active_id = old_active;
    };
    const w = try h.create(false);
    defer h.retire(w);
    w.hold = true;
    w.cfg.kitty_graphics = false;
    w.cfg.copy_on_select = .none;
    w.cfg.confirm_close = .never;
    const session = w.active().?;
    w.configureSession(session);
    const pid = session.pid;
    try vt.feed(session.vt, "\x1b[2J\x1b[Hab\x1b[1;4:3;58;2;255;0;0m中\x1b[0m\x1b[?25l");
    var t: ui.Tester = undefined;
    try t.init(s.gpa, .init(w, W.view), .{ .width = 640, .height = 400, .scale = 1, .theme = @import("appearance.zig").theme(w.cfg) });
    defer t.deinit();
    w.pending = .{ .action = .inspector };
    t.frame();
    try check(w.inspector.open and w.modalOpen() and w.inspector.target == session.id and t.hasText("Terminal Inspector"), "action opens a modal for the exact live session");
    w.inspector.x = 2;
    w.inspector.y = 0;
    t.frame();
    const cell = w.inspector.snapshot;
    try check(cell.cell_present and cell.cell_width == 2 and cell.sample.len == 0 and cell.flags & 1 != 0 and cell.underline == 3, "default Inspector reports styled cell metadata without capturing terminal body");
    try check(cell.window == w.id and cell.pid == pid and cell.history_lines == w.cfg.scrollback_lines and cell.history_bytes == w.cfg.scrollback_bytes, "read-only Inspector includes stable window process and history budgets");
    try t.clickText("Show Cell Text");
    t.frame();
    try check(w.inspector.show_cell_text and std.mem.eql(u8, w.inspector.snapshot.sample.text(), "中"), "explicit opt-in captures only the selected visible cell");
    try check(cell.actual_font.len > 0 and cell.glyphs.len > 0 and cell.configured_font.len > 0, "actual run glyph IDs and raster font source are copied from this pane");
    const revision = vt.lt_vt_revision(session.vt);
    w.inspector.frozen = true;
    try vt.feed(session.vt, "\x1b[Hnew output");
    t.frame();
    try check(vt.lt_vt_revision(session.vt) != revision and std.mem.eql(u8, w.inspector.snapshot.sample.text(), "中") and session.pid == pid, "Freeze holds only diagnostic data while VT and PTY stay live");
    try t.clickText("Copy Diagnostics");
    try check(std.mem.indexOf(u8, t.clipboard.items, "[omitted]") != null and std.mem.indexOf(u8, t.clipboard.items, "中") == null and std.mem.indexOf(u8, t.clipboard.items, "queued input bytes=") != null, "copy uses fake clipboard and omits visible cell text");
    try t.clickText("Hide Cell Text");
    try check(!w.inspector.show_cell_text and w.inspector.snapshot.sample.len == 0, "hiding cell text clears even a frozen copied cell immediately");
    const fd = session.fd;
    session.fd = -1;
    defer session.fd = fd;
    const queued = session.tx.len;
    t.typeText("INSPECTOR_MUST_NOT_REACH_PTY");
    try check(session.tx.len == queued, "modal query text is neither recorded nor sent to PTY");
    t.key(.escape);
    t.frame();
    try check(!w.inspector.open and !w.modalOpen() and session.pid == pid and session.tx.len == queued and w.inspector.snapshot.sample.len == 0, "Escape closes without leaking text or escape input");
    w.inspector.show(&t.ctx, session);
    t.frame();
    t.resize(480, 240);
    const rect = w.inspector.geometry;
    try check(rect.x >= 0 and rect.y >= 0 and rect.x + rect.w <= t.size.w and rect.y + rect.h <= t.size.h and closeVisible(&t), "minimum window retains bounded Inspector and close action");
    w.inspector.close(&t.ctx);
    t.frame();
}

fn closeVisible(t: *ui.Tester) bool {
    const r = t.findText("Close") orelse return false;
    if (r.w <= 0 or r.h <= 0 or r.x < 0 or r.y < 0 or r.x + r.w > t.size.w or r.y + r.h > t.size.h) return false;
    for (t.ctx.nodes.items) |node| {
        if (node.content != .text or !std.mem.eql(u8, node.content.text.str, "Close")) continue;
        var p = node.parent;
        var depth: usize = 0;
        while (p != std.math.maxInt(u32)) {
            if (p >= t.ctx.nodes.items.len or depth >= t.ctx.nodes.items.len) return false;
            const parent = t.ctx.nodes.items[p];
            if (parent.style.clip) {
                const visible = r.intersect(parent.rect);
                if (visible.w + 0.1 < r.w or visible.h + 0.1 < r.h) return false;
            }
            p = parent.parent;
            depth += 1;
        }
        return true;
    }
    return false;
}
