//! Cancellable nanoui confirmation and diagnostic display, with modal input isolation.
const ui = @import("nanoui").ui;
const chrome = @import("chrome.zig");
const semantic = @import("ui_semantics.zig");
pub const Kind = enum { close_sessions, create_config, diagnostics, paste, osc52_write, drop_preview, target_error };
pub const Result = enum { none, accept, cancel, copy };
pub const Dialog = struct {
    open: bool = false,
    generation: u64 = 0,
    geometry: semantic.Geometry = .{},
    ax_focus: u64 = 0,
    kind: Kind = .diagnostics,
    title: []const u8 = "",
    body: @import("fixed_text.zig").Text(8192) = .{},
    primary: []const u8 = "OK",
    primary_selected: bool = false,
    ax_pending: ?struct { generation: u64, result: Result } = null,
    pub fn requestAx(d: *Dialog, generation: u64, result: Result) bool {
        if (!d.open or d.generation != generation or result == .none) return false;
        d.ax_pending = .{ .generation = generation, .result = result };
        return true;
    }
    pub fn show(d: *Dialog, ctx: *ui.Context, kind: Kind, title: []const u8, body: []const u8, primary: []const u8) void {
        semantic.advance(&d.generation);
        d.ax_pending = null;
        d.ax_focus = 0;
        d.open = true;
        d.kind = kind;
        d.title = title;
        d.body.set(body);
        d.primary = primary;
        d.primary_selected = false;
        ctx.focus = 0;
        ctx.active = 0;
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
    pub fn draw(d: *Dialog, ctx: *ui.Context) Result {
        d.geometry.begin(d.generation, ctx.frame);
        if (d.ax_pending) |pending| {
            d.ax_pending = null;
            if (pending.generation == d.generation) {
                if (pending.result == .cancel) d.dismiss(ctx);
                return pending.result;
            }
        }
        var cancel = ctx.shortcut(.{ .key = ui.Shortcut.escape }) or ctx.input.key == .escape;
        for (ctx.input.ops) |op| if (op == .command and op.command == .cancel) {
            cancel = true;
        };
        if (cancel) {
            d.dismiss(ctx);
            return .cancel;
        }
        if (ctx.shortcut(.{ .key = ui.Shortcut.tab }) or ctx.input.key == .tab or ctx.input.key == .left or ctx.input.key == .right) {
            d.primary_selected = !d.primary_selected;
            ctx.input.key = null;
        }
        const enter = ctx.shortcut(.{ .key = ui.Shortcut.enter }) or ctx.input.key == .enter;
        if (enter) {
            ctx.input.key = null;
            if (!d.primary_selected) {
                d.dismiss(ctx);
                return .cancel;
            } else return .accept;
        }
        const width = @min(500, ctx.size.w - 32);
        const height = @min(320, ctx.size.h - 32);
        const rect: ui.Rect = .{ .x = (ctx.size.w - width) / 2, .y = @max(16, (ctx.size.h - height) / 3), .w = width, .h = height };
        if (ctx.input.pressed and !rect.contains(ctx.input.mouse)) {
            d.dismiss(ctx);
            return .cancel;
        }
        ui.key(ctx, "message-dialog-modal");
        const overlay = ctx.open(.{ .absolute = true, .width = .{ .px = ctx.size.w }, .height = .{ .px = ctx.size.h } }, null);
        _ = ctx.interact(overlay, .{});
        defer ctx.end();
        d.geometry.add(ctx, .panel, 0, d.title, "", true, false, null);
        ui.column(ctx, .{ .absolute = true, .offset = .{ .x = rect.x, .y = rect.y }, .width = .{ .px = width }, .height = .{ .px = height }, .padding = .all(16), .gap = 12, .radius = 10, .background = ctx.theme.surface, .border = ctx.theme.border, .shadow = .{ .color = ui.Color.black.alpha(0.18), .blur = 24, .y = 8 } });
        defer ui.end(ctx);
        ui.text(ctx, d.title, .{ .size = 15 });
        ui.key(ctx, "message-dialog-details");
        ui.scroll(ctx, .{ .width = .fill, .height = .{ .px = @max(48, height - 110) }, .clip = true });
        d.geometry.add(ctx, .body, 0, "Details", d.body.text(), true, false, null);
        ui.text(ctx, d.body.text(), .{ .size = 12, .wrap = true });
        ui.end(ctx);
        ui.row(ctx, .{ .width = .fill, .gap = 8 });
        var result: Result = .none;
        if (d.kind == .diagnostics or d.kind == .target_error or d.kind == .drop_preview) {
            d.geometry.add(ctx, .copy, 0, "Copy Details", "", true, false, null);
            if (chrome.button(ctx, "Copy Details", .{ .variant = .ghost, .size = 12 }).clicked) result = .copy;
        }
        ui.spacer(ctx);
        d.geometry.add(ctx, .cancel, 0, if (d.kind == .diagnostics or d.kind == .target_error or d.kind == .drop_preview) "Close" else "Cancel", "", true, !d.primary_selected, null);
        if (chrome.button(ctx, if ((d.kind == .diagnostics or d.kind == .target_error or d.kind == .drop_preview)) "Close" else "Cancel", .{ .variant = if (d.primary_selected) .ghost else .secondary, .size = 12 }).clicked) cancel = true;
        d.geometry.add(ctx, .accept, 0, d.primary, "", true, d.primary_selected, null);
        if (chrome.button(ctx, d.primary, .{ .variant = if (d.primary_selected) .primary else .secondary, .size = 12 }).clicked) result = .accept;
        ui.end(ctx);
        if (cancel) {
            d.dismiss(ctx);
            return .cancel;
        }
        return result;
    }
};
