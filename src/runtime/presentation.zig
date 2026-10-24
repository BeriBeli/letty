//! Geometry and faces from the retained Kero UI, connected to local owners.
const std = @import("std");
const nano = @import("nanoui");
const ui = nano.ui;
pub const icons = @import("interface-assets").icons;
pub const Icon = icons.Icon;
pub const header_height: f32 = 44;
pub const card_radius: f32 = 14;
pub const terminal_inset: f32 = 16;
pub fn theme(ctx: *ui.Context) void {
    const dark = ctx.theme.dark;
    ctx.theme.text = .hex(if (dark) 0xececf0 else 0x1d1d1f);
    ctx.theme.muted = .hex(if (dark) 0xa9a9b4 else 0x6e6e78);
    ctx.theme.surface = card(ctx);
    ctx.theme.surface_hover = ui.Color.white.alpha(if (dark) 0.06 else 0.45);
    ctx.theme.border = edge(ctx);
    ctx.theme.accent = .hex(if (dark) 0x6b93ff else 0x3b6cf6);
    ctx.theme.accent_hover = ctx.theme.accent.alpha(0.85);
    ctx.theme.danger = .hex(if (dark) 0xff6961 else 0xd93a35);
}
pub fn card(ctx: *ui.Context) ui.Color {
    return if (ctx.theme.dark) .hex(0x232328) else .white;
}
pub fn faint(ctx: *ui.Context) ui.Color {
    return .hex(if (ctx.theme.dark) 0x747480 else 0xa3a3ad);
}
pub fn selected(ctx: *ui.Context) ui.Color {
    return if (ctx.theme.dark) ui.Color.white.alpha(0.10) else .white;
}
pub fn edge(ctx: *ui.Context) ui.Color {
    return if (ctx.theme.dark) ui.Color.white.alpha(0.08) else ui.Color.black.alpha(0.07);
}
pub fn shadow(ctx: *ui.Context) ui.Color {
    return ui.Color.black.alpha(if (ctx.theme.dark) 0.35 else 0.07);
}
pub fn icon(ctx: *ui.Context, name: Icon, size: f32) void {
    icons.draw(ctx, name, size, 0.9);
}
pub fn tintedIcon(ctx: *ui.Context, name: Icon, size: f32, color: ui.Color) void {
    const first = ctx.nodes.items.len;
    icon(ctx, name, size);
    if (ctx.nodes.items.len > first) {
        const node = ctx.node(@intCast(first));
        if (node.content == .image) node.content.image.tint = color;
    }
}
pub fn iconControl(ctx: *ui.Context, name: Icon, title: []const u8, extent: f32) ui.Interaction {
    ui.key(ctx, title);
    const node = ctx.open(.{ .width = .{ .px = extent }, .height = .{ .px = extent }, .radius = 6, .control = true, .align_items = .center, .justify = .center }, null);
    const hit = ctx.interact(node, .{ .focusable = true });
    if (hit.clicked) ctx.changed = true;
    if (hit.hovered) ctx.node(node).style.background = ctx.theme.text.alpha(0.045);
    tintedIcon(ctx, name, 16, ctx.theme.muted);
    ui.end(ctx);
    nano.kit.tooltip(ctx, hit, @import("locale.zig").t(title), .{});
    return hit;
}
pub fn button(ctx: *ui.Context, name: Icon, title: []const u8, extent: f32) bool {
    return iconControl(ctx, name, title, extent).clicked;
}
pub fn textControl(ctx: *ui.Context, title: []const u8, active: bool) bool {
    ui.key(ctx, title);
    const node = ctx.open(.{ .direction = .row, .height = .{ .px = 24 }, .padding = .xy(8, 0), .radius = 6, .align_items = .center, .justify = .center, .control = true, .background = if (active) card(ctx) else null }, null);
    const hit = ctx.interact(node, .{ .focusable = true });
    if (hit.clicked) ctx.changed = true;
    if (hit.hovered and !active) ctx.node(node).style.background = ctx.theme.text.alpha(0.045);
    ui.text(ctx, @import("locale.zig").t(title), .{ .size = 12, .weight = .medium, .color = if (active) ctx.theme.text else ctx.theme.muted });
    ui.end(ctx);
    return hit.clicked;
}
pub fn shortcutLabel(ctx: *ui.Context, raw: []const u8) []const u8 {
    if (@import("builtin").os.tag != .macos or raw.len == 0) return raw;
    const key = @import("actions.zig").parse(raw, true) catch return raw;
    const character = switch (key.key) {
        13 => "↩",
        9 => "⇥",
        27 => "⎋",
        32 => "Space",
        0xf702 => "←",
        0xf703 => "→",
        0xf700 => "↑",
        0xf701 => "↓",
        else => blk: {
            var bytes: [4]u8 = undefined;
            const count = std.unicode.utf8Encode(if (key.key >= 'a' and key.key <= 'z') key.key - 32 else key.key, &bytes) catch return raw;
            break :blk ctx.alloc().dupe(u8, bytes[0..count]) catch return raw;
        },
    };
    return ctx.print("{s}{s}{s}{s}{s}", .{ if (key.ctrl) "⌃" else "", if (key.alt) "⌥" else "", if (key.shift) "⇧" else "", if (key.cmd) "⌘" else "", character });
}
pub fn ellipsize(ctx: *ui.Context, text: []const u8, width: f32, size: f32) []const u8 {
    if (ctx.text.layout(text, .{ .size = size }).width <= width) return text;
    var length = text.len;
    while (length > 0) {
        length -= 1;
        while (length > 0 and text[length] & 0xc0 == 0x80) length -= 1;
        const value = ctx.print("{s}…", .{text[0..length]});
        if (ctx.text.layout(value, .{ .size = size }).width <= width) return value;
    }
    return "…";
}
pub fn status(ctx: *ui.Context, state: []const u8, unread: bool, exited: bool) void {
    const name: Icon = if (std.mem.eql(u8, state, "error")) .status_failed else if (unread or std.mem.eql(u8, state, "blocked") or std.mem.eql(u8, state, "waiting")) .status_waiting else if (std.mem.eql(u8, state, "working")) working: {
        const frames = [_]Icon{ .status_working_0, .status_working_1, .status_working_2, .status_working_3, .status_working_4, .status_working_5, .status_working_6, .status_working_7 };
        ctx.frameIn(0.125);
        break :working frames[@as(usize, @intFromFloat(@mod(ctx.time * 8, 8)))];
    } else if (exited) .status_exited else if (std.mem.eql(u8, state, "done")) .status_done else .status_idle;
    icon(ctx, name, 15);
}
// Locate the image actually drawn by a control, independent of text labels.
pub fn findIcon(t: *ui.Tester, key: []const u8) ?ui.Rect {
    const hash = std.hash.Wyhash.hash(0x1a9e, key);
    for (t.ctx.nodes.items) |node| if (node.content == .image and node.content.image.key == hash) return node.rect;
    return null;
}
pub fn clickIcon(t: *ui.Tester, key: []const u8) !void {
    const r = findIcon(t, key) orelse return error.IconControlMissing;
    t.click(r.x + r.w / 2, r.y + r.h / 2);
}
pub fn clickIconWithin(t: *ui.Tester, key: []const u8, bounds: ui.Rect) !void {
    const hash = std.hash.Wyhash.hash(0x1a9e, key);
    for (t.ctx.nodes.items) |node| if (node.content == .image and node.content.image.key == hash and bounds.contains(.{ .x = node.rect.x + node.rect.w / 2, .y = node.rect.y + node.rect.h / 2 })) {
        t.click(node.rect.x + node.rect.w / 2, node.rect.y + node.rect.h / 2);
        return;
    };
    return error.IconControlMissing;
}
