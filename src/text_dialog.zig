//! Small modal editor shared by application prompts, with isolated text input.
const ui = @import("nanoui").ui;
const chrome = @import("chrome.zig");
const semantic = @import("ui_semantics.zig");
pub const Result = enum { none, cancel, submit };
pub const Dialog = struct {
    open: bool = false,
    generation: u64 = 0,
    geometry: semantic.Geometry = .{},
    ax_focus: u64 = 0,
    text: ui.TextBuffer = .{},
    composing: bool = false,
    ax_pending: ?struct { generation: u64, result: Result } = null,
    pub fn requestAx(d: *Dialog, generation: u64, result: Result) bool {
        if (!d.open or d.generation != generation or result == .none or d.composing) return false;
        d.ax_pending = .{ .generation = generation, .result = result };
        return true;
    }
    pub fn show(d: *Dialog, ctx: *ui.Context, text: []const u8) void {
        d.text.set(text);
        semantic.advance(&d.generation);
        d.ax_pending = null;
        d.ax_focus = 0;
        d.open = true;
        d.composing = false;
        ctx.input.clearEdges();
        ctx.changed = true;
    }
    pub fn dismiss(d: *Dialog, ctx: *ui.Context) void {
        if (d.open) semantic.advance(&d.generation);
        d.ax_pending = null;
        d.ax_focus = 0;
        d.open = false;
        ctx.focus = 0;
        ctx.active = 0;
        ctx.input.clearEdges();
        ctx.changed = true;
    }
    pub fn draw(d: *Dialog, ctx: *ui.Context, title: []const u8, label: []const u8) Result {
        d.geometry.begin(d.generation, ctx.frame);
        if (d.ax_pending) |pending| {
            d.ax_pending = null;
            if (pending.generation == d.generation and !d.composing) {
                if (pending.result == .cancel) d.dismiss(ctx);
                return pending.result;
            }
        }
        var cancel = !d.composing and (ctx.shortcut(.{ .key = ui.Shortcut.escape }) or ctx.input.key == .escape);
        for (ctx.input.ops) |op| if (!d.composing and op == .command and op.command == .cancel) {
            cancel = true;
        };
        if (cancel) {
            d.dismiss(ctx);
            return .cancel;
        }
        const width = @min(420, ctx.size.w - 32);
        const rect: ui.Rect = .{ .x = (ctx.size.w - width) / 2, .y = @max(16, (ctx.size.h - 160) / 3), .w = width, .h = 160 };
        if (ctx.input.pressed and !rect.contains(ctx.input.mouse)) {
            d.dismiss(ctx);
            return .cancel;
        }
        ui.key(ctx, "text-dialog-modal");
        const overlay = ctx.open(.{ .absolute = true, .width = .{ .px = ctx.size.w }, .height = .{ .px = ctx.size.h } }, null);
        _ = ctx.interact(overlay, .{});
        defer ctx.end();
        d.geometry.add(ctx, .panel, 0, title, "", true, false, null);
        ui.column(ctx, .{ .absolute = true, .offset = .{ .x = rect.x, .y = rect.y }, .width = .{ .px = width }, .padding = .all(16), .gap = 12, .radius = 10, .border = ctx.theme.border, .background = ctx.theme.surface, .shadow = .{ .color = ui.Color.black.alpha(0.18), .blur = 24, .y = 8 } });
        defer ui.end(ctx);
        ui.text(ctx, title, .{ .size = 15 });
        ui.key(ctx, "text-dialog-query");
        d.geometry.add(ctx, .query, 0, "Tab title", d.text.text(), true, false, null);
        ctx.focus = if (d.ax_focus != 0) d.ax_focus else ctx.peekId(null);
        const composing = d.composing;
        const result = ui.textField(ctx, &d.text, .{ .width = .{ .px = width - 32 }, .size = 13, .placeholder = "Leave empty to use the terminal title" });
        d.composing = if (ctx.focused_text) |f| f.marked != null else false;
        ui.row(ctx, .{ .width = .fill, .gap = 8 });
        ui.spacer(ctx);
        d.geometry.add(ctx, .cancel, 0, "Cancel", "", true, false, null);
        if (chrome.button(ctx, "Cancel", .{ .variant = .ghost }).clicked) cancel = true;
        d.geometry.add(ctx, .accept, 0, label, "", !d.composing, false, null);
        const submit = chrome.button(ctx, label, .{}).clicked or (!composing and result.submitted);
        ui.end(ctx);
        if (cancel) {
            d.dismiss(ctx);
            return .cancel;
        }
        if (submit) return .submit;
        return .none;
    }
};
