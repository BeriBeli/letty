//! Row text is shaped only after every cell background in that row exists.
//! The VT iterator's borrowed bytes are copied by terminal_view before here.
const std = @import("std");
const ui = @import("nanoui").ui;
const Config = @import("config.zig").Config;
pub const CellText = struct {
    style: ui.Style,
    str: []const u8,
    font: ui.TextStyle,
    color: ui.Color,
    col: u32,
    width: u8,
    boundary: u64,
    isolated: bool = false,
};
pub fn fontSize(ctx: *const ui.Context, cfg: Config) f32 {
    return cfg.font_size * ctx.points_to_logical;
}
pub fn configure(ctx: *ui.Context, cfg: Config) !ui.TextStyle {
    @import("portable_text_bridge.zig").install(ctx.text);
    try ctx.text.setFallbacks(cfg.font_fallbacks);
    const effective = try cfg.effectiveFontFeatures();
    const owned = try ctx.alloc().alloc(ui.FontFeature, effective.len);
    for (owned, effective.items()) |*dst, feature| dst.* = .{ .tag = feature.tag, .value = feature.value };
    return .{ .size = fontSize(ctx, cfg), .mono = true, .features = owned };
}
fn same(a: CellText, b: CellText) bool {
    return !a.isolated and !b.isolated and a.col + a.width == b.col and a.boundary == b.boundary and
        a.font.weight == b.font.weight and a.font.italic == b.font.italic and std.meta.eql(a.color, b.color);
}
pub fn paint(ctx: *ui.Context, texts: []const CellText, cw: f32, ch: f32) void {
    var start: usize = 0;
    while (start < texts.len) {
        var end = start + 1;
        var bytes = texts[start].str.len;
        while (end < texts.len and end - start < ui.gridText.max_cells and same(texts[end - 1], texts[end]) and bytes + texts[end].str.len <= ui.gridText.max_bytes) : (end += 1) bytes += texts[end].str.len;
        run(ctx, texts[start..end], bytes, cw, ch) catch |err| {
            ctx.text.last_shape_error = @errorName(err);
            for (texts[start..end]) |text| _ = ctx.leaf(text.style, .{ .text = .{ .str = text.str, .style = text.font, .color = text.color } }, null);
        };
        start = end;
    }
}
fn run(ctx: *ui.Context, cells: []const CellText, byte_count: usize, cw: f32, ch: f32) !void {
    if (byte_count > ui.gridText.max_bytes) return error.GridRunLimit;
    const text = try ctx.alloc().alloc(u8, byte_count);
    const spans = try ctx.alloc().alloc(ui.gridText.Cell, cells.len);
    var offset: u32 = 0;
    for (cells, spans) |cell, *span| {
        @memcpy(text[offset..][0..cell.str.len], cell.str);
        span.* = .{ .byte_start = offset, .byte_end = offset + @as(u32, @intCast(cell.str.len)), .col = cell.col - cells[0].col, .width = cell.width };
        offset = span.byte_end;
    }
    const first = cells[0];
    const shaped = try ctx.text.gridLayout(text, first.font, spans, cw);
    const font = ctx.text.font(first.font);
    const baseline = (ch - (font.ascent + font.descent + font.leading)) / 2 + font.leading / 2 + font.ascent;
    var style = first.style;
    style.width = .{ .px = shaped.width };
    style.padding = .{};
    // Overhanging Nerd Font glyphs may use the next cell; the pane clips them.
    style.clip = false;
    _ = ctx.leaf(style, .{ .glyph_run = .{ .str = text, .cells = spans, .glyphs = shaped.glyphs, .color = first.color, .baseline = baseline } }, null);
}
