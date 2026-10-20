const std = @import("std");
const ax = @import("accessibility.zig");
extern "c" fn lt_ax_test_node(*ax.Native, u64) ?*const ax.WireNode;
extern "c" fn lt_ax_test_invoke(*ax.Native, u64, u32) c_int;
extern "c" fn lt_ax_test_attached() c_uint;
extern "c" fn lt_ax_test_detached() c_uint;
extern "c" fn lt_ax_scalars([*]const u8, usize) usize;
extern "c" fn lt_ax_byte_at([*]const u8, usize, usize) usize;
const Sink = struct {
    id: u64 = 0,
    action: u32 = 0,
    fn callback(context: ?*anyopaque, id: u64, action: u32) callconv(.c) c_int {
        const self: *Sink = @ptrCast(@alignCast(context.?));
        self.* = .{ .id = id, .action = action };
        return 1;
    }
};
test "native transaction owns text, rejects stale routes and rolls back backend failure" {
    var sink = Sink{};
    const before_attach = lt_ax_test_attached();
    const before_detach = lt_ax_test_detached();
    const bridge = ax.lt_ax_attach(@ptrFromInt(1), Sink.callback, &sink).?;
    var snapshot = ax.Snapshot{};
    try snapshot.add(.{ .id = 10, .label = "Root" });
    try snapshot.add(.{ .id = 22, .parent = 10, .role = .terminal, .state = ax.State.enabled | ax.State.visible | ax.State.focusable, .actions = @backingInt(ax.Action.copy), .value = "A中🙂", .caret = 8, .selection_start = 1, .selection_end = 4 });
    var storage: [ax.max_nodes]ax.WireNode = undefined;
    const input = snapshot.wire(&storage);
    try std.testing.expectEqual(@as(c_int, 0), ax.lt_ax_update(bridge, input.ptr, input.len, 0));
    @memset(&snapshot.bytes, 'x');
    const owned = lt_ax_test_node(bridge, 22).?;
    try std.testing.expectEqualStrings("A中🙂", owned.value[0..owned.value_len]);
    try std.testing.expectEqual(@as(c_int, 1), lt_ax_test_invoke(bridge, 22, @backingInt(ax.Action.copy)));
    try std.testing.expectEqual(@as(u64, 22), sink.id);
    try std.testing.expectEqual(@as(c_int, 0), lt_ax_test_invoke(bridge, 22, @backingInt(ax.Action.press)));
    try std.testing.expectEqual(@as(c_int, 0), lt_ax_test_invoke(bridge, 999, @backingInt(ax.Action.copy)));
    var next = ax.Snapshot{};
    try next.add(.{ .id = 10, .label = "Root" });
    try next.add(.{ .id = 33, .parent = 10, .role = .button, .actions = @backingInt(ax.Action.press), .label = "Next" });
    const replacement = next.wire(&storage);
    try std.testing.expectEqual(@as(c_int, -2), ax.lt_ax_update(bridge, replacement.ptr, replacement.len, 0x80000000));
    try std.testing.expect(lt_ax_test_node(bridge, 22) != null);
    try std.testing.expect(lt_ax_test_node(bridge, 33) == null);
    try std.testing.expectEqual(@as(c_int, 0), ax.lt_ax_update(bridge, replacement.ptr, replacement.len, 0));
    try std.testing.expectEqual(@as(c_int, 0), lt_ax_test_invoke(bridge, 22, @backingInt(ax.Action.copy)));
    try std.testing.expectEqual(@as(c_int, 1), lt_ax_test_invoke(bridge, 33, @backingInt(ax.Action.press)));
    ax.lt_ax_detach(bridge);
    try std.testing.expectEqual(before_attach + 1, lt_ax_test_attached());
    try std.testing.expectEqual(before_detach + 1, lt_ax_test_detached());
}
test "native validation mirrors byte boundaries, capacity and modal action isolation" {
    var sink = Sink{};
    const bridge = ax.lt_ax_attach(@ptrFromInt(1), Sink.callback, &sink).?;
    defer ax.lt_ax_detach(bridge);
    var model = ax.Snapshot{};
    try model.add(.{ .id = 1 });
    try model.add(.{ .id = 2, .parent = 1, .role = .terminal, .actions = @backingInt(ax.Action.copy), .value = "中" });
    try model.add(.{ .id = 3, .parent = 1, .role = .dialog, .state = ax.State.enabled | ax.State.visible | ax.State.modal });
    try model.add(.{ .id = 4, .parent = 3, .role = .button, .actions = @backingInt(ax.Action.press) });
    var storage: [ax.max_nodes]ax.WireNode = undefined;
    const nodes = model.wire(&storage);
    try std.testing.expectEqual(@as(c_int, 0), ax.lt_ax_update(bridge, nodes.ptr, nodes.len, 0));
    try std.testing.expectEqual(@as(c_int, 0), lt_ax_test_invoke(bridge, 2, @backingInt(ax.Action.copy)));
    try std.testing.expectEqual(@as(c_int, 1), lt_ax_test_invoke(bridge, 4, @backingInt(ax.Action.press)));
    storage[1].caret = 1;
    try std.testing.expectEqual(@as(c_int, -1), ax.lt_ax_update(bridge, &storage, nodes.len, 0));
    storage[1].caret = 0;
    storage[2].parent = 999;
    try std.testing.expectEqual(@as(c_int, -1), ax.lt_ax_update(bridge, &storage, nodes.len, 0));
    try std.testing.expectEqual(@as(c_int, -1), ax.lt_ax_update(bridge, &storage, ax.max_nodes + 1, 0));
    try std.testing.expect(lt_ax_test_node(bridge, 4) != null);
}

