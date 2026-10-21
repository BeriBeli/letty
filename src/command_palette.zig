//! A portable nanoui command palette, following Ghostty's overlay structure.
const std = @import("std");
const ui = @import("nanoui").ui;
const semantic = @import("ui_semantics.zig");
const actions = @import("actions.zig");
const keys = @import("keybindings.zig");
const catalogue = @import("command_catalogue.zig");
const chrome = @import("chrome.zig");
pub const Palette = struct {
    open: bool = false,
    generation: u64 = 0,
    geometry: semantic.Geometry = .{},
    ax_focus: u64 = 0,
    query: ui.TextBuffer = .{},
    previous: ui.TextBuffer = .{},
    composing: bool = false,
    selected: usize = 0,
    wheel: @import("scroll_input.zig").Rows = .{},
    first: usize = 0,
    ax_pending: ?struct { generation: u64, command: semantic.Command } = null,
    pub fn requestAx(p: *Palette, generation: u64, command: semantic.Command) bool {
        if (!p.open or p.generation != generation) return false;
        p.ax_pending = .{ .generation = generation, .command = command };
        return true;
    }

    pub fn toggle(p: *Palette, ctx: *ui.Context) void {
        if (p.open) p.dismiss(ctx) else {
            semantic.advance(&p.generation);
            p.ax_focus = 0;
            p.ax_pending = null;
            p.open = true;
            p.composing = false;
            p.query.clear();
            p.previous.clear();
            p.selected = 0;
            p.first = 0;
            p.wheel = .{};
            ctx.input.clearEdges();
            ctx.changed = true;
        }
    }
    pub fn dismiss(p: *Palette, ctx: *ui.Context) void {
        if (p.open) semantic.advance(&p.generation);
        p.ax_pending = null;
        p.ax_focus = 0;
        p.open = false;
        ctx.focus = 0;
        ctx.active = 0;
        ctx.input.clearEdges();
        ctx.changed = true;
    }
    fn take(ctx: *ui.Context, comptime key: anytype, shortcut: u21) bool {
        const found = ctx.shortcut(.{ .key = shortcut }) or ctx.input.key == key;
        if (found) ctx.input.key = null;
        return found;
    }
    pub fn draw(p: *Palette, ctx: *ui.Context, overrides: []const keys.Binding, clear: bool, capabilities: actions.Capabilities) ?actions.Request {
        p.geometry.begin(p.generation, ctx.frame);
        if (p.ax_pending) |pending| {
            p.ax_pending = null;
            if (pending.generation == p.generation and capabilities.disabled(pending.command.request()) == null) {
                p.dismiss(ctx);
                return pending.command.request();
            }
        }
        ctx.wants_wheel = true;
        const composing = p.composing;
        var cancel = !composing and take(ctx, .escape, ui.Shortcut.escape);
        for (ctx.input.ops) |op| if (!composing and op == .command and op.command == .cancel) {
            cancel = true;
        };
        if (cancel) {
            p.dismiss(ctx);
            return null;
        }
        const up = !composing and take(ctx, .up, ui.Shortcut.up);
        const down = !composing and take(ctx, .down, ui.Shortcut.down);
        const enter = !composing and take(ctx, .enter, ui.Shortcut.enter);
        const width = @min(500, ctx.size.w - 32);
        const y = @max(16, ctx.size.h * 0.05);
        const visible: usize = @intFromFloat(@max(1, @min(8, @floor((ctx.size.h - y - 86) / 34))));
        const initial = catalogue.filter(p.query.text());
        const height = 71 + @as(f32, @floatFromInt(@max(1, @min(visible, initial.len)))) * 34;
        const rect: ui.Rect = .{ .x = (ctx.size.w - width) / 2, .y = y, .w = width, .h = height };
        if (ctx.input.pressed and !rect.contains(ctx.input.mouse)) {
            p.dismiss(ctx);
            return null;
        }
        // The full-window hit target captures clicks that would otherwise hit tabs or panes.
        ui.key(ctx, "command-palette-modal");
        const overlay = ctx.open(.{ .absolute = true, .width = .{ .px = ctx.size.w }, .height = .{ .px = ctx.size.h } }, null);
        _ = ctx.interact(overlay, .{});
        defer ctx.end();
        ui.key(ctx, "command-palette-card");
        p.geometry.add(ctx, .panel, 0, "Command Palette", "", true, false, null);
        ui.column(ctx, .{ .absolute = true, .offset = .{ .x = rect.x, .y = rect.y }, .width = .{ .px = width }, .radius = 10, .border = ctx.theme.border, .background = ctx.theme.background, .shadow = .{ .color = ui.Color.black.alpha(0.18), .blur = 24, .y = 8 }, .clip = true });
        defer ui.end(ctx);
        ui.row(ctx, .{ .width = .fill, .height = .{ .px = 44 }, .padding = .xy(14, 0), .gap = 10, .align_items = .center });
        ui.key(ctx, "command-palette-query");
        // Keep focus in the query after clicking rows or empty card space.
        p.geometry.add(ctx, .query, 0, "Find Command", p.query.text(), true, false, null);
        ctx.focus = if (p.ax_focus != 0) p.ax_focus else ctx.peekId(null);
        const field = ui.textField(ctx, &p.query, .{ .placeholder = "Type a command…", .width = .{ .px = width - 68 }, .size = 14, .bare = true });
        p.composing = if (ctx.focused_text) |f| f.marked != null else false;
        ui.text(ctx, "esc", .{ .size = 10, .color = ctx.theme.muted });
        ui.end(ctx);
        chrome.separator(ctx);
        const list = catalogue.filter(p.query.text());
        if (!std.mem.eql(u8, p.previous.text(), p.query.text())) {
            p.previous.set(p.query.text());
            p.selected = 0;
            p.first = 0;
            p.wheel = .{};
            ctx.changed = true;
        }
        if (list.len > 0) {
            p.selected = @min(p.selected, list.len - 1);
            if (down) p.selected = (p.selected + 1) % list.len;
            if (up) p.selected = (p.selected + list.len - 1) % list.len;
            if ((ctx.input.scroll.y != 0 or ctx.input.scroll_started) and rect.contains(ctx.input.mouse)) {
                p.selected = p.wheel.select(ctx.input, 34, p.selected, list.len);
                ctx.changed = true;
            }
            if (p.selected < p.first) p.first = p.selected;
            if (p.selected >= p.first + visible) p.first = p.selected + 1 - visible;
            if (!composing and (enter or field.submitted)) {
                const request = catalogue.entries[list.indices[p.selected]].request();
                if (capabilities.disabled(request) == null) {
                    p.dismiss(ctx);
                    return request;
                }
            }
        } else {
            p.selected = 0;
            p.first = 0;
            p.wheel = .{};
        }
        ui.column(ctx, .{ .width = .fill, .padding = .xy(5, 4) });
        if (list.len == 0) {
            ui.row(ctx, .{ .width = .fill, .height = .{ .px = 34 }, .padding = .xy(9, 0), .align_items = .center });
            ui.text(ctx, "No matching commands", .{ .size = 13, .color = ctx.theme.muted });
            ui.end(ctx);
        } else for (p.first..@min(list.len, p.first + visible)) |index| {
            const entry = catalogue.entries[list.indices[index]];
            const selected = index == p.selected;
            ui.key(ctx, ctx.print("command-{d}", .{list.indices[index]}));
            const disabled = capabilities.disabled(entry.request());
            p.geometry.add(ctx, .command, @intCast(list.indices[index]), entry.title, "", disabled == null, selected, semantic.Command.from(entry.request()));
            const it = chrome.control(ctx, .{ .direction = .row, .width = .fill, .height = .{ .px = 34 }, .padding = .xy(9, 0), .gap = 8, .align_items = .center, .radius = 5, .control = true, .background = if (selected) ctx.theme.accent.alpha(0.12) else null }, ctx.theme.surface_hover);
            const accelerator = keys.acceleratorFor(overrides, clear, entry.request());
            const shortcut_width = ctx.text.layout(accelerator, .{ .size = 11 }).width;
            ui.text(ctx, chrome.ellipsize(ctx, entry.title, width - 46 - shortcut_width, 13), .{ .size = 13, .color = if (disabled != null) ctx.theme.muted else ctx.theme.text });
            ui.spacer(ctx);
            ui.text(ctx, accelerator, .{ .size = 11, .color = ctx.theme.muted });
            ui.end(ctx);
            if (it.clicked and disabled == null) {
                p.dismiss(ctx);
                ui.end(ctx);
                return entry.request();
            }
        }
        ui.end(ctx);
        ui.row(ctx, .{ .width = .fill, .height = .{ .px = 18 }, .padding = .xy(14, 0), .align_items = .center });
        ui.text(ctx, if (list.len > 0) capabilities.disabled(catalogue.entries[list.indices[p.selected]].request()) orelse "↑↓ select    ↵ run" else "↑↓ select    ↵ run", .{ .size = 10, .color = ctx.theme.muted });
        ui.spacer(ctx);
        ui.textf(ctx, .{ .size = 10, .color = ctx.theme.muted }, "{d} commands", .{list.len});
        ui.end(ctx);
        return null;
    }
};
