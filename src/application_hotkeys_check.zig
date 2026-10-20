//! Standalone Fake tests only. The exported ABI shims deliberately cannot open
//! any OS backend and must never be imported into the application build.
const std = @import("std");
const service = @import("application_hotkeys.zig");
const hotkey = @import("global_hotkey.zig");
const actions = @import("actions.zig");

var opens: usize = 0;
export fn lt_hotkey_open(_: *const fn (?*anyopaque, u64) callconv(.c) void, _: ?*anyopaque, _: [*]u8, _: usize) ?*anyopaque {
    opens += 1;
    return null;
}
export fn lt_hotkey_register(_: *anyopaque, _: u32, _: u32, _: u64, _: *u64) c_int {
    return 5;
}
export fn lt_hotkey_unregister(_: *anyopaque, _: u64) c_int {
    return 5;
}
export fn lt_hotkey_last_error(_: *const anyopaque) [*:0]const u8 {
    return "test backend never opens";
}
export fn lt_hotkey_close(_: *anyopaque) void {}

const Fake = struct {
    const Registration = struct { key: u32, token: u64, handle: u64 };
    slots: [64]?Registration = @splat(null),
    next: u64 = 1,
    adds: usize = 0,
    removes: usize = 0,
    shutdowns: usize = 0,
    conflict: ?u32 = null,
    blocked: ?u64 = null,
    manager: ?*service.Manager = null,
    during_mutation: ?u64 = null,
    reenter: bool = false,
    reentrant_errors: usize = 0,
    delivered: usize = 0,
    queued: actions.Request = .{},

    fn from(ctx: ?*anyopaque) *Fake {
        return @ptrCast(@alignCast(ctx.?));
    }
    fn adapter(f: *Fake) hotkey.Adapter {
        return .{ .context = f, .add = add, .remove = remove, .shutdown = shutdown };
    }
    fn add(ctx: ?*anyopaque, chord: hotkey.Chord, event_token: u64) hotkey.RegisterError!u64 {
        const f = from(ctx);
        f.adds += 1;
        if (f.during_mutation) |old| f.manager.?.registry.dispatch(old);
        if (f.conflict != null and f.conflict.? == chord.key) return error.Conflict;
        for (&f.slots) |*slot| if (slot.* == null) {
            const handle = f.next;
            f.next += 1;
            slot.* = .{ .key = chord.key, .token = event_token, .handle = handle };
            return handle;
        };
        return error.Limit;
    }
    fn remove(ctx: ?*anyopaque, handle: u64) bool {
        const f = from(ctx);
        f.removes += 1;
        if (f.during_mutation) |old| f.manager.?.registry.dispatch(old);
        if (f.blocked != null and f.blocked.? == handle) return false;
        for (&f.slots) |*slot| if (slot.* != null and slot.*.?.handle == handle) {
            slot.* = null;
            return true;
        };
        return false;
    }
    fn shutdown(ctx: ?*anyopaque) void {
        const f = from(ctx);
        f.shutdowns += 1;
        f.slots = @splat(null);
    }
    fn deliver(ctx: ?*anyopaque, request: *const actions.Request) void {
        const f = from(ctx);
        f.delivered += 1;
        f.queued = request.*; // Host queue must make this copy before returning.
        if (f.reenter) {
            const manager = f.manager.?;
            manager.deinit() catch |err| {
                if (err == error.Reentrant) f.reentrant_errors += 1;
            };
            _ = manager.replace(&.{}) catch |err| {
                if (err == error.Reentrant) f.reentrant_errors += 1;
            };
            manager.registry.dispatch(manager.registry.entries[0].token);
        }
    }
    fn token(f: *const Fake, key: u32) u64 {
        for (f.slots) |slot| if (slot != null and slot.?.key == key) return slot.?.token;
        unreachable;
    }
    fn live(f: *const Fake) usize {
        var count: usize = 0;
        for (f.slots) |slot| if (slot != null) {
            count += 1;
        };
        return count;
    }
};
fn entry(key: u32, action: actions.Action) service.Entry {
    return .{ .chord = .{ .key = key, .modifiers = hotkey.ctrl | hotkey.alt }, .request = .{ .action = action } };
}

