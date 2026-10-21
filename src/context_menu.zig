//! Portable terminal/tab menus. Targets are stable identities, resolved on execution.
const std = @import("std");
const ui = @import("nanoui").ui;
const semantic = @import("ui_semantics.zig");
const actions = @import("actions.zig");
const keys = @import("keybindings.zig");
const catalogue = @import("command_catalogue.zig");
const chrome = @import("chrome.zig");
pub const Kind = enum { terminal, tab };
const terminal = [_]actions.Action{ .copy, .paste, .select_all, .search_selection, .preview_selected_path, .horizontal, .vertical, .toggle_zoom, .clear_screen, .close };
const tabs = [_]actions.Action{ .rename_tab, .move_tab, .move_tab, .close_tab, .close_other_tabs, .toggle_tab_pin };
pub const Menu = struct {
    open: bool = false,
    generation: u64 = 0,
    geometry: semantic.Geometry = .{},
    ax_focus: u64 = 0,
    kind: Kind = .terminal,
    target: u64 = 0,
    point: ui.Point = .{},
    link: @import("fixed_text.zig").Text(2048) = .{},
    selected: usize = 0,
    wheel: @import("scroll_input.zig").Rows = .{},
    first: usize = 0,
    ax_pending: ?struct { generation: u64, command: semantic.Command } = null,
    pub fn requestAx(m: *Menu, generation: u64, command: semantic.Command) bool {
        if (!m.open or m.generation != generation) return false;
        m.ax_pending = .{ .generation = generation, .command = command };
        return true;
    }
    pub fn show(m: *Menu, ctx: *ui.Context, kind: Kind, target: u64) void {
        const generation = m.generation;
        m.* = .{ .generation = generation, .open = true, .kind = kind, .target = target, .point = ctx.input.mouse };
        semantic.advance(&m.generation);
        ctx.focus = 0;
        ctx.active = 0;
        ctx.input.clearEdges();
        ctx.changed = true;
    }
    pub fn dismiss(m: *Menu, ctx: *ui.Context) void {
        if (m.open) semantic.advance(&m.generation);
        m.ax_pending = null;
        m.ax_focus = 0;
        m.open = false;
        ctx.focus = 0;
        ctx.active = 0;
        ctx.input.clearEdges();
        ctx.changed = true;
    }
    fn request(m: Menu, index: usize) actions.Request {
        if (m.kind == .terminal and m.link.len > 0 and index < 2) return .{ .action = if (index == 0) .open_link else .copy_link };
        const action = if (m.kind == .terminal) terminal[index - @as(usize, if (m.link.len > 0) 2 else 0)] else tabs[index];
        return .{ .action = action, .args = if (m.kind == .tab and action == .move_tab) .{ .offset = if (index == 1) -1 else 1 } else .none };
    }
    pub fn draw(m: *Menu, ctx: *ui.Context, bindings: []const keys.Binding, clear: bool, capabilities: actions.Capabilities) ?actions.Request {
        m.geometry.begin(m.generation, ctx.frame);
        if (m.ax_pending) |pending| {
            m.ax_pending = null;
            if (pending.generation == m.generation and capabilities.disabled(pending.command.request()) == null) {
                m.dismiss(ctx);
                return pending.command.request();
            }
        }
        var cancel = ctx.shortcut(.{ .key = ui.Shortcut.escape }) or ctx.input.key == .escape;
        for (ctx.input.ops) |op| if (op == .command and op.command == .cancel) {
            cancel = true;
        };
        if (cancel) {
            m.dismiss(ctx);
            return null;
        }
        const count = if (m.kind == .terminal) terminal.len + @as(usize, if (m.link.len > 0) 2 else 0) else tabs.len;
        if (ctx.shortcut(.{ .key = ui.Shortcut.up }) or ctx.input.key == .up) {
            m.selected = (m.selected + count - 1) % count;
            ctx.input.key = null;
        }
        if (ctx.shortcut(.{ .key = ui.Shortcut.down }) or ctx.input.key == .down) {
            m.selected = (m.selected + 1) % count;
            ctx.input.key = null;
        }
        const enter = ctx.shortcut(.{ .key = ui.Shortcut.enter }) or ctx.input.key == .enter;
        if (enter) ctx.input.key = null;
        const width = @min(300, ctx.size.w - 16);
        const visible: usize = @max(1, @min(count, @as(usize, @intFromFloat(@floor((ctx.size.h - 28) / 28)))));
        const height = 12 + @as(f32, @floatFromInt(visible)) * 28;
        const rect: ui.Rect = .{ .x = std.math.clamp(m.point.x, 8, @max(8, ctx.size.w - width - 8)), .y = std.math.clamp(m.point.y, 8, @max(8, ctx.size.h - height - 8)), .w = width, .h = height };
        if (ctx.input.pressed and !rect.contains(ctx.input.mouse)) {
            m.dismiss(ctx);
            return null;
        }
        if ((ctx.input.scroll.y != 0 or ctx.input.scroll_started) and rect.contains(ctx.input.mouse)) {
            m.selected = m.wheel.select(ctx.input, 28, m.selected, count);
            ctx.changed = true;
        }
        if (m.selected < m.first) m.first = m.selected;
        if (m.selected >= m.first + visible) m.first = m.selected + 1 - visible;
        if (enter and capabilities.disabled(m.request(m.selected)) == null) {
            const result = m.request(m.selected);
            m.dismiss(ctx);
            return result;
        }
        ctx.wants_wheel = true;
        ui.key(ctx, "context-menu-modal");
        const overlay = ctx.open(.{ .absolute = true, .width = .{ .px = ctx.size.w }, .height = .{ .px = ctx.size.h } }, null);
        _ = ctx.interact(overlay, .{});
        defer ctx.end();
        m.geometry.add(ctx, .panel, 0, "Context Menu", "", true, false, null);
        ui.column(ctx, .{ .absolute = true, .offset = .{ .x = rect.x, .y = rect.y }, .width = .{ .px = width }, .padding = .all(6), .radius = 8, .background = ctx.theme.surface, .border = ctx.theme.border, .shadow = .{ .color = ui.Color.black.alpha(0.15), .blur = 12, .y = 4 } });
        defer ui.end(ctx);
        for (m.first..@min(count, m.first + visible)) |index| {
            const command = m.request(index);
            const disabled = capabilities.disabled(command);
            var label = catalogue.title(command.action);
            for (catalogue.entries) |entry| if (entry.request().same(command)) {
                label = entry.title;
                break;
            };
            if (m.kind == .terminal and m.link.len > 0 and index < 2 and !@import("url.zig").allowed(m.link.text())) label = if (index == 0) "Preview File" else "Copy Path";
            ui.key(ctx, ctx.print("context-item-{d}", .{index}));
            m.geometry.add(ctx, .command, @intCast(index), label, "", disabled == null, index == m.selected, semantic.Command.from(command));
            const item = chrome.control(ctx, .{ .direction = .row, .width = .fill, .height = .{ .px = 28 }, .padding = .xy(8, 0), .gap = 6, .radius = 4, .align_items = .center, .control = true, .background = if (index == m.selected) ctx.theme.surface_hover else null }, ctx.theme.surface_hover);
            const accelerator = keys.acceleratorFor(bindings, clear, command);
            ui.text(ctx, chrome.ellipsize(ctx, label, width - 40 - ctx.text.layout(accelerator, .{ .size = 10 }).width, 12), .{ .size = 12, .color = if (disabled != null) ctx.theme.muted else ctx.theme.text });
            ui.spacer(ctx);
            ui.text(ctx, accelerator, .{ .size = 10, .color = ctx.theme.muted });
            ui.end(ctx);
            if (item.clicked and disabled == null) {
                m.dismiss(ctx);
                return command;
            }
        }
        return null;
    }
};
