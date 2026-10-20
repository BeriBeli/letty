//! VT-driven text/background passes. Image layers are inserted by the View.
const std = @import("std");
const ui = @import("nanoui").ui;
const vt_api = @import("vt.zig");
const Session = @import("session.zig").Session;
const Config = @import("config.zig").Config;
const runs = @import("terminal_runs.zig");
const CellText = runs.CellText;
pub const Pass = enum { normal, background, base_text, overlay };
/// The caller owns the open VT frame and closes it on every path.
pub fn cells(v: anytype, s: *Session, ctx: *ui.Context, cfg: Config, configured: ui.TextStyle, cw: f32, ch: f32, active: bool, cursor_visible: bool, pass: Pass) void {
    const font = ctx.text.font(configured);
    const text_offset = (ch - (font.ascent + font.descent + font.leading)) / 2;
    // Backgrounds must precede ALL glyphs in a row. Nerd Font symbols
    // can extend into the following space; its background must not erase
    // the right half of the symbol (e.g. Starship's U+F43A clock).
    const texts = ctx.alloc().alloc(CellText, s.cols) catch return;
    var text_count: usize = 0;
    var row: ?u32 = null;
    var cell: vt_api.Cell = undefined;
    while (vt_api.lt_vt_next(s.vt, &cell)) {
        if (row != null and row.? != cell.y) {
            runs.paint(ctx, texts[0..text_count], cw, ch);
            text_count = 0;
        }
        row = cell.y;
        if (cell.width == 0) continue;
        const selected = cell.flags & 16 != 0;
        const block_cursor = active and cursor_visible and v.cursor.style == 1 and cell.x == v.cursor.x and cell.y == v.cursor.y;
        const current_match = cell.flags & 64 != 0;
        const matched = cell.flags & 32 != 0;
        const overlay = selected or block_cursor or matched;
        if (pass == .overlay and !overlay) continue;
        if (pass == .background) {
            if (cell.bg != v.cursor.bg) _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = cfg.padding_x[0] + @as(f32, @floatFromInt(cell.x)) * cw, .y = cfg.padding_y[0] + @as(f32, @floatFromInt(cell.y)) * ch }, .width = .{ .px = cw * @as(f32, @floatFromInt(cell.width)) }, .height = .{ .px = ch }, .background = ui.Color.hex(@intCast(cell.bg)) }, .none, null);
            continue;
        }
        const decorated = pass != .base_text;
        const bg = if (decorated and block_cursor) v.cursor.color else if (decorated and selected) sColor(cfg.selection_background) else cell.bg;
        const fg = if (decorated and block_cursor) v.cursor.bg else if (decorated and selected) sColor(cfg.selection_foreground) else cell.fg;
        if (cell.len == 0 and bg == v.cursor.bg and !matched) continue;
        const style: ui.Style = .{ .absolute = true, .offset = .{ .x = cfg.padding_x[0] + @as(f32, @floatFromInt(cell.x)) * cw, .y = cfg.padding_y[0] + @as(f32, @floatFromInt(cell.y)) * ch }, .width = .{ .px = cw * @as(f32, @floatFromInt(cell.width)) }, .height = .{ .px = ch }, .background = if (decorated and !selected and !block_cursor and matched) (if (current_match) ctx.theme.accent else ctx.theme.accent.mix(ui.Color.hex(cfg.background), 0.8)) else ui.Color.hex(@intCast(bg)), .padding = .{ .top = text_offset }, .clip = true };
        const str = if (cell.len > 0) ctx.alloc().dupe(u8, cell.text.?[0..cell.len]) catch "" else "";
        if (pass != .base_text) _ = ctx.leaf(style, .none, null);
        var text_style = style;
        text_style.background = null;
        if (str.len > 0 and text_count < texts.len) {
            var cell_font = configured;
            cell_font.weight = if (cell.flags & 1 != 0) .bold else .regular;
            cell_font.italic = cell.flags & 2 != 0;
            texts[text_count] = .{ .col = cell.x, .width = @intCast(cell.width), .boundary = @as(u64, cell.flags) | (if (v.link.contains(s.cols, cell.x, cell.y)) @as(u64, 1 << 10) else 0) | (@as(u64, cell.underline) << 12) | (@as(u64, cell.underline_color) << 16), .isolated = cell.y == v.cursor.y and cell.x <= v.cursor.x and cell.x + cell.width > v.cursor.x, .style = text_style, .str = str, .font = cell_font, .color = if (decorated and current_match and !selected and !block_cursor) ctx.theme.accent_text else ui.Color.hex(@intCast(fg)) };
            text_count += 1;
        }
        if (cell.flags & 256 == 0) {
            const decorations = @import("terminal_decorations.zig");
            if (cell.flags & 4 != 0 or v.link.contains(s.cols, cell.x, cell.y)) decorations.underline(ctx, style.offset.x, style.offset.y + ch - 2, cw * @as(f32, @floatFromInt(cell.width)), if (cell.underline == 0) 1 else cell.underline, ui.Color.hex(@intCast(if (cell.flags & 4 != 0) cell.underline_color else fg)));
            if (cell.flags & 8 != 0) line(ctx, style.offset.x, style.offset.y + ch * 0.55, cw * @as(f32, @floatFromInt(cell.width)), ui.Color.hex(@intCast(fg)));
            if (cell.flags & 128 != 0) line(ctx, style.offset.x, style.offset.y + 1, cw * @as(f32, @floatFromInt(cell.width)), ui.Color.hex(@intCast(fg)));
        }
    }
    runs.paint(ctx, texts[0..text_count], cw, ch);
}
fn sColor(v: u24) u32 {
    return v;
}
fn line(ctx: *ui.Context, x: f32, y: f32, w: f32, color: ui.Color) void {
    _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = .{ .px = w }, .height = .{ .px = 1 }, .background = color }, .none, null);
}
