//! Per-pane history navigation using VT-owned row offsets, never a history copy.
const std = @import("std");
const ui = @import("nanoui").ui;
const vt_api = @import("vt.zig");
const chrome = @import("chrome.zig");
pub const Bar = struct {
    dragging: bool = false,
    grab: f32 = 0,
    info: vt_api.Scroll = .{},
    fn thumb(b: *const Bar, rect: ui.Rect) ui.Rect {
        const height = @min(rect.h, @max(24, rect.h * @as(f32, @floatFromInt(b.info.len)) / @as(f32, @floatFromInt(@max(1, b.info.total)))));
        const range = b.info.total -| b.info.len;
        const offset = if (range == 0) 0 else (rect.h - height) * @as(f32, @floatFromInt(b.info.offset)) / @as(f32, @floatFromInt(range));
        return .{ .x = rect.x + rect.w - 8, .y = rect.y + offset, .w = 6, .h = height };
    }
    pub fn input(b: *Bar, ctx: *ui.Context, vt: *vt_api.Vt, rect: ui.Rect) bool {
        vt_api.lt_vt_scroll_info(vt, &b.info);
        if (b.info.alternate or b.info.total <= b.info.len) {
            b.dragging = false;
            return false;
        }
        const hit: ui.Rect = .{ .x = rect.x + rect.w - 10, .y = rect.y, .w = 10, .h = rect.h };
        const indicator = b.thumb(rect);
        if (hit.contains(ctx.input.mouse)) ctx.cursor_hand = true;
        if (ctx.input.pressed and ctx.input.mouse_button == 1 and hit.contains(ctx.input.mouse)) {
            if (indicator.contains(ctx.input.mouse)) {
                b.dragging = true;
                b.grab = ctx.input.mouse.y - indicator.y;
            } else vt_api.lt_vt_scroll(vt, (if (ctx.input.mouse.y < indicator.y) @as(c_int, -1) else 1) * @as(c_int, @intCast(@max(1, b.info.len -| 1))));
            ctx.changed = true;
            return true;
        }
        if (!b.dragging) return false;
        ctx.wants_moves = true;
        if (ctx.input.released or !ctx.input.down) {
            b.dragging = false;
            return true;
        }
        const travel = @max(1, rect.h - indicator.h);
        const fraction = std.math.clamp((ctx.input.mouse.y - rect.y - b.grab) / travel, 0, 1);
        const row: u64 = @intFromFloat(@as(f64, fraction) * @as(f64, @floatFromInt(b.info.total - b.info.len)));
        if (row != b.info.offset) {
            vt_api.lt_vt_scroll_to(vt, row);
            ctx.changed = true;
        }
        return true;
    }
    pub fn draw(b: *Bar, ctx: *ui.Context, vt: *vt_api.Vt, rect: ui.Rect) void {
        vt_api.lt_vt_scroll_info(vt, &b.info);
        if (b.info.alternate or b.info.total <= b.info.len) return;
        const indicator = b.thumb(.{ .w = rect.w, .h = rect.h });
        chrome.box(ctx, rect.w - 9, 0, 9, rect.h, ctx.theme.text.alpha(0.025));
        _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = indicator.x, .y = indicator.y }, .width = .{ .px = indicator.w }, .height = .{ .px = indicator.h }, .radius = 3, .background = ctx.theme.text.alpha(if (b.dragging) 0.5 else 0.23) }, .none, null);
        if (b.dragging) {
            _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = @max(0, rect.w - 118), .y = std.math.clamp(indicator.y, 0, @max(0, rect.h - 22)) }, .padding = .xy(6, 3), .radius = 4, .background = ctx.theme.surface, .border = ctx.theme.border }, .{ .text = .{ .str = ctx.print("{d} / {d}", .{ b.info.offset + 1, b.info.total }), .style = .{ .size = 10 }, .color = ctx.theme.text } }, null);
        }
    }
};
