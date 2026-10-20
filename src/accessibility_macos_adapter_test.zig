//! Actual AppKit bridge + owned application adapter, with an unattached NSView.
const std = @import("std");
const app = @import("application_accessibility.zig");
const ax = app.ax;
extern "c" fn lt_ax_native_host_new() ?*anyopaque;
extern "c" fn lt_ax_native_host_view(*anyopaque) *anyopaque;
extern "c" fn lt_ax_native_host_action(*anyopaque, u64, c_uint) c_int;
extern "c" fn lt_ax_native_host_free(*anyopaque) void;
const Sink = struct {
    owner: *app.Adapter,
    count: usize = 0,
    pub fn accessibilityAlive(_: *@This(), target: app.Target) bool {
        return target.eql(.{ .window = 10, .session = 30, .tab = 20 });
    }
    pub fn accessibilityDispatch(self: *@This(), request: app.Request) !void {
        try std.testing.expect(!self.owner.callback_active);
        try std.testing.expectEqual(@as(u64, 3), request.node);
        try std.testing.expectEqual(ax.Action.copy, request.action);
        self.count += 1;
    }
};
test "actual AppKit action only queues stable route until separate UI dispatch" {
    const host = lt_ax_native_host_new().?;
    defer lt_ax_native_host_free(host);
    var owner = try app.Adapter.init(10);
    defer owner.detach();
    const records = [_]app.Record{
        .{ .node = .{ .id = 1 }, .target = .{ .window = 10 } },
        .{ .node = .{ .id = 3, .parent = 1, .role = .terminal, .state = ax.State.enabled | ax.State.visible | ax.State.focusable | ax.State.focused, .actions = @backingInt(ax.Action.copy) }, .target = .{ .window = 10, .session = 30, .tab = 20 }, .visible_text = .{ .text = "visible 中🙂" } },
    };
    _ = try owner.publish(&records);
    try owner.attach(lt_ax_native_host_view(host));
    try std.testing.expectEqual(@as(c_int, 1), lt_ax_native_host_action(host, 3, @backingInt(ax.Action.copy)));
    var sink = Sink{ .owner = &owner };
    try std.testing.expectEqual(@as(usize, 0), sink.count);
    try std.testing.expectEqual(@as(usize, 1), owner.request_count);
    try std.testing.expectEqual(@as(usize, 1), try owner.dispatch(&sink));
    owner.detach();
    try std.testing.expectEqual(@as(c_int, 0), lt_ax_native_host_action(host, 3, @backingInt(ax.Action.copy)));
    try std.testing.expect(!owner.enqueue(3, .copy));
}
test "actual attach before first publish and permanent detach lifecycle" {
    const host = lt_ax_native_host_new().?;
    defer lt_ax_native_host_free(host);
    var owner = try app.Adapter.init(10);
    try owner.attach(lt_ax_native_host_view(host));
    try std.testing.expectError(error.AccessibilityAlreadyAttached, owner.attach(lt_ax_native_host_view(host)));
    _ = try owner.publish(&.{.{ .node = .{ .id = 1, .label = "Empty" }, .target = .{ .window = 10 } }});
    owner.detach();
    try std.testing.expectError(error.AccessibilityDetached, owner.attach(lt_ax_native_host_view(host)));
}
