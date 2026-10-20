//! Portable stable-ID tab strip and overflow / drag interactions.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("nanoui").ui;
const chrome = @import("chrome.zig");
pub fn draw(s: anytype, ctx: *ui.Context) void {
    ui.key(ctx, "tabs");
    s.ax.note(.{ .widget = ctx.peekId(null), .role = .tab_group, .target = .{ .window = s.id }, .label = "Tabs" });
    ui.row(ctx, .{ .width = .fill, .height = .{ .px = @import("navigation/geometry.zig").top_height }, .background = ctx.theme.surface, .align_items = .center, .clip = true });
    defer ui.end(ctx);
    const count: usize = s.layout.tab_count;
    if (count == 0) return;
    const controls: f32 = if (builtin.os.tag == .macos) 32 else 64;
    const overflow = (ctx.size.w - controls) / @as(f32, @floatFromInt(count)) < 120;
    const available = ctx.size.w - controls - (if (overflow) @as(f32, 48) else 0);
    const visible: usize = @max(1, @min(count, @as(usize, @intFromFloat(@floor(@max(0, available) / 120)))));
    const width = @max(1, @min(260, available / @as(f32, @floatFromInt(visible))));
    if (s.layout.active_tab < s.tab_first) s.tab_first = s.layout.active_tab;
    if (s.layout.active_tab >= s.tab_first + visible) s.tab_first = s.layout.active_tab + 1 - visible;
    s.tab_first = @min(s.tab_first, count - visible);
    const start_x: f32 = if (overflow) 24 else 0;
    if (overflow) {
        ui.key(ctx, "tab-overflow-previous");
        s.ax.note(.{ .widget = ctx.peekId(null), .role = .button, .target = .{ .window = s.id }, .intent = .previous_tab, .label = "Previous Tab" });
        if (chrome.iconButton(ctx, .left, 24)) s.pending = .{ .action = .previous_tab };
    }
    for (s.tab_first..@min(count, s.tab_first + visible)) |tab| {
        const metadata = s.layout.tabs[tab];
        const selected = tab == s.layout.active_tab;
        ui.key(ctx, ctx.print("tab-{d}", .{metadata.id}));
        s.ax.note(.{ .widget = ctx.peekId(null), .role = .tab, .target = .{ .window = s.id, .tab = metadata.id }, .intent = .tab, .label = s.tabLabel(@intCast(tab)), .selected = selected });
        const it = ui.pressable(ctx, .{ .direction = .row, .width = .{ .px = width }, .height = .{ .px = 30 }, .padding = .{ .left = 12, .right = 28 }, .gap = 8, .radius = 6, .background = if (selected) chrome.selected(ctx) else ctx.theme.surface, .control = true, .align_items = .center, .clip = true }, if (selected) null else ctx.theme.surface_hover);
        if (it.pressed and ctx.input.pressed and ctx.input.mouse_button == 2) {
            s.activateTab(@intCast(tab));
            s.openContext(ctx, .tab, metadata.id);
        }
        if (it.pressed and ctx.input.pressed and ctx.input.mouse_button == 1) {
            s.drag_tab = metadata.id;
            s.drag_origin = ctx.input.mouse.x;
        }
        if (it.clicked) {
            s.activateTab(@intCast(tab));
            if (it.double_clicked) s.pending = .{ .action = .rename_tab };
            ctx.changed = true;
        }
        const file_path = if (s.preview.active(metadata.id)) |d| d.panel.model.path.text() else "";
        chrome.icon(ctx, if (s.layout.isDocument(tab)) @import("ui_icons/icons.zig").file(file_path) else .folder, 16);
        const badge = @import("feedback.zig").badge(s, ctx, @intCast(tab));
        const name = ctx.print("{s}{s}", .{ badge, s.tabLabel(@intCast(tab)) });
        const raw_cwd = if (!s.layout.isDocument(tab) and metadata.focused < s.sessions.len) (if (s.sessions[metadata.focused]) |session| session.cwd.text() else "") else "";
        var clean_cwd: @import("fixed_text.zig").Text(4096) = .{};
        @import("navigation/snapshot.zig").clean(&clean_cwd, raw_cwd);
        const cwd = ctx.print("{s}", .{clean_cwd.text()});
        const title_width = if (cwd.len > 0) @min(width * 0.42, ctx.text.layout(name, .{ .size = 12 }).width) else width - 70;
        ui.text(ctx, chrome.ellipsize(ctx, name, @max(1, title_width), 12), .{ .size = 12, .color = ctx.theme.text, .weight = if (selected) .medium else .regular });
        if (cwd.len > 0) ui.text(ctx, chrome.ellipsize(ctx, cwd, @max(1, width - title_width - 78), 11), .{ .size = 11, .color = ctx.theme.muted });
        if (it.hovered or selected) {
            _ = ctx.open(.{ .absolute = true, .offset = .{ .x = width - 39, .y = 3 } }, null);
            ui.key(ctx, "tab-close");
            s.ax.note(.{ .widget = ctx.peekId(null), .role = .button, .target = .{ .window = s.id, .tab = metadata.id }, .intent = .tab_close, .label = "Close Tab" });
            if (chrome.iconButton(ctx, .close, 24)) {
                s.activateTab(@intCast(tab));
                s.pending = .{ .action = .close_tab };
            }
            ctx.end();
        }

        ui.end(ctx);
    }
    if (s.drag_tab) |id| {
        if (ctx.input.released or !ctx.input.down) s.drag_tab = null else if (@abs(ctx.input.mouse.x - s.drag_origin) > 6) {
            const target: usize = @intCast(s.tab_first + @as(usize, @intFromFloat(std.math.clamp(@floor((ctx.input.mouse.x - start_x) / width), 0, @as(f32, @floatFromInt(visible - 1))))));
            if (s.layout.tabIndex(id)) |from| if (from != target) {
                s.layout.move(from, target);
                s.save();
                ctx.changed = true;
            };
        }
    }
    if (overflow) {
        ui.key(ctx, "tab-overflow-next");
        s.ax.note(.{ .widget = ctx.peekId(null), .role = .button, .target = .{ .window = s.id }, .intent = .next_tab, .label = "Next Tab" });
        if (chrome.iconButton(ctx, .right, 24)) s.pending = .{ .action = .next_tab };
    }
    ui.key(ctx, "new-tab");
    s.ax.note(.{ .widget = ctx.peekId(null), .role = .button, .target = .{ .window = s.id }, .intent = .new_tab, .label = "New Tab" });
    if (chrome.iconButton(ctx, .plus, 28)) s.pending = .{ .action = .tab };
    ui.spacer(ctx);
    if (builtin.os.tag != .macos) {
        ui.key(ctx, "commands-button");
        s.ax.note(.{ .widget = ctx.peekId(null), .role = .button, .target = .{ .window = s.id }, .intent = .palette, .label = "Commands" });
        if (chrome.iconButton(ctx, .more, 28)) s.pending = .{ .action = .palette };
    }
}
