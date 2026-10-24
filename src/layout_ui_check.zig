//! M1 interaction checks use only in-process nanoui input and owned PTYs.
const std = @import("std");
const ui = @import("nanoui").ui;
const Request = @import("actions.zig").Request;
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.LayoutUiCheck;
}
fn runAction(s: anytype, t: *ui.Tester, request: Request) void {
    s.menu_actions[0] = request;
    s.menu_action_count = 1;
    t.frame();
}
fn sameNodes(a: []const @import("layout.zig").Node, b: []const @import("layout.zig").Node) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.meta.eql(x, y)) return false;
    return true;
}
pub fn run(s: anytype, t: *ui.Tester) !void {
    t.resize(1000, 680);
    try adjacentNewTab(s, t);
    try t.screenshot(".cache/test-logs/navigation-top-two-paper.png");
    runAction(s, t, .{ .action = .horizontal });
    runAction(s, t, .{ .action = .vertical });
    runAction(s, t, .{ .action = .split_left });
    const session = s.sessions[s.layout.active_pane].?;
    const pid = session.pid;
    const nodes = try s.gpa.dupe(@import("layout.zig").Node, s.layout.nodes);
    defer s.gpa.free(nodes);
    const before_cols = session.cols;
    runAction(s, t, .{ .action = .toggle_zoom });
    try check(s.zoom == session.id and session.cols > before_cols and sameNodes(nodes, s.layout.nodes), "zoom changes presentation without changing split topology or ratios");
    runAction(s, t, .{ .action = .toggle_zoom });
    try check(s.zoom == null and session.cols == before_cols and session.pid == pid, "restore zoom keeps PTY and original geometry");
    const before = s.layout.active_pane;
    runAction(s, t, .{ .action = .focus_pane, .args = .{ .direction = .right } });
    try check(s.layout.active_pane != before, "directional action reaches adjacent visible pane");
    runAction(s, t, .{ .action = .equalize });
    const root = s.layout.roots[s.layout.active_tab];
    const ratio = s.layout.nodes[root].ratio;
    runAction(s, t, .{ .action = .resize_pane, .args = .{ .resize = .{ .direction = .right, .pixels = 25 } } });
    // The closest compatible ancestor may be inside the root.
    try check(!sameNodes(nodes, s.layout.nodes) and s.layout.nodes[root].ratio >= ratio, "keyboard resize updates compatible divider within bounds");
    for (0..4) |_| {
        @import("nanoui").runFor(0.05);
        t.frame();
    }
    const old_bg = s.cfg.background;
    const old_fg = s.cfg.foreground;
    s.cfg.background = 0x222831;
    s.cfg.foreground = 0xeaeaea;
    t.frame();
    try t.screenshot(".cache/test-logs/layout-nested-dark.png");
    s.cfg.background = old_bg;
    s.cfg.foreground = old_fg;
    t.frame();
    const tab_id = s.layout.tabs[s.layout.active_tab].id;
    const focused = s.layout.active_pane;
    runAction(s, t, .{ .action = .previous_tab });
    runAction(s, t, .{ .action = .next_tab });
    try check(s.layout.tabs[s.layout.active_tab].id == tab_id and s.layout.active_pane == focused, "tab switch restores each tab's last focused split");
    runAction(s, t, .{ .action = .rename_tab });
    t.typeText("工作区");
    t.key(.enter);
    t.frame();
    try check(!s.rename_dialog.open and std.mem.eql(u8, s.layout.tabs[s.layout.active_tab].name(), "工作区") and session.pid == pid, "nanoui rename prompt updates stable tab without restarting PTY");
    runAction(s, t, .{ .action = .move_tab, .args = .{ .offset = -1 } });
    try check(s.layout.active_tab == 0 and s.layout.tabs[0].id == tab_id, "move_tab wraps position while retaining active tab identity");
    const from = s.sidebar.rowRect(s.layout.tabIndex(tab_id).?, s.navigation_rects.navigation);
    const to = s.sidebar.rowRect(1, s.navigation_rects.navigation);
    t.drag(from.x + 20, from.y + 12, to.x + 20, to.y + 12);
    try check(s.layout.tabIndex(tab_id) == 1 and session.pid == pid, "drag reorders tab using stable identity");
    t.resize(480, 240);
    while (s.host.paneCount() < 16) runAction(s, t, .{ .action = .tab });
    var controls_inside = true;
    var interactive: usize = 0;
    var rects = t.ctx.rects.iterator();
    while (rects.next()) |entry| if (entry.value_ptr.y < @import("navigation/geometry.zig").top_height) {
        interactive += 1;
        if (entry.value_ptr.x < -0.5 or entry.value_ptr.x + entry.value_ptr.w > t.size.w + 0.5) controls_inside = false;
    };
    try check(controls_inside and interactive >= 2 and s.layout.tab_count > 8, "many-session window keeps Letty toolbar controls inside the window");
    try t.screenshot(".cache/test-logs/layout-overflow-paper.png");
    const full_count = s.layout.tab_count;
    runAction(s, t, .{ .action = .tab });
    try check(s.layout.tab_count == full_count + 1, "new workspace crosses the former sixteen-PTY ceiling");
    s.close(s.layout.active_pane);
    try s.layout.validate(s.cfg.profiles.len);
}

fn adjacentNewTab(s: anytype, t: *ui.Tester) !void {
    var button: ?ui.Rect = null;
    var rows: usize = 0;
    for (s.ax.routes[0..s.ax.route_count]) |route| {
        if (route.intent == .tab) rows += 1;
        if (route.intent == .new_tab) button = t.ctx.rects.get(route.widget);
    }
    try check(rows == s.layout.tab_count and button != null and button.?.y == 16 and button.?.x + button.?.w < s.navigation_rects.content.x, "Letty New Session button stays in the sidebar toolbar above session rows");
}
