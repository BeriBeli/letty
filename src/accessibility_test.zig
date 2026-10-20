const std = @import("std");
const ax = @import("accessibility.zig");
const active = ax.State.enabled | ax.State.visible | ax.State.focusable;
test "semantic snapshots own labels and visible Unicode text after input mutation" {
    var snapshot = ax.Snapshot{};
    try snapshot.add(.{ .id = 1, .label = "Letty" });
    var text = [_]u8{ 'A', 0xe4, 0xb8, 0xad, 0xf0, 0x9f, 0x99, 0x82 };
    try snapshot.add(.{ .id = 2, .parent = 1, .role = .terminal, .state = active | ax.State.focused | ax.State.read_only, .actions = @backingInt(ax.Action.copy) | @backingInt(ax.Action.focus), .label = "Terminal", .value = &text, .caret = 8, .selection_start = 1, .selection_end = 4 });
    @memset(&text, 'x');
    try std.testing.expectEqualStrings("A中🙂", snapshot.value(snapshot.find(2).?.*));
    try std.testing.expectEqual(@as(u64, 2), snapshot.focused());
    var wire: [ax.max_nodes]ax.WireNode = undefined;
    const nodes = snapshot.wire(&wire);
    try std.testing.expectEqualStrings("A中🙂", nodes[1].value[0..nodes[1].value_len]);
    try std.testing.expectEqual(@as(u32, 1), nodes[1].selection_start);
    try std.testing.expectEqual(@as(u32, 4), nodes[1].selection_end);
}
test "IDs, hierarchy, UTF-8 ranges and focus are validated without partial mutation" {
    var snapshot = ax.Snapshot{};
    try std.testing.expectError(error.InvalidAccessibilityRoot, snapshot.add(.{ .id = 1, .parent = 2 }));
    try snapshot.add(.{ .id = 1 });
    const used = snapshot.used;
    try std.testing.expectError(error.InvalidAccessibilityId, snapshot.add(.{ .id = 1, .parent = 1 }));
    try std.testing.expectError(error.InvalidAccessibilityParent, snapshot.add(.{ .id = 3, .parent = 4 }));
    try std.testing.expectError(error.InvalidAccessibilityRange, snapshot.add(.{ .id = 3, .parent = 1, .value = "中", .caret = 1 }));
    try std.testing.expectError(error.InvalidAccessibilityText, snapshot.add(.{ .id = 3, .parent = 1, .value = "a\x00b" }));
    try std.testing.expectError(error.InvalidAccessibilityFocus, snapshot.add(.{ .id = 3, .parent = 1, .state = ax.State.focused }));
    try std.testing.expectEqual(@as(usize, 1), snapshot.count);
    try std.testing.expectEqual(used, snapshot.used);
    try snapshot.add(.{ .id = 3, .parent = 1, .state = active | ax.State.focused });
    try std.testing.expectError(error.InvalidAccessibilityFocus, snapshot.add(.{ .id = 4, .parent = 1, .state = active | ax.State.focused }));
}
test "modal keyboard traversal excludes underlying terminal and disabled controls" {
    var snapshot = ax.Snapshot{};
    try snapshot.add(.{ .id = 1 });
    try snapshot.add(.{ .id = 2, .parent = 1, .role = .terminal, .state = active, .actions = @backingInt(ax.Action.copy) });
    try snapshot.add(.{ .id = 3, .parent = 1, .role = .dialog, .state = ax.State.enabled | ax.State.visible | ax.State.modal });
    try snapshot.add(.{ .id = 4, .parent = 3, .role = .button, .state = active, .actions = @backingInt(ax.Action.press) });
    try snapshot.add(.{ .id = 5, .parent = 3, .role = .button, .state = ax.State.visible | ax.State.focusable });
    try snapshot.add(.{ .id = 6, .parent = 3, .role = .button, .state = active });
    try std.testing.expectEqual(@as(?u64, 4), snapshot.nextFocusable(2, false));
    try std.testing.expectEqual(@as(?u64, 6), snapshot.nextFocusable(4, false));
    try std.testing.expectEqual(@as(?u64, 4), snapshot.nextFocusable(6, false));
    try std.testing.expectEqual(@as(?u64, 6), snapshot.nextFocusable(4, true));
    try std.testing.expect(snapshot.canInvoke(4, .press));
    try std.testing.expect(!snapshot.canInvoke(2, .copy));
    try std.testing.expect(!snapshot.canInvoke(5, .press));
    try std.testing.expect(!snapshot.canInvoke(99, .press));
}
test "controlled updates distinguish text from hierarchy and focus notifications" {
    var previous = ax.Snapshot{};
    try previous.add(.{ .id = 1 });
    try previous.add(.{ .id = 2, .parent = 1, .role = .terminal, .state = active | ax.State.focused, .value = "old" });
    var current = ax.Snapshot{};
    try current.add(.{ .id = 1 });
    try current.add(.{ .id = 2, .parent = 1, .role = .terminal, .state = active | ax.State.focused, .value = "new output" });
    const change = current.changes(&previous);
    try std.testing.expect(change.value);
    try std.testing.expect(!change.tree and !change.focus and !change.geometry);
    try std.testing.expectEqual(ax.Change{}, current.changes(&current));
}
test "node, text, total bytes and visible-prefix truncation are bounded" {
    var snapshot = ax.Snapshot{};
    try snapshot.add(.{ .id = 1 });
    for (2..ax.max_nodes + 1) |id| try snapshot.add(.{ .id = @intCast(id), .parent = 1 });
    try std.testing.expectError(error.AccessibilityNodeLimit, snapshot.add(.{ .id = 999, .parent = 1 }));
    var long: [ax.max_value + 4]u8 = @splat('x');
    @memcpy(long[ax.max_value - 1 ..][0..3], "中");
    const prefix = try ax.visiblePrefix(&long);
    try std.testing.expect(prefix.truncated);
    try std.testing.expectEqual(@as(usize, ax.max_value - 1), prefix.text.len);
    var bytes = ax.Snapshot{};
    try bytes.add(.{ .id = 1 });
    try std.testing.expectError(error.AccessibilityTextLimit, bytes.add(.{ .id = 2, .parent = 1, .value = &long }));
    @memset(&long, 'x');
    for (2..5) |id| try bytes.add(.{ .id = @intCast(id), .parent = 1, .value = long[0..ax.max_value] });
    try std.testing.expectError(error.AccessibilityByteLimit, bytes.add(.{ .id = 5, .parent = 1, .value = long[0..ax.max_value] }));
}
