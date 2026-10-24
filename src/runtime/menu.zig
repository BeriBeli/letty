//! Shared, content-sized native-drawn menus. No terminal/document owners retained.
const std = @import("std");
const ui = @import("nanoui").ui;
const C = @import("presentation.zig");
pub const row_height: f32 = 24;
pub const separator_height: f32 = 9;
pub const padding: f32 = 6;
pub const Item = struct {
    label: []const u8 = "",
    hint: []const u8 = "",
    disabled: bool = false,
    separator: bool = false,
    submenu: bool = false,
    checked: bool = false,
};
pub const State = struct { selected: ?usize = null, mouse: ui.Point = .{ .x = -1e6, .y = -1e6 } };
pub fn contentHeight(items: []const Item) f32 {
    var height: f32 = padding * 2;
    for (items) |item| height += if (item.separator) separator_height else row_height;
    return height;
}
pub fn contentWidth(ctx: *ui.Context, items: []const Item, minimum: f32) f32 {
    var width = minimum;
    for (items) |item| {
        if (item.separator) continue;
        const hint = if (item.hint.len > 0) ctx.text.layout(item.hint, .{ .size = 12 }).width + 12 else if (item.submenu or item.checked) @as(f32, 20) else 0;
        width = @max(width, ctx.text.layout(@import("locale.zig").t(item.label), .{ .size = 13 }).width + hint + 32);
    }
    return @min(320, width);
}
pub fn place(size: ui.Size, point: ui.Point, width: f32, height: f32) ui.Rect {
    const w = @min(width, @max(1, size.w - 16));
    const h = @min(height, @max(1, size.h - 16));
    return .{ .x = std.math.clamp(point.x, 8, @max(8, size.w - w - 8)), .y = std.math.clamp(point.y, 8, @max(8, size.h - h - 8)), .w = w, .h = h };
}
fn enabled(items: []const Item, index: usize) bool {
    return !items[index].separator and !items[index].disabled;
}
fn next(items: []const Item, current: ?usize, forward: bool) ?usize {
    if (items.len == 0) return null;
    var index = current orelse if (forward) items.len - 1 else 0;
    for (0..items.len) |_| {
        index = if (forward) (index + 1) % items.len else (index + items.len - 1) % items.len;
        if (enabled(items, index)) return index;
    }
    return null;
}
pub fn draw(state: *State, ctx: *ui.Context, bounds: ui.Rect, items: []const Item, keyboard: bool) ?usize {
    const moved = state.mouse.x != ctx.input.mouse.x or state.mouse.y != ctx.input.mouse.y;
    state.mouse = ctx.input.mouse;
    if (keyboard) {
        if (ctx.input.key == .down) state.selected = next(items, state.selected, true);
        if (ctx.input.key == .up) state.selected = next(items, state.selected, false);
        if (ctx.input.key == .home) state.selected = next(items, null, true);
        if (ctx.input.key == .end) state.selected = next(items, null, false);
    }
    if (state.selected) |i| if (i >= items.len or !enabled(items, i)) {
        state.selected = null;
    };
    const node = ctx.open(.{ .absolute = true, .fixed = true, .layer = 40, .offset = .{ .x = bounds.x, .y = bounds.y }, .width = .{ .px = bounds.w }, .height = .{ .px = bounds.h }, .padding = .all(padding), .background = C.card(ctx), .border = C.edge(ctx), .radius = 10, .shadow = .{ .color = ui.Color.black.alpha(if (ctx.theme.dark) 0.4 else 0.16), .blur = 16, .y = 4 }, .scroll = true }, null);
    defer ui.end(ctx);
    if (keyboard and ctx.input.key != null) if (state.selected) |selected| {
        var top: f32 = 0;
        for (items[0..selected]) |item| top += if (item.separator) separator_height else row_height;
        const id = ctx.node(node).id;
        const offset = ctx.scroll.get(id) orelse 0;
        ctx.scroll.put(ctx.gpa, id, std.math.clamp(offset, @max(0, top + row_height - bounds.h + padding * 2), top)) catch {};
    };
    var chosen: ?usize = null;
    for (items, 0..) |item, i| {
        ui.key(ctx, ctx.print("menu-item-{d}", .{i}));
        if (item.separator) {
            ui.column(ctx, .{ .width = .fill, .height = .{ .px = separator_height }, .padding = .{ .left = 8, .right = 8, .top = 4, .bottom = 4 } });
            _ = ctx.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = C.edge(ctx) }, .none, null);
            ui.end(ctx);
            continue;
        }
        const row = ctx.open(.{ .direction = .row, .width = .fill, .height = .{ .px = row_height }, .padding = .xy(10, 0), .gap = 8, .align_items = .center, .radius = 5, .control = true }, null);
        const hit = ctx.interact(row, .{});
        // Keyboard navigation keeps its highlight until the pointer actually moves.
        if (hit.hovered and moved and !item.disabled) state.selected = i;
        const selected = state.selected == i and !item.disabled;
        if (selected) ctx.node(row).style.background = ctx.theme.accent;
        const color = if (item.disabled) ctx.theme.muted else if (selected) ui.Color.white else ctx.theme.text;
        const trailing = if (item.hint.len > 0) ctx.text.layout(item.hint, .{ .size = 12 }).width + 12 else if (item.submenu or item.checked) @as(f32, 20) else 0;
        ui.text(ctx, C.ellipsize(ctx, @import("locale.zig").t(item.label), bounds.w - 32 - trailing, 13), .{ .size = 13, .color = color });
        ui.spacer(ctx);
        if (item.hint.len > 0) ui.text(ctx, item.hint, .{ .size = 12, .color = if (selected) .white else ctx.theme.muted });
        if (item.submenu or item.checked) C.tintedIcon(ctx, if (item.submenu) .right else .check, 12, color);
        ui.end(ctx);
        if (!item.disabled and (hit.clicked or (keyboard and state.selected == i and (ctx.input.key == .enter or (item.submenu and ctx.input.key == .right))))) chosen = i;
    }
    if (chosen != null) ctx.changed = true;
    return chosen;
}
