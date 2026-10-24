//! Bounded notification tokens; never retain GUI or terminal pointers.
const std = @import("std");
pub const Target = struct { window: u64, workspace: u64, pane: u64 };
pub const Registry = struct {
    entries: [64]Entry = @splat(.{}),
    serial: u64 = 0,
    pub const Entry = struct { token: u64 = 0, target: Target = .{ .window = 0, .workspace = 0, .pane = 0 }, server: u32 = 0, pending: bool = false };
    pub fn add(self: *Registry, target: Target) ?u64 {
        var slot: ?*Entry = null;
        for (&self.entries) |*entry| if (!entry.pending and (slot == null or entry.token < slot.?.token)) {
            slot = entry;
            if (entry.token == 0) break;
        };
        const entry = slot orelse return null;
        self.serial +%= 1;
        if (self.serial == 0) self.serial = 1;
        entry.* = .{ .token = self.serial, .target = target };
        return entry.token;
    }
    pub fn find(self: *Registry, token: u64) ?*Entry {
        if (token == 0) return null;
        for (&self.entries) |*entry| if (entry.token == token) return entry;
        return null;
    }
    pub fn take(self: *Registry, token: u64) ?Target {
        const entry = self.find(token) orelse return null;
        const target = entry.target;
        entry.* = .{};
        return if (target.pane != 0) target else null;
    }
    pub fn invalidate(self: *Registry, pane: u64) void {
        for (&self.entries) |*entry| if (entry.target.pane == pane) {
            if (entry.pending) entry.target.pane = 0 else entry.* = .{};
        };
    }
};
test "notification routing uses bounded single-use tokens and rejects closed panes" {
    var registry: Registry = .{};
    const token = registry.add(.{ .window = 1, .workspace = 2, .pane = 3 }).?;
    try std.testing.expectEqual(@as(u64, 3), registry.take(token).?.pane);
    try std.testing.expect(registry.take(token) == null);
    const stale = registry.add(.{ .window = 1, .workspace = 2, .pane = 3 }).?;
    registry.invalidate(3);
    try std.testing.expect(registry.take(stale) == null);
    for (&registry.entries) |*entry| {
        const next = registry.add(.{ .window = 4, .workspace = 5, .pane = 6 }).?;
        registry.find(next).?.pending = true;
        _ = entry;
    }
    try std.testing.expect(registry.add(.{ .window = 4, .workspace = 5, .pane = 6 }) == null);
}
