//! Quiet, shadow-free terminal controls. Geometry stays portable across renderers.
const std = @import("std");
const ui = @import("nanoui").ui;

pub const icons = @import("ui_icons/icons.zig");
pub const Icon = icons.Icon;
pub fn selected(ctx: *ui.Context) ui.Color {
    return ctx.theme.surface.mix(ctx.theme.accent, 0.12);
}
pub fn icon(ctx: *ui.Context, name: Icon, size: f32) void {
    icons.draw(ctx, name, size, 0.9);
}
pub fn iconControl(ctx: *ui.Context, name: Icon, extent: f32, active: bool, disabled: bool) ui.Interaction {
    const id = ctx.peekId(null);
    var it = ui.pressable(ctx, .{ .width = .{ .px = extent }, .height = .{ .px = extent }, .radius = 6, .control = true, .align_items = .center, .justify = .center, .background = if (active) selected(ctx) else null, .border = if (ctx.focus == id) ctx.theme.accent else null, .opacity = if (disabled) 0.4 else 1 }, if (disabled) null else ctx.theme.surface_hover);
    icon(ctx, name, 16);
    ui.end(ctx);
    if (disabled) it.clicked = false;
    if (it.clicked) ctx.changed = true;
    return it;
}
pub fn iconButton(ctx: *ui.Context, name: Icon, extent: f32) bool {
    return iconControl(ctx, name, extent, false, false).clicked;
}
pub fn button(ctx: *ui.Context, title: []const u8, options: ui.ButtonOptions) ui.Interaction {
    const id = ctx.peekId(null);
    const primary = options.variant == .primary or options.variant == .danger;
    const bg = if (options.variant == .danger) ctx.theme.danger else ctx.theme.accent;
    var it = ui.pressable(ctx, .{ .direction = .row, .width = options.width, .height = .{ .px = 30 }, .padding = .xy(10, 0), .gap = 6, .radius = 6, .align_items = .center, .justify = .center, .control = true, .clip = true, .opacity = if (options.disabled) 0.4 else 1, .background = if (primary) bg else if (options.variant == .secondary) ctx.theme.background else null, .border = if (ctx.focus == id) ctx.theme.accent else if (options.variant == .secondary) ctx.theme.border.alpha(0.7) else null }, if (options.disabled) null else if (primary) bg.mix(ctx.theme.text, 0.08) else ctx.theme.surface_hover);
    if (options.icon.len > 0) ui.icon(ctx, options.icon, .{ .size = 14 });
    if (title.len > 0) ui.text(ctx, title, .{ .size = options.size, .weight = .medium, .color = if (primary) ctx.theme.accent_text else ctx.theme.text });
    ui.end(ctx);
    if (options.disabled) it.clicked = false;
    if (it.clicked) ctx.changed = true;
    return it;
}
pub fn box(ctx: *ui.Context, x: f32, y: f32, w: f32, h: f32, color: ui.Color) void {
    _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = .{ .px = w }, .height = .{ .px = h }, .background = color }, .none, null);
}
pub fn ellipsize(ctx: *ui.Context, text: []const u8, width: f32, size: f32) []const u8 {
    if (ctx.text.layout(text, .{ .size = size }).width <= width) return text;
    var len = text.len;
    while (len > 0) {
        len -= 1;
        while (len > 0 and text[len] & 0xc0 == 0x80) len -= 1;
        const short = ctx.print("{s}…", .{text[0..len]});
        if (ctx.text.layout(short, .{ .size = size }).width <= width) return short;
    }
    return "…";
}
