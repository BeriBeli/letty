//! Native libghostty-vt to nanoui rendering. No serialized grid or Mirror.
const std = @import("std");
const ui = @import("nanoui").ui;
const ghostty = @import("ghostty-vt");
const Terminal = @import("terminal.zig").Terminal;
const Settings = @import("settings.zig").Settings;
const themes = @import("themes.zig");
pub const Metrics = struct { width: f32, height: f32, min_contrast: f32, font: ui.TextStyle };
pub fn metrics(ctx: *ui.Context, settings: Settings) Metrics {
    const font: ui.TextStyle = .{ .mono = true, .size = settings.@"font-size" * ctx.points_to_logical, .weight = if (settings.@"font-weight" >= 700) .bold else if (settings.@"font-weight" >= 600) .semibold else if (settings.@"font-thicken" or settings.@"font-weight" >= 500) .medium else .regular, .features = if (settings.@"font-ligatures") &.{} else &.{ .{ .tag = "liga".*, .value = 0 }, .{ .tag = "calt".*, .value = 0 } } };
    const shaped = ctx.text.layout("M", font);
    return .{ .width = @max(1, shaped.width), .height = @ceil(ctx.text.font(font).lineHeight() * settings.@"line-height"), .font = font, .min_contrast = settings.@"minimum-contrast" };
}
fn color(v: ghostty.color.RGB) ui.Color {
    return ui.Color.hex((@as(u24, v.r) << 16) | (@as(u24, v.g) << 8) | v.b);
}
pub fn paint(vt: *Terminal, ctx: *ui.Context, m: Metrics, active: bool) !void {
    if (vt.interaction.search) |*search| search.feed(&vt.terminal, false);
    const now: u64 = @intFromFloat(@max(0, ctx.time) * 1000);
    try vt.render.update(vt.alloc, &vt.terminal);
    try vt.graphics.prepare(vt.alloc, &vt.terminal, &vt.render, m.width, m.height, ctx.scale);
    const generation = vt.terminal.screens.active.kitty_images.generation;
    if (vt.graphics.tick(&vt.terminal, now)) |delay| ctx.frameIn(@as(f32, @floatFromInt(@max(1, delay))) / 1000);
    if (vt.terminal.screens.active.kitty_images.generation != generation) {
        try vt.render.update(vt.alloc, &vt.terminal);
        try vt.graphics.prepare(vt.alloc, &vt.terminal, &vt.render, m.width, m.height, ctx.scale);
    }
    const viewport_w = @as(f32, @floatFromInt(vt.render.cols)) * m.width;
    const viewport_h = @as(f32, @floatFromInt(vt.render.rows)) * m.height;
    vt.graphics.draw(ctx, .below_background, viewport_w, viewport_h);
    const render = &vt.render;
    for (0..render.rows) |y| {
        const row = render.viewportStart() + y;
        const cells = render.row_data.items(.cells)[row];
        // Draw all backgrounds before glyphs, including overhanging Nerd Fonts.
        var x: usize = 0;
        while (x < render.cols) {
            const raw = cells.items(.raw)[x];
            const style: ghostty.Style = if (raw.hasStyling()) cells.items(.style)[x] else .{};
            const bg = if (style.flags.inverse) style.fg(.{ .default = render.colors.foreground, .palette = &render.colors.palette }) else style.bg(&raw, &render.colors.palette) orelse render.colors.background;
            var end = x + 1;
            while (end < render.cols) : (end += 1) {
                const next = cells.items(.raw)[end];
                const s: ghostty.Style = if (next.hasStyling()) cells.items(.style)[end] else .{};
                const other = if (s.flags.inverse) s.fg(.{ .default = render.colors.foreground, .palette = &render.colors.palette }) else s.bg(&next, &render.colors.palette) orelse render.colors.background;
                if (!std.meta.eql(bg, other)) break;
            }
            if (!std.meta.eql(bg, render.colors.background)) box(ctx, @as(f32, @floatFromInt(x)) * m.width, @as(f32, @floatFromInt(y)) * m.height, @as(f32, @floatFromInt(end - x)) * m.width, m.height, color(bg));
            x = end;
        }
    }
    vt.graphics.draw(ctx, .below_text, viewport_w, viewport_h);
    for (0..render.rows) |y| {
        const row = render.viewportStart() + y;
        const cells = render.row_data.items(.cells)[row];
        var x: usize = 0;
        if (vt.interaction.search) |*search| {
            const pin = render.row_data.items(.pin)[row];
            const matches = try search.viewportMatches();
            for (matches) |match| highlight(ctx, m, y, pin, match, ui.Color.hex(0xf4d65c).alpha(0.35));
            if (search.activeScreenSearch()) |screen| if (screen.selectedMatch()) |match| highlight(ctx, m, y, pin, match, ui.Color.hex(0xf5a43c).alpha(0.6));
        }
        if (render.row_data.items(.selection)[row]) |selection| box(ctx, @as(f32, @floatFromInt(selection[0])) * m.width, @as(f32, @floatFromInt(y)) * m.height, @as(f32, @floatFromInt(selection[1] - selection[0] + 1)) * m.width, m.height, color(vt.selection_background));
        x = 0;
        while (x < render.cols) {
            const start = x;
            const raw = cells.items(.raw)[x];
            if (raw.wide == .spacer_head or raw.wide == .spacer_tail) {
                x += 1;
                continue;
            }
            const style: ghostty.Style = if (raw.hasStyling()) cells.items(.style)[x] else .{};
            const base_fg = if (style.flags.inverse) style.bg(&raw, &render.colors.palette) orelse render.colors.background else style.fg(.{ .default = render.colors.foreground, .palette = &render.colors.palette });
            const selection = render.row_data.items(.selection)[row];
            const selected = if (selection) |range| start >= range[0] and start <= range[1] else false;
            const base_bg = if (selected) vt.selection_background else if (style.flags.inverse) style.fg(.{ .default = render.colors.foreground, .palette = &render.colors.palette }) else style.bg(&raw, &render.colors.palette) orelse render.colors.background;
            const graphics = themes.graphicsElement(if (raw.hasText()) raw.codepoint() else ' ');
            const fg = themes.terminalForeground(if (raw.hasText()) raw.codepoint() else ' ', if (selected) vt.selection_foreground else base_fg, base_bg, m.min_contrast);
            var text: std.ArrayList(u8) = .empty;
            var spans: std.ArrayList(ui.gridText.Cell) = .empty;
            while (x < render.cols and text.items.len < 16000) {
                const cell = cells.items(.raw)[x];
                const s: ghostty.Style = if (cell.hasStyling()) cells.items(.style)[x] else .{};
                if (!std.meta.eql(style, s)) break;
                if (themes.graphicsElement(if (cell.hasText()) cell.codepoint() else ' ') != graphics) break;
                if (selection) |range| if ((x >= range[0] and x <= range[1]) != selected) break;
                if (cell.wide == .spacer_head or cell.wide == .spacer_tail) {
                    x += 1;
                    continue;
                }
                const from = text.items.len;
                var bytes: [4]u8 = undefined;
                const placeholder = cell.hasText() and cell.codepoint() == 0x10EEEE;
                const cp: u21 = if (cell.hasText() and !s.flags.invisible and !placeholder) cell.codepoint() else ' ';
                const n = try std.unicode.utf8Encode(cp, &bytes);
                try text.appendSlice(ctx.alloc(), bytes[0..n]);
                if (cell.content_tag == .codepoint_grapheme and !s.flags.invisible and !placeholder) for (cells.items(.grapheme)[x]) |extra| {
                    const count = try std.unicode.utf8Encode(extra, &bytes);
                    try text.appendSlice(ctx.alloc(), bytes[0..count]);
                };
                try spans.append(ctx.alloc(), .{ .byte_start = @intCast(from), .byte_end = @intCast(text.items.len), .col = @intCast(x - start), .width = if (cell.wide == .wide) 2 else 1 });
                x += if (cell.wide == .wide) @as(usize, 2) else 1;
            }
            var font = m.font;
            if (style.flags.bold) font.weight = .bold;
            font.italic = style.flags.italic;
            const shaped = try ctx.text.gridLayout(text.items, font, spans.items, m.width);
            const f = ctx.text.font(font);
            const baseline = (m.height - f.lineHeight()) / 2 + f.leading / 2 + f.ascent;
            _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = @as(f32, @floatFromInt(start)) * m.width, .y = @as(f32, @floatFromInt(y)) * m.height }, .width = .{ .px = shaped.width }, .height = .{ .px = m.height } }, .{ .glyph_run = .{ .str = text.items, .cells = spans.items, .glyphs = shaped.glyphs, .color = color(fg), .baseline = baseline } }, null);
            if (style.flags.underline != .none) box(ctx, @as(f32, @floatFromInt(start)) * m.width, @as(f32, @floatFromInt(y + 1)) * m.height - 2, @as(f32, @floatFromInt(x - start)) * m.width, 1, color(style.underlineColor(&render.colors.palette) orelse fg));
            if (style.flags.strikethrough) box(ctx, @as(f32, @floatFromInt(start)) * m.width, (@as(f32, @floatFromInt(y)) + 0.5) * m.height, @as(f32, @floatFromInt(x - start)) * m.width, 1, color(fg));
        }
    }
    vt.graphics.draw(ctx, .above_text, viewport_w, viewport_h);
    const cursor = render.cursor;
    if (active and cursor.visible) if (cursor.viewport) |pos| {
        if (cursor.blinking) {
            const phase = @mod(ctx.time, 1);
            ctx.frameIn(@floatCast(if (phase < 0.5) 0.5 - phase else 1 - phase));
            if (phase >= 0.5) {
                render.clean();
                return;
            }
        }
        const x = @as(f32, @floatFromInt(pos.x)) * m.width;
        const y = @as(f32, @floatFromInt(pos.y)) * m.height;
        const tint = color(render.colors.cursor orelse render.colors.foreground);
        switch (cursor.visual_style) {
            .bar => box(ctx, x, y, 2, m.height, tint),
            .underline => box(ctx, x, y + m.height - 2, m.width, 2, tint),
            else => box(ctx, x, y, m.width, m.height, tint.alpha(0.45)),
        }
    };
    render.clean();
}
fn highlight(ctx: *ui.Context, m: Metrics, y: usize, pin: ghostty.PageList.Pin, match: ghostty.highlight.Flattened, tint: ui.Color) void {
    const chunks = match.chunks.slice();
    for (0..chunks.len) |i| {
        if (chunks.items(.node)[i] != pin.node or pin.y < chunks.items(.start)[i] or pin.y >= chunks.items(.end)[i]) continue;
        const first = if (i == 0 and pin.y == chunks.items(.start)[i]) match.top_x else 0;
        const last = if (i + 1 == chunks.len and pin.y + 1 == chunks.items(.end)[i]) match.bot_x else pin.node.cols() - 1;
        if (last >= first) box(ctx, @as(f32, @floatFromInt(first)) * m.width, @as(f32, @floatFromInt(y)) * m.height, @as(f32, @floatFromInt(last - first + 1)) * m.width, m.height, tint);
    }
}
fn box(ctx: *ui.Context, x: f32, y: f32, w: f32, h: f32, bg: ui.Color) void {
    _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = .{ .px = w }, .height = .{ .px = h }, .background = bg }, .none, null);
}

pub fn link(ctx: *ui.Context, m: Metrics, value: @import("links.zig").Link, cols: u16) void {
    var row = value.first.y;
    while (row <= value.last.y) : (row += 1) {
        const first = if (row == value.first.y) value.first.x else 0;
        const last = if (row == value.last.y) value.last.x else cols - 1;
        if (last >= first) box(ctx, @as(f32, @floatFromInt(first)) * m.width, @as(f32, @floatFromInt(row + 1)) * m.height - 1, @as(f32, @floatFromInt(last - first + 1)) * m.width, 1, ctx.theme.accent);
    }
}
