//! Actual portable raster, without a window, PTY, text engine or clipboard.
const std = @import("std");
const ui = @import("nanoui").ui;
pub fn main(init: std.process.Init) !void {
    const width = 3000;
    const height = 1600;
    const bytes = try init.gpa.alloc(u8, width * height * 4);
    defer init.gpa.free(bytes);
    const pixels: ui.gpu.Pixels = .{ .bytes = bytes, .width = width, .height = height };
    var instances: [257]ui.gpu.Instance = undefined;
    instances[0] = .{ .rect = .{ 0, 0, width, height }, .color = .{ 0.94, 0.93, 0.91, 1 } };
    for (instances[1..], 0..) |*item, n| item.* = .{
        .rect = .{ @floatFromInt(20 + n % 16 * 180), @floatFromInt(20 + n / 16 * 94), 160, 80 },
        .color = .{ 0.2, 0.4, 0.6, 1 },
    };
    for (0..4) |scene| {
        if (scene == 1) for (instances[1..]) |*item| {
            item.radius = 8;
        };
        if (scene == 2) for (instances[1..]) |*item| {
            item.color[3] = 0.6;
            item.clip_round = ui.gpu.clipRound(6, 15);
            item.clip = .{ 0, 0, width, height };
        };
        if (scene == 3) for (instances[1..]) |*item| {
            item.color[3] = 0;
            item.clip_round = 0;
        };
        var times: [15]f64 = undefined;
        for (0..18) |n| {
            const start = ui.clock.now();
            ui.raster.draw(pixels, &instances, .{ .pixels = &.{}, .size = 0 }, .{}, 1, .black);
            const elapsed = (ui.clock.now() - start) * 1000;
            if (n >= 3) times[n - 3] = elapsed;
        }
        std.mem.sort(f64, &times, {}, std.sort.asc(f64));
        std.debug.print("RASTER {{\"scene\":{d},\"width\":3000,\"height\":1600,\"instances\":257,\"samples\":15,\"median_ms\":{d:.6},\"p95_ms\":{d:.6},\"pixels_hash\":{d}}}\n", .{ scene, times[7], times[14], std.hash.Wyhash.hash(0, bytes) });
    }
}
