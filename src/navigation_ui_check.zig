//! M2 user flows against real shell output in the isolated nanoui Tester.
const std = @import("std");
const nano = @import("nanoui");
const ui = nano.ui;
const vt_api = @import("vt.zig");
const Request = @import("actions.zig").Request;
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.NavigationUiCheck;
}
fn action(s: anytype, t: *ui.Tester, request: Request) void {
    s.menu_actions[0] = request;
    s.menu_action_count = 1;
    t.frame();
}
fn drain(t: *ui.Tester) void {
    for (0..8) |_| {
        nano.runFor(0.05);
        t.frame();
    }
}
pub fn run(s: anytype, t: *ui.Tester) !void {
    t.resize(800, 500);
    drain(t);
    const session = s.sessions[s.layout.active_pane].?;
    t.typeText("i=0; while [ $i -lt 60 ]; do printf 'MATCH_%s 中é\\n' \"$i\"; i=$((i+1)); done");
    t.key(.enter);
    drain(t);
    var scroll: vt_api.Scroll = .{};
    vt_api.lt_vt_scroll_info(session.vt, &scroll);
    try check(scroll.total > scroll.len, "real shell output creates scrollable history");
    s.query.clear();
    action(s, t, .{ .action = .search });
    t.typeText("MATCH_");
    drain(t);
    try check(s.total >= 60 and s.search_info.current > 0, "find bar exposes current and total matches from real output");
    var cursor: vt_api.Cursor = .{};
    var cell: vt_api.Cell = undefined;
    _ = vt_api.lt_vt_frame(session.vt, &cursor);
    var matched: usize = 0;
    var current: usize = 0;
    while (vt_api.lt_vt_next(session.vt, &cell)) {
        if (cell.flags & 32 != 0) matched += 1;
        if (cell.flags & 64 != 0) current += 1;
    }
    vt_api.lt_vt_frame_end(session.vt);
    try check(matched > current and current > 0, "search draws visible hits separately from current result");
    try t.screenshot(".cache/test-logs/search-matches-paper.png");
    const original = s.search_info.current;
    t.ctx.input.shift = true;
    t.key(.enter);
    t.ctx.input.shift = false;
    t.frame();
    try check(s.search_info.current != original, "Shift+Enter navigates to previous match");
    action(s, t, .{ .action = .end_search });
    action(s, t, .{ .action = .scroll_bottom });
    vt_api.lt_vt_scroll_info(session.vt, &scroll);
    const bottom = scroll.offset;
    const pane = for (s.drop_panes[0..s.drop_pane_count]) |target| {
        if (target.session == session.id) break target.rect;
    } else return error.MissingWheelPane;
    const wheel_x: f32 = @floatCast(pane.x + 20);
    const wheel_y: f32 = @floatCast(pane.y + 20);
    const row_height = @as(f32, @floatFromInt(session.cell_h)) / @max(1, t.ctx.scale);
    s.views[s.layout.active_pane].wheel = .{};
    for (0..7) |_| t.scroll(wheel_x, wheel_y, row_height / 8);
    vt_api.lt_vt_scroll_info(session.vt, &scroll);
    try check(scroll.offset == bottom, "precise wheel retains fractions without premature row jumps");
    t.scroll(wheel_x, wheel_y, row_height / 8);
    vt_api.lt_vt_scroll_info(session.vt, &scroll);
    try check(scroll.offset == bottom - 1, "eight small native deltas scroll exactly one terminal row up");
    t.scroll(wheel_x, wheel_y, -row_height);
    vt_api.lt_vt_scroll_info(session.vt, &scroll);
    try check(scroll.offset == bottom, "negative native wheel delta returns terminal viewport downward");
    t.ctx.input.scroll_lines = 1;
    t.scroll(wheel_x, wheel_y, 12);
    vt_api.lt_vt_scroll_info(session.vt, &scroll);
    try check(scroll.offset == bottom - 1, "discrete wheel retains native line units independently of font height");
    action(s, t, .{ .action = .scroll_bottom });
    action(s, t, .{ .action = .page_up });
    vt_api.lt_vt_scroll_info(session.vt, &scroll);
    try check(scroll.offset < bottom, "page navigation moves VT history viewport");
    action(s, t, .{ .action = .scroll_bottom });
    const body = body_rect: for (s.ax.routes[0..s.ax.route_count]) |route| {
        if (route.intent != .pane) continue;
        for (s.ax.adapter.?.routes[0..s.ax.adapter.?.route_count]) |target| if (target.node == route.id and target.target.session == session.id) break :body_rect t.ctx.rects.get(route.widget).?;
    } else return error.MissingScrollbarPane;
    const scrollbar_x = body.x + body.w - 6;
    t.drag(scrollbar_x, body.y + body.h - 10, scrollbar_x, body.y + 10);
    vt_api.lt_vt_scroll_info(session.vt, &scroll);
    try check(scroll.offset < bottom, "per-pane scrollbar thumb drags to earlier history");
    action(s, t, .{ .action = .scroll_top });
    vt_api.lt_vt_scroll_info(session.vt, &scroll);
    try check(scroll.offset == 0, "scroll_to_top action reaches oldest retained row");
    action(s, t, .{ .action = .select_all });
    try check(vt_api.lt_vt_has_selection(session.vt), "select_all is dispatched to VT selection");
    action(s, t, .{ .action = .clear_screen });
    vt_api.lt_vt_scroll_info(session.vt, &scroll);
    try check(scroll.total == scroll.len and !vt_api.lt_vt_has_selection(session.vt), "clear_screen clears content and scrollback without replacing PTY");
    vt_api.lt_vt_feed(session.vt, "\x1b[?2004h", 8);
    const pid = session.pid;
    action(s, t, .{ .action = .reset });
    try check(session.pid == pid and !vt_api.lt_vt_bracketed(session.vt), "terminal reset clears modes and preserves running process");
}
