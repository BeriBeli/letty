//! Peak recovery latency and pixel stability on real offscreen UI frames.
const std = @import("std");
const ui = @import("nanoui").ui;
const Scene = struct {
    fn draw(_: *@This(), ctx: *ui.Context) void {
        ui.column(ctx, .{ .width = .fill, .height = .fill });
        defer ui.end(ctx);
        for (0..80) |row| ui.text(ctx, ctx.print("row {d} - 0123456789 abcdefghijklmnopqrstuvwxyz", .{row}), .{ .size = 12 });
    }
};
pub fn main(init: std.process.Init) !void {
    var scene: Scene = .{};
    var tester: ui.Tester = undefined;
    try tester.init(init.gpa, .init(&scene, Scene.draw), .{ .width = 1000, .height = 1000, .scale = 1 });
    defer tester.deinit();
    for (0..10) |_| tester.frame();
    const initial = try tester.render(init.gpa);
    defer initial.deinit(init.gpa);
    const before_hash = std.hash.Wyhash.hash(0, initial.bytes);
    const transient = try tester.ctx.alloc().alloc(u8, 32 * 1024 * 1024);
    @memset(transient, 0x5a);
    const peak = tester.ctx.arena.queryCapacity();
    var previous = peak;
    var trim_us: f64 = 0;
    var times: [180]f64 = undefined;
    for (&times) |*time| {
        const start = ui.clock.now();
        tester.frame();
        time.* = (ui.clock.now() - start) * 1e6;
        const capacity = tester.ctx.arena.queryCapacity();
        if (capacity < previous / 2) trim_us = time.*;
        previous = capacity;
    }
    const final = try tester.render(init.gpa);
    defer final.deinit(init.gpa);
    const after_hash = std.hash.Wyhash.hash(0, final.bytes);
    if (before_hash != after_hash) return error.PixelMismatch;
    std.mem.sort(f64, &times, {}, std.sort.asc(f64));
    std.debug.print("CACHE {{\"peak_capacity\":{d},\"final_capacity\":{d},\"samples\":180,\"median_us\":{d:.3},\"p95_us\":{d:.3},\"max_us\":{d:.3},\"trim_frame_us\":{d:.3},\"pixel_hash\":\"{x}\"}}\n", .{ peak, tester.ctx.arena.queryCapacity(), times[90], times[170], times[179], trim_us, after_hash });
}