test "ATK character offsets preserve CJK, combining marks and emoji byte ranges" {
    const text = "A中e\u{0301}🙂";
    try std.testing.expectEqual(@as(usize, 5), lt_ax_scalars(text, text.len));
    try std.testing.expectEqual(@as(usize, 4), lt_ax_byte_at(text, text.len, 2));
    try std.testing.expectEqual(@as(usize, text.len), lt_ax_byte_at(text, text.len, 5));
    try std.testing.expectEqual(@as(usize, text.len), lt_ax_byte_at(text, text.len, 100));
}

test "native focus validation rejects hidden ancestry and modal escape transactionally" {
    var sink = Sink{};
    const bridge = ax.lt_ax_attach(@ptrFromInt(1), Sink.callback, &sink).?;
    defer ax.lt_ax_detach(bridge);
    var model = ax.Snapshot{};
    try model.add(.{ .id = 1 });
    try model.add(.{ .id = 2, .parent = 1 });
    try model.add(.{ .id = 3, .parent = 2, .role = .button, .state = ax.State.enabled | ax.State.visible | ax.State.focusable | ax.State.focused, .actions = @backingInt(ax.Action.press) });
    var storage: [ax.max_nodes]ax.WireNode = undefined;
    const nodes = model.wire(&storage);
    try std.testing.expectEqual(@as(c_int, 0), ax.lt_ax_update(bridge, nodes.ptr, nodes.len, 0));
    storage[1].state &= ~ax.State.visible;
    try std.testing.expectEqual(@as(c_int, -1), ax.lt_ax_update(bridge, &storage, nodes.len, 0));
    try std.testing.expectEqual(@as(c_int, 1), lt_ax_test_invoke(bridge, 3, @backingInt(ax.Action.press)));
    storage[1].state |= ax.State.visible;
    storage[1].state &= ~ax.State.enabled;
    try std.testing.expectEqual(@as(c_int, -1), ax.lt_ax_update(bridge, &storage, nodes.len, 0));
    storage[1].state |= ax.State.enabled;
    storage[3] = storage[1];
    storage[3].id = 4;
    storage[3].state |= ax.State.modal;
    try std.testing.expectEqual(@as(c_int, -1), ax.lt_ax_update(bridge, &storage, nodes.len + 1, 0));
    try std.testing.expect(lt_ax_test_node(bridge, 4) == null);
    storage[2].state &= ~ax.State.focused;
    try std.testing.expectEqual(@as(c_int, 0), ax.lt_ax_update(bridge, &storage, nodes.len + 1, 0));
    try std.testing.expectEqual(@as(c_int, 0), lt_ax_test_invoke(bridge, 3, @backingInt(ax.Action.press)));
}
