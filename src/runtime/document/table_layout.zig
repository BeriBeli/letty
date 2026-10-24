//! Cached shaped cell geometry. Painting, selection, links and search use the
//! same wrapped fragments; Markdown's flat text keeps tab-separated copy order.
const std = @import("std");
const ui = @import("nanoui").ui;
const md = @import("markdown.zig");
const render = @import("markdown_render.zig");
const text = @import("read_only_text.zig");
const padding: f32 = 10;
const inset: f32 = 6;
pub const max_fragments = 131072;
pub const Fragment = struct { block: md.Line, x: f32, y: f32, width: f32, height: f32 };
pub const Cell = struct { x: f32, width: f32, first: usize, end: usize };
pub const Row = struct { first: usize = 0, end: usize = 0, width: f32 = 0, height: f32 = 0 };
pub const Layout = struct {
    rows: std.ArrayList(Row) = .empty,
    cells: std.ArrayList(Cell) = .empty,
    fragments: std.ArrayList(Fragment) = .empty,
    pub fn deinit(self: *Layout, gpa: std.mem.Allocator) void {
        self.rows.deinit(gpa);
        self.cells.deinit(gpa);
        self.fragments.deinit(gpa);
        self.* = .{};
    }
    pub fn rebuild(self: *Layout, ctx: *ui.Context, doc: *const md.Document, flat: *const text.Document, size: f32, available: f32) !void {
        self.cells.clearRetainingCapacity();
        self.fragments.clearRetainingCapacity();
        try self.rows.resize(ctx.gpa, doc.lines.len);
        @memset(self.rows.items, .{});
        var first: usize = 0;
        while (first < doc.lines.len) {
            if (doc.lines[first].kind != .table) {
                first += 1;
                continue;
            }
            var end = first + 1;
            while (end < doc.lines.len and doc.lines[end].kind == .table and !doc.lines[end].table_header) : (end += 1) {}
            const widths = try ctx.gpa.alloc(f32, doc.lines[first].cells.len);
            defer ctx.gpa.free(widths);
            const minimums = try ctx.gpa.alloc(f32, widths.len);
            defer ctx.gpa.free(minimums);
            const table_available = @max(1, available - render.indent(doc.lines[first], size, available));
            const minimum = 64 * size / 14;
            @memset(widths, minimum);
            @memset(minimums, minimum);
            for (doc.lines[first..end]) |line| for (line.cells, widths, minimums) |cell, *width, *min_width| {
                const block = cellBlock(line, cell);
                const math_inline = @import("math_inline.zig");
                for (doc.formulas[math_inline.first(doc, block)..]) |formula| {
                    if (formula.start >= cell.end) break;
                    min_width.* = @max(min_width.*, @import("math_render.zig").measure(ctx, formula.node, size).width + 2 * padding);
                }
                const shaped_width = render.xAt(ctx, doc, block, block.end - block.start, size);
                width.* = @max(min_width.*, @max(width.*, @min(360 * size / 14, shaped_width + 2 * padding)));
            };
            var natural: f32 = 0;
            for (widths) |width| natural += width;
            var floor: f32 = 0;
            for (minimums) |min_width| floor += min_width;
            if (natural > table_available and natural > floor) {
                const ratio = std.math.clamp((table_available - floor) / (natural - floor), 0, 1);
                for (widths, minimums) |*width, min_width| width.* = min_width + (width.* - min_width) * ratio;
            }
            for (first..end) |index| {
                const line = doc.lines[index];
                var row: Row = .{ .first = self.cells.items.len, .height = render.lineHeight(line, size) + inset * 2 };
                for (line.cells, widths) |cell, width| {
                    var box: Cell = .{ .x = row.width, .width = width, .first = self.fragments.items.len, .end = 0 };
                    const block = cellBlock(line, cell);
                    const wrapped = render.wrap(ctx, doc, block, size, @max(1, width - 2 * padding));
                    var start = cell.start;
                    var y: f32 = inset;
                    for (0..@max(1, wrapped.len)) |i| {
                        const stop = if (i + 1 < wrapped.len) flat.ceil(cell.start + wrapped[i + 1].start) else cell.end;
                        if (stop <= start and cell.start != cell.end) continue;
                        if (self.fragments.items.len >= max_fragments) return error.PreviewVisualRowLimit;
                        var fragment = block;
                        fragment.start = start;
                        fragment.end = stop;
                        const measured = render.xAt(ctx, doc, fragment, stop - start, size);
                        const spare = @max(0, width - 2 * padding - measured);
                        const aligned = switch (cell.alignment) {
                            .left => @as(f32, 0),
                            .center => spare / 2,
                            .right => spare,
                        };
                        const height = render.height(ctx, doc, fragment, size);
                        try self.fragments.append(ctx.gpa, .{ .block = fragment, .x = box.x + padding + aligned, .y = y, .width = measured, .height = height });
                        y += height;
                        start = stop;
                    }
                    box.end = self.fragments.items.len;
                    try self.cells.append(ctx.gpa, box);
                    row.width += width;
                    row.height = @max(row.height, y + inset);
                }
                row.end = self.cells.items.len;
                self.rows.items[index] = row;
            }
            first = end;
        }
    }
    pub fn fragmentAt(self: *const Layout, row_index: usize, byte: usize) ?Fragment {
        const row = self.rows.items[row_index];
        var last: ?Fragment = null;
        for (self.cells.items[row.first..row.end]) |cell| {
            for (self.fragments.items[cell.first..cell.end]) |fragment| {
                if (byte < fragment.block.end or byte <= fragment.block.start) return fragment;
                last = fragment;
            }
            // A cell-end caret belongs before its separator, rather than at
            // the next cell's start. Wrapped fragments still advance above.
            if (last) |fragment| if (byte == fragment.block.end) return fragment;
        }
        return last;
    }
    pub fn pointAt(self: *const Layout, ctx: *ui.Context, doc: *const md.Document, row: usize, byte: usize, size: f32) ui.Point {
        const fragment = self.fragmentAt(row, byte) orelse return .{};
        const relative = std.math.clamp(byte, fragment.block.start, fragment.block.end) - fragment.block.start;
        return .{ .x = fragment.x + render.xAt(ctx, doc, fragment.block, relative, size), .y = fragment.y };
    }
    pub fn moveVertical(self: *const Layout, ctx: *ui.Context, doc: *const md.Document, row_index: usize, byte: usize, down: bool, size: f32) ?usize {
        const row = self.rows.items[row_index];
        for (self.cells.items[row.first..row.end]) |cell| {
            for (self.fragments.items[cell.first..cell.end], cell.first..) |fragment, index| {
                if (byte < fragment.block.start or byte >= fragment.block.end) continue;
                if ((down and index + 1 == cell.end) or (!down and index == cell.first)) return null;
                const target = self.fragments.items[if (down) index + 1 else index - 1];
                const x = fragment.x + render.xAt(ctx, doc, fragment.block, byte - fragment.block.start, size);
                return target.block.start + render.hitTest(ctx, doc, target.block, x - target.x, size);
            }
        }
        return null;
    }
    pub fn hit(self: *const Layout, ctx: *ui.Context, doc: *const md.Document, index: usize, point: ui.Point, size: f32) usize {
        const row = self.rows.items[index];
        for (self.cells.items[row.first..row.end], row.first..) |cell, ci| {
            if (point.x >= cell.x + cell.width and ci + 1 < row.end) continue;
            for (self.fragments.items[cell.first..cell.end], cell.first..) |fragment, fi| {
                if (point.y >= fragment.y + fragment.height and fi + 1 < cell.end) continue;
                return fragment.block.start + render.hitTest(ctx, doc, fragment.block, point.x - fragment.x, size);
            }
        }
        return doc.lines[index].end;
    }
    pub fn draw(self: *const Layout, ctx: *ui.Context, doc: *const md.Document, index: usize, origin: ui.Point, clip: ui.Size, size: f32, selected: text.Match) void {
        const row = self.rows.items[index];
        const header = doc.lines[index].table_header;
        for (self.cells.items[row.first..row.end]) |cell| {
            if (origin.x + cell.x + cell.width < 0 or origin.x + cell.x > clip.w) continue;
            // Every row draws the same column edges, including when its header
            // is above the viewport. Borders are shapes, never font glyphs.
            _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = origin.x + cell.x, .y = origin.y }, .width = .{ .px = cell.width }, .height = .{ .px = row.height }, .border = ctx.theme.border, .background = if (header) ctx.theme.text.alpha(0.065) else null }, .none, null);
            for (self.fragments.items[cell.first..cell.end]) |fragment| {
                const y = origin.y + fragment.y;
                if (y + fragment.height < 0 or y > clip.h) continue;
                const block = fragment.block;
                if (selected.end > block.start and selected.start < block.end) {
                    const from = render.xAt(ctx, doc, block, @max(selected.start, block.start) - block.start, size);
                    const to = render.xAt(ctx, doc, block, @min(selected.end, block.end) - block.start, size);
                    _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = origin.x + fragment.x + from, .y = y }, .width = .{ .px = @max(1, to - from) }, .height = .{ .px = fragment.height }, .background = ctx.theme.accent.alpha(0.25) }, .none, null);
                }
                ui.column(ctx, .{ .absolute = true, .offset = .{ .x = origin.x + fragment.x, .y = y }, .height = .{ .px = fragment.height } });
                render.drawLine(ctx, doc, block, size);
                ui.end(ctx);
            }
        }
    }
};
fn cellBlock(line: md.Line, cell: md.Cell) md.Line {
    var block = line;
    block.start = cell.start;
    block.end = cell.end;
    block.cells = &.{};
    return block;
}
