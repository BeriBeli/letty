//! A portable nanoui command palette, ported from Kero's mygo palette.
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
    chosen_tab: u64 = 0,
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
            p.chosen_tab = 0;
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
        return p.drawWorkspaces(ctx, overrides, clear, capabilities, &.{});
    }
    pub fn drawWorkspaces(p: *Palette, ctx: *ui.Context, overrides: []const keys.Binding, clear: bool, capabilities: actions.Capabilities, rows: []const @import("navigation/snapshot.zig").Row) ?actions.Request {
        p.geometry.begin(p.generation, ctx.frame);
        if (p.ax_pending) |pending| {
            p.ax_pending = null;
            if (pending.generation == p.generation and pending.command.target_tab != 0) {
                for (rows) |row| if (row.id == pending.command.target_tab) {
                    p.chosen_tab = row.id;
                    p.dismiss(ctx);
                    return null;
                };
            }
            if (pending.generation == p.generation and pending.command.target_tab == 0 and capabilities.disabled(pending.command.request()) == null) {
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
        const width = @min(600, ctx.size.w - 32);
        const y = @min(84, @max(16, ctx.size.h - 140));
        const visible: usize = @intFromFloat(@max(1, @min(10, @floor((ctx.size.h - y - 76) / 38))));
        const initial = filter(ctx, p.query.text(), rows);
        const height = 62 + @as(f32, @floatFromInt(@max(1, @min(visible, initial.len)))) * 38;
        const rect: ui.Rect = .{ .x = (ctx.size.w - width) / 2, .y = y, .w = width, .h = height };
        if (ctx.input.pressed and !rect.contains(ctx.input.mouse)) {
            p.dismiss(ctx);
            return null;
        }
        // The full-window hit target captures clicks that would otherwise hit tabs or panes.
        ui.key(ctx, "command-palette-modal");
        const overlay = ctx.open(.{ .absolute = true, .width = .{ .px = ctx.size.w }, .height = .{ .px = ctx.size.h }, .background = @import("rex_chrome.zig").overlay(ctx) }, null);
        _ = ctx.interact(overlay, .{});
        defer ctx.end();
        ui.key(ctx, "command-palette-card");
        p.geometry.add(ctx, .panel, 0, "Command Palette", "", true, false, null);
        ui.column(ctx, .{ .absolute = true, .offset = .{ .x = rect.x, .y = rect.y }, .width = .{ .px = width }, .radius = 14, .border = ctx.theme.border, .background = ctx.theme.surface, .shadow = .{ .color = ui.Color.black.alpha(0.18), .blur = 28, .y = 8 }, .clip = true });
        defer ui.end(ctx);
        ui.row(ctx, .{ .width = .fill, .height = .{ .px = 50 }, .padding = .xy(16, 0), .gap = 10, .align_items = .center });
        chrome.icon(ctx, .search, 16);
        ui.key(ctx, "command-palette-query");
        // Keep focus in the query after clicking rows or empty card space.
        p.geometry.add(ctx, .query, 0, "Find Command", p.query.text(), true, false, null);
        ctx.focus = if (p.ax_focus != 0) p.ax_focus else ctx.peekId(null);
        const field = ui.textField(ctx, &p.query, .{ .placeholder = "Go to a session or run a command…", .width = .{ .px = width - 76 }, .size = 15, .bare = true });
        p.composing = if (ctx.focused_text) |f| f.marked != null else false;
        ui.end(ctx);
        chrome.separator(ctx);
        const list = filter(ctx, p.query.text(), rows);
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
                p.selected = p.wheel.select(ctx.input, 38, p.selected, list.len);
                ctx.changed = true;
            }
            if (p.selected < p.first) p.first = p.selected;
            if (p.selected >= p.first + visible) p.first = p.selected + 1 - visible;
            if (!composing and (enter or field.submitted)) {
                const entry = list.items[p.selected];
                const request = entry.request();
                if (entry.tab != 0) {
                    p.chosen_tab = entry.tab;
                    p.dismiss(ctx);
                    return null;
                }
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
        ui.column(ctx, .{ .width = .fill, .padding = .all(6) });
        if (list.len == 0) {
            ui.row(ctx, .{ .width = .fill, .height = .{ .px = 38 }, .padding = .xy(10, 0), .align_items = .center });
            ui.text(ctx, "No matching commands", .{ .size = 13, .color = ctx.theme.muted });
            ui.end(ctx);
        } else for (p.first..@min(list.len, p.first + visible)) |index| {
            const entry = list.items[index];
            const selected = index == p.selected;
            ui.key(ctx, ctx.print("palette-item-{d}-{d}", .{ entry.tab, entry.command orelse 0 }));
            const disabled = if (entry.tab != 0) null else capabilities.disabled(entry.request());
            p.geometry.add(ctx, .command, @intCast(index), entry.title, entry.detail, disabled == null, selected, if (entry.tab != 0) .{ .action = .none, .target_tab = entry.tab } else semantic.Command.from(entry.request()));
            const it = chrome.control(ctx, .{ .direction = .row, .width = .fill, .height = .{ .px = 38 }, .padding = .xy(10, 0), .gap = 8, .align_items = .center, .radius = 8, .control = true, .background = if (selected) ctx.theme.accent.alpha(0.12) else null }, ctx.theme.surface_hover);
            chrome.icon(ctx, if (entry.tab != 0) .status_idle else .return_key, 14);
            const detail = disabled orelse entry.detail;
            const accelerator = if (entry.tab != 0) "" else keys.acceleratorFor(overrides, clear, entry.request());
            const shortcut_width = ctx.text.layout(accelerator, .{ .size = 11 }).width;
            if (disabled) |reason| {
                ui.column(ctx, .{ .width = .fill, .gap = 1 });
                ui.text(ctx, chrome.ellipsize(ctx, entry.title, width - 76 - shortcut_width, 13.5), .{ .size = 13.5, .color = ctx.theme.muted });
                ui.text(ctx, chrome.ellipsize(ctx, reason, width - 76 - shortcut_width, 11), .{ .size = 11, .color = ctx.theme.muted });
                ui.end(ctx);
            } else {
                ui.text(ctx, chrome.ellipsize(ctx, entry.title, if (detail.len > 0) @min(260, width * 0.45) else width - 76 - shortcut_width, 13.5), .{ .size = 13.5 });
                if (detail.len > 0) ui.text(ctx, chrome.ellipsize(ctx, detail, @max(0, width - 320), 12.5), .{ .size = 12.5, .color = ctx.theme.muted });
            }
            ui.spacer(ctx);
            if (accelerator.len > 0) {
                ui.row(ctx, .{ .padding = .xy(5, 2), .radius = 5, .background = ctx.theme.text.alpha(0.055) });
                ui.text(ctx, accelerator, .{ .size = 11, .color = ctx.theme.muted });
                ui.end(ctx);
            }
            ui.end(ctx);
            if (it.clicked and disabled == null) {
                if (entry.tab != 0) p.chosen_tab = entry.tab;
                p.dismiss(ctx);
                ui.end(ctx);
                return if (entry.tab != 0) null else entry.request();
            }
        }
        ui.end(ctx);
        return null;
    }
};

const Item = struct {
    tab: u64 = 0,
    command: ?usize = null,
    title: []const u8,
    detail: []const u8 = "",
    fn request(self: Item) actions.Request {
        return if (self.command) |at| catalogue.entries[at].request() else .{ .action = .none };
    }
};
fn filter(ctx: *ui.Context, query: []const u8, rows: []const @import("navigation/snapshot.zig").Row) struct { items: []Item, len: usize } {
    const items = ctx.alloc().alloc(Item, rows.len + catalogue.entries.len) catch return .{ .items = &.{}, .len = 0 };
    var count: usize = 0;
    for (rows) |*row| {
        var words = std.mem.tokenizeAny(u8, query, " \t\r\n");
        const found = while (words.next()) |word| {
            if (!@import("settings/schema.zig").contains(row.title.text(), word) and !@import("settings/schema.zig").contains(row.cwd.text(), word)) break false;
        } else true;
        if (!found) continue;
        items[count] = .{ .tab = row.id, .title = row.title.text(), .detail = row.cwd.text() };
        count += 1;
    }
    const commands = catalogue.filter(query);
    for (commands.indices[0..commands.len]) |at| {
        items[count] = .{ .command = at, .title = catalogue.entries[at].title };
        count += 1;
    }
    return .{ .items = items[0..count], .len = count };
}