test "disabled native startup makes no native call and failed explicit startup stays inert" {
    var manager: service.Manager = .{};
    var fake: Fake = .{};
    opens = 0;
    try std.testing.expect(!try manager.nativeInit(false, Fake.deliver, &fake));
    try std.testing.expectEqual(@as(usize, 0), opens);
    try std.testing.expectError(error.Unavailable, manager.nativeInit(true, Fake.deliver, &fake));
    try std.testing.expectEqual(@as(usize, 1), opens);
    try std.testing.expect(manager.registry.adapter == null);
    try std.testing.expectEqual(@as(usize, 0), manager.count);
    try manager.deinit();
}

test "registration rollback keeps both old owned action targets" {
    var fake: Fake = .{};
    var manager: service.Manager = .{};
    try manager.initAdapter(fake.adapter(), Fake.deliver, &fake);
    defer manager.deinit() catch unreachable;
    _ = try manager.replace(&.{ entry('a', .tab), entry('b', .palette) });
    const a = fake.token('a');
    const b = fake.token('b');
    fake.conflict = 'x';
    try std.testing.expectError(error.Conflict, manager.replace(&.{ entry('c', .quit), entry('x', .close_window) }));
    try std.testing.expectEqual(@as(usize, 2), fake.live());
    try std.testing.expectEqualStrings("Conflict", manager.lastError());
    manager.registry.dispatch(a);
    try std.testing.expectEqual(actions.Action.tab, fake.queued.action);
    manager.registry.dispatch(b);
    try std.testing.expectEqual(actions.Action.palette, fake.queued.action);
}

test "successful reorder and changed actions reuse grabs but publish current request" {
    var fake: Fake = .{};
    var manager: service.Manager = .{};
    try manager.initAdapter(fake.adapter(), Fake.deliver, &fake);
    defer manager.deinit() catch unreachable;
    _ = try manager.replace(&.{ entry('a', .tab), entry('b', .palette) });
    const a = fake.token('a');
    const b = fake.token('b');
    _ = try manager.replace(&.{ entry('b', .quit), entry('a', .close_window) });
    try std.testing.expectEqual(@as(usize, 2), fake.adds);
    manager.registry.dispatch(a);
    try std.testing.expectEqual(actions.Action.close_window, fake.queued.action);
    manager.registry.dispatch(b);
    try std.testing.expectEqual(actions.Action.quit, fake.queued.action);
    _ = try manager.replace(&.{entry('a', .ignore)});
    const before = fake.delivered;
    manager.registry.dispatch(b);
    try std.testing.expectEqual(before, fake.delivered);
}

test "Unicode ESC NUL and backslash survive config arena and input destruction" {
    var fake: Fake = .{};
    var manager: service.Manager = .{};
    try manager.initAdapter(fake.adapter(), Fake.deliver, &fake);
    defer manager.deinit() catch unreachable;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const source = try arena.allocator().dupe(u8, "text:中e\\u{301}\\\\\\x1b\\x00");
    var candidate = entry('a', .send_bytes);
    candidate.request = try actions.parse(source);
    _ = try manager.replace(&.{candidate});
    candidate.request.args.bytes.data = @splat(0xff);
    arena.deinit();
    manager.registry.dispatch(fake.token('a'));
    try std.testing.expectEqualStrings("中e\xcc\x81\\\x1b\x00", fake.queued.args.bytes.bytes());
    _ = try manager.replace(&.{});
    try std.testing.expectEqualStrings("中e\xcc\x81\\\x1b\x00", fake.queued.args.bytes.bytes());
}

