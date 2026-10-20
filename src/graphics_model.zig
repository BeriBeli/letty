//! Portable Kitty renderer geometry, pixel conversion and resource limits.
//! The native graphics adapter owns protocol and PNG decoder integration.
const std = @import("std");
pub const max_side = 2048;
pub const max_image_bytes = 4 * 1024 * 1024;
pub const max_png_input_bytes = 4 * 1024 * 1024;
pub const decode_scratch_bytes = 16 * 1024 * 1024;

pub const Rect = struct { x: f32, y: f32, width: f32, height: f32 };
pub const Sample = struct { source: Rect, destination: Rect };

/// Clip image source and destination together; fractional source coordinates
/// prevent top/left scrolling from stretching the visible remainder. Cell
/// position and resolved source geometry come from the VT placement API.
pub fn clip(source: Rect, destination: Rect, viewport: Rect) ?Sample {
    if (destination.width <= 0 or destination.height <= 0 or source.width <= 0 or source.height <= 0) return null;
    const left = @max(destination.x, viewport.x);
    const top = @max(destination.y, viewport.y);
    const right = @min(destination.x + destination.width, viewport.x + viewport.width);
    const bottom = @min(destination.y + destination.height, viewport.y + viewport.height);
    if (right <= left or bottom <= top) return null;
    const sx = source.width / destination.width;
    const sy = source.height / destination.height;
    return .{
        .source = .{ .x = source.x + (left - destination.x) * sx, .y = source.y + (top - destination.y) * sy, .width = (right - left) * sx, .height = (bottom - top) * sy },
        .destination = .{ .x = left, .y = top, .width = right - left, .height = bottom - top },
    };
}

pub const Layer = enum { below_background, below_text, above_text };
pub fn layer(z: i32) Layer {
    return if (z < @divTrunc(std.math.minInt(i32), 2)) .below_background else if (z < 0) .below_text else .above_text;
}

/// nanoui CPU/Metal pixels use premultiplied BGRA. Convert into a separately
/// budgeted renderer-owned upload; never mutate the shared snapshot pixels.
pub fn toBgra(dst: []u8, rgba: []const u8) error{InvalidLength}!void {
    if (dst.len != rgba.len or rgba.len % 4 != 0) return error.InvalidLength;
    var at: usize = 0;
    while (at < rgba.len) : (at += 4) {
        const alpha: u32 = rgba[at + 3];
        dst[at] = @intCast((@as(u32, rgba[at + 2]) * alpha + 127) / 255);
        dst[at + 1] = @intCast((@as(u32, rgba[at + 1]) * alpha + 127) / 255);
        dst[at + 2] = @intCast((@as(u32, rgba[at]) * alpha + 127) / 255);
        dst[at + 3] = @intCast(alpha);
    }
}

test "scrolled placement clips matching source pixels and preserves z layer boundaries" {
    const got = clip(.{ .x = 4, .y = 8, .width = 100, .height = 80 }, .{ .x = -10, .y = -20, .width = 50, .height = 40 }, .{ .x = 0, .y = 0, .width = 100, .height = 100 }).?;
    try std.testing.expectEqual(@as(f32, 24), got.source.x);
    try std.testing.expectEqual(@as(f32, 48), got.source.y);
    try std.testing.expectEqual(@as(f32, 80), got.source.width);
    try std.testing.expectEqual(@as(f32, 40), got.source.height);
    try std.testing.expectEqual(Layer.below_background, layer(std.math.minInt(i32)));
    try std.testing.expectEqual(Layer.below_text, layer(-1073741824));
    try std.testing.expectEqual(Layer.above_text, layer(0));
    try std.testing.expect(clip(got.source, .{ .x = 100, .y = 100, .width = 5, .height = 5 }, .{ .x = 0, .y = 0, .width = 10, .height = 10 }) == null);
}
test "renderer upload converts straight RGBA with alpha and rejects incomplete pixels" {
    var dst: [8]u8 = undefined;
    try toBgra(&dst, &.{ 255, 0, 30, 128, 40, 80, 120, 0 });
    try std.testing.expectEqualSlices(u8, &.{ 15, 0, 128, 128, 0, 0, 0, 0 }, &dst);
    try std.testing.expectError(error.InvalidLength, toBgra(dst[0..3], &.{ 0, 0, 0 }));
}
