const std = @import("std");
const n = @import("nanoui");
const ui = n.ui;
const vt_api = @import("vt.zig");
const Session = @import("session.zig").Session;
const Config = @import("config.zig").Config;
const runs = @import("terminal_runs.zig");

pub const View = struct {
    selecting: bool = false,
    wheel: @import("scroll_input.zig").Rows = .{},
    wheel_tracking: bool = false,
    auto_scroll_at: f64 = -1,
    scrollbar: @import("scrollbar.zig").Bar = .{},
    link: @import("link_view.zig").Hover = .{},
    preedit: std.ArrayList(u8) = .empty,
    cursor: vt_api.Cursor = .{},
    blink_epoch: f64 = 0,
    was_active: bool = false,
    graphics: @import("terminal_graphics_state.zig").State = .{},
    pub fn deinit(v: *View, a: std.mem.Allocator) void {
        v.graphics.deinit();
        v.preedit.deinit(a);
    }
    pub fn key(s: *Session, k: u32, mods: u32, text: []const u8) bool {
        var out: [4096]u8 = undefined;
        var len: usize = 0;
        if (vt_api.lt_vt_key(s.vt, k, mods, text.ptr, text.len, &out, out.len, &len) != 0) return false;
        return if (len > 0) s.send(out[0..len]) else true;
    }
    pub fn paste(s: *Session, a: std.mem.Allocator, text: []const u8) bool {
        if (text.len > 1024 * 1024 - 12) return false;
        const normalized = a.alloc(u8, text.len) catch return false;
        defer a.free(normalized);
        var used: usize = 0;
        for (text, 0..) |ch, index| {
            if (ch == '\n' and index > 0 and text[index - 1] == '\r') continue;
            normalized[used] = if (ch == '\r') '\n' else ch;
            used += 1;
        }
        const out = a.alloc(u8, used + 12) catch return false;
        defer a.free(out);
        var len: usize = 0;
        if (vt_api.lt_vt_paste(normalized.ptr, used, vt_api.lt_vt_bracketed(s.vt), out.ptr, out.len, &len) != 0) return false;
        return s.send(out[0..len]);
    }

    pub fn copy(s: *Session, ctx: *ui.Context) bool {
        const buf = ctx.alloc().alloc(u8, 1024 * 1024) catch return false;
        var len: usize = 0;
        if (vt_api.lt_vt_copy(s.vt, buf.ptr, buf.len, &len) != 0) return false;
        ctx.clipboard.write(ctx.clipboard.ctx, buf[0..len]);
        return true;
    }
    pub fn input(v: *View, s: *Session, ctx: *ui.Context, rect: ui.Rect, cw: f32, ch: f32, cfg: Config, active: bool) bool {
        const i = &ctx.input;
        var ok = true;
        ctx.wants_wheel = true;
        ctx.wants_moves = true;
        if (active) {
            for (i.ops) |op| switch (op) {
                .set_marked => |m| {
                    v.preedit.clearRetainingCapacity();
                    v.preedit.appendSlice(s.gpa, m.text) catch {};
                },
                .unmark => v.preedit.clearRetainingCapacity(),
                .insert => |text| {
                    ok = paste(s, s.gpa, text) and ok;
                    v.preedit.clearRetainingCapacity();
                },
                .command => |cmd| {
                    const k: ?u32 = switch (cmd) {
                        .insert_newline => 0x108,
                        .insert_tab => 0x109,
                        .delete_backward => 0x100,
                        .delete_forward => 0x101,
                        .move_left => 0x102,
                        .move_right => 0x103,
                        .move_line_start => 0x106,
                        .move_line_end => 0x107,
                        .cancel => 0x10a,
                        .copy => {
                            _ = copy(s, ctx);
                            break;
                        },
                        else => null,
                    };
                    if (k) |value| ok = key(s, value, 0, "") and ok;
                },
            };
            if (i.chars.len > 0) {
                ok = key(s, 0, 0, i.chars) and ok;
                v.preedit.clearRetainingCapacity();
            }
            if (i.key) |k| ok = key(s, 0x100 + @as(u32, @intCast(@backingInt(k))), (if (i.shift) @as(u32, 1) else 0) | (if (i.ctrl) @as(u32, 2) else 0), "") and ok;
        }
        const inside = rect.contains(i.mouse);
        if (!inside and !v.selecting) return ok;
        const x: u32 = @intFromFloat(std.math.clamp(@floor((i.mouse.x - rect.x - cfg.padding_x[0]) / cw), 0, @as(f32, @floatFromInt(s.cols - 1))));
        const y: u32 = @intFromFloat(std.math.clamp(@floor((i.mouse.y - rect.y - cfg.padding_y[0]) / ch), 0, @as(f32, @floatFromInt(s.rows - 1))));
        const mouse_mods: u32 = (if (i.shift) @as(u32, 1) else 0) | (if (i.ctrl) @as(u32, 2) else 0) | (if (i.alt) @as(u32, 4) else 0);
        const tracking = vt_api.lt_vt_mouse_tracking(s.vt) and !i.shift;
        const button: u32 = switch (i.mouse_button) {
            2 => 3,
            3 => 2,
            else => 1,
        };
        if (inside and (i.scroll.y != 0 or i.scroll_started)) {
            const rows = v.wheel.take(i.scroll.y, i.scroll_lines, ch, i.scroll_started or v.wheel_tracking != tracking);
            v.wheel_tracking = tracking;
            if (rows != 0) {
                ctx.changed = true;
                if (tracking) {
                    for (0..@abs(rows)) |_| ok = mouse(s, 0, if (rows > 0) 4 else 5, x, y, mouse_mods) and ok;
                } else vt_api.lt_vt_scroll(s.vt, -rows);
            }
        }
        if (v.selecting and i.down and !tracking and (i.mouse.y < rect.y or i.mouse.y >= rect.y + rect.h)) {
            if (v.auto_scroll_at < 0 or ctx.time - v.auto_scroll_at >= 0.05) {
                vt_api.lt_vt_scroll(s.vt, if (i.mouse.y < rect.y) -1 else 1);
                v.auto_scroll_at = ctx.time;
            }
            ctx.frameIn(0.05);
        }
        if (i.pressed and (tracking or button == 1)) {
            v.selecting = true;
            if (tracking) ok = mouse(s, 0, button, x, y, mouse_mods) and ok else vt_api.lt_vt_select(s.vt, x, y, if (i.click_count >= 3) 3 else if (i.click_count == 2) 2 else 0);
        } else if (v.selecting and i.down) {
            if (tracking) ok = mouse(s, 2, button, x, y, mouse_mods) and ok else vt_api.lt_vt_select(s.vt, x, y, 1);
        }
        if (v.selecting and i.released) {
            if (tracking) ok = mouse(s, 1, button, x, y, mouse_mods) and ok;
            v.selecting = false;
            v.auto_scroll_at = -1;
        }
        return ok;
    }
    fn mouse(s: *Session, action: u32, button: u32, x: u32, y: u32, mods: u32) bool {
        var out: [128]u8 = undefined;
        var len: usize = 0;
        if (vt_api.lt_vt_mouse(s.vt, action, button, mods, x, y, &out, out.len, &len) != 0) return false;
        return if (len > 0) s.send(out[0..len]) else true;
    }
    pub fn draw(v: *View, s: *Session, ctx: *ui.Context, cfg: Config, cw: f32, ch: f32, active: bool, rect: ui.Rect) void {
        const previous = v.cursor;
        if (vt_api.lt_vt_frame(s.vt, &v.cursor) != 0) return;
        if (previous.x != v.cursor.x or previous.y != v.cursor.y or (active and !v.was_active) or (active and (ctx.input.key != null or ctx.input.chars.len > 0 or ctx.input.ops.len > 0 or ctx.input.pressed))) v.blink_epoch = ctx.time;
        v.was_active = active;
        const phase = @mod(@max(0, ctx.time - v.blink_epoch), 1.2);
        const cursor_visible = v.cursor.visible and (!active or !v.cursor.blinking or phase < 0.6);
        if (active and v.cursor.visible and v.cursor.blinking) ctx.frameIn(@floatCast(if (phase < 0.6) 0.6 - phase else 1.2 - phase));
        const configured = runs.configure(ctx, cfg) catch |err| failed: {
            ctx.text.last_shape_error = @errorName(err);
            break :failed ui.TextStyle{ .size = runs.fontSize(ctx, cfg), .mono = true };
        };
        const painter = @import("terminal_paint.zig");
        if (v.graphics.active()) {
            v.graphics.layer(ctx, .below_background);
            painter.cells(v, s, ctx, cfg, configured, cw, ch, active, cursor_visible, .background);
            vt_api.lt_vt_frame_end(s.vt);
            v.graphics.layer(ctx, .below_text);
            if (vt_api.lt_vt_frame(s.vt, &v.cursor) == 0) {
                painter.cells(v, s, ctx, cfg, configured, cw, ch, active, cursor_visible, .base_text);
                vt_api.lt_vt_frame_end(s.vt);
            }
            v.graphics.layer(ctx, .above_text);
            if (vt_api.lt_vt_frame(s.vt, &v.cursor) == 0) {
                painter.cells(v, s, ctx, cfg, configured, cw, ch, active, cursor_visible, .overlay);
                vt_api.lt_vt_frame_end(s.vt);
            }
        } else {
            painter.cells(v, s, ctx, cfg, configured, cw, ch, active, cursor_visible, .normal);
            vt_api.lt_vt_frame_end(s.vt);
        }
        if (v.link.label(ctx)) |text| {
            const chrome = @import("chrome.zig");
            _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = 4, .y = std.math.clamp(ctx.input.mouse.y - rect.y + (if (ctx.input.mouse.y - rect.y < rect.h / 2) ch + 4 else -30), 0, @max(0, rect.h - 24)) }, .padding = .xy(6, 3), .radius = 4, .background = ctx.theme.surface, .border = ctx.theme.border }, .{ .text = .{ .str = chrome.ellipsize(ctx, text, @max(1, rect.w - 30), 11), .style = .{ .size = 11 }, .color = if (v.link.visible) ctx.theme.text else ctx.theme.muted } }, null);
        }
        const x = cfg.padding_x[0] + @as(f32, @floatFromInt(v.cursor.x)) * cw;
        const y = cfg.padding_y[0] + @as(f32, @floatFromInt(v.cursor.y)) * ch;
        if (cursor_visible and !(active and v.cursor.style == 1)) {
            const hollow = !active or v.cursor.style == 3;
            const is_bar = v.cursor.style == 0;
            const underline = v.cursor.style == 2;
            const color = ui.Color.hex(@intCast(v.cursor.color));
            _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = if (underline and !hollow) y + ch - 1 else y }, .width = .{ .px = if (is_bar and !hollow) 1 else cw }, .height = .{ .px = if (underline and !hollow) 1 else ch }, .background = if (hollow) null else color, .border = if (hollow) color else null }, .none, null);
        }
        if (active) {
            ctx.focused_text = .{ .id = s.id | (@as(u64, 1) << 63), .text = "", .caret = 0, .anchor = 0, .marked = null, .caret_rect = .{ .x = rect.x + x, .y = rect.y + y, .w = cw, .h = ch } };
            if (v.preedit.items.len > 0) {
                const mark = ctx.alloc().dupe(u8, v.preedit.items) catch "";
                _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .height = .{ .px = ch }, .background = ctx.theme.accent.alpha(0.15) }, .{ .text = .{ .str = mark, .style = .{ .size = runs.fontSize(ctx, cfg), .mono = true }, .color = ui.Color.hex(cfg.foreground) } }, null);
            }
        }
    }
};
