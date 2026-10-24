//! Editable native Markdown: uses the reader's actual glyph hit geometry and
//! paints the same rich IR, with native text-client caret/IME metadata.
const std = @import("std");
const ui = @import("nanoui").ui;
const view = @import("view.zig");
const md = @import("markdown.zig");
const Model = @import("rich_model.zig").Projection;
const text = @import("text_buffer.zig");
const a = std.heap.page_allocator;
pub fn draw(p: anytype, ctx: *ui.Context) void {
    p.inline_link = false;
    inner(p, ctx) catch |err| {
        p.notice.set(message(err));
    };
}
pub fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.EditResourceInSource, error.EditCodeDelimiterInSource => "Use Source to edit code, formulas, diagrams or image references.",
        error.EditFormattedBreakInSource => "Use Source to split an existing formatted span across paragraphs.",
        error.EditOneTextBlock, error.EditTextBlock => "Edit within one text block. Use Source for changes across blocks.",
        error.EditTableCell => "Edit within one table cell. Use Source to change table structure.",
        error.PreviewUpdating => "Updating document…",
        else => @errorName(err),
    };
}
fn ensure(p: anytype) !void {
    const editor = p.editor.?;
    if (p.rich != null and p.rich.?.revision == editor.buffer.revision) return;
    p.clearRich();
    p.rich = try Model.init(a, &p.prepared.?.markdown.?, &editor.buffer);
    if (std.mem.eql(u8, p.notice.text(), "Updating document…")) p.notice.set("");
    p.selection.caret = p.rich.?.displayAtSource(editor.buffer.caret, editor.buffer.text);
    p.selection.anchor = p.rich.?.displayAtSource(editor.buffer.anchor, editor.buffer.text);
    p.layout_width = -1;
}
fn bind(p: anytype, model: *const Model, original: anytype) void {
    var borrowed = original;
    borrowed.markdown = model.markdown;
    borrowed.rendered = model.rendered;
    // Images retain their owner; locate their current row through the unchanged
    // image reference, even when optimistic paragraph breaks shift later rows.
    for (borrowed.images[0..borrowed.image_count]) |*maybe| if (maybe.*) |*image| if (image.line) |old_line| {
        for (original.markdown.?.links) |old| if (old.image and old.line == old_line) {
            for (model.markdown.links) |link| if (link.image and std.mem.eql(u8, old.target, link.target)) {
                image.line = link.line;
                break;
            };
            break;
        };
    };
    p.prepared = borrowed;
}
fn inner(p: anytype, ctx: *ui.Context) !void {
    // Native nodes borrow strings until layout/painting AFTER the view returns.
    // Retire the preceding frame's marked-text projection only on the next draw.
    if (p.rich_preedit) |*previous| previous.deinit();
    p.rich_preedit = null;
    try ensure(p);
    const original = p.prepared.?;
    defer p.prepared = original;
    p.rich_bound = true;
    defer p.rich_bound = false;
    bind(p, &p.rich.?, original);
    try view.ensureLayout(p, ctx);
    const scrolling = view.scrollInput(p, ctx);
    const editor = p.editor.?;
    // Responsive chrome may reparent the body and therefore change its toolkit
    // ID. Retarget only the focus previously owned by this same document.
    if (p.rich_focus_id != 0 and ctx.focus == p.rich_focus_id and p.focused and p.field == .body) ctx.focus = p.ax_body;
    if (editor.focus) {
        ctx.focus = p.ax_body;
        p.focused = true;
        p.field = .body;
        editor.focus = false;
    }
    if (p.body_frame != ctx.frame) {
        p.body_frame = ctx.frame;
        const over = p.body_rect.contains(ctx.input.mouse);
        if (!scrolling and over and ctx.input.pressed and ctx.input.mouse_button == 1 and editor.composition.range == null) {
            p.field = .body;
            p.focused = true;
            ctx.focus = p.ax_body;
            p.selection.place(p.document().?, view.hit(p, ctx, ctx.input.mouse), ctx.input.shift);
            p.selection.dragging = true;
        }
        if (p.selection.dragging and ctx.input.down) {
            p.selection.place(p.document().?, view.hit(p, ctx, ctx.input.mouse), true);
            if (ctx.input.mouse.y < p.body_rect.y) p.scroll_y -= 16;
            if (ctx.input.mouse.y > p.body_rect.y + p.body_rect.h) p.scroll_y += 16;
        }
        if (ctx.input.released) {
            p.selection.dragging = false;
            if (over and p.selection.anchor == p.selection.caret and (ctx.input.cmd or ctx.input.ctrl)) {
                for (p.rich.?.markdown.links) |link| if (link.safe and !link.image and p.selection.caret >= link.start and p.selection.caret < link.end) {
                    if (std.mem.startsWith(u8, link.target, "#")) {
                        _ = p.anchor(link.target);
                    } else {
                        p.link_target.set(link.target);
                        p.inline_link = true;
                    }
                    break;
                };
            }
        }
        if (over) {
            view.wheel(p, ctx);
            if (!scrolling) ctx.cursor = .text;
        }
        if (p.focused and p.field == .body and ctx.focus == p.ax_body) {
            input(p, ctx) catch |err| {
                p.notice.set(message(err));
                ctx.changed = true;
            };
            if (p.rich.?.sourceAt(p.selection.caret)) |pos| editor.buffer.caret = pos;
            if (p.rich.?.sourceAt(p.selection.anchor)) |pos| editor.buffer.anchor = pos;
        }
        editor.update();
    }
    // Input can replace the optimistic arena. Rebind before touching its text.
    bind(p, &p.rich.?, original);
    const b = text.Buffer{ .text = p.rich.?.rendered.text, .caret = p.selection.caret, .anchor = p.selection.anchor };
    const display = try editor.composition.display(ctx.alloc(), &b);
    const selection = p.selection;
    defer p.selection = selection;
    if (editor.composition.range) |range| {
        p.rich_preedit = try p.rich.?.preedit(a, range[0], range[1], editor.composition.text);
        bind(p, &p.rich_preedit.?, original);
        p.selection.caret = display.caret;
        p.selection.anchor = display.anchor;
        p.layout_width = -1;
    }
    try view.ensureLayout(p, ctx);
    const max_y = @max(0, p.row_y.items[p.row_y.items.len - 1] - p.body_rect.h);
    if (p.reveal_match) view.revealMatch(p, ctx);
    p.scroll_y = std.math.clamp(p.scroll_y, 0, max_y);
    const caret = caretPoint(p, ctx, display.caret);
    if (ctx.focus == p.ax_body and (ctx.input.ops.len > 0 or ctx.input.key != null or ctx.input.shortcut != null)) {
        if (caret.y < p.body_rect.y) p.scroll_y = @max(0, p.scroll_y - (p.body_rect.y - caret.y)) else if (caret.y + caret.h > p.body_rect.y + p.body_rect.h) p.scroll_y += caret.y + caret.h - p.body_rect.y - p.body_rect.h;
    }
    const first = view.visualAt(p, p.scroll_y);
    const last = @min(p.visual_rows.items.len, view.visualAt(p, p.scroll_y + p.body_rect.h) + 2);
    for (first..last) |i| view.drawLine(p, ctx, i);
    if (ctx.focus == p.ax_body and p.focused and p.field == .body) {
        p.rich_focus_id = p.ax_body;
        const point = caretPoint(p, ctx, display.caret);
        _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = point.x - p.body_rect.x, .y = point.y - p.body_rect.y }, .width = .{ .px = 1 }, .height = .{ .px = point.h }, .background = ctx.theme.accent }, .none, null);
        if (display.marked) |marked| for (first..last) |i| {
            const row = p.visual_rows.items[i];
            const start = @max(marked[0], row.start);
            const end = @min(marked[1], row.end);
            if (end <= start) continue;
            const x = view.xAt(p, ctx, i, start);
            const right = view.xAt(p, ctx, i, end);
            _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = 24 + x - view.horizontal(p, i), .y = row.y + row.height - 2 - p.scroll_y }, .width = .{ .px = @max(1, right - x) }, .height = .{ .px = 1 }, .background = ctx.theme.accent }, .none, null);
        };
        ctx.focused_text = .{ .id = p.ax_body, .editable = true, .text = try ctx.alloc().dupe(u8, display.text), .caret = display.caret, .anchor = display.anchor, .marked = display.marked, .caret_rect = point };
    }
    view.scrollbar(p, ctx);
    if (p.rich_preedit != null) p.layout_width = -1;
}
fn caretPoint(p: anytype, ctx: *ui.Context, at_raw: usize) ui.Rect {
    const at = @min(at_raw, p.document().?.text.len);
    var index: usize = 0;
    for (p.visual_rows.items, 0..) |row, i| {
        if (row.start > at) break;
        index = i;
        if (at < row.end) break;
    }
    const row = p.visual_rows.items[index];
    const block = p.prepared.?.markdown.?.lines[row.row];
    if (block.kind == .table) {
        const point = p.tables.pointAt(ctx, &p.prepared.?.markdown.?, row.row, at, 14 * p.zoom);
        return .{ .x = p.body_rect.x + 24 + view.blockIndent(p, block) + point.x - view.horizontal(p, index), .y = p.body_rect.y + row.y + point.y - p.scroll_y, .w = 1, .h = 21 * p.zoom };
    }
    const font = @import("markdown_render.zig").textStyle(block, 14 * p.zoom);
    return .{ .x = p.body_rect.x + 24 + view.xAt(p, ctx, index, @min(at, row.end)) - view.horizontal(p, index), .y = p.body_rect.y + row.y - p.scroll_y, .w = 1, .h = @max(16 * p.zoom, font.size * 1.2) };
}
fn replace(p: anytype, value: []const u8) !void {
    const range = p.editor.?.composition.range orelse .{ @min(p.selection.anchor, p.selection.caret), @max(p.selection.anchor, p.selection.caret) };
    const caret = try p.rich.?.replace(a, &p.editor.?.buffer, range[0], range[1], value);
    p.editor.?.composition.clear(a);
    p.selection = .{ .caret = caret, .anchor = caret };
    p.layout_width = -1;
    p.search_valid = false;
    p.notice.set("");
    p.prepared.?.markdown = p.rich.?.markdown;
    p.prepared.?.rendered = p.rich.?.rendered;
}
fn finish(p: anytype) !void {
    if (p.editor.?.composition.range != null) try replace(p, p.editor.?.composition.text);
}
fn command(p: anytype, ctx: *ui.Context, cmd: ui.Command) !void {
    if (cmd == .cancel) {
        if (p.editor.?.composition.range != null) p.editor.?.composition.clear(a) else {
            p.focused = false;
            ctx.focus = 0;
        }
        return;
    }
    try finish(p);
    const doc = &p.rich.?.rendered;
    const range = p.selection.range();
    switch (cmd) {
        .insert_newline, .insert_line_break => try replace(p, "\n"),
        .insert_tab => try replace(p, "\t"),
        .delete_backward, .delete_forward, .delete_word_backward, .delete_word_forward, .delete_to_line_start, .delete_to_line_end => {
            if (range.start == range.end) {
                const b = text.Buffer{ .text = doc.text, .caret = range.start };
                p.selection.anchor = switch (cmd) {
                    .delete_backward => doc.previous(range.start),
                    .delete_forward => doc.next(range.end),
                    .delete_word_backward => b.wordLeft(range.start),
                    .delete_word_forward => b.wordRight(range.end),
                    .delete_to_line_start => doc.lines[doc.lineAt(range.start)].start,
                    .delete_to_line_end => doc.lines[doc.lineAt(range.end)].end,
                    else => unreachable,
                };
            }
            try replace(p, "");
        },
        .select_all => p.selection.all(doc),
        .copy, .cut => {
            p.copy(ctx);
            ctx.copy_done = true;
            if (cmd == .cut) try replace(p, "");
        },
        .move_left, .select_left => p.selection.move(doc, .left, cmd == .select_left),
        .move_right, .select_right => p.selection.move(doc, .right, cmd == .select_right),
        .move_word_left, .select_word_left, .move_word_right, .select_word_right => {
            const b = text.Buffer{ .text = doc.text };
            p.selection.place(doc, if (cmd == .move_word_left or cmd == .select_word_left) b.wordLeft(p.selection.caret) else b.wordRight(p.selection.caret), cmd == .select_word_left or cmd == .select_word_right);
        },
        .move_line_start, .select_line_start => p.selection.move(doc, .home, cmd == .select_line_start),
        .move_line_end, .select_line_end => p.selection.move(doc, .end, cmd == .select_line_end),
        .move_up, .select_up, .move_down, .select_down => {
            try view.ensureLayout(p, ctx);
            const old = ctx.input.shift;
            ctx.input.shift = cmd == .select_up or cmd == .select_down;
            defer ctx.input.shift = old;
            view.moveVisual(p, ctx, cmd == .move_down or cmd == .select_down);
        },
        .cancel => unreachable,
    }
}
fn input(p: anytype, ctx: *ui.Context) !void {
    if (ctx.input.shortcut) |shortcut| if ((shortcut.cmd or shortcut.ctrl) and !shortcut.alt) {
        switch (shortcut.key) {
            'a' => try command(p, ctx, .select_all),
            'c' => try command(p, ctx, .copy),
            'x' => try command(p, ctx, .cut),
            'z' => {
                p.editor.?.composition.clear(a);
                try p.editor.?.undo(shortcut.shift);
                var rebuilt = try Model.fromSource(a, &p.editor.?.buffer);
                errdefer rebuilt.deinit();
                p.clearRich();
                p.rich = rebuilt;
                p.prepared.?.markdown = p.rich.?.markdown;
                p.prepared.?.rendered = p.rich.?.rendered;
                p.selection = .{ .caret = p.rich.?.displayAtSource(p.editor.?.buffer.caret, p.editor.?.buffer.text), .anchor = p.rich.?.displayAtSource(p.editor.?.buffer.anchor, p.editor.?.buffer.text) };
                p.layout_width = -1;
            },
            else => return,
        }
        ctx.shortcut_taken = true;
        ctx.changed = true;
        return;
    };
    for (ctx.input.ops) |op| switch (op) {
        .insert => |value| try replace(p, value),
        .set_marked => |marked| {
            const b = text.Buffer{ .text = p.rich.?.rendered.text, .caret = p.selection.caret, .anchor = p.selection.anchor };
            try p.rich.?.checkRange(@min(b.caret, b.anchor), @max(b.caret, b.anchor));
            try p.editor.?.composition.set(a, &b, marked.text, marked.sel_start, marked.sel_len);
        },
        .unmark => try finish(p),
        .command => |cmd| try command(p, ctx, cmd),
    };
    if (ctx.input.ops.len == 0) {
        if (ctx.input.key) |key| {
            const cmd: ?ui.Command = switch (key) {
                .left => if (ctx.input.shift) .select_left else .move_left,
                .right => if (ctx.input.shift) .select_right else .move_right,
                .up => if (ctx.input.shift) .select_up else .move_up,
                .down => if (ctx.input.shift) .select_down else .move_down,
                .home => if (ctx.input.shift) .select_line_start else .move_line_start,
                .end => if (ctx.input.shift) .select_line_end else .move_line_end,
                .backspace => .delete_backward,
                .delete => .delete_forward,
                .enter => .insert_newline,
                .escape => .cancel,
                .tab => .insert_tab,
                else => null,
            };
            if (cmd) |c| try command(p, ctx, c);
        } else if (ctx.input.chars.len > 0 and !ctx.input.cmd and !ctx.input.ctrl) try replace(p, ctx.input.chars);
    }
    if (ctx.input.ops.len > 0 or ctx.input.key != null or ctx.input.chars.len > 0) ctx.changed = true;
}
