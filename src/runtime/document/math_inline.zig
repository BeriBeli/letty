//! Inline formulas are atomic boxes. Text, wrapping and hit mapping share widths;
//! selecting a formula selects its TeX source, which also remains searchable.
const std = @import("std");
const ui = @import("nanoui").ui;
const md = @import("markdown.zig");
const render = @import("markdown_render.zig");
const math = @import("math_render.zig");
const Formula = @import("markdown_extensions.zig").Formula;
pub fn first(doc: *const md.Document, line: md.Line) usize {
    var low: usize = 0;
    var high = doc.formulas.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (doc.formulas[mid].end <= line.start) low = mid + 1 else high = mid;
    }
    return low;
}
pub fn has(doc: *const md.Document, line: md.Line) bool {
    const i = first(doc, line);
    return i < doc.formulas.len and doc.formulas[i].start < line.end;
}
fn part(line: md.Line, start: usize, end: usize) md.Line {
    var out = line;
    out.start = start;
    out.end = end;
    return out;
}
fn width(ctx: *ui.Context, doc: *const md.Document, line: md.Line, size: f32) f32 {
    return @import("rich_layout.zig").layout(ctx, doc.text[line.start..line.end], render.textStyle(line, size), render.lineSpans(ctx, doc, line), 0).width;
}
pub fn metrics(ctx: *ui.Context, doc: *const md.Document, line: md.Line, size: f32) math.Box {
    const font_size = render.textStyle(line, size).size;
    var out: math.Box = .{ .width = 0, .ascent = font_size * 1.05, .descent = font_size * 0.6 };
    var at = line.start;
    for (doc.formulas[first(doc, line)..]) |formula| {
        if (formula.start >= line.end) break;
        out.width += width(ctx, doc, part(line, at, formula.start), size);
        const box = math.measure(ctx, formula.node, render.textStyle(line, size).size);
        out.width += box.width;
        out.ascent = @max(out.ascent, box.ascent);
        out.descent = @max(out.descent, box.descent + font_size * 0.2);
        at = formula.end;
    }
    out.width += width(ctx, doc, part(line, at, line.end), size);
    return out;
}
pub fn draw(ctx: *ui.Context, doc: *const md.Document, line: md.Line, size: f32) void {
    const box = metrics(ctx, doc, line, size);
    var x: f32 = 0;
    var at = line.start;
    for (doc.formulas[first(doc, line)..]) |formula| {
        if (formula.start >= line.end) break;
        drawText(ctx, doc, part(line, at, formula.start), size, x, box.ascent - render.textStyle(line, size).size * 1.05);
        x += width(ctx, doc, part(line, at, formula.start), size);
        math.draw(ctx, formula.node, render.textStyle(line, size).size, x, box.ascent);
        x += math.measure(ctx, formula.node, render.textStyle(line, size).size).width;
        at = formula.end;
    }
    drawText(ctx, doc, part(line, at, line.end), size, x, box.ascent - render.textStyle(line, size).size * 1.05);
}
fn drawText(ctx: *ui.Context, doc: *const md.Document, line: md.Line, size: f32, x: f32, y: f32) void {
    if (line.start == line.end) return;
    ui.column(ctx, .{ .absolute = true, .offset = .{ .x = x, .y = y } });
    ui.richText(ctx, doc.text[line.start..line.end], render.lineSpans(ctx, doc, line), render.textStyle(line, size));
    ui.end(ctx);
}
pub fn xAt(ctx: *ui.Context, doc: *const md.Document, line: md.Line, byte: usize, size: f32) f32 {
    const target = @min(line.end, line.start + byte);
    var x: f32 = 0;
    var at = line.start;
    for (doc.formulas[first(doc, line)..]) |formula| {
        if (formula.start >= line.end) break;
        if (target <= formula.start) return x + render.plainXAt(ctx, doc, part(line, at, formula.start), target - at, size);
        x += width(ctx, doc, part(line, at, formula.start), size);
        const w = math.measure(ctx, formula.node, render.textStyle(line, size).size).width;
        if (target < formula.end) return x + if (target - formula.start < (formula.end - formula.start) / 2) @as(f32, 0) else w;
        x += w;
        at = formula.end;
    }
    return x + render.plainXAt(ctx, doc, part(line, at, line.end), target - at, size);
}
pub fn hit(ctx: *ui.Context, doc: *const md.Document, line: md.Line, x: f32, size: f32) usize {
    var at = line.start;
    var offset: f32 = 0;
    for (doc.formulas[first(doc, line)..]) |formula| {
        if (formula.start >= line.end) break;
        const w = width(ctx, doc, part(line, at, formula.start), size);
        if (x <= offset + w) return at - line.start + render.plainHitTest(ctx, doc, part(line, at, formula.start), x - offset, size);
        offset += w;
        const fw = math.measure(ctx, formula.node, render.textStyle(line, size).size).width;
        if (x < offset + fw) return (if (x - offset < fw / 2) formula.start else formula.end) - line.start;
        offset += fw;
        at = formula.end;
    }
    return at - line.start + render.plainHitTest(ctx, doc, part(line, at, line.end), x - offset, size);
}
pub const Wrapped = struct { start: usize };
pub fn wrap(ctx: *ui.Context, doc: *const md.Document, line: md.Line, size: f32, available: f32) []const Wrapped {
    var rows: std.ArrayList(Wrapped) = .empty;
    rows.append(ctx.alloc(), .{ .start = 0 }) catch return &.{};
    var at = line.start;
    var x: f32 = 0;
    var fi = first(doc, line);
    while (at < line.end) {
        if (fi < doc.formulas.len and doc.formulas[fi].start == at) {
            const f = doc.formulas[fi];
            const w = math.measure(ctx, f.node, render.textStyle(line, size).size).width;
            if (x > 0 and x + w > available) {
                rows.append(ctx.alloc(), .{ .start = at - line.start }) catch return rows.items;
                x = 0;
            }
            x += w;
            at = f.end;
            fi += 1;
            continue;
        }
        const limit = if (fi < doc.formulas.len) @min(line.end, doc.formulas[fi].start) else line.end;
        if (x > 0) {
            const block = part(line, at, limit);
            const wrapped = ctx.text.wrapAttributed(doc.text[at..limit], render.textStyle(block, size), render.lineSpans(ctx, doc, block), @max(1, available - x));
            const end = if (wrapped.len > 1) at + wrapped[1].start else limit;
            const w = width(ctx, doc, part(line, at, end), size);
            if (x + w <= available or w == 0) {
                x += w;
                at = end;
                if (at == limit) continue;
            }
            rows.append(ctx.alloc(), .{ .start = at - line.start }) catch return rows.items;
            x = 0;
        }
        const block = part(line, at, limit);
        const wrapped = ctx.text.wrapAttributed(doc.text[at..limit], render.textStyle(block, size), render.lineSpans(ctx, doc, block), @max(1, available));
        for (wrapped, 0..) |row, i| {
            if (i > 0) rows.append(ctx.alloc(), .{ .start = at + row.start - line.start }) catch return rows.items;
            const end = if (i + 1 < wrapped.len) at + wrapped[i + 1].start else limit;
            x = width(ctx, doc, part(line, at + row.start, end), size);
        }
        at = limit;
    }
    return rows.items;
}
