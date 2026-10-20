//! Test adapter only. This file never calls native capability/open/register.
const std = @import("std");
const hotkey = @import("global_hotkey.zig");
const Fake = struct {
    const Registration = struct { key: u32, token: u64, handle: u64 };
    registrations: [64]?Registration = @splat(null),
    next_handle: u64 = 1,
    adds: usize = 0,
    removes: usize = 0,
    shutdowns: usize = 0,
    conflict_key: ?u32 = null,
    blocked_remove: ?u64 = null,
    last_id: u32 = 0,
    deliveries: usize = 0,
    fn adapter(self: *Fake) hotkey.Adapter {
        return .{ .context = self, .add = add, .remove = remove, .shutdown = shutdown };
    }
    fn from(context: ?*anyopaque) *Fake {
        return @ptrCast(@alignCast(context.?));
    }
    fn add(context: ?*anyopaque, chord: hotkey.Chord, token: u64) hotkey.RegisterError!u64 {
        const self = from(context);
        self.adds += 1;
        if (self.conflict_key != null and self.conflict_key.? == chord.key) return error.Conflict;
        for (&self.registrations) |*entry| if (entry.* == null) {
            const handle = self.next_handle;
            self.next_handle += 1;
            entry.* = .{ .key = chord.key, .token = token, .handle = handle };
            return handle;
        };
        return error.Limit;
    }
    fn remove(context: ?*anyopaque, handle: u64) bool {
        const self = from(context);
        self.removes += 1;
        if (self.blocked_remove != null and self.blocked_remove.? == handle) return false;
        for (&self.registrations) |*entry| if (entry.* != null and entry.*.?.handle == handle) {
            entry.* = null;
            return true;
        };
        return false;
    }
    fn shutdown(context: ?*anyopaque) void {
        const self = from(context);
        self.shutdowns += 1;
        self.registrations = @splat(null);
    }
    fn delivered(context: ?*anyopaque, id: u32) void {
        const self = from(context);
        self.last_id = id;
        self.deliveries += 1;
    }
    fn live(self: *const Fake) usize {
        var count: usize = 0;
        for (self.registrations) |entry| if (entry != null) {
            count += 1;
        };
        return count;
    }
};
fn binding(id: u32, key: u32) hotkey.Binding {
    return .{ .id = id, .chord = .{ .key = key, .modifiers = hotkey.ctrl | hotkey.alt } };
}

