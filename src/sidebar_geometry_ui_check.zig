//! Checks real arranged content/drop/AX rectangles with a private fake drop
//! destination. No native drag registry, desktop event or clipboard is used.
const std = @import("std");
const ui = @import("nanoui").ui;
const drop = @import("application_drop.zig");

fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI Sidebar geometry {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.SidebarGeometryUiCheck;
}
const Destination = struct {
    window: u64,
    ids: [16]u64 = @splat(0),
    count: usize = 0,
    fn valid(raw: *anyopaque, target: drop.Target) bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (target.window != self.window) return false;
        for (self.ids[0..self.count]) |id| if (id == target.session) return true;
        return false;
    }
    fn wake(_: *anyopaque) void {}
    fn paste(_: *anyopaque, _: drop.Target, _: []const u8) bool {
        return false;
    }
    fn attach(_: *anyopaque, _: drop.Callback, _: ?*anyopaque, _: [*]u8, _: usize) ?*anyopaque {
        return @ptrFromInt(1);
    }
    fn detach(_: *anyopaque) void {}
    fn geometry(_: *anyopaque, _: f64, _: f64) void {}
    fn current(_: *anyopaque) bool {
        return true;
    }
    fn host(self: *@This()) drop.Host {
        return .{ .ctx = self, .window = self.window, .valid = valid, .wake = wake, .paste = paste };
    }
    const adapter: drop.Adapter = .{ .attach = attach, .detach = detach, .geometry = geometry, .current = current };
};
fn inside(r: anytype, x: f64, y: f64, width: f64, height: f64) bool {
    return x + 0.1 >= r.x and y + 0.1 >= r.y and x + width <= r.x + r.w + 0.1 and y + height <= r.y + r.h + 0.1;
}

/// Caller has selected sidebar mode and a visible split workspace. Geometry is
/// taken from the exact final Tester frame, not a separate model calculation.
pub fn run(w: anytype, t: *ui.Tester) !void {
    t.frame();
    const rects = w.navigation_rects;
    try check(w.cfg.workspace_navigation == .sidebar and rects.navigation.w > 0 and rects.content.x >= rects.navigation.x + rects.navigation.w - 0.1 and rects.content.x > 0 and @abs(rects.content.x + rects.content.w + w.preview.rect.w - t.size.w) < 0.1, "navigation and right-hand terminal content partition the actual window without overlap");
    try check(w.drop_pane_count > 0 and !w.drop_geometry_fault, "actual workspace draw publishes terminal-cell rectangles after sidebar layout");
    var destination: Destination = .{ .window = w.id };
    for (w.drop_panes[0..w.drop_pane_count]) |pane| {
        try check(inside(rects.content, pane.rect.x, pane.rect.y, pane.rect.width, pane.rect.height), "published file-drop cell rectangle is contained in right-hand content");
        destination.ids[destination.count] = pane.session;
        destination.count += 1;
    }
    var bridge = drop.Bridge.initWithAdapter(w.gpa, destination.host(), Destination.adapter);
    defer bridge.deinit();
    try bridge.attach(@ptrFromInt(1));
    try bridge.publish(w.drop_panes[0..w.drop_pane_count], false);
    const pane = w.drop_panes[0];
    try check(drop.Bridge.receive(&bridge, @backingInt(drop.Phase.probe), 0, null, 0, pane.rect.x + 1, pane.rect.y + 1, false), "exact drop callback accepts actual terminal cells at their shifted window coordinates");
    try check(!drop.Bridge.receive(&bridge, @backingInt(drop.Phase.probe), 0, null, 0, rects.navigation.x + rects.navigation.w / 2, rects.navigation.y + @min(60, rects.navigation.h / 2), false), "exact drop callback refuses sidebar coordinates instead of pasting into terminal first column");
    const adapter = if (w.ax.adapter) |*value| value else return error.SidebarMissingAccessibility;
    var terminal_count: usize = 0;
    var search_count: usize = 0;
    var tab_count: usize = 0;
    for (adapter.snapshot.nodes[0..adapter.snapshot.count]) |node| {
        if (node.role == .terminal or node.role == .pane or node.role == .scrollbar) {
            try check(inside(rects.content, node.bounds.x, node.bounds.y, node.bounds.width, node.bounds.height), "terminal/pane/scrollbar AX bounds use final content offset");
            if (node.role == .terminal) terminal_count += 1;
        }
        if (node.role == .search) {
            try check(inside(rects.content, node.bounds.x, node.bounds.y, node.bounds.width, node.bounds.height), "find query AX bounds remain inside content rather than covering sidebar");
            search_count += 1;
        }
        if (node.role == .tab) {
            try check(inside(rects.navigation, node.bounds.x, node.bounds.y, node.bounds.width, node.bounds.height), "workspace AX tab bounds match actual sidebar row region");
            tab_count += 1;
        }
    }
    try check(terminal_count == w.drop_pane_count and tab_count > 0 and (!w.search_open or search_count == 1), "postframe AX tree includes each visible shifted terminal and actual sidebar/search controls");
}
