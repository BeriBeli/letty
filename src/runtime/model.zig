//! In-process terminal/workspace values adapted from Kero internal/proto. No IPC or Mirror.
const std = @import("std");
pub const Status = enum { idle, working, waiting, @"error", exited };
pub const Record = struct {
    id: []const u8 = "",
    state: []const u8,
    kind: []const u8 = "",
    progress: i32 = -1,
    app: []const u8 = "",
    title: []const u8 = "",
    msg: []const u8 = "",
    updated: i64 = 0,
};
pub const Layout = struct {
    pane: []const u8 = "",
    row: bool = false,
    ratio: f64 = 0.5,
    a: ?*Layout = null,
    b: ?*Layout = null,
    pub fn leaf(self: Layout) bool {
        return self.a == null and self.b == null;
    }
    pub fn contains(self: *const Layout, id: []const u8) bool {
        if (self.leaf()) return std.mem.eql(u8, self.pane, id);
        return (if (self.a) |a| a.contains(id) else false) or (if (self.b) |b| b.contains(id) else false);
    }
    pub fn clone(self: *const Layout, alloc: std.mem.Allocator) !*Layout {
        const p = try alloc.create(Layout);
        errdefer alloc.destroy(p);
        p.* = .{ .pane = try alloc.dupe(u8, self.pane), .row = self.row, .ratio = self.ratio };
        errdefer alloc.free(p.pane);
        if (self.a) |a| p.a = try a.clone(alloc);
        errdefer if (p.a) |a| a.deinit(alloc);
        if (self.b) |b| p.b = try b.clone(alloc);
        return p;
    }
    pub fn deinit(self: *Layout, alloc: std.mem.Allocator) void {
        if (self.a) |a| a.deinit(alloc);
        if (self.b) |b| b.deinit(alloc);
        alloc.free(self.pane);
        alloc.destroy(self);
    }
    pub fn remove(self: *Layout, alloc: std.mem.Allocator, id: []const u8) ?*Layout {
        if (self.leaf()) {
            if (std.mem.eql(u8, self.pane, id)) {
                self.deinit(alloc);
                return null;
            }
            return self;
        }
        if (self.a) |a| self.a = a.remove(alloc, id);
        if (self.b) |b| self.b = b.remove(alloc, id);
        if (self.a == null or self.b == null) {
            const survivor = self.a orelse self.b;
            alloc.free(self.pane);
            alloc.destroy(self);
            return survivor;
        }
        return self;
    }
    pub fn replace(self: *Layout, alloc: std.mem.Allocator, old: []const u8, replacement: []const u8) !bool {
        if (self.leaf()) {
            if (!std.mem.eql(u8, self.pane, old)) return false;
            const name = try alloc.dupe(u8, replacement);
            alloc.free(self.pane);
            self.pane = name;
            return true;
        }
        if (self.a) |left| if (try left.replace(alloc, old, replacement)) return true;
        if (self.b) |right| return right.replace(alloc, old, replacement);
        return false;
    }
    pub fn split(self: *Layout, alloc: std.mem.Allocator, at: []const u8, id: []const u8, direction: []const u8, ratio_in: f64) !bool {
        if (!self.leaf()) {
            if (self.a) |a| if (try a.split(alloc, at, id, direction, ratio_in)) return true;
            if (self.b) |b| return b.split(alloc, at, id, direction, ratio_in);
            return false;
        }
        if (!std.mem.eql(u8, self.pane, at)) return false;
        const old = try alloc.create(Layout);
        errdefer alloc.destroy(old);
        const nu = try alloc.create(Layout);
        errdefer alloc.destroy(nu);
        const name = try alloc.dupe(u8, id);
        errdefer alloc.free(name);
        const empty = try alloc.dupe(u8, "");
        const ratio = if (std.math.isFinite(ratio_in) and ratio_in > 0 and ratio_in < 1) ratio_in else 0.5;
        const before = std.mem.eql(u8, direction, "left") or std.mem.eql(u8, direction, "up");
        old.* = self.*;
        nu.* = .{ .pane = name };
        self.* = .{ .pane = empty, .row = std.mem.eql(u8, direction, "left") or std.mem.eql(u8, direction, "right"), .ratio = if (before) ratio else 1 - ratio, .a = if (before) nu else old, .b = if (before) old else nu };
        return true;
    }
};
test "Letty split direction and ratio, deep clone ownership" {
    const a = std.testing.allocator;
    var root = try a.create(Layout);
    root.* = .{ .pane = try a.dupe(u8, "p1") };
    defer root.deinit(a);
    try std.testing.expect(try root.split(a, "p1", "p2", "left", 0.3));
    try std.testing.expect(root.row and root.contains("p2"));
    try std.testing.expectEqualStrings("p2", root.a.?.pane);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), root.ratio, 0.0001);
    const copy = try root.clone(a);
    defer copy.deinit(a);
    try std.testing.expect(try root.split(a, "p2", "p3", "down", 0.5));
    try std.testing.expect(!copy.contains("p3"));
}

test "closing one split retains its sibling and stable pane identity" {
    const a = std.testing.allocator;
    var root = try a.create(Layout);
    root.* = .{ .pane = try a.dupe(u8, "one") };
    try std.testing.expect(try root.split(a, "one", "two", "right", 0.5));
    root = root.remove(a, "one").?;
    defer root.deinit(a);
    try std.testing.expect(root.leaf());
    try std.testing.expectEqualStrings("two", root.pane);
}
