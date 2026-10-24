//! Stable local navigation order; moving a row never transfers PTY ownership.
const std = @import("std");
pub fn move(comptime T: type, items: []T, source: u64, target: u64, after: bool) bool {
    var from: ?usize = null;
    var to: ?usize = null;
    for (items, 0..) |item, i| {
        if (item.id == source) from = i;
        if (item.id == target) to = i;
    }
    const first = from orelse return false;
    const last = to orelse return false;
    if (first == last) return false;
    const insertion = last + @intFromBool(after);
    const destination = insertion - @intFromBool(first < insertion);
    const owned = items[first];
    if (destination > first) std.mem.copyForwards(T, items[first..destination], items[first + 1 .. destination + 1]) else if (destination < first) std.mem.copyBackwards(T, items[destination + 1 .. first + 1], items[destination..first]) else return false;
    items[destination] = owned;
    return true;
}
pub fn project(comptime T: type, a: std.mem.Allocator, items: []T, source: u64, target: u64, after: bool) !bool {
    var from: ?[]const u8 = null;
    var to: ?[]const u8 = null;
    for (items) |item| {
        if (item.id == source) from = item.directory;
        if (item.id == target) to = item.directory;
    }
    const first = from orelse return false;
    const last = to orelse return false;
    if (std.mem.eql(u8, first, last)) return false;
    const result = try a.alloc(T, items.len);
    defer a.free(result);
    var count: usize = 0;
    for (items, 0..) |item, i| {
        if (std.mem.eql(u8, item.directory, first)) continue;
        var seen = false;
        for (items[0..i]) |prior| if (std.mem.eql(u8, prior.directory, item.directory)) {
            seen = true;
            break;
        };
        if (seen) continue;
        const destination = std.mem.eql(u8, item.directory, last);
        if (destination and !after) appendGroup(T, items, result, &count, first);
        appendGroup(T, items, result, &count, item.directory);
        if (destination and after) appendGroup(T, items, result, &count, first);
    }
    std.debug.assert(count == items.len);
    @memcpy(items, result);
    return true;
}
fn appendGroup(comptime T: type, items: []const T, result: []T, count: *usize, directory: []const u8) void {
    for (items) |item| if (std.mem.eql(u8, item.directory, directory)) {
        result[count.*] = item;
        count.* += 1;
    };
}
test "sidebar ordering retains noncontiguous project members and stable identities" {
    const Item = struct { id: u64, directory: []const u8 };
    var rows = [_]Item{ .{ .id = 1, .directory = "a" }, .{ .id = 2, .directory = "b" }, .{ .id = 3, .directory = "a" }, .{ .id = 4, .directory = "c" } };
    try std.testing.expect(try project(Item, std.testing.allocator, &rows, 1, 4, true));
    try std.testing.expectEqual(@as(u64, 2), rows[0].id);
    try std.testing.expectEqual(@as(u64, 4), rows[1].id);
    try std.testing.expectEqual(@as(u64, 1), rows[2].id);
    try std.testing.expectEqual(@as(u64, 3), rows[3].id);
    try std.testing.expect(move(Item, &rows, 3, 1, false));
    try std.testing.expectEqual(@as(u64, 3), rows[2].id);
    try std.testing.expect(!move(Item, &rows, 99, 1, true));
    try std.testing.expect(!try project(Item, std.testing.allocator, &rows, 1, 3, false));
}