test "callbacks during replacement are muted and callback mutation destruction recursion rejected" {
    var fake: Fake = .{};
    var manager: service.Manager = .{};
    fake.manager = &manager;
    try manager.initAdapter(fake.adapter(), Fake.deliver, &fake);
    defer manager.deinit() catch unreachable;
    _ = try manager.replace(&.{entry('a', .tab)});
    fake.during_mutation = fake.token('a');
    _ = try manager.replace(&.{entry('b', .quit)});
    try std.testing.expectEqual(@as(usize, 0), fake.delivered);
    try std.testing.expect(manager.muted_events >= 2);
    fake.during_mutation = null;
    fake.reenter = true;
    manager.registry.dispatch(fake.token('b'));
    try std.testing.expectEqual(@as(usize, 1), fake.delivered);
    try std.testing.expectEqual(@as(usize, 2), fake.reentrant_errors);
    try std.testing.expectEqual(@as(usize, 1), manager.count);
    try std.testing.expectEqual(@as(usize, 0), fake.shutdowns);
}

test "failed native cleanup publishes new table and never dispatches orphan action" {
    var fake: Fake = .{};
    var manager: service.Manager = .{};
    try manager.initAdapter(fake.adapter(), Fake.deliver, &fake);
    defer manager.deinit() catch unreachable;
    _ = try manager.replace(&.{entry('a', .tab)});
    const a = fake.token('a');
    fake.blocked = manager.registry.entries[0].handle;
    const result = try manager.replace(&.{entry('b', .quit)});
    try std.testing.expectEqual(@as(usize, 1), result.cleanup_pending);
    manager.registry.dispatch(a);
    try std.testing.expectEqual(@as(usize, 0), fake.delivered);
    manager.registry.dispatch(fake.token('b'));
    try std.testing.expectEqual(actions.Action.quit, fake.queued.action);
    try std.testing.expectError(error.CleanupPending, manager.replace(&.{}));
    try std.testing.expectEqual(@as(usize, 1), manager.count);
    fake.blocked = null;
    _ = try manager.replace(&.{});
    try std.testing.expectEqual(@as(usize, 0), fake.live());
}

test "typed malformed requests and duplicate chords reject before native changes" {
    var fake: Fake = .{};
    var manager: service.Manager = .{};
    try manager.initAdapter(fake.adapter(), Fake.deliver, &fake);
    defer manager.deinit() catch unreachable;
    const invalid = [_]actions.Request{
        .{},                                                 .{ .action = .unbind },                                                                   .{ .action = .send_bytes },
        .{ .action = .palette, .args = .{ .amount = 2 } },   .{ .action = .font_up, .args = .{ .amount = std.math.nan(f32) } },                        .{ .action = .goto_tab, .args = .{ .index = 0 } },
        .{ .action = .move_tab, .args = .{ .offset = -8 } }, .{ .action = .resize_pane, .args = .{ .resize = .{ .direction = .left, .pixels = 0 } } },
    };
    for (&invalid) |*request| {
        var candidate = entry('a', .tab);
        candidate.request = request.*;
        try std.testing.expectError(error.InvalidRequest, manager.replace(&.{candidate}));
    }
    var overlong = entry('a', .send_bytes);
    overlong.request.args = .{ .bytes = .{ .len = 4097 } };
    try std.testing.expectError(error.InvalidRequest, manager.replace(&.{overlong}));
    try std.testing.expectError(error.DuplicateChord, manager.replace(&.{ entry('a', .tab), entry('A', .quit) }));
    try std.testing.expectEqual(@as(usize, 0), fake.adds);
}

