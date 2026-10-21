//! Hidden native/portable geometry and interaction checks, private clipboard only.
const std = @import("std");
const ui = @import("nanoui").ui;
const panel = @import("panel.zig");
const render = @import("markdown_render.zig");
const math = @import("math_render.zig");
const flow = @import("flowchart_render.zig");
const fixtures = @import("markdown_extension_check.zig");
const View = struct {
    p: *panel.Panel,
    fn draw(self: *View, ctx: *ui.Context) void {
        const rect: ui.Rect = .{ .w = ctx.size.w, .h = ctx.size.h };
        _ = self.p.prepareInput(ctx, rect);
        _ = self.p.draw(ctx, rect);
    }
};
fn fixture(p: *panel.Panel, a: std.mem.Allocator, source: []const u8) !void {
    p.model.kind = .markdown;
    p.model.status = .ready;
    p.model.revision += 1;
    p.opened = true;
    p.focused = true;
    p.mode = .rendered;
    p.apply(try panel.Prepared.init(a, .markdown, source), p.model.revision);
}
fn check(count: *usize, ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI Preview Markdown {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.MarkdownExtensionCheck;
    count.* += 1;
}
pub fn run(a: std.mem.Allocator) !usize {
    var count: usize = 0;
    var p: panel.Panel = .{};
    defer p.deinit(a);
    try fixture(&p, a, fixtures.fixture);
    var view: View = .{ .p = &p };
    var t: ui.Tester = undefined;
    try t.init(a, .init(&view, View.draw), .{ .width = 420, .height = 650 });
    defer t.deinit();
    var md = &p.prepared.?.markdown.?;
    try check(&count, md.formulas.len == 5, "inline display and table math all reach native layout");
    var quoted_rows: usize = 0;
    var quote_visual: ?panel.VisualRow = null;
    for (p.visual_rows.items) |row| if (row.row < md.lines.len and md.lines[row.row].kind == .quote and md.lines[row.row].quote_depth == 1) {
        quoted_rows += 1;
        if (quote_visual == null) quote_visual = row;
    };
    try check(&count, quoted_rows >= 2 and quote_visual != null, "blockquote wraps into indented visual rows");
    const q = quote_visual.?;
    const indent = render.indent(md.lines[q.row], 14);
    t.click(p.body_rect.x + 24 + indent + 0.1, p.body_rect.y + q.y + 5);
    try check(&count, p.selection.caret == q.start, "blockquote pointer hit includes the same inset as painting");
    var tall = false;
    for (md.lines, 0..) |line, index| if (line.kind == .math) {
        tall = tall or p.row_y.items[index + 1] - p.row_y.items[index] > 35;
    };
    try check(&count, tall, "fractions and scripts reserve full ascent and descent");
    var atomic = true;
    for (md.formulas) |formula| {
        const logical = p.document().?.lineAt(formula.start);
        if (md.lines[logical].kind == .table) {
            for (p.tables.fragments.items) |fragment| if (fragment.block.start <= formula.start and fragment.block.end > formula.start) {
                atomic = atomic and fragment.block.end >= formula.end;
            };
        } else {
            var found = false;
            for (p.visual_rows.items) |row| if (row.start <= formula.start and row.end > formula.start) {
                found = row.end >= formula.end;
            };
            atomic = atomic and found;
        }
    }
    try check(&count, atomic, "wrapping never splits a TeX formula across visual rows or cells");
    const f = md.formulas[1];
    var block = md.lines[p.document().?.lineAt(f.start)];
    block.start = f.start;
    block.end = f.end;
    const w = math.measure(&t.ctx, f.node, 14).width;
    try check(&count, @abs(render.xAt(&t.ctx, md, block, f.end - f.start, 14) - w) < 0.1 and render.hitTest(&t.ctx, md, block, w * 0.2, 14) == 0 and render.hitTest(&t.ctx, md, block, w * 0.8, 14) == f.end - f.start, "formula hit mapping uses native box width and atomic endpoints");
    p.selection.place(p.document().?, f.start, false);
    p.selection.place(p.document().?, f.end, true);
    p.copy(&t.ctx);
    try check(&count, std.mem.eql(u8, t.clipboard.items, "x_i^2 + \\frac{a}{b}"), "formula selection copies exact TeX rather than visual approximations");
    t.resize(240, 650);
    var boundaries = true;
    for (p.visual_rows.items) |row| boundaries = boundaries and p.document().?.boundary(row.start) and p.document().?.boundary(row.end);
    try check(&count, boundaries, "narrow math prose preserves UTF-8 grapheme boundaries");
    try fixture(&p, a, "```mermaid\n" ++ fixtures.workflow ++ "\n```\n");
    p.show_find = true;
    p.query.set("Header");
    for (0..4) |_| t.frame();
    md = &p.prepared.?.markdown.?;
    const graph = md.lines[0].diagram.?;
    const g = flow.geometry(&t.ctx, graph, 14);
    const point = flow.pointAt(&t.ctx, graph, g, p.selection.range().start);
    try check(&count, graph.nodes.len == 7 and graph.edges.len == 7 and p.scroll_x_max > 0, "real workflow lays out all nodes and edges with horizontal overflow");
    try check(&count, p.match_count == 1 and p.scroll_x > 0 and point.x >= p.scroll_x and point.x < p.scroll_x + p.body_rect.w and p.row_y.items[0] + point.y >= p.scroll_y and p.row_y.items[0] + point.y < p.scroll_y + p.body_rect.h, "flowchart search reveals a far-right lower node on both axes");
    const at = p.selection.range().start;
    t.click(p.body_rect.x + 24 + point.x - p.scroll_x + 0.1, p.body_rect.y + p.row_y.items[0] + point.y - p.scroll_y + 5);
    try check(&count, p.selection.caret == at, "flowchart node pointer hit resolves the matching source text");
    p.selection.all(p.document().?);
    p.copy(&t.ctx);
    try check(&count, std.mem.eql(u8, t.clipboard.items, fixtures.workflow ++ "\n"), "selecting an entire flowchart copies exact multiline Mermaid source");
    @import("view.zig").copyCode(&p, &t.ctx, 0);
    try check(&count, std.mem.eql(u8, t.clipboard.items, fixtures.workflow ++ "\n"), "flowchart copy control preserves original labels arrows and newlines");
    p.show_find = false;
    try fixture(&p, a, "```mermaid\nsequenceDiagram\nA->>B: hello\n```\n\n$$\\unknown{x}$$\n");
    t.resize(640, 650);
    try check(&count, t.hasText("Unsupported Mermaid · source") and t.containsText("[Unsupported math]"), "unsupported diagram and formula syntax is explicitly visible as source");
    try fixture(&p, a, "# Heading $\\frac{a}{b}$\n\nNext paragraph\n");
    t.frame();
    md = &p.prepared.?.markdown.?;
    try check(&count, p.row_y.items[1] - p.row_y.items[0] >= render.lineHeight(md.lines[0], 14) and render.height(&t.ctx, md, md.lines[0], 14) > render.height(&t.ctx, md, md.lines[2], 14), "heading formulas scale with the heading and reserve their full height");
    try fixture(&p, a, "| Formula | After |\n|-|-|\n| $a+b+c+d+e+f+g+h+i+j+k+l+m+n+o+p$ | visible |\n");
    t.resize(240, 650);
    md = &p.prepared.?.markdown.?;
    const formula_cell = p.tables.cells.items[p.tables.rows.items[1].first];
    const formula_width = math.measure(&t.ctx, md.formulas[0].node, 14).width;
    try check(&count, formula_cell.width >= formula_width + 20 and p.scroll_x_max > 0, "wide table formulas enlarge their column instead of overlapping adjacent cells");
    return count;
}