test "failed replacement removes staged grabs and retains every old action target" {
    var fake: Fake = .{};
    var manager = hotkey.Manager.init(fake.adapter(), Fake.delivered, &fake);
    defer manager.deinit();
    _ = try manager.replace(&.{ binding(1, 'a'), binding(2, 'b') });
    const old_a = manager.entries[0].token;
    const old_b = manager.entries[1].token;
    fake.conflict_key = 'x';
    try std.testing.expectError(error.Conflict, manager.replace(&.{ binding(3, 'c'), binding(4, 'x') }));
    try std.testing.expectEqual(@as(usize, 2), fake.live());
    manager.dispatch(old_a);
    try std.testing.expectEqual(@as(u32, 1), fake.last_id);
    manager.dispatch(old_b);
    try std.testing.expectEqual(@as(u32, 2), fake.last_id);
    const deliveries = fake.deliveries;
    manager.dispatch(manager.next_token - 2); // removed staged c
    try std.testing.expectEqual(deliveries, fake.deliveries);
    try std.testing.expectEqualStrings("Conflict", manager.lastError());
}
test "same chord action changes and ID swaps reuse registrations without transient conflicts" {
    var fake: Fake = .{};
    var manager = hotkey.Manager.init(fake.adapter(), Fake.delivered, &fake);
    defer manager.deinit();
    _ = try manager.replace(&.{ binding(1, 'a'), binding(2, 'b') });
    const a = manager.entries[0].token;
    const b = manager.entries[1].token;
    _ = try manager.replace(&.{ binding(2, 'a'), binding(1, 'b') });
    try std.testing.expectEqual(@as(usize, 2), fake.adds);
    try std.testing.expectEqual(@as(usize, 0), fake.removes);
    manager.dispatch(a);
    try std.testing.expectEqual(@as(u32, 2), fake.last_id);
    manager.dispatch(b);
    try std.testing.expectEqual(@as(u32, 1), fake.last_id);
}
test "successful replacement removes old grabs and stale native tokens cannot dispatch" {
    var fake: Fake = .{};
    var manager = hotkey.Manager.init(fake.adapter(), Fake.delivered, &fake);
    _ = try manager.replace(&.{binding(7, 'a')});
    const old = manager.entries[0].token;
    _ = try manager.replace(&.{binding(8, 'b')});
    manager.dispatch(old);
    try std.testing.expectEqual(@as(usize, 0), fake.deliveries);
    manager.dispatch(manager.entries[0].token);
    try std.testing.expectEqual(@as(u32, 8), fake.last_id);
    _ = try manager.replace(&.{});
    try std.testing.expectEqual(@as(usize, 0), fake.live());
    manager.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.shutdowns);
    manager.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.shutdowns);
}
test "validation rejects ambiguous or unsafe declarations before any native call" {
    var fake: Fake = .{};
    var manager = hotkey.Manager.init(fake.adapter(), Fake.delivered, &fake);
    defer manager.deinit();
    try std.testing.expectError(error.DuplicateId, manager.replace(&.{ binding(1, 'a'), binding(1, 'b') }));
    try std.testing.expectError(error.DuplicateChord, manager.replace(&.{ binding(1, 'a'), binding(2, 'A') }));
    try std.testing.expectError(error.Invalid, manager.replace(&.{.{ .id = 1, .chord = .{ .key = 'p', .modifiers = hotkey.shift } }}));
    try std.testing.expectError(error.Invalid, manager.replace(&.{binding(0, 'a')}));
    try std.testing.expectError(error.Invalid, manager.replace(&.{binding(1, 0xd800)}));
    try std.testing.expectEqual(@as(usize, 0), fake.adds);
}
test "failed OS cleanup is muted, surfaced and retried before another transaction" {
    var fake: Fake = .{};
    var manager = hotkey.Manager.init(fake.adapter(), Fake.delivered, &fake);
    defer manager.deinit();
    _ = try manager.replace(&.{binding(1, 'a')});
    const old = manager.entries[0];
    fake.blocked_remove = old.handle;
    const commit = try manager.replace(&.{binding(2, 'b')});
    try std.testing.expectEqual(@as(usize, 1), commit.cleanup_pending);
    manager.dispatch(old.token);
    try std.testing.expectEqual(@as(usize, 0), fake.deliveries);
    try std.testing.expectError(error.CleanupPending, manager.replace(&.{binding(3, 'c')}));
    try std.testing.expectEqual(@as(usize, 2), fake.adds);
    fake.blocked_remove = null;
    _ = try manager.replace(&.{binding(3, 'c')});
    try std.testing.expectEqual(@as(usize, 1), fake.live());
    try std.testing.expectEqual(@as(usize, 0), manager.orphan_count);
}
test "independent managers route only their own scalar action identities and own copies" {
    var first: Fake = .{};
    var second: Fake = .{};
    var a = hotkey.Manager.init(first.adapter(), Fake.delivered, &first);
    defer a.deinit();
    var b = hotkey.Manager.init(second.adapter(), Fake.delivered, &second);
    defer b.deinit();
    var declarations = [_]hotkey.Binding{binding(41, 'a')};
    _ = try a.replace(&declarations);
    declarations[0] = binding(99, 'z');
    _ = try b.replace(&.{binding(51, 'b')});
    a.dispatch(a.entries[0].token);
    b.dispatch(b.entries[0].token);
    try std.testing.expectEqual(@as(u32, 41), first.last_id);
    try std.testing.expectEqual(@as(u32, 51), second.last_id);
}
test "full-capacity replacement stages both sets and unregisters everything at teardown" {
    var fake: Fake = .{};
    var manager = hotkey.Manager.init(fake.adapter(), Fake.delivered, &fake);
    var previous: [hotkey.max_bindings]hotkey.Binding = undefined;
    var next: [hotkey.max_bindings]hotkey.Binding = undefined;
    for (&previous, &next, 0..) |*old, *new, index| {
        old.* = binding(@intCast(index + 1), @intCast(0x100 + index));
        new.* = binding(@intCast(index + 101), @intCast(0x200 + index));
    }
    _ = try manager.replace(&previous);
    _ = try manager.replace(&next);
    try std.testing.expectEqual(@as(usize, hotkey.max_bindings), fake.live());
    manager.deinit();
    try std.testing.expectEqual(@as(usize, 0), fake.live());
    try std.testing.expectEqual(@as(usize, hotkey.max_bindings * 2), fake.removes);
}

test "failed rollback keeps old actions and tracks only muted cleanup registrations" {
    var fake: Fake = .{};
    var manager = hotkey.Manager.init(fake.adapter(), Fake.delivered, &fake);
    defer manager.deinit();
    _ = try manager.replace(&.{binding(1, 'a')});
    const old = manager.entries[0].token;
    fake.blocked_remove = fake.next_handle;
    fake.conflict_key = 'x';
    try std.testing.expectError(error.Conflict, manager.replace(&.{ binding(2, 'b'), binding(3, 'x') }));
    try std.testing.expectEqual(@as(usize, 1), manager.orphan_count);
    try std.testing.expectEqual(@as(usize, 1), manager.count);
    manager.dispatch(old);
    try std.testing.expectEqual(@as(u32, 1), fake.last_id);
    const deliveries = fake.deliveries;
    manager.dispatch(manager.next_token - 2);
    try std.testing.expectEqual(deliveries, fake.deliveries);
    fake.blocked_remove = null;
    fake.conflict_key = null;
    _ = try manager.replace(&.{binding(4, 'c')});
    try std.testing.expectEqual(@as(usize, 1), fake.live());
}
