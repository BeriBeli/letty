const ui = @import("nanoui").ui;
pub fn draw(p: anytype, ctx: *ui.Context) void {
    const editor = p.editor orelse return;
    ui.key(ctx, "document-source-editor");
    const id = ctx.peekId(null);
    p.ax_body = id;
    if (editor.focus and !p.edit_busy) {
        ctx.focus = id;
        editor.focus = false;
    }
    if (p.edit_busy) {
        ui.text(ctx, "Saving…", .{ .size = 14 });
        return;
    }
    if (ctx.focus == id) if (ctx.input.shortcut) |sc| {
        if ((sc.cmd or sc.ctrl) and !sc.alt and sc.key == 'z' and !@import("view.zig").composing(ctx)) {
            _ = ctx.shortcut(sc);
            editor.undo(sc.shift);
            ctx.input.ops = &.{};
            ctx.input.chars = "";
            ctx.changed = true;
        }
    };
    const before = if (ctx.edits.getPtr(id)) |e| .{ e.caret, e.anchor } else .{ @as(usize, 0), @as(usize, 0) };
    const result = ui.textField(ctx, &editor.buffer, .{ .width = .fill, .size = 14 * p.zoom, .bare = true, .mono = true, .multiline = true, .newline_on_enter = true, .max_lines = @intFromFloat(@max(1, @min(200, @floor((p.body_rect.h - 16) / ctx.text.font(.{ .size = 14 * p.zoom, .mono = true }).lineHeight())))) });
    if (result.focused) p.field = .body;
    if (editor.buffer.overflow) {
        editor.buffer.overflow = false;
        if (ctx.edits.getPtr(id)) |e| {
            e.caret = before[0];
            e.anchor = before[1];
            e.marked = null;
        }
        p.notice.set("Edit exceeds the 2 MiB limit; insertion rejected.");
    }
    if (result.changed) editor.update();
    if (!@import("view.zig").composing(ctx)) editor.record() catch {
        p.notice.set("Undo history unavailable; draft retained.");
    };
}
