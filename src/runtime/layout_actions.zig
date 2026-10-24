//! Transactional local pane rearrangement. PTYs never move or restart here.
const std = @import("std");
const Layout = @import("model.zig").Layout;
pub const Zone = enum { left, right, up, down, swap };
pub fn zone(u: f32, v: f32) Zone {
    if (u > 0.3 and u < 0.7 and v > 0.3 and v < 0.7) return .swap;
    var result: Zone = .left;
    var best = u;
    const edges = .{ .{ 1 - u, Zone.right }, .{ v, Zone.up }, .{ 1 - v, Zone.down } };
    inline for (edges) |edge| if (edge[0] < best) {
        best = edge[0];
        result = edge[1];
    };
    return result;
}
pub fn first(tree: *const Layout) []const u8 {
    return if (tree.a) |a| first(a) else tree.pane;
}
pub fn ratio(tree: *Layout, left: []const u8, right: []const u8, value: f64) bool {
    if (!std.math.isFinite(value) or tree.leaf()) return false;
    if (tree.a.?.contains(left) and tree.b.?.contains(right)) {
        tree.ratio = std.math.clamp(value, 0.12, 0.88);
        return true;
    }
    return ratio(tree.a.?, left, right, value) or ratio(tree.b.?, left, right, value);
}
fn leaf(tree: *Layout, key: []const u8) ?*Layout {
    if (tree.leaf()) return if (std.mem.eql(u8, tree.pane, key)) tree else null;
    return leaf(tree.a.?, key) orelse leaf(tree.b.?, key);
}
pub fn move(a: std.mem.Allocator, tree: *const Layout, source: []const u8, target: []const u8, where: Zone) !?*Layout {
    if (std.mem.eql(u8, source, target) or !tree.contains(source) or !tree.contains(target)) return null;
    var replacement = try tree.clone(a);
    errdefer replacement.deinit(a);
    if (where == .swap) {
        const left = leaf(replacement, source).?;
        const right = leaf(replacement, target).?;
        std.mem.swap([]const u8, &left.pane, &right.pane);
    } else {
        replacement = replacement.remove(a, source).?;
        if (!try replacement.split(a, target, source, @tagName(where), 0.5)) return error.InvalidLayout;
    }
    return replacement;
}
test "pane rearrangement preserves identities and rolls back all allocation failures" {
    const a = std.testing.allocator;
    const root = try a.create(Layout);
    root.* = .{ .pane = try a.dupe(u8, "one") };
    defer root.deinit(a);
    try std.testing.expect(try root.split(a, "one", "two", "right", 0.5));
    const swapped = (try move(a, root, "one", "two", .swap)).?;
    defer swapped.deinit(a);
    try std.testing.expectEqualStrings("two", swapped.a.?.pane);
    try std.testing.expectEqualStrings("one", root.a.?.pane);
    const moved = (try move(a, root, "one", "two", .down)).?;
    defer moved.deinit(a);
    try std.testing.expect(!moved.row and moved.contains("one") and moved.contains("two"));
    try std.testing.expect(ratio(moved, "two", "one", 0.99));
    try std.testing.expectEqual(@as(f64, 0.88), moved.ratio);
    try std.testing.expect(!ratio(moved, "missing", "one", 0.3));
    try std.testing.checkAllAllocationFailures(a, checkMove, .{});
}
fn checkMove(a: std.mem.Allocator) !void {
    const root = try a.create(Layout);
    const key = a.dupe(u8, "one") catch |err| {
        a.destroy(root);
        return err;
    };
    root.* = .{ .pane = key };
    defer root.deinit(a);
    try std.testing.expect(try root.split(a, "one", "two", "right", 0.5));
    const moved = (try move(a, root, "one", "two", .down)).?;
    defer moved.deinit(a);
}
