//! Native glyph-backed rendering and hit mapping over the same flat IR text.
//! The panel splits prose into grapheme-safe visual rows and owns scroll,
//! selection/find overlays and input. Fonts come from nanoui's UI/mono faces.
const std = @import("std");
const ui = @import("nanoui").ui;
const md = @import("markdown.zig");
pub fn textStyle(line: md.Line, size: f32) ui.TextStyle {
    const base = if (std.math.isFinite(size)) std.math.clamp(size, 8, 48) else 14;
    return .{
        .size = if (line.kind == .heading) base * switch (line.level) {
            1 => @as(f32, 2.4),
            2 => 1.5,
            3 => 1.3,
            else => 1.1,
        } else base,
        .weight = if (line.kind == .heading or line.table_header) .bold else .regular,
        .mono = line.kind == .code or line.kind == .table or line.kind == .rule,
        .wrap = false,
    };
}
pub fn lineHeight(line: md.Line, size: f32) f32 {
    return @ceil(textStyle(line, size).size * 1.65);
}
pub fn lineSpans(ctx: *ui.Context, doc: *const md.Document, line: md.Line) []const ui.Span {
    var low: usize = 0;
    var high = doc.spans.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (doc.spans[mid].end <= line.start) low = mid + 1 else high = mid;
    }
    var end = low;
    while (end < doc.spans.len and doc.spans[end].start < line.end) end += 1;
    const output = ctx.alloc().alloc(ui.Span, end - low) catch return &.{};
    for (doc.spans[low..end], output) |span, *target| target.* = .{
        .start = @intCast(@max(span.start, line.start) - line.start),
        .end = @intCast(@min(span.end, line.end) - line.start),
        .italic = span.flags & md.emphasis != 0,
        .weight = if (span.flags & md.strong != 0) .bold else null,
        .strike = span.flags & md.strike != 0,
        .mono = span.flags & md.code != 0 and line.kind != .code and line.kind != .table,
        .underline = span.flags & md.link != 0,
        .color = if (span.flags & md.link != 0) ctx.theme.accent else null,
        .background = if (span.flags & md.code != 0 and line.kind != .code) ctx.theme.text.alpha(0.07) else null,
    };
    return output;
}
pub fn drawLine(ctx: *ui.Context, doc: *const md.Document, line: md.Line, size: f32) void {
    const style = textStyle(line, size);
    // Code-block backgrounds are painted full-width by the panel.
    _ = ctx.open(.{ .width = .auto, .height = .{ .px = lineHeight(line, size) } }, null);
    ui.richText(ctx, doc.text[line.start..line.end], lineSpans(ctx, doc, line), style);
    ctx.end();
}
/// Line-relative rendered byte offset -> actual shaped cluster origin. Carets within
/// a ligature share its origin; no re-shaping of prefixes changes kerning.
pub fn xAt(ctx: *ui.Context, doc: *const md.Document, line: md.Line, byte_offset: usize, size: f32) f32 {
    const text = doc.text[line.start..line.end];
    const layout = ui.rich.layout(ctx.text, text, textStyle(line, size), lineSpans(ctx, doc, line), 0);
    const at = @min(byte_offset, text.len);
    if (at == text.len) return layout.width;
    var index: usize = 0;
    var x: f32 = 0;
    var found = false;
    for (layout.glyphs) |glyph| if (glyph.index <= at) {
        if (!found or glyph.index > index) {
            index = glyph.index;
            x = glyph.x;
            found = true;
        } else if (glyph.index == index) x = @min(x, glyph.x);
    };
    return x;
}
/// Nearest visual cluster boundary -> line-relative rendered byte offset. The host
/// applies its grapheme floor/ceil index before constructing a selection.
pub fn hitTest(ctx: *ui.Context, doc: *const md.Document, line: md.Line, local_x: f32, size: f32) usize {
    const layout = ui.rich.layout(ctx.text, doc.text[line.start..line.end], textStyle(line, size), lineSpans(ctx, doc, line), 0);
    var distance = @abs(local_x - layout.width);
    var byte = line.end - line.start;
    for (layout.glyphs) |glyph| {
        const candidate = @abs(local_x - glyph.x);
        if (candidate < distance) {
            distance = candidate;
            byte = glyph.index;
        }
    }
    return @min(byte, line.end - line.start);
}
