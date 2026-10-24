//! Product-owned attributed metrics using current public native text APIs.
//! The same disjoint font runs are painted by ui.richText. No private nanoui
//! module or retired ui.rich export is needed.
const std = @import("std");
const ui = @import("nanoui").ui;
fn styled(base: ui.TextStyle, spans: []const ui.Span, at: usize) ui.TextStyle {
    var result = base;
    for (spans) |span| if (span.start <= at and at < span.end) {
        if (span.weight) |weight| result.weight = weight;
        if (span.italic) result.italic = true;
        if (span.mono and !base.mono) {
            result.mono = true;
            result.size = base.size * 0.9;
        }
    };
    return result;
}
fn same(a: ui.TextStyle, b: ui.TextStyle) bool {
    return a.size == b.size and a.weight == b.weight and a.mono == b.mono and a.italic == b.italic;
}
pub fn layout(ctx: *ui.Context, value: []const u8, style: ui.TextStyle, spans: []const ui.Span, _: usize) @TypeOf(ctx.text.layout(value, style)) {
    const Layout = @TypeOf(ctx.text.layout(value, style));
    const Glyph = @typeInfo(@FieldType(Layout, "glyphs")).pointer.child;
    const TS = @typeInfo(@TypeOf(ctx.text)).pointer.child;
    var hash = std.hash.Wyhash.init(0xd0c0a771);
    for (spans) |span| {
        hash.update(std.mem.asBytes(&span.start));
        hash.update(std.mem.asBytes(&span.end));
        hash.update(&.{ if (span.weight) |w| @as(u8, @backingInt(w)) + 1 else 0, @intFromBool(span.italic), @intFromBool(span.mono) });
    }
    const key = TS.key(value, style, hash.final());
    if (ctx.text.cached(key)) |cached| return cached;
    var glyphs: std.ArrayList(Glyph) = .empty;
    var x: f32 = 0;
    var start: usize = 0;
    while (start < value.len) {
        const font = styled(style, spans, start);
        var end = start + 1;
        while (end < value.len and same(font, styled(style, spans, end))) end += 1;
        const run = ctx.text.layout(value[start..end], font);
        for (run.glyphs) |source| {
            var glyph = source;
            glyph.x += x;
            glyph.index += @intCast(start);
            glyphs.append(ctx.text.gpa, glyph) catch {
                glyphs.deinit(ctx.text.gpa);
                return .{ .width = 0, .glyphs = &.{} };
            };
        }
        x += run.width;
        start = end;
    }
    return ctx.text.keep(key, .{ .width = x, .glyphs = glyphs.toOwnedSlice(ctx.text.gpa) catch return .{ .width = 0, .glyphs = &.{} } });
}
