//! Kero mygo control faces on nanoui.kit. Keep application keys, focus decoration,
//! compact geometry and shared Lucide images; kit owns button interaction.
const std = @import("std");
const ui = @import("nanoui").ui;
const kit = @import("nanoui").kit;

pub const icons = @import("ui_icons/icons.zig");
pub const Icon = icons.Icon;
pub fn selected(ctx: *ui.Context) ui.Color {
    return if (@import("rex_chrome.zig").light(ctx)) ui.Color.white else ui.Color.white.alpha(0.10);
}
pub fn icon(ctx: *ui.Context, name: Icon, size: f32) void {
    icons.draw(ctx, name, size, 0.9);
}
// Kit's Div interaction clears focus on press. Restore it before the next
// control registers, otherwise Settings assigns its fallback focus to that row.
fn focusOnPress(ctx: *ui.Context, interaction: ui.Interaction, enabled: bool) ui.Interaction {
    var it = interaction;
    if (enabled and ctx.input.pressed and ctx.hot == it.id) {
        ctx.focus = it.id;
        ctx.changed = true;
    }
    it.focused = ctx.focus == it.id;
    return it;
}
pub fn iconControl(ctx: *ui.Context, name: Icon, extent: f32, active: bool, disabled: bool) ui.Interaction {
    const id = ctx.peekId(null);
    const b = kit.beginButton(ctx, false, .{ .disabled = disabled, .selected = active, .appearance = .{
        .style = .{ .width = .{ .px = extent }, .height = .{ .px = extent }, .radius = 6, .control = true, .align_items = .center, .justify = .center, .background = if (active) selected(ctx) else null, .border = if (ctx.focus == id) ctx.theme.accent else null, .opacity = if (disabled) 0.4 else 1 },
        .hover = if (disabled) null else ctx.theme.surface_hover,
    } });
    defer b.end();
    icon(ctx, name, 16);
    return focusOnPress(ctx, b.interaction, !disabled);
}
pub fn iconButton(ctx: *ui.Context, name: Icon, extent: f32) bool {
    return iconControl(ctx, name, extent, false, false).clicked;
}
pub fn button(ctx: *ui.Context, title: []const u8, options: ui.ButtonOptions) ui.Interaction {
    const id = ctx.peekId(null);
    const primary = options.variant == .primary or options.variant == .danger;
    const bg = if (options.variant == .danger) ctx.theme.danger else ctx.theme.accent;
    const it = kit.button(ctx, title, .{
        .variant = switch (options.variant) {
            .primary => .primary,
            .secondary => .secondary,
            .ghost => .ghost,
            .danger => .danger,
        },
        .disabled = options.disabled,
        .icon = options.icon,
        .appearance = .{
            .style = .{ .direction = .row, .width = options.width, .height = .{ .px = 28 }, .padding = .xy(12, 0), .gap = 6, .radius = 6, .align_items = .center, .justify = .center, .control = true, .clip = true, .opacity = if (options.disabled) 0.4 else 1, .background = if (primary) bg else if (options.variant == .secondary) (if (@import("rex_chrome.zig").light(ctx)) ui.Color.white else ui.Color.hex(0x404047)) else null, .border = if (ctx.focus == id) ctx.theme.accent else if (options.variant == .secondary) ctx.theme.border.alpha(0.7) else null },
            .hover = if (options.disabled) null else if (primary) bg.mix(ctx.theme.text, 0.08) else ctx.theme.surface_hover,
            .foreground = if (primary) ctx.theme.accent_text else ctx.theme.text,
            .text_size = options.size,
        },
    });
    return focusOnPress(ctx, it, !options.disabled);
}
/// A composed kit button (choice trigger, disclosure, command or settings row).
/// Draw its existing children and call ui.end, keeping semantic node IDs stable.
/// Keyboard/AX activation and disabled-action policy stay with the owner.
pub fn control(ctx: *ui.Context, style: ui.Style, hover: ?ui.Color) ui.Interaction {
    const b = kit.beginButton(ctx, true, .{ .appearance = .{ .style = style, .hover = hover } });
    return focusOnPress(ctx, b.interaction, style.control);
}
pub fn separator(ctx: *ui.Context) void {
    kit.separator(ctx, .{});
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
