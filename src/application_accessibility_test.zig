const std = @import("std");
const app = @import("application_accessibility.zig");
const ax = app.ax;
const active = ax.State.enabled | ax.State.visible | ax.State.focusable;
fn records(text: []const u8) [3]app.Record {
    return .{
        .{ .node = .{ .id = 1, .label = "Window" }, .target = .{ .window = 10 } },
        .{ .node = .{ .id = 2, .parent = 1, .role = .tab, .label = "Shell", .state = active | ax.State.selected, .actions = @backingInt(ax.Action.press) }, .target = .{ .window = 10, .tab = 20 } },
        .{ .node = .{ .id = 3, .parent = 2, .role = .terminal, .state = active | ax.State.focused, .actions = @backingInt(ax.Action.focus) | @backingInt(ax.Action.copy), .bounds = .{ .x = 10, .y = 20, .width = 600, .height = 400 } }, .target = .{ .window = 10, .session = 30, .tab = 20 }, .visible_text = .{ .text = text } },
    };
}
const Fake = struct {
    adapter: *app.Adapter,
    alive: bool = true,
    close_on_resolve: bool = false,
    reenter: bool = false,
    fail: bool = false,
    calls: usize = 0,
    last: ?app.Request = null,
    pub fn accessibilityAlive(self: *@This(), target: app.Target) bool {
        if (self.close_on_resolve) self.adapter.detach();
        return self.alive and target.window == 10 and (target.session == 0 or target.session == 30) and (target.tab == 0 or target.tab == 20);
    }
    pub fn accessibilityDispatch(self: *@This(), request: app.Request) anyerror!void {
        try std.testing.expect(!self.adapter.callback_active);
        if (self.reenter) {
            try std.testing.expect(!self.adapter.enqueue(3, .copy));
            try std.testing.expectError(error.AccessibilityReentrant, self.adapter.dispatch(self));
            try std.testing.expectError(error.AccessibilityReentrant, self.adapter.publish(&records("no")));
        }
        if (self.fail) return error.DispatchFailed;
        self.calls += 1;
        self.last = request;
    }
};
test "application snapshot owns viewport text, IDs, routes, geometry and focus" {
    var owner = try app.Adapter.init(10);
    var text = [_]u8{ 'A', 0xe4, 0xb8, 0xad, 0xf0, 0x9f, 0x99, 0x82 };
    var input = records(&text);
    input[2].visible_text.?.caret = 8;
    input[2].visible_text.?.selection_start = 1;
    input[2].visible_text.?.selection_end = 4;
    const changed = try owner.publish(&input);
    @memset(&text, 'x');
    input[2].target.session = 99;
    try std.testing.expect(changed.tree and changed.focus);
    const terminal = owner.snapshot.find(3).?.*;
    try std.testing.expectEqualStrings("A中🙂", owner.snapshot.value(terminal));
    try std.testing.expectEqual(@as(u32, 8), terminal.caret);
    try std.testing.expectEqual(@as(f32, 600), terminal.bounds.width);
    try std.testing.expectEqual(@as(u64, 3), owner.snapshot.focused());
    try std.testing.expect(owner.enqueue(3, .copy));
    var host = Fake{ .adapter = &owner };
    try std.testing.expectEqual(@as(usize, 0), host.calls);
    try std.testing.expectEqual(@as(usize, 1), try owner.dispatch(&host));
    try std.testing.expectEqual(@as(u64, 30), host.last.?.target.session);
}
test "terminal text requires explicit viewport input and safely clamps truncation" {
    var owner = try app.Adapter.init(10);
    var long: [ax.max_value + 5]u8 = @splat('a');
    @memcpy(long[ax.max_value - 1 ..][0..3], "中");
    var input = records(&long);
    input[2].visible_text.?.caret = long.len;
    input[2].visible_text.?.selection_end = long.len;
    _ = try owner.publish(&input);
    const terminal = owner.snapshot.find(3).?.*;
    try std.testing.expectEqual(@as(u32, ax.max_value - 1), terminal.value_len);
    try std.testing.expectEqual(terminal.value_len, terminal.caret);
    try std.testing.expectEqual(terminal.value_len, terminal.selection_end);
    try std.testing.expect(terminal.state & ax.State.truncated != 0);
    input[2].visible_text = null;
    try std.testing.expectError(error.AccessibilityVisibleTextRequired, owner.publish(&input));
    input = records("visible");
    input[2].node.value = "history forbidden";
    try std.testing.expectError(error.InvalidAccessibilityTerminal, owner.publish(&input));
}
test "publication rollback preserves owned snapshot and routes on invalid input" {
    var owner = try app.Adapter.init(10);
    _ = try owner.publish(&records("old"));
    var input = records("new");
    input[2].target.window = 11;
    try std.testing.expectError(error.AccessibilityWrongWindow, owner.publish(&input));
    try std.testing.expectEqualStrings("old", owner.snapshot.value(owner.snapshot.find(3).?.*));
    input = records("中");
    input[2].visible_text.?.caret = 1;
    try std.testing.expectError(error.InvalidAccessibilityRange, owner.publish(&input));
    try std.testing.expectError(error.AccessibilityNodeLimit, owner.publish(&.{}));
}
test "bounded callbacks queue only valid actions and never synchronously dispatch" {
    var owner = try app.Adapter.init(10);
    _ = try owner.publish(&records("text"));
    try std.testing.expect(!owner.enqueue(3, .press));
    try std.testing.expect(!owner.enqueue(999, .copy));
    for (0..app.max_requests) |_| try std.testing.expect(owner.enqueue(3, .copy));
    try std.testing.expect(!owner.enqueue(3, .copy));
    var host = Fake{ .adapter = &owner, .reenter = true };
    try std.testing.expectEqual(@as(usize, app.max_requests), try owner.dispatch(&host));
    try std.testing.expectEqual(@as(usize, 0), owner.request_count);
}
test "closed sessions and moved or removed targets cannot consume queued actions" {
    var owner = try app.Adapter.init(10);
    _ = try owner.publish(&records("a"));
    var host = Fake{ .adapter = &owner, .alive = false };
    try std.testing.expect(owner.enqueue(3, .copy));
    try std.testing.expectEqual(@as(usize, 0), try owner.dispatch(&host));
    host.alive = true;
    try std.testing.expect(owner.enqueue(3, .copy));
    var moved = records("b");
    moved[2].target.session = 31;
    _ = try owner.publish(&moved);
    try std.testing.expectEqual(@as(usize, 0), try owner.dispatch(&host));
    _ = try owner.publish(&records("a"));
    try std.testing.expect(owner.enqueue(3, .copy));
    _ = try owner.publish(records("a")[0..2]);
    try std.testing.expectEqual(@as(usize, 0), try owner.dispatch(&host));
}
test "new modal invalidates underlying queued action and restricts tree focus" {
    var owner = try app.Adapter.init(10);
    _ = try owner.publish(&records("a"));
    try std.testing.expect(owner.enqueue(3, .copy));
    var modal: [5]app.Record = undefined;
    @memcpy(modal[0..3], &records("a"));
    modal[2].node.state &= ~ax.State.focused;
    modal[3] = .{ .node = .{ .id = 4, .parent = 1, .role = .dialog, .state = ax.State.enabled | ax.State.visible | ax.State.modal }, .target = .{ .window = 10 } };
    modal[4] = .{ .node = .{ .id = 5, .parent = 4, .role = .button, .state = active | ax.State.focused, .actions = @backingInt(ax.Action.press) }, .target = .{ .window = 10 } };
    _ = try owner.publish(&modal);
    try std.testing.expect(!owner.enqueue(3, .copy));
    try std.testing.expect(owner.enqueue(5, .press));
    var host = Fake{ .adapter = &owner };
    try std.testing.expectEqual(@as(usize, 1), try owner.dispatch(&host));
    try std.testing.expectEqual(@as(u64, 5), host.last.?.node);
    try std.testing.expectEqual(@as(?u64, 5), owner.snapshot.nextFocusable(3, false));
    modal[2].node.state |= ax.State.focused;
    modal[4].node.state &= ~ax.State.focused;
    try std.testing.expectError(error.InvalidAccessibilityFocus, owner.publish(&modal));
}
test "hidden ancestor blocks descendant actions and invalidates focused trees" {
    var owner = try app.Adapter.init(10);
    var input = records("a");
    input[1].node.state &= ~ax.State.visible;
    try std.testing.expectError(error.InvalidAccessibilityFocus, owner.publish(&input));
    input[2].node.state &= ~ax.State.focused;
    _ = try owner.publish(&input);
    try std.testing.expect(!owner.enqueue(3, .copy));
}
test "teardown is idempotent, clears pending work and refuses late callbacks" {
    var owner = try app.Adapter.init(10);
    _ = try owner.publish(&records("a"));
    try std.testing.expect(owner.enqueue(3, .copy));
    owner.detach();
    owner.detach();
    try std.testing.expect(!owner.enqueue(3, .copy));
    try std.testing.expectEqual(@as(usize, 0), owner.request_count);
    try std.testing.expectEqual(@as(usize, 0), owner.snapshot.count);
    var host = Fake{ .adapter = &owner };
    try std.testing.expectError(error.AccessibilityDetached, owner.dispatch(&host));
    try std.testing.expectError(error.AccessibilityDetached, owner.publish(&records("b")));
}
test "dispatch failure consumes one action while preserving later queued work" {
    var owner = try app.Adapter.init(10);
    _ = try owner.publish(&records("a"));
    try std.testing.expect(owner.enqueue(3, .copy));
    try std.testing.expect(owner.enqueue(3, .focus));
    var host = Fake{ .adapter = &owner, .fail = true };
    try std.testing.expectError(error.DispatchFailed, owner.dispatch(&host));
    try std.testing.expectEqual(@as(usize, 1), owner.request_count);
    host.fail = false;
    try std.testing.expectEqual(@as(usize, 1), try owner.dispatch(&host));
}
test "owner closed while resolving target never calls host dispatch" {
    var owner = try app.Adapter.init(10);
    _ = try owner.publish(&records("a"));
    try std.testing.expect(owner.enqueue(3, .copy));
    var host = Fake{ .adapter = &owner, .close_on_resolve = true };
    try std.testing.expectEqual(@as(usize, 0), try owner.dispatch(&host));
    try std.testing.expectEqual(@as(usize, 0), host.calls);
}
