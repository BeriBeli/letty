//! Native rendered-width regressions, using owned hidden surfaces and files.
const std = @import("std");
const ui = @import("nanoui").ui;
const docs = @import("document-native");
const os = @import("platform.zig");
const md_render = docs.view;
const Scene = struct {
    document: *docs.Document,
    fn draw(self: *Scene, ctx: *ui.Context) void {
        _ = self.document.draw(ctx, .{ .w = ctx.size.w, .h = ctx.size.h });
    }
};
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.MarkdownWidthRegression;
}
fn capture(a: std.mem.Allocator, t: *ui.Tester, name: []const u8) !void {
    if (os.env("LETTY_UI_SCREENSHOT_DIR")) |directory| {
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ directory, name });
        defer a.free(path);
        try t.screenshot(path);
    }
}
fn settle(document: *docs.Document, t: *ui.Tester) !void {
    const until = os.millis() + 6000;
    while (os.millis() < until) {
        @import("nanoui").runFor(0.01);
        try document.drain();
        t.frame();
        if (document.panel.editor != null and document.job == null and document.draft_revision == document.panel.editor.?.buffer.revision) return;
    }
    return error.MarkdownWidthTimeout;
}
fn fits(t: *ui.Tester, p: *docs.panel.Panel) bool {
    const doc = p.document().?;
    const markdown = if (p.rich) |*rich| &rich.markdown else &p.prepared.?.markdown.?;
    var valid = true;
    for (p.visual_rows.items, 0..) |row, i| {
        if (row.height == 0) continue; // A successfully fitted image hides its alt label.
        if (row.row >= markdown.lines.len) continue; // Flat text keeps the final empty row.
        var block = markdown.lines[row.row];
        if (block.kind == .code or block.kind == .table or block.kind == .rule or block.kind == .diagram or block.kind == .math) continue;
        block.start = row.start;
        block.end = row.end;
        const before = p.prepared;
        defer p.prepared = before;
        p.prepared.?.markdown = markdown.*;
        const width = md_render.xAt(p, &t.ctx, i, row.end);
        if (!doc.boundary(row.start) or !doc.boundary(row.end) or width > p.body_rect.w - 52 + 10) {
            std.debug.print("WIDTH row={d} body={d} measured={d} depth={d} text={s}\n", .{ i, p.body_rect.w, width, block.quote_depth, markdown.text[row.start..row.end] });
            valid = false;
        }
        // Independently measure the actual native text node, rather than only
        // trusting the product's glyph map used above for invisible rows.
        for (t.ctx.nodes.items) |node| if (node.content == .text and node.rect.y + node.rect.h >= p.body_rect.y and node.rect.y < p.body_rect.y + p.body_rect.h and std.mem.eql(u8, node.content.text.str, markdown.text[row.start..row.end])) {
            const native = t.text.wrapAttributed(node.content.text.str, node.content.text.style, node.content.text.spans, 1e6);
            if (native.len > 0 and node.rect.x + native[0].width > p.body_rect.x + p.body_rect.w - 16 + 2) valid = false;
        };
    }
    return valid;
}
fn find(t: *ui.Tester, p: *docs.panel.Panel, needle: []const u8) !void {
    p.show_find = true;
    p.query.set(needle);
    p.search_valid = false;
    t.frame();
    if (p.match_count != 1) {
        std.debug.print("WIDTH FIND needle={s} query={s} matches={d} field={s} index={?d} composing={} notice={s}\n", .{ needle, p.query.text(), p.match_count, @tagName(p.field), std.mem.indexOf(u8, p.document().?.text, needle), docs.view.composing(&t.ctx), p.notice.text() });
        return error.MarkdownWidthMissingTail;
    }
    t.frame();
}
fn point(t: *ui.Tester, p: *docs.panel.Panel, at: usize) !ui.Point {
    for (p.visual_rows.items, 0..) |row, i| if (at >= row.start and (at < row.end or at == p.document().?.text.len)) {
        const saved = p.prepared;
        defer p.prepared = saved;
        if (p.rich) |*rich| p.prepared.?.markdown = rich.markdown;
        return .{ .x = p.body_rect.x + 24 + docs.view.xAt(p, &t.ctx, i, at) - docs.view.horizontal(p, i), .y = p.body_rect.y + row.y - p.scroll_y + 8 };
    };
    return error.MarkdownWidthMissingRow;
}
fn coverage(p: *docs.panel.Panel) bool {
    for (p.document().?.lines, 0..) |line, logical| {
        var at = line.start;
        for (p.visual_rows.items) |row| if (row.row == logical) {
            if (row.start != at) return false;
            at = row.end;
        };
        if (at != line.end) return false;
    }
    return true;
}
pub fn verify(a: std.mem.Allocator, root: []const u8) !void {
    const file = try std.fmt.allocPrint(a, "{s}/markdown-width.md", .{root});
    defer a.free(file);
    const source =
        "# A_heading_with_a_long_uninterrupted_identifier_HEADING_END\n\n" ++
        "Ordinary paragraphs with **bold words** and *italic words* wrap with native metrics. 中文段落保留全部文字 é 👩‍💻 and reach PARAGRAPH_END.\n\n" ++
        "> > > > > > > > > > > > > > > Nested quoted words must remain visible at QUOTE_END.\n\n" ++
        "- List words with [https://example.invalid/a/long/label/LINK_END](https://example.invalid) and `some_long_inline_identifier_INLINE_END`. LIST_END.\n\n" ++
        "| Description | Value |\n|---|---|\n| A very long table cell with 中文 é 👩‍💻 words reaches TABLE_END | More long words and information reach CELL_END |\n\n" ++
        "Inline $E=mc^2$ with more ordinary words reaching MATH_PROSE_END.\n\n" ++
        "```text\nCODE_BEGIN_abcdefghijklmnopqrstuvwxyz_abcdefghijklmnopqrstuvwxyz_abcdefghijklmnopqrstuvwxyz_CODE_END\nshort line\n```\n\n" ++
        "```mermaid\nflowchart LR\nA[First node] --> B[Second node] --> C[CHART_TAIL]\n```\n\n" ++
        "| one | two | three | four | five | six | seven | WIDE_CELL_END |\n|---|---|---|---|---|---|---|---|\n| a | b | c | d | e | f | g | h |\n\n" ++
        "$$\na+b+c+d+e+f+g+h+i+j+k+l+m+n+o+p+q+r+s+t+u+v+w+x+y+z\n$$\n\n" ++
        "![WIDTH_IMAGE](width-image.png)\n\n" ++
        "Final words reaching DOCUMENT_END.\n";
    const image_file = try std.fmt.allocPrint(a, "{s}/width-image.png", .{root});
    defer a.free(image_file);
    var image_pixels: [512 * 64 * 4]u8 = undefined;
    for (0..512 * 64) |i| image_pixels[i * 4 ..][0..4].* = .{ 20, 120, 220, 255 };
    const png = try ui.png.encode(a, .{ .width = 512, .height = 64, .bytes = &image_pixels });
    defer a.free(png);
    try os.atomicFile(a, image_file, png);
    defer {
        const z = a.dupeSentinel(u8, image_file, 0) catch unreachable;
        defer a.free(z);
        _ = os.c.unlink(z);
    }
    try os.atomicFile(a, file, source);
    defer {
        const z = a.dupeSentinel(u8, file, 0) catch unreachable;
        defer a.free(z);
        _ = os.c.unlink(z);
    }
    const document = try docs.Document.create(a, 991991, file, .{});
    defer document.destroy();
    var scene: Scene = .{ .document = document };
    var t: ui.Tester = undefined;
    try t.init(a, .init(&scene, Scene.draw), .{ .width = 320, .height = 720 });
    defer t.deinit();
    try settle(document, &t);
    try capture(a, &t, "document-width-narrow.png");
    const p = &document.panel;
    try check(fits(&t, p) and coverage(p), "rendered narrow heading paragraphs nested quotes and lists fit without dropping source bytes");
    const initial_rows = p.visual_rows.items.len;
    t.resize(640, 720);
    try check(fits(&t, p) and p.visual_rows.items.len < initial_rows, "widening the reading card rebuilds visual rows rather than retaining its narrow cache");
    t.resize(240, 720);
    try check(fits(&t, p) and coverage(p), "initial and cached layouts retain Chinese emoji long links and inline code in a 240 point card");
    t.resize(320, 720);
    for (0..6) |_| {
        docs.view.zoom(p, &t.ctx, true);
        t.frame();
    }
    try check(fits(&t, p) and p.layout_zoom == p.zoom, "zoom reflows both native text and compressed quote indentation at the final reading width");
    for (0..6) |_| {
        docs.view.zoom(p, &t.ctx, false);
        t.frame();
    }
    try find(&t, p, "QUOTE_END");
    const target = p.matches[0].start;
    const at = try point(&t, p, target);
    try check(p.body_rect.contains(at), "Find reveals the formerly clipped nested quote tail inside the actual reading viewport");
    try capture(a, &t, "document-width-quote.png");
    t.click(at.x + 0.1, at.y);
    try check(p.selection.caret == target and t.ctx.focused_text != null, "pointer placement at a wrapped tail shares the rendered glyph and caret geometry");
    t.textOps(&.{.{ .insert = "EDIT_" }});
    try check(fits(&t, p) and coverage(p), "optimistic rendered edits immediately reflow using the current narrow width");
    try settle(document, &t);
    try check(fits(&t, p) and coverage(p), "background Markdown reconciliation retains the same complete narrow layout");
    try find(&t, p, "CODE_END");
    try check(p.scroll_x > 0, "Find reaches the last characters of an unwrapped code block");
    const original_selection = p.selection;
    const track_y = p.body_rect.y + p.body_rect.h - 6;
    t.click(p.body_rect.x + 26, track_y);
    t.key(.home);
    try check(p.scroll_x == 0 and p.selection.caret == original_selection.caret, "horizontal track Home scrolls to its beginning without moving the text caret");
    const vertical_before = p.scroll_y;
    t.ctx.input.shift = true;
    t.scroll(p.body_rect.x + 60, p.body_rect.y + 60, -100);
    t.ctx.input.shift = false;
    try check(p.scroll_x > 0 and p.scroll_y == vertical_before, "Shift-wheel pans wide Markdown resources without changing vertical position");
    t.key(.home);
    const track = t.ctx.rects.get(p.scrollbar_x_id).?;
    t.drag(track.x + 4, track.y + 6, track.x + track.w - 1, track.y + 6);
    try check(p.scroll_x > p.scroll_x_max * 0.9, "dragging the horizontal thumb reaches the far edge of wide code tables and diagrams");
    t.key(.end);
    try check(@abs(p.scroll_x - p.scroll_x_max) < 1, "a focused horizontal scrollbar accepts keyboard End at the exact content boundary");
    var table_visible = false;
    for (t.ctx.nodes.items) |node| if (node.content == .text and std.mem.indexOf(u8, node.content.text.str, "TABLE_END") != null) {
        table_visible = node.rect.x >= p.body_rect.x and node.rect.x + node.rect.w <= p.body_rect.x + p.body_rect.w;
    };
    try check(table_visible, "panning long code cannot scroll a narrower fitted table out of the reading viewport");
    var previous_code_pan: ?f32 = null;
    var code_aligned = true;
    for (p.visual_rows.items, 0..) |row, i| if (p.rich.?.markdown.lines[row.row].kind == .code) {
        const pan = docs.view.horizontal(p, i);
        if (previous_code_pan) |previous| code_aligned = code_aligned and previous == pan;
        previous_code_pan = pan;
    };
    try check(code_aligned and previous_code_pan != null, "all lines of the same code block retain shared horizontal alignment");
    try capture(a, &t, "document-width-code.png");
    try find(&t, p, "CHART_TAIL");
    try capture(a, &t, "document-width-diagram.png");
    try find(&t, p, "WIDE_CELL_END");
    try capture(a, &t, "document-width-table.png");
    try check(p.scroll_x > 0 and coverage(p), "Find pans into the last column of a truly wide table without losing its other cells");
    try find(&t, p, "v+w+x+y+z");
    var formula_tail_visible = false;
    for (t.ctx.nodes.items) |node| if (node.content == .text and std.mem.eql(u8, node.content.text.str, "z")) {
        formula_tail_visible = node.rect.x >= p.body_rect.x and node.rect.x + node.rect.w <= p.body_rect.x + p.body_rect.w;
    };
    try check(formula_tail_visible, "the far end of an oversized atomic formula remains horizontally reachable");
    try capture(a, &t, "document-width-math.png");
    try find(&t, p, "WIDTH_IMAGE");
    var fitted = false;
    for (t.ctx.nodes.items) |node| if (node.content == .texture) {
        fitted = node.rect.x >= p.body_rect.x and node.rect.x + node.rect.w <= p.body_rect.x + p.body_rect.w;
    };
    try check(fitted, "fitted Markdown images remain inside the card after horizontal code or table scrolling");
    try find(&t, p, "PARAGRAPH_END");
    const prose_point = try point(&t, p, p.matches[0].start);
    t.click(prose_point.x + 0.1, prose_point.y);
    t.textOps(&.{.{ .set_marked = .{ .text = "中文", .sel_start = 3, .sel_len = 0 } }});
    try check(t.ctx.focused_text != null and p.body_rect.contains(.{ .x = t.ctx.focused_text.?.caret_rect.x, .y = t.ctx.focused_text.?.caret_rect.y }), "rendered caret and IME stay aligned with wrapped prose after horizontal resource scrolling");
    try capture(a, &t, "document-width-ime.png");
    t.textOps(&.{.{ .command = .cancel }});
    t.theme = ui.Theme.dark_theme;
    try find(&t, p, "DOCUMENT_END");
    try capture(a, &t, "document-width-dark.png");
    try check(p.body_rect.contains(try point(&t, p, p.matches[0].start)), "the last paragraph remains vertically reachable in the dark narrow card");
    const vertical = t.ctx.rects.get(p.scrollbar_y_id).?;
    t.click(vertical.x + 6, vertical.y + 2);
    t.key(.end);
    try check(p.scroll_y > 0 and @abs(p.scroll_y - @max(0, p.row_y.items[p.row_y.items.len - 1] - p.body_rect.h)) < 1, "vertical scrollbar keyboard End reaches the complete wrapped document height");
    p.live_split = true;
    t.resize(1040, 720);
    document.preview.prepared = p.prepared;
    const split_fits = fits(&t, &document.preview);
    document.preview.prepared = null;
    try check(document.preview.layout_width == document.preview.body_rect.w and document.preview.body_rect.w < 520 and split_fits, "Source plus Preview lays out its passive Markdown using the final half width");
    var controls_distinct = true;
    for (p.ax_controls[0..p.ax_count]) |left| for (document.preview.ax_controls[0..document.preview.ax_count]) |right| {
        controls_distinct = controls_distinct and left.widget != right.widget;
    };
    try check(controls_distinct and p.ax_body != document.preview.ax_body, "source and passive preview keep distinct widget IDs and do not overwrite each other's rectangles");
    try capture(a, &t, "document-width-split.png");
    t.resize(320, 720);
    p.live_split = false;
    p.editor_rendered = true;
    t.frame();
    try check(fits(&t, p) and coverage(p), "returning from split preview to a narrow rendered editor invalidates both layouts");
}
