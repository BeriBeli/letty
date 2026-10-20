//! Owned hidden-window regression checks; never sends desktop input.
const std = @import("std");
const nano = @import("nanoui");
const ui = nano.ui;
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.WindowFrameCheck;
}
const Fixture = struct {
    builds: usize = 0,
    fn draw(f: *@This(), c: *ui.Context) void {
        f.builds += 1;
        ui.column(c, .{ .width = .fill, .height = .fill, .background = .hex(0x224466) });
        ui.end(c);
    }
};
pub fn run(s: anytype) !void {
    if (@import("builtin").os.tag != .macos) return;
    const objc = nano.objc;
    var fixture: Fixture = .{};
    const window = try s.app.newWindow(.{ .visible = false, .content = .{ .view = .init(&fixture, Fixture.draw) } });
    defer {
        window.close();
        // Surface owns its queued fallback callback until it runs. Let the
        // owned hidden windows finish asynchronous destruction before leak checks.
        nano.runFor(0.03);
    }
    const surface = window.surface.?;
    // Hold both GPU slots. A normal frame must return and arrange a retry,
    // rather than block the main thread waiting for one of these slots.
    var acquired: usize = 0;
    defer for (0..acquired) |_| {
        _ = objc.dispatch_semaphore_signal(surface.renderer.in_flight);
    };
    for (0..2) |_| {
        _ = objc.dispatch_semaphore_wait(surface.renderer.in_flight, objc.DISPATCH_TIME_FOREVER);
        acquired += 1;
    }
    for (0..8) |i| window.setSize(600 + @as(f64, @floatFromInt(i)) * 10, 420);
    const before = fixture.builds;
    const start = ui.clock.now();
    surface.frame();
    try check(ui.clock.now() - start < 0.1 and fixture.builds > before, "GPU backpressure returns without blocking the main thread");
    const retry = if (surface.display_link) |link| !objc.msg(bool, link, "isPaused", .{}) else surface.tick_scheduled;
    try check(retry, "busy GPU schedules another display refresh instead of losing the frame");
    const size = window.contentSize();
    try check(@abs(size[0] - surface.ctx.size.w) < 0.5 and @abs(size[1] - surface.ctx.size.h) < 0.5, "resize burst retains the final geometry while the GPU is busy");
    // The app's headless flag normally permits rendering hidden test windows.
    // Temporarily apply the real occluded-window rule to this owned window.
    const hidden = s.app.flags.hidden;
    s.app.flags.hidden = false;
    surface.requestFrame();
    s.app.flags.hidden = hidden;
    const paused = if (surface.display_link) |link| objc.msg(bool, link, "isPaused", .{}) else true;
    try check(surface.pending and paused, "hidden updates stay pending with the display link paused");
}