test "manager is explicitly initialized once and deinit disables every callback" {
    var fake: Fake = .{};
    var manager: service.Manager = .{};
    try std.testing.expectError(error.Unavailable, manager.replace(&.{entry('a', .tab)}));
    try manager.initAdapter(fake.adapter(), Fake.deliver, &fake);
    try std.testing.expectError(error.AlreadyInitialized, manager.initAdapter(fake.adapter(), Fake.deliver, &fake));
    _ = try manager.replace(&.{entry('a', .tab)});
    const a = fake.token('a');
    try manager.deinit();
    manager.registry.dispatch(a);
    try std.testing.expectEqual(@as(usize, 0), fake.delivered);
    try std.testing.expectEqual(@as(usize, 1), fake.shutdowns);
    try std.testing.expectEqual(@as(usize, 0), fake.live());
    try manager.deinit();
}

test "fixed capacity rejects excess entries before registration and supports full replacement" {
    var fake: Fake = .{};
    var manager: service.Manager = .{};
    try manager.initAdapter(fake.adapter(), Fake.deliver, &fake);
    defer manager.deinit() catch unreachable;
    var candidates: [service.max_bindings + 1]service.Entry = undefined;
    for (&candidates, 0..) |*candidate, i| candidate.* = entry(@intCast('a' + i), .ignore);
    try std.testing.expectError(error.Limit, manager.replace(&candidates));
    try std.testing.expectEqual(@as(usize, 0), fake.adds);
    _ = try manager.replace(candidates[0..service.max_bindings]);
    try std.testing.expectEqual(service.max_bindings, manager.count);
    for (&candidates, 0..) |*candidate, i| candidate.* = entry(@intCast(0x400 + i), .palette);
    _ = try manager.replace(candidates[0..service.max_bindings]);
    try std.testing.expectEqual(service.max_bindings, fake.live());
    manager.registry.dispatch(fake.token(0x400 + service.max_bindings - 1));
    try std.testing.expectEqual(actions.Action.palette, fake.queued.action);
}

test "independent host managers keep their delivery context and owned requests" {
    var a: Fake = .{};
    var b: Fake = .{};
    var manager_a: service.Manager = .{};
    var manager_b: service.Manager = .{};
    try manager_a.initAdapter(a.adapter(), Fake.deliver, &a);
    defer manager_a.deinit() catch unreachable;
    try manager_b.initAdapter(b.adapter(), Fake.deliver, &b);
    defer manager_b.deinit() catch unreachable;
    _ = try manager_a.replace(&.{entry('a', .tab)});
    _ = try manager_b.replace(&.{entry('a', .quit)});
    manager_a.registry.dispatch(a.token('a'));
    try std.testing.expectEqual(actions.Action.tab, a.queued.action);
    try std.testing.expectEqual(@as(usize, 0), b.delivered);
    manager_b.registry.dispatch(b.token('a'));
    try std.testing.expectEqual(actions.Action.quit, b.queued.action);
}

test "reserved requests keep old routing until no-failure commit and own candidate bytes" {
    var fake: Fake = .{};
    var manager: service.Manager = .{};
    try manager.initAdapter(fake.adapter(), Fake.deliver, &fake);
    defer manager.deinit() catch unreachable;
    _ = try manager.replace(&.{entry('a', .tab)});
    const old = fake.token('a');
    var candidate = entry('b', .send_bytes);
    candidate.request = try actions.parse("text:reserved中\\x00");
    try manager.prepare(&.{candidate});
    candidate.request.args.bytes.data = @splat(0xff);
    const staged = fake.token('b');
    try std.testing.expect(manager.prepared and manager.registry.prepared);
    try std.testing.expectEqual(@as(usize, 1), manager.count);
    manager.registry.dispatch(staged);
    try std.testing.expectEqual(@as(usize, 0), fake.delivered);
    manager.registry.dispatch(old);
    try std.testing.expectEqual(actions.Action.tab, fake.queued.action);
    const adds = fake.adds;
    try std.testing.expectError(error.PreparationPending, manager.prepare(&.{entry('c', .quit)}));
    try std.testing.expectError(error.PreparationPending, manager.replace(&.{}));
    const committed = manager.commitPrepared();
    try std.testing.expectEqual(@as(usize, 0), committed.cleanup_pending);
    try std.testing.expectEqual(adds, fake.adds);
    manager.registry.dispatch(staged);
    try std.testing.expectEqualStrings("reserved中\x00", fake.queued.args.bytes.bytes());
    const delivered = fake.delivered;
    manager.registry.dispatch(old);
    try std.testing.expectEqual(delivered, fake.delivered);
}

