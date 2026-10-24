//! Native theme selection with live, non-mutating color preview.
const std = @import("std");
const ui = @import("nanoui").ui;
const L = @import("localized.zig");
const themes = @import("themes.zig");
pub const State = struct { query: ui.TextBuffer = .{}, selected: usize = 0, focus: bool = true };
pub const Event = union(enum) { close, use: struct { value: []const u8, scope: enum { both, light, dark } } };
pub fn view(ctx: *ui.Context, state: *State, catalog: *const themes.Catalog) ?Event {
    L.text(ctx, "Terminal themes", .{ .size = 22, .weight = .semibold });
    ui.key(ctx, "theme-query");
    if (state.focus) {
        ctx.focus = ctx.peekId(null);
        state.focus = false;
    }
    _ = L.field(ctx, &state.query, .{ .width = .fill, .placeholder = "Search Ghostty themes…" });
    var results: std.ArrayList(usize) = .empty;
    if (@import("actions.zig").fuzzy(state.query.text(), "letty") >= 0) results.append(ctx.alloc(), 0) catch return null;
    for (catalog.parsed.value.entries, 0..) |entry, i| if (@import("actions.zig").fuzzy(state.query.text(), entry.name) >= 0) {
        results.append(ctx.alloc(), i + 1) catch return null;
    };
    ui.key(ctx, "theme-list");
    const node = ctx.open(.{ .scroll = true, .width = .fill, .height = .{ .px = @min(230, ctx.size.h / 3) } }, null);
    const id = ctx.node(node).id;
    const offset = ctx.scroll.get(id) orelse 0;
    const start = @min(results.items.len, @as(usize, @intFromFloat(@floor(@max(0, offset) / 32))));
    const count = @min(results.items.len, start + 24);
    if (start > 0) _ = ctx.leaf(.{ .height = .{ .px = @as(f32, @floatFromInt(start)) * 32 } }, .none, null);
    for (results.items[start..count]) |index| {
        const colors = if (index == 0) themes.builtin(ctx.theme.dark) else catalog.parsed.value.entries[index - 1];
        ui.key(ctx, colors.name);
        ui.row(ctx, .{ .width = .fill, .height = .{ .px = 32 }, .gap = 4 });
        if (ui.button(ctx, colors.name, .{ .width = .fill, .size = 12, .variant = if (state.selected == index) .primary else .ghost }).clicked) state.selected = index;
        ui.end(ctx);
    }
    if (count < results.items.len) _ = ctx.leaf(.{ .height = .{ .px = @as(f32, @floatFromInt(results.items.len - count)) * 32 } }, .none, null);
    ui.end(ctx);
    const selected = if (state.selected == 0) themes.builtin(ctx.theme.dark) else catalog.parsed.value.entries[@min(state.selected - 1, catalog.parsed.value.entries.len - 1)];
    ui.column(ctx, .{ .width = .fill, .padding = .all(16), .gap = 10, .background = ui.Color.hex(selected.background), .radius = 8 });
    ui.text(ctx, selected.name, .{ .color = ui.Color.hex(selected.foreground), .mono = true, .size = 15 });
    L.text(ctx, "$ printf 'Letty · 中文 · é'", .{ .mono = true, .color = ui.Color.hex(selected.foreground) });
    ui.row(ctx, .{ .gap = 3 });
    for (selected.palette) |color| {
        _ = ctx.leaf(.{ .width = .{ .px = 22 }, .height = .{ .px = 18 }, .background = ui.Color.hex(color) }, .none, null);
    }
    ui.end(ctx);
    ui.end(ctx);
    ui.row(ctx, .{ .gap = 8 });
    var scope: ?@FieldType(@FieldType(Event, "use"), "scope") = null;
    if (L.button(ctx, "Use for both", .{ .variant = .primary }).clicked) scope = .both;
    if (L.button(ctx, "Use for light", .{}).clicked) scope = .light;
    if (L.button(ctx, "Use for dark", .{}).clicked) scope = .dark;
    ui.end(ctx);
    if (scope) |value| return .{ .use = .{ .value = selected.name, .scope = value } };
    if (L.button(ctx, "Back to settings", .{}).clicked) return .close;
    return null;
}
