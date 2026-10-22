//! Alternate independent UI trees, exercising real layout/shaping cache churn.
const std = @import("std");
const ui = @import("nanoui").ui;
const Scene = struct {
    tab: usize = 0,
    fn draw(s: *@This(), ctx: *ui.Context) void {
        ui.column(ctx, .{ .width = .fill, .height = .fill });
        defer ui.end(ctx);
        for (0..80) |row| ui.text(ctx, ctx.print("tab {d} row {d} - 0123456789 abcdefghijklmnopqrstuvwxyz", .{ s.tab, row }), .{ .size = 12 });
    }
};
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedAllocator;
    const libc = std.mem.eql(u8, args[1], "libc-backing");
    var safe: std.heap.SafeAllocator = .init(if (libc) std.heap.c_allocator else std.heap.page_allocator, .{});
    defer if (safe.deinit() != 0) @panic("fixture leaked");
    const gpa = safe.allocator();
    var scene: Scene = .{};
    var tester: ui.Tester = undefined;
    try tester.init(gpa, .init(&scene, Scene.draw), .{ .width = 1000, .height = 1000, .scale = 1 });
    defer tester.deinit();
    tester.dt = 0;
    var times: [120]f64 = undefined;
    const before = std.posix.getrusage(0);
    for (0..140) |n| {
        scene.tab = n % 3;
        const start = ui.clock.now();
        tester.frame();
        if (n >= 20) times[n - 20] = (ui.clock.now() - start) * 1000;
    }
    const after = std.posix.getrusage(0);
    std.mem.sort(f64, &times, {}, std.sort.asc(f64));
    std.debug.print("ALLOCATOR {{\"allocator\":\"{s}\",\"samples\":120,\"median_ms\":{d:.6},\"p95_ms\":{d:.6},\"maxrss_native_units\":{d},\"minor_faults\":{d},\"nodes\":{d},\"instances\":{d}}}\n", .{ args[1], times[60], times[114], after.maxrss, after.minflt - before.minflt, tester.ctx.stats.nodes, tester.ctx.stats.instances });
}
