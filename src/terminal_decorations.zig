//! Bounded cell-space SGR decoration geometry. Coordinates remain on the VT grid.
const std = @import("std");
const ui = @import("nanoui").ui;
fn rect(ctx: *ui.Context, x: f32, y: f32, w: f32, h: f32, color: ui.Color) void {
    _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = .{ .px = w }, .height = .{ .px = h }, .background = color }, .none, null);
}
pub fn underline(ctx: *ui.Context, x: f32, y: f32, width: f32, kind: u8, color: ui.Color) void {
    const pixel = 1 / @max(1, ctx.scale);
    switch (kind) {
        2 => { // double
            rect(ctx, x, y - 2 * pixel, width, pixel, color);
            rect(ctx, x, y, width, pixel, color);
        },
        3, 4, 5 => { // curly, dotted, dashed
            const step: f32 = if (kind == 3) pixel else if (kind == 4) 3 * pixel else 6 * pixel;
            const count: usize = @intFromFloat(@min(4096, @ceil(width / step)));
            for (0..count) |i| {
                const at = @as(f32, @floatFromInt(i)) * step;
                const segment = @min(width - at, if (kind == 5) 3 * pixel else pixel);
                const dy: f32 = if (kind == 3) switch (i % 4) {
                    0 => 0,
                    1 => -pixel,
                    2 => -2 * pixel,
                    else => -pixel,
                } else 0;
                rect(ctx, x + at, y + dy, segment, pixel, color);
            }
        },
        else => rect(ctx, x, y, width, pixel, color),
    }
}
