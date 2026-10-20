//! Owned VT-byte/cell mapping, independent of fonts, nanoui and VT internals.
//! This positions existing glyph records; it does not shape fonts or infer VT
//! widths. Geometry unit fixtures use synthetic records, never pretend fonts.
const std = @import("std");
pub const max_bytes = 16384;
pub const max_cells = 4096;
pub const max_glyphs = 4096;
pub const Glyph = extern struct { glyph: u32, cluster: u32, x_advance: i32, y_advance: i32, x_offset: i32, y_offset: i32 };
/// One non-spacer VT grapheme, including all combining scalars. Bytes must
/// partition text and logical columns exactly; insert spaces or split at gaps. A wide
/// cell includes its continuation column, whose width-zero record is omitted.
pub const CellSpan = struct { byte_start: u32, byte_end: u32, col: u32, width: u8 };
pub const Geometry = struct {
    scale: f32,
    cell_width: f32,
    origin_x: f32 = 0,
    baseline_y: f32 = 0,
};
pub const PlacedGlyph = struct {
    glyph: u32,
    byte_start: u32,
    byte_end: u32,
    cell_first: u32,
    cell_end: u32,
    /// Position in nanoui points, y down. Does not round/snap raster origins.
    x: f32,
    y: f32,
    /// Physical 26.6 offset from the owning cell's grid origin/baseline.
    x_offset: i64,
    y_offset: i64,
};
pub const Error = error{ InvalidUtf8, InvalidSpans, InvalidCluster, InvalidGeometry, CapacityExceeded, OutOfMemory };
pub const Run = struct {
    text: []u8,
    cells: []CellSpan,

    pub fn init(gpa: std.mem.Allocator, text: []const u8, cells: []const CellSpan) Error!Run {
        if (text.len > max_bytes or cells.len > max_cells) return error.CapacityExceeded;
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        var end: u32 = 0;
        var column: u64 = 0;
        for (cells, 0..) |cell, index| {
            if (cell.byte_start != end or cell.byte_end <= cell.byte_start or cell.byte_end > text.len or
                !boundary(text, cell.byte_start) or !boundary(text, cell.byte_end) or
                (cell.width != 1 and cell.width != 2) or (index > 0 and cell.col != column)) return error.InvalidSpans;
            column = @as(u64, cell.col) + cell.width;
            if (column > std.math.maxInt(u32)) return error.InvalidSpans;
            end = cell.byte_end;
        }
        if (end != text.len) return error.InvalidSpans;
        const owned_text = try gpa.dupe(u8, text);
        errdefer gpa.free(owned_text);
        return .{ .text = owned_text, .cells = try gpa.dupe(CellSpan, cells) };
    }

    pub fn deinit(self: *Run, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        gpa.free(self.cells);
        self.* = .{ .text = &.{}, .cells = &.{} };
    }

    /// Returns owned values. Original glyph order is preserved, including
    /// descending/repeated clusters from another shaper. No paragraph bidi,
    /// new cell widths, rasterization or font fallback occurs here.
    pub fn place(self: *const Run, gpa: std.mem.Allocator, glyphs: []const Glyph, geo: Geometry) Error![]PlacedGlyph {
        if (glyphs.len > max_glyphs) return error.CapacityExceeded;
        if (!std.math.isFinite(geo.scale) or geo.scale <= 0 or geo.scale > 16 or
            !std.math.isFinite(geo.cell_width) or geo.cell_width <= 0 or geo.cell_width > 4096 or
            !std.math.isFinite(geo.origin_x) or !std.math.isFinite(geo.baseline_y)) return error.InvalidGeometry;
        var clusters: [max_glyphs]u32 = undefined;
        for (glyphs, 0..) |glyph, index| {
            if (glyph.cluster >= self.text.len or !boundary(self.text, glyph.cluster)) return error.InvalidCluster;
            clusters[index] = glyph.cluster;
        }
        // Sort only offsets for span extent lookup, never the glyph records.
        std.mem.sort(u32, clusters[0..glyphs.len], {}, std.sort.asc(u32));
        const Anchor = struct { x: i64, y: i64, set: bool = false };
        const anchors = try gpa.alloc(Anchor, self.cells.len);
        defer gpa.free(anchors);
        @memset(anchors, .{ .x = 0, .y = 0 });
        const out = try gpa.alloc(PlacedGlyph, glyphs.len);
        errdefer gpa.free(out);
        var pen_x: i64 = 0;
        var pen_y: i64 = 0;
        const units = @as(f64, 64) * geo.scale;
        for (glyphs, out) |glyph, *placed| {
            const first = self.cellAt(glyph.cluster);
            var lo: usize = 0;
            var hi: usize = glyphs.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (clusters[mid] <= glyph.cluster) lo = mid + 1 else hi = mid;
            }
            const limit: u32 = if (lo == glyphs.len) @intCast(self.text.len) else clusters[lo];
            const last = self.cellAt(limit - 1);
            // Combining scalars with separate shaper clusters still use one
            // VT-cell anchor. Revisited clusters retain their original anchor.
            const anchor = &anchors[first];
            if (!anchor.set) anchor.* = .{ .x = pen_x, .y = pen_y, .set = true };
            const dx = pen_x - anchor.x + glyph.x_offset;
            const dy = pen_y - anchor.y + glyph.y_offset;
            const x: f64 = @as(f64, geo.origin_x) + @as(f64, @floatFromInt(self.cells[first].col)) * geo.cell_width + @as(f64, @floatFromInt(dx)) / units;
            const y: f64 = @as(f64, geo.baseline_y) - @as(f64, @floatFromInt(dy)) / units;
            if (!std.math.isFinite(x) or !std.math.isFinite(y) or @abs(x) > std.math.floatMax(f32) or @abs(y) > std.math.floatMax(f32)) return error.InvalidGeometry;
            placed.* = .{ .glyph = glyph.glyph, .byte_start = self.cells[first].byte_start, .byte_end = self.cells[last].byte_end, .cell_first = self.cells[first].col, .cell_end = self.cells[last].col + self.cells[last].width, .x = @floatCast(x), .y = @floatCast(y), .x_offset = dx, .y_offset = dy };
            pen_x += glyph.x_advance;
            pen_y += glyph.y_advance;
        }
        return out;
    }

    fn cellAt(self: *const Run, offset: u32) usize {
        var lo: usize = 0;
        var hi = self.cells.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.cells[mid].byte_end <= offset) lo = mid + 1 else hi = mid;
        }
        return lo;
    }
};
fn boundary(text: []const u8, offset: usize) bool {
    return offset == text.len or (offset < text.len and text[offset] & 0xc0 != 0x80);
}
fn g(id: u32, cluster: u32, advance: i32, dx: i32, dy: i32) Glyph {
    return .{ .glyph = id, .cluster = cluster, .x_advance = advance, .y_advance = 0, .x_offset = dx, .y_offset = dy };
}
test "owned VT spans survive input reuse and map wide continuation columns" {
    const a = std.testing.allocator;
    var bytes = "a中".*;
    var cells = [_]CellSpan{ .{ .byte_start = 0, .byte_end = 1, .col = 3, .width = 1 }, .{ .byte_start = 1, .byte_end = 4, .col = 4, .width = 2 } };
    var run = try Run.init(a, &bytes, &cells);
    defer run.deinit(a);
    @memset(&bytes, 'x');
    cells[0].col = 99;
    const placed = try run.place(a, &.{ g(1, 0, 640, 0, 0), g(2, 1, 1280, 0, 0) }, .{ .scale = 2, .cell_width = 10, .origin_x = 5, .baseline_y = 20 });
    defer a.free(placed);
    try std.testing.expectEqualStrings("a中", run.text);
    try std.testing.expectEqual(@as(f32, 35), placed[0].x);
    try std.testing.expectEqual(@as(f32, 45), placed[1].x);
    try std.testing.expectEqual(@as(u32, 6), placed[1].cell_end);
}
test "synthetic combining records share VT anchor and convert physical offsets once" {
    const a = std.testing.allocator;
    var run = try Run.init(a, "e\xcc\x81", &.{.{ .byte_start = 0, .byte_end = 3, .col = 0, .width = 1 }});
    defer run.deinit(a);
    const placed = try run.place(a, &.{ g(1, 0, 1280, 0, 0), g(2, 1, 0, -1152, 256) }, .{ .scale = 2, .cell_width = 10, .baseline_y = 30 });
    defer a.free(placed);
    try std.testing.expectEqual(@as(f32, 1), placed[1].x);
    try std.testing.expectEqual(@as(f32, 28), placed[1].y);
    try std.testing.expectEqual(@as(u32, 1), placed[1].cell_end);
}
test "synthetic ligature spans two cells without advancing the following grid origin" {
    const a = std.testing.allocator;
    var run = try Run.init(a, "fix", &.{ .{ .byte_start = 0, .byte_end = 1, .col = 2, .width = 1 }, .{ .byte_start = 1, .byte_end = 2, .col = 3, .width = 1 }, .{ .byte_start = 2, .byte_end = 3, .col = 4, .width = 1 } });
    defer run.deinit(a);
    const placed = try run.place(a, &.{ g(7, 0, 1900, 0, 0), g(8, 2, 640, -64, 0) }, .{ .scale = 1, .cell_width = 10 });
    defer a.free(placed);
    try std.testing.expectEqual(@as(u32, 4), placed[0].cell_end);
    try std.testing.expectEqual(@as(f32, 39), placed[1].x);
}
test "synthetic RTL and revisited clusters preserve painter order and logical cell coordinates" {
    const a = std.testing.allocator;
    var run = try Run.init(a, "abc", &.{ .{ .byte_start = 0, .byte_end = 1, .col = 0, .width = 1 }, .{ .byte_start = 1, .byte_end = 2, .col = 1, .width = 1 }, .{ .byte_start = 2, .byte_end = 3, .col = 2, .width = 1 } });
    defer run.deinit(a);
    const placed = try run.place(a, &.{ g(3, 2, -640, 0, 0), g(2, 1, -640, 0, 0), g(1, 0, 0, 0, 0), g(4, 2, 0, 1280, 0) }, .{ .scale = 1, .cell_width = 10 });
    defer a.free(placed);
    for ([_]u32{ 3, 2, 1, 4 }, [_]f32{ 20, 10, 0, 20 }, placed) |id, x, item| {
        try std.testing.expectEqual(id, item.glyph);
        try std.testing.expectEqual(x, item.x);
    }
}
test "mapping rejects invalid UTF8 spans clusters geometry and allocation failure" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidUtf8, Run.init(a, "\xff", &.{}));
    try std.testing.expectError(error.InvalidSpans, Run.init(a, "中", &.{.{ .byte_start = 0, .byte_end = 2, .col = 0, .width = 2 }}));
    try std.testing.expectError(error.InvalidSpans, Run.init(a, "a", &.{.{ .byte_start = 0, .byte_end = 1, .col = 0, .width = 0 }}));
    var run = try Run.init(a, "中", &.{.{ .byte_start = 0, .byte_end = 3, .col = 0, .width = 2 }});
    defer run.deinit(a);
    try std.testing.expectError(error.InvalidCluster, run.place(a, &.{g(1, 1, 0, 0, 0)}, .{ .scale = 1, .cell_width = 10 }));
    try std.testing.expectError(error.InvalidGeometry, run.place(a, &.{}, .{ .scale = 0, .cell_width = 10 }));
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Run.init(failing.allocator(), run.text, run.cells));
    try std.testing.expectError(error.OutOfMemory, run.place(failing.allocator(), &.{g(1, 0, 0, 0, 0)}, .{ .scale = 1, .cell_width = 10 }));
}

fn allocationFixture(a: std.mem.Allocator) !void {
    var run = try Run.init(a, "a", &.{.{ .byte_start = 0, .byte_end = 1, .col = 0, .width = 1 }});
    defer run.deinit(a);
    const placed = try run.place(a, &.{g(1, 0, 640, 0, 0)}, .{ .scale = 1, .cell_width = 10 });
    defer a.free(placed);
}
test "all owned input and output allocation failures release partial state" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFixture, .{});
}
test "empty mapping is owned and invalid gaps or oversized input are rejected" {
    const a = std.testing.allocator;
    var run = try Run.init(a, "", &.{});
    defer run.deinit(a);
    const placed = try run.place(a, &.{}, .{ .scale = 1, .cell_width = 10 });
    defer a.free(placed);
    try std.testing.expectEqual(@as(usize, 0), placed.len);
    try std.testing.expectError(error.InvalidSpans, Run.init(a, "ab", &.{
        .{ .byte_start = 0, .byte_end = 1, .col = 0, .width = 1 },
        .{ .byte_start = 1, .byte_end = 2, .col = 2, .width = 1 },
    }));
    const excessive: [max_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.CapacityExceeded, Run.init(a, &excessive, &.{}));
}