test "failed save rollback retires staged token while old registrations and actions remain" {
    var fake: Fake = .{};
    var manager: service.Manager = .{};
    try manager.initAdapter(fake.adapter(), Fake.deliver, &fake);
    defer manager.deinit() catch unreachable;
    _ = try manager.replace(&.{entry('a', .tab)});
    const old = fake.token('a');
    try manager.prepare(&.{ entry('a', .quit), entry('b', .palette) });
    const abandoned = fake.token('b');
    manager.rollbackPrepared();
    manager.rollbackPrepared();
    try std.testing.expect(!manager.prepared and !manager.registry.prepared);
    try std.testing.expectEqual(@as(usize, 1), fake.live());
    manager.registry.dispatch(old);
    try std.testing.expectEqual(actions.Action.tab, fake.queued.action);
    const delivered = fake.delivered;
    manager.registry.dispatch(abandoned);
    try std.testing.expectEqual(delivered, fake.delivered);
    try manager.prepare(&.{entry('b', .ignore)});
    const current = fake.token('b');
    try std.testing.expect(current != abandoned);
    _ = manager.commitPrepared();
    manager.registry.dispatch(abandoned);
    try std.testing.expectEqual(delivered, fake.delivered);
    manager.registry.dispatch(current);
    try std.testing.expectEqual(actions.Action.ignore, fake.queued.action);
}

test "prepared disable and shutdown clean staged and published registrations once" {
    var fake: Fake = .{};
    var manager: service.Manager = .{};
    try manager.initAdapter(fake.adapter(), Fake.deliver, &fake);
    _ = try manager.replace(&.{entry('a', .tab)});
    const old = fake.token('a');
    try manager.prepare(&.{entry('b', .quit)});
    const staged = fake.token('b');
    try manager.deinit();
    manager.registry.dispatch(old);
    manager.registry.dispatch(staged);
    try std.testing.expectEqual(@as(usize, 0), fake.delivered);
    try std.testing.expectEqual(@as(usize, 0), fake.live());
    try std.testing.expectEqual(@as(usize, 1), fake.shutdowns);
    try std.testing.expect(!manager.prepared);
    try manager.initAdapter(fake.adapter(), Fake.deliver, &fake);
    try manager.prepare(&.{});
    _ = manager.commitPrepared();
    try std.testing.expectEqual(@as(usize, 0), manager.count);
    try manager.deinit();
}

test "rollback cleanup failure stays muted and prevents another prepare until cleanup succeeds" {
    var fake: Fake = .{};
    var manager: service.Manager = .{};
    try manager.initAdapter(fake.adapter(), Fake.deliver, &fake);
    defer manager.deinit() catch unreachable;
    _ = try manager.replace(&.{entry('a', .tab)});
    try manager.prepare(&.{entry('b', .quit)});
    const staged = fake.token('b');
    for (fake.slots) |slot| if (slot != null and slot.?.key == 'b') {
        fake.blocked = slot.?.handle;
    };
    manager.rollbackPrepared();
    try std.testing.expectEqual(@as(usize, 1), manager.registry.orphan_count);
    manager.registry.dispatch(staged);
    try std.testing.expectEqual(@as(usize, 0), fake.delivered);
    try std.testing.expectError(error.CleanupPending, manager.prepare(&.{entry('c', .ignore)}));
    fake.blocked = null;
    try manager.prepare(&.{entry('c', .ignore)});
    _ = manager.commitPrepared();
    try std.testing.expectEqual(@as(usize, 1), fake.live());
    try std.testing.expectEqual(@as(usize, 0), manager.registry.orphan_count);
}
