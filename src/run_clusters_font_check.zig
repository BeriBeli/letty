//! Joint HB/cell mapping checks on the pinned upstream fonts, not fabricated
//! font tables. Fixture copyright/license remains in vendor/harfbuzz/test and
//! the original font metadata; none of these fonts is bundled by this module.
const std = @import("std");
const shaper = @import("portable_shaper.zig");
const clusters = shaper.clusters;
const a = std.testing.allocator;
fn font(path: []const u8) !shaper.Font {
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 << 20));
    defer a.free(data);
    return shaper.Font.init(data, 0);
}
test "real GSUB fixture ligature toggle preserves the original two VT columns" {
    var f = try font("vendor/harfbuzz/test/api/fonts/Roboto-Regular.gsub.fi.ttf");
    defer f.deinit();
    var run = try clusters.Run.init(a, "fi", &.{
        .{ .byte_start = 0, .byte_end = 1, .col = 0, .width = 1 },
        .{ .byte_start = 1, .byte_end = 2, .col = 1, .width = 1 },
    });
    defer run.deinit(a);
    var output: shaper.Output = .{};
    try f.shape(run.text, 32, &.{.{ .tag = "liga".*, .value = 1 }}, &output);
    try std.testing.expectEqual(@as(usize, 1), output.len);
    try std.testing.expect(output.glyphs[0].glyph != 0);
    const ligature = try output.place(a, &run, .{ .scale = 2, .cell_width = 10 });
    defer a.free(ligature);
    try std.testing.expectEqual(@as(u32, 2), ligature[0].cell_end);
    try f.shape(run.text, 32, &.{.{ .tag = "liga".*, .value = 0 }}, &output);
    try std.testing.expectEqual(@as(usize, 2), output.len);
    const separate = try output.place(a, &run, .{ .scale = 2, .cell_width = 10 });
    defer a.free(separate);
    try std.testing.expectEqual(@as(f32, 10), separate[1].x);
    try std.testing.expectEqual(@as(u32, 2), separate[1].cell_end);
    var scratch: [2]shaper.Glyph = undefined;
    try std.testing.expectEqual(@as(usize, 2), try f.shapeInto(run.text, 32, &.{.{ .tag = "liga".*, .value = 0 }}, &scratch));
    try std.testing.expectError(error.CapacityExceeded, f.shapeInto(run.text, 32, &.{.{ .tag = "liga".*, .value = 0 }}, scratch[0..1]));
}
test "real combining accent shaping maps one owned VT grapheme" {
    var f = try font("vendor/harfbuzz/test/api/fonts/OpenSans-Regular.ttf");
    defer f.deinit();
    var run = try clusters.Run.init(a, "e\xcc\x81", &.{.{ .byte_start = 0, .byte_end = 3, .col = 3, .width = 1 }});
    defer run.deinit(a);
    var output: shaper.Output = .{};
    try f.shape(run.text, 32, &.{}, &output);
    try std.testing.expectEqual(@as(usize, 1), output.len);
    const placed = try output.place(a, &run, .{ .scale = 2, .cell_width = 10 });
    defer a.free(placed);
    try std.testing.expectEqual(@as(u32, 3), placed[0].byte_end);
    try std.testing.expectEqual(@as(u32, 4), placed[0].cell_end);
    try std.testing.expectEqual(@as(f32, 30), placed[0].x);
    // A successful mapping is not a successful fallback/rasterization claim.
    try std.testing.expect(!f.hasGlyph('中'));
    try f.shape("中", 32, &.{}, &output);
    try std.testing.expectEqual(@as(u32, 0), output.glyphs[0].glyph);
}
test "real CJK fixture keeps its wide cell span without a continuation glyph" {
    var f = try font("vendor/harfbuzz/test/api/fonts/Mplus1p-Regular.660E,6975,73E0,5EA6,8F38,6E05.ttf");
    defer f.deinit();
    var run = try clusters.Run.init(a, "明", &.{.{ .byte_start = 0, .byte_end = 3, .col = 7, .width = 2 }});
    defer run.deinit(a);
    var output: shaper.Output = .{};
    try f.shape(run.text, 32, &.{}, &output);
    try std.testing.expect(output.len == 1 and output.glyphs[0].glyph != 0);
    const placed = try output.place(a, &run, .{ .scale = 2, .cell_width = 10 });
    defer a.free(placed);
    try std.testing.expectEqual(@as(u32, 9), placed[0].cell_end);
    try std.testing.expectEqual(@as(f32, 70), placed[0].x);
}
test "real ZWJ fixture maps one sequence without claiming color raster support" {
    var f = try font("vendor/harfbuzz/test/shape/data/in-house/fonts/3cf6f8ac6d647473a43a3100e7494b202b2cfafe.ttf");
    defer f.deinit();
    const sequence = "💁🏻‍♂️";
    var run = try clusters.Run.init(a, sequence, &.{.{ .byte_start = 0, .byte_end = sequence.len, .col = 0, .width = 2 }});
    defer run.deinit(a);
    var output: shaper.Output = .{};
    try f.shape(run.text, 32, &.{}, &output);
    try std.testing.expect(output.len == 1 and output.glyphs[0].glyph == 7);
    const placed = try output.place(a, &run, .{ .scale = 2, .cell_width = 10 });
    defer a.free(placed);
    try std.testing.expectEqual(@as(u32, 2), placed[0].cell_end);
    try std.testing.expectEqual(@as(u32, sequence.len), placed[0].byte_end);
}
