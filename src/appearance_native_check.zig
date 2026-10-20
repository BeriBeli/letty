//! Invoke the owned AppKit observer; never change or post system appearance.
const std = @import("std");
const nano = @import("nanoui");
const Watch = @import("system_appearance.zig").Watch;
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} APPEARANCE {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.AppearanceCheck;
}
const Probe = struct {
    count: usize = 0,
    dark: bool = false,
    fn changed(data: *anyopaque, dark: bool) void {
        const self: *Probe = @ptrCast(@alignCast(data));
        self.count += 1;
        self.dark = dark;
    }
};
pub fn main() !void {
    const objc = nano.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    var probe: Probe = .{};
    var watch: Watch = .{};
    defer watch.stop();
    try check(watch.start(.{ .context = &probe, .changed = Probe.changed }) and watch.object != null, "register owned distributed observer without OS settings changes");
    const value = watch.current();
    try check(probe.count == 0 and watch.last_dark == value, "initial system appearance is cached without a duplicate callback");
    const object: objc.Object = @ptrCast(watch.object.?);
    _ = objc.msg(objc.Object, object, "retain", .{});
    defer objc.release(object);
    // Change only our last-seen cache, then call the actual registered selector.
    watch.last_dark = !value;
    objc.msg(void, object, "appearanceChanged:", .{@as(?objc.Object, null)});
    try check(probe.count == 1 and probe.dark == value, "native registered selector reads system mode and delivers one effective change");
    objc.msg(void, object, "appearanceChanged:", .{@as(?objc.Object, null)});
    try check(probe.count == 1, "duplicate native selector invocation is deduplicated");
    watch.stop();
    try check(watch.object == null and watch.callback == null, "observer teardown removes registration and clears borrowed context");
    objc.msg(void, object, "appearanceChanged:", .{@as(?objc.Object, null)});
    try check(probe.count == 1, "late invocation of separately retained observer cannot reach released owner");
    std.debug.print("All 6 native appearance checks passed.\n", .{});
}
