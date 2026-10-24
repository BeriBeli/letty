//! The retained Kero grouped form layout, using current native field interfaces.
const std = @import("std");
const nano = @import("nanoui");
const ui = nano.ui;
const L = @import("localized.zig");
const C = @import("presentation.zig");
const Settings = @import("settings.zig").Settings;
const Themes = @import("themes.zig");
const Menu = enum { font, size, choices, light_theme, dark_theme };
const font_sizes = [_][]const u8{ "9", "10", "11", "12", "13", "14", "15", "16", "17", "18", "20", "22", "24", "28", "32" };
const font_weights = [_][]const u8{ "300", "400", "500", "600" };
const history_sizes = [_][]const u8{ "0", "1", "4", "8", "16", "32", "64", "128", "256" };
pub const Page = enum { general, appearance, terminal, shell, notifications, keyboard, advanced };
pub const names = [_][]const u8{ "General", "Appearance", "Terminal", "Shell", "Notifications", "Keyboard", "Advanced" };
pub const State = struct {
    query: ui.TextBuffer = .{},
    edit: ui.TextBuffer = .{},
    key: ?[]const u8 = null,
    focus: bool = false,
    page: Page = .general,
    draft: @import("settings_draft.zig").Draft = .{},
    fonts: ?@import("font_catalog.zig").Catalog = null,
    font_query: ui.TextBuffer = .{},
    font_focus: bool = false,
    popup: ui.Rect = .{},
    menu: ?Menu = null,
    choices: []const []const u8 = &.{},
    menu_index: usize = 0,
    choice_state: @import("menu.zig").State = .{},
    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        self.draft.deinit(a);
        if (self.fonts) |*fonts| fonts.deinit();
        self.fonts = null;
    }
};
pub const Edit = struct { key: []const u8, value: []const u8 };
pub fn category(key: []const u8) Page {
    const group = @import("preference_schema.zig").field(key).group;
    if (std.mem.eql(u8, group, "General")) return .general;
    if (std.mem.eql(u8, group, "Appearance")) return .appearance;
    if (std.mem.eql(u8, group, "Terminal")) return .terminal;
    if (std.mem.eql(u8, group, "Shell")) return .shell;
    if (std.mem.eql(u8, group, "Input")) return .terminal;
    if (std.mem.eql(u8, group, "Changes")) return .general;
    if (std.mem.eql(u8, group, "Notifications")) return .notifications;
    return .advanced;
}
fn subgroup(key: []const u8) []const u8 {
    if (std.mem.startsWith(u8, key, "font-") or std.mem.eql(u8, key, "line-height")) return "Text";
    if (std.mem.startsWith(u8, key, "cursor-")) return "Cursor";
    if (std.mem.eql(u8, key, "theme") or std.mem.eql(u8, key, "minimum-contrast") or std.mem.eql(u8, key, "dim-unfocused-terminals")) return "Colors";
    const group = @import("preference_schema.zig").field(key).group;
    if (std.mem.eql(u8, group, "General")) return "Sessions";
    if (std.mem.eql(u8, group, "Appearance")) return "";
    if (std.mem.eql(u8, group, "Changes")) return "Git";
    if (std.mem.startsWith(u8, key, "notify-on-")) return "Notify me when";
    if (std.mem.eql(u8, group, "Notifications")) return "How";
    return group;
}
pub fn view(state: *State, ctx: *ui.Context, settings: Settings, catalog: *const Themes.Catalog, colors: Themes.Set) ?Edit {
    @setEvalBranchQuota(10000);
    var event: ?Edit = null;
    if (state.page == .terminal and state.query.len == 0) preview(ctx, settings, if (ctx.theme.dark) colors.dark else colors.light);
    var group: []const u8 = "";
    var opened = false;
    inline for (.{ "new-session-directory", "session-name", "focus-follows-mouse", "confirm-close", "window-theme", "language", "background", "window-translucent", "font-family", "font-size", "line-height", "font-weight", "font-ligatures", "font-thicken", "theme", "dim-unfocused-terminals", "minimum-contrast", "cursor-style", "cursor-style-blink", "command", "scrollback-limit", "macos-option-as-alt", "copy-on-select", "clipboard-read", "right-click-action", "notify-on-waiting", "notify-on-done", "notify-on-error", "notify-sound", "dock-badge", "dock-bounce", "git-status", "diff-layout" }) |key| {
        const schema = comptime @import("preference_schema.zig").field(key);
        const label = @import("locale.zig").t(schema.title);
        const matches = if (state.query.len > 0) @import("actions.zig").fuzzy(state.query.text(), key) >= 0 or @import("actions.zig").fuzzy(state.query.text(), label) >= 0 else category(key) == state.page;
        if (matches and !(std.mem.eql(u8, key, "background") and state.query.len == 0)) {
            const section = subgroup(key);
            if (!opened or !std.mem.eql(u8, group, section)) {
                if (opened) {
                    ui.end(ctx);
                    ui.end(ctx);
                }
                ui.column(ctx, .{ .width = .fill, .gap = 8 });
                if (section.len > 0) L.text(ctx, section, .{ .size = 12, .weight = .semibold, .color = ctx.theme.muted });
                ui.column(ctx, .{ .width = .fill, .radius = 12, .background = ctx.theme.text.alpha(if (ctx.theme.dark) 0.07 else 0.045), .padding = .xy(16, 4) });
                opened = true;
                group = section;
            } else _ = ctx.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = C.edge(ctx) }, .none, null);
            ui.key(ctx, key);
            ui.row(ctx, .{ .width = .fill, .min_height = 42, .padding = .xy(0, 11), .align_items = .center, .gap = 16 });
            ui.column(ctx, .{ .width = .fill, .grow = 1, .gap = 3 });
            ui.text(ctx, if (comptime std.mem.eql(u8, key, "theme")) @import("locale.zig").t("Light windows") else label, .{ .size = 13.5 });
            const detail = comptime @import("preference_schema.zig").detail(key);
            if (detail.len > 0) L.text(ctx, detail, .{ .size = 12, .color = ctx.theme.muted, .wrap = true });
            ui.end(ctx);
            const value = @field(settings, key);
            if (@TypeOf(value) == bool) {
                const node = ctx.open(.{ .width = .{ .px = 38 }, .height = .{ .px = 22 }, .radius = 11, .background = if (value) ctx.theme.accent else ctx.theme.muted.alpha(0.2), .control = true }, "switch");
                const hit = ctx.interact(node, .{ .focusable = true });
                _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = if (value) 18 else 2, .y = 2 }, .width = .{ .px = 18 }, .height = .{ .px = 18 }, .radius = 9, .background = .white }, .none, null);
                ui.end(ctx);
                if (hit.clicked) event = .{ .key = key, .value = if (value) "false" else "true" };
            } else if (comptime std.mem.eql(u8, key, "theme")) {
                menuControl(state, ctx, key, Themes.name(value, false) catch "letty", .light_theme, 240, &.{});
            } else if (comptime std.mem.eql(u8, key, "line-height")) {
                var height = value;
                if (ui.slider(ctx, &height, .{ .min = 1, .max = 2, .width = .{ .px = 144 } })) event = .{ .key = key, .value = ctx.print("{d:.2}", .{height}) };
                ui.text(ctx, ctx.print("{d:.2}×", .{value}), .{ .size = 12, .color = ctx.theme.muted });
            } else if (comptime schema.choices.len > 0) {
                if (comptime segmentedKey(key)) {
                    if (segments(ctx, key, value, schema.choices)) |choice| event = .{ .key = key, .value = choice };
                } else menuControl(state, ctx, key, choiceLabel(key, value), .choices, 190, schema.choices);
            } else if (comptime std.mem.eql(u8, key, "font-size")) {
                menuControl(state, ctx, key, ctx.print("{d:.0} pt", .{value}), .size, 90, &font_sizes);
            } else if (comptime std.mem.eql(u8, key, "font-weight")) {
                menuControl(state, ctx, key, choiceLabel(key, ctx.print("{d}", .{value})), .choices, 150, &font_weights);
            } else if (comptime std.mem.eql(u8, key, "scrollback-limit")) {
                menuControl(state, ctx, key, ctx.print("{d} MiB", .{value}), .choices, 150, &history_sizes);
            } else if (comptime std.mem.eql(u8, key, "font-family")) {
                menuControl(state, ctx, key, if (std.mem.eql(u8, value, "monospace")) "System" else if (value.len > 0 and !std.mem.eql(u8, value, @import("fonts.zig").family)) value else "JetBrains Mono Nerd Font", .font, 240, &.{});
            } else if (state.key != null and std.mem.eql(u8, state.key.?, key) and !std.mem.eql(u8, key, "font-family")) {
                if (state.focus) {
                    ui.key(ctx, "value");
                    ctx.focus = ctx.peekId(null);
                    state.focus = false;
                }
                const field = L.field(ctx, &state.edit, .{ .width = .{ .px = @min(230, ctx.size.w / 3) } });
                if (field.submitted or L.button(ctx, "Apply", .{ .variant = .ghost, .size = 12 }).clicked) {
                    event = .{ .key = key, .value = state.edit.text() };
                    state.key = null;
                    ctx.focus = 0;
                }
            } else {
                const text = if (@TypeOf(value) == []const u8) ctx.print("{s}", .{if (value.len > 0) value else "Default"}) else ctx.print("{any}", .{value});
                const node = ctx.open(.{ .direction = .row, .height = .{ .px = 30 }, .gap = 12, .radius = 15, .align_items = .center, .control = true }, "choice");
                const hit = ctx.interact(node, .{});
                ui.text(ctx, C.ellipsize(ctx, text, @min(270, ctx.size.w / 3), 13), .{ .size = 13 });
                C.icon(ctx, .down, 12);
                ui.end(ctx);
                if (hit.clicked) {
                    state.key = key;
                    state.edit.set(text);
                    state.focus = true;
                    state.popup = ctx.rects.get(ctx.node(node).id) orelse .{};
                    state.font_query.clear();
                    state.font_focus = true;
                }
            }
            ui.end(ctx);
            if (comptime std.mem.eql(u8, key, "theme")) {
                _ = ctx.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = C.edge(ctx) }, .none, null);
                ui.row(ctx, .{ .width = .fill, .height = .{ .px = 50 }, .align_items = .center });
                L.text(ctx, "Dark windows", .{ .size = 13.5 });
                ui.spacer(ctx);
                menuControl(state, ctx, key, Themes.name(value, true) catch "letty", .dark_theme, 240, &.{});
                ui.end(ctx);
            }
        }
    }
    if (opened) {
        ui.end(ctx);
        ui.end(ctx);
    }
    if (state.page == .appearance and state.query.len == 0) if (backgrounds(ctx, settings.background)) |name| {
        event = .{ .key = "background", .value = name };
    };
    _ = catalog;
    return event;
}
fn segmentedKey(key: []const u8) bool {
    for ([_][]const u8{ "new-session-directory", "session-name", "window-theme", "cursor-style", "clipboard-read", "diff-layout" }) |name| if (std.mem.eql(u8, key, name)) return true;
    return false;
}
fn choiceLabel(key: []const u8, value: []const u8) []const u8 {
    if (std.mem.eql(u8, key, "font-weight")) {
        const weights = .{ .{ "300", "Light" }, .{ "400", "Regular" }, .{ "500", "Medium" }, .{ "600", "Semibold" } };
        inline for (weights) |pair| if (std.mem.eql(u8, value, pair[0])) return @import("locale.zig").t(pair[1]);
    }
    const choices = .{
        .{ "current", "Current Folder" },    .{ "project", "Project" }, .{ "home", "Home" },
        .{ "focused", "Pane You’re In" },
        .{ "lead", "Pane That Needs You" },  .{ "folder", "Folder" },   .{ "system", "System" },
        .{ "light", "Light" },               .{ "dark", "Dark" },       .{ "en", "English" },
        .{ "zh-Hans", "简体中文" },
        .{ "block", "Block" },               .{ "bar", "Bar" },         .{ "underline", "Underline" },
        .{ "ask", "Ask" },                   .{ "allow", "Allow" },     .{ "deny", "Deny" },
        .{ "auto", "Auto" },                 .{ "split", "Split" },     .{ "unified", "Unified" },
        .{ "context-menu", "Shows a menu" }, .{ "paste", "Pastes" },    .{ "copy-or-paste", "Copies, or pastes" },
    };
    inline for (choices) |pair| if (std.mem.eql(u8, value, pair[0])) return @import("locale.zig").t(pair[1]);
    return value;
}
fn choiceText(ctx: *ui.Context, key: []const u8, value: []const u8) []const u8 {
    if (std.mem.eql(u8, key, "scrollback-limit")) return ctx.print("{s} MiB", .{value});
    return choiceLabel(key, value);
}
fn segments(ctx: *ui.Context, key: []const u8, value: []const u8, choices: []const []const u8) ?[]const u8 {
    ui.row(ctx, .{ .height = .{ .px = 24 }, .padding = .all(2), .radius = 7, .background = ctx.theme.text.alpha(0.06), .align_items = .center });
    defer ui.end(ctx);
    var result: ?[]const u8 = null;
    for (choices) |choice| {
        ui.key(ctx, choice);
        const selected = std.mem.eql(u8, value, choice);
        const node = ctx.open(.{ .height = .fill, .padding = .xy(12, 0), .radius = 5, .align_items = .center, .justify = .center, .control = true, .background = if (selected) C.card(ctx) else null, .shadow = if (selected) .{ .color = ui.Color.black.alpha(0.16), .blur = 1.5, .y = 0.5 } else null }, null);
        const hit = ctx.interact(node, .{ .focusable = true });
        ui.text(ctx, choiceLabel(key, choice), .{ .size = 12.5 });
        ui.end(ctx);
        if (hit.clicked) result = choice;
    }
    return result;
}
fn menuControl(state: *State, ctx: *ui.Context, key: []const u8, text: []const u8, menu: Menu, width: f32, choices: []const []const u8) void {
    ui.key(ctx, @tagName(menu));
    const extent = @min(@min(width, @max(90, ctx.size.w - 500)), ctx.text.layout(text, .{ .size = 13 }).width + 44);
    const node = ctx.open(.{ .direction = .row, .width = .{ .px = extent }, .height = .{ .px = 28 }, .padding = .{ .left = 10, .right = 3 }, .gap = 8, .radius = 14, .align_items = .center, .control = true }, null);
    const hit = ctx.interact(node, .{ .focusable = true });
    if (hit.hovered) ctx.node(node).style.background = ctx.theme.text.alpha(0.045);
    ui.text(ctx, C.ellipsize(ctx, text, extent - 43, 13), .{ .size = 13 });
    ui.spacer(ctx);
    ui.column(ctx, .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .radius = 11, .background = ctx.theme.text.alpha(0.045), .align_items = .center, .justify = .center });
    C.icon(ctx, .updown, 16);
    ui.end(ctx);
    ui.end(ctx);
    if (hit.clicked) {
        ctx.changed = true;
        if (state.menu == menu and state.key != null and std.mem.eql(u8, state.key.?, key)) {
            state.menu = null;
            return;
        }
        state.menu = menu;
        state.key = key;
        state.choices = choices;
        state.popup = ctx.rects.get(ctx.node(node).id) orelse .{};
        state.edit.set(text);
        state.font_query.clear();
        state.font_focus = true;
        state.menu_index = 0;
        state.choice_state = .{};
    }
}
pub fn popup(state: *State, ctx: *ui.Context, settings: Settings, catalog: *const Themes.Catalog) ?Edit {
    const menu = state.menu orelse return null;
    if (menu == .choices or menu == .size) return choicePopup(state, ctx, menu);
    var values: std.ArrayList([]const u8) = .empty;
    const a = ctx.alloc();
    switch (menu) {
        .font => {
            const common = [_][]const u8{ "JetBrains Mono Nerd Font", "System", "SF Mono", "Menlo", "Monaco", "JetBrains Mono", "Fira Code", "Cascadia Code", "Iosevka", "Berkeley Mono", "Geist Mono", "IBM Plex Mono", "Source Code Pro", "Hack", "Maple Mono" };
            values.appendSlice(a, &common) catch return null;
            if (state.fonts) |fonts| for (fonts.names) |name| {
                var found = false;
                for (values.items) |prior| if (std.ascii.eqlIgnoreCase(prior, name)) {
                    found = true;
                    break;
                };
                if (!found) values.append(a, name) catch return null;
            };
        },
        .choices, .size => values.appendSlice(a, state.choices) catch return null,
        .light_theme, .dark_theme => {
            values.append(a, "letty") catch return null;
            for (catalog.parsed.value.entries) |entry| values.append(a, entry.name) catch return null;
        },
    }
    var filtered: std.ArrayList([]const u8) = .empty;
    for (values.items) |value| if (std.ascii.findIgnoreCase(value, state.font_query.text()) != null) filtered.append(a, value) catch return null;
    const opening = state.font_focus;
    if (opening) for (filtered.items, 0..) |value, i| {
        if (std.mem.eql(u8, state.edit.text(), if (menu == .size) ctx.print("{s} pt", .{value}) else if (menu == .choices) choiceText(ctx, state.key orelse "", value) else value)) {
            state.menu_index = i;
            break;
        }
    };
    const width: f32 = if (menu == .size) 100 else 260;
    const height = @min(300, @as(f32, @floatFromInt(filtered.items.len)) * 24 + 40);
    const x = std.math.clamp(state.popup.x + state.popup.w - width, 8, @max(8, ctx.size.w - width - 8));
    const y = std.math.clamp(state.popup.y + state.popup.h + 3, 8, @max(8, ctx.size.h - height - 8));
    const bounds: ui.Rect = .{ .x = x, .y = y, .w = width, .h = height };
    if (ctx.input.key == .escape or (ctx.input.pressed and !bounds.contains(ctx.input.mouse) and !state.popup.contains(ctx.input.mouse))) {
        state.menu = null;
        state.key = null;
        ctx.focus = 0;
        ctx.input.clearEdges();
        return null;
    }
    ui.column(ctx, .{ .fixed = true, .absolute = true, .layer = 25, .offset = .{ .x = x, .y = y }, .width = .{ .px = width }, .height = .{ .px = height }, .padding = .all(5), .radius = 13, .border = C.edge(ctx), .background = C.card(ctx), .shadow = .{ .color = C.shadow(ctx), .blur = 12, .y = 4 } });
    defer ui.end(ctx);
    ui.key(ctx, "font-search");
    if (state.font_focus) {
        ctx.focus = ctx.peekId(null);
        state.font_focus = false;
    }
    const field = L.field(ctx, &state.font_query, .{ .placeholder = "Search…", .width = .fill, .size = 13, .bare = true });
    if (field.changed) state.menu_index = 0;
    if (ctx.input.key == .down) state.menu_index +|= 1;
    if (ctx.input.key == .up) state.menu_index -|= 1;
    state.menu_index = @min(state.menu_index, filtered.items.len -| 1);
    ui.key(ctx, "choice-options");
    const list = ctx.open(.{ .scroll = true, .width = .fill, .height = .fill, .grow = 1 }, null);
    defer ui.end(ctx);
    const id = ctx.node(list).id;
    var offset = ctx.scroll.get(id) orelse 0;
    if (opening or ctx.input.key == .down or ctx.input.key == .up) {
        const top = @as(f32, @floatFromInt(state.menu_index)) * 24;
        offset = std.math.clamp(offset, @max(0, top - height + 64), top);
        ctx.scroll.put(ctx.gpa, id, offset) catch {};
    }
    const start = @min(filtered.items.len, @as(usize, @intFromFloat(@floor(@max(0, offset) / 24))));
    const end = @min(filtered.items.len, start + 14);
    if (start > 0) _ = ctx.leaf(.{ .height = .{ .px = @as(f32, @floatFromInt(start)) * 24 } }, .none, null);
    for (filtered.items[start..end], start..) |value, i| {
        ui.key(ctx, value);
        const row = ctx.open(.{ .direction = .row, .width = .fill, .height = .{ .px = 24 }, .padding = .xy(8, 0), .gap = 6, .radius = 7, .align_items = .center, .control = true, .background = if (i == state.menu_index) ctx.theme.accent else null }, null);
        const hit = ctx.interact(row, .{});
        const saved_background = ctx.theme.background;
        if (i == state.menu_index) ctx.theme.background = .black;
        if (std.mem.eql(u8, state.edit.text(), if (menu == .size) ctx.print("{s} pt", .{value}) else if (menu == .choices) choiceText(ctx, state.key orelse "", value) else value)) C.icon(ctx, .check, 12) else _ = ctx.leaf(.{ .width = .{ .px = 12 }, .height = .{ .px = 12 } }, .none, null);
        ctx.theme.background = saved_background;
        ui.text(ctx, C.ellipsize(ctx, if (menu == .choices) choiceText(ctx, state.key orelse "", value) else @import("locale.zig").t(value), width - 42, 13), .{ .size = 13, .color = if (i == state.menu_index) .white else ctx.theme.text });
        ui.end(ctx);
        if (hit.clicked or (field.submitted and i == state.menu_index)) {
            const key = state.key orelse return null;
            state.menu = null;
            state.key = null;
            ctx.focus = 0;
            const value_ = if (menu == .font and std.mem.eql(u8, value, "System")) "monospace" else if (menu == .font and std.mem.eql(u8, value, "JetBrains Mono Nerd Font")) "" else if (menu == .light_theme or menu == .dark_theme) ctx.print("light:{s},dark:{s}", .{ if (menu == .light_theme) value else Themes.name(settings.theme, false) catch "letty", if (menu == .dark_theme) value else Themes.name(settings.theme, true) catch "letty" }) else value;
            return .{ .key = key, .value = value_ };
        }
    }
    if (end < filtered.items.len) _ = ctx.leaf(.{ .height = .{ .px = @as(f32, @floatFromInt(filtered.items.len - end)) * 24 } }, .none, null);
    return null;
}
fn choicePopup(state: *State, ctx: *ui.Context, menu: Menu) ?Edit {
    const Popup = @import("menu.zig");
    const values = if (menu == .size) &font_sizes else state.choices;
    const a = ctx.alloc();
    const items = a.alloc(Popup.Item, values.len) catch return null;
    var width: f32 = 100;
    for (values, items, 0..) |value, *item, i| {
        const label = if (menu == .size) ctx.print("{s} pt", .{value}) else choiceText(ctx, state.key orelse "", value);
        item.* = .{ .label = label, .checked = std.mem.eql(u8, state.edit.text(), label) };
        width = @max(width, ctx.text.layout(label, .{ .size = 13 }).width + 54);
        if (state.font_focus and item.checked) state.choice_state.selected = i;
    }
    const opening = state.font_focus;
    state.font_focus = false;
    const height = @min(300, Popup.contentHeight(items));
    const below = state.popup.y + state.popup.h + 3;
    const point: ui.Point = .{ .x = state.popup.x + state.popup.w - width, .y = if (below + height > ctx.size.h - 8 and state.popup.y - height - 3 >= 8) state.popup.y - height - 3 else below };
    const bounds = Popup.place(ctx.size, point, width, height);
    if (ctx.input.key == .escape or (ctx.input.pressed and !opening and !bounds.contains(ctx.input.mouse) and !state.popup.contains(ctx.input.mouse))) {
        state.menu = null;
        state.key = null;
        ctx.focus = 0;
        ctx.input.clearEdges();
        return null;
    }
    ui.key(ctx, "settings-choice-menu");
    if (Popup.draw(&state.choice_state, ctx, bounds, items, true)) |index| {
        const key = state.key orelse return null;
        state.menu_index = index;
        state.menu = null;
        state.key = null;
        ctx.focus = 0;
        return .{ .key = key, .value = values[index] };
    }
    return null;
}
pub fn preview(ctx: *ui.Context, settings: Settings, colors: Themes.Colors) void {
    ui.column(ctx, .{ .width = .fill, .padding = .xy(18, 16), .gap = 0, .radius = 12, .border = C.edge(ctx), .background = ui.Color.hex(colors.background) });
    const size = settings.@"font-size";
    ui.row(ctx, .{ .gap = 0 });
    ui.text(ctx, "\u{f07b} ~/dev/letty", .{ .mono = true, .size = size, .color = .hex(colors.palette[4]) });
    ui.text(ctx, " \u{e0a0} main", .{ .mono = true, .size = size, .color = .hex(colors.palette[5]) });
    ui.text(ctx, " ❯ ", .{ .mono = true, .size = size, .color = .hex(colors.palette[2]) });
    ui.text(ctx, "git status", .{ .mono = true, .size = size, .color = .hex(colors.foreground) });
    ui.end(ctx);
    ui.row(ctx, .{ .gap = 0 });
    ui.text(ctx, "modified: ", .{ .mono = true, .size = size, .color = .hex(colors.foreground) });
    ui.text(ctx, "settings.zig", .{ .mono = true, .size = size, .color = .hex(colors.palette[1]) });
    ui.end(ctx);
    ui.row(ctx, .{ .gap = 0 });
    ui.text(ctx, "fn ", .{ .mono = true, .size = size, .color = .hex(colors.palette[5]) });
    ui.text(ctx, "main", .{ .mono = true, .size = size, .color = .hex(colors.palette[4]) });
    ui.text(ctx, "() { a != b and c >= d; }", .{ .mono = true, .size = size, .color = .hex(colors.foreground) });
    ui.end(ctx);
    ui.row(ctx, .{ .width = .fill, .gap = 4, .padding = .{ .top = 10 } });
    for (colors.palette) |rgb| _ = ctx.leaf(.{ .width = .{ .px = 16 }, .height = .{ .px = 10 }, .radius = 3, .background = ui.Color.hex(rgb) }, .none, null);
    ui.end(ctx);
    ui.end(ctx);
}

fn backgrounds(ctx: *ui.Context, selected: []const u8) ?[]const u8 {
    const background_names = [_][]const u8{ "rex", "mist", "meadow", "dusk", "plain" };
    const labels = [_][]const u8{ "Petal", "Mist", "Meadow", "Dusk", "Plain" };
    const available = @max(104, ctx.size.w - 212 - 56);
    const cols = @min(background_names.len, @max(1, @as(usize, @intFromFloat(@floor((available + 12) / 116)))));
    ui.column(ctx, .{ .width = .fill, .gap = 8 });
    defer ui.end(ctx);
    L.text(ctx, "Background", .{ .size = 12, .weight = .semibold, .color = ctx.theme.muted });
    ui.column(ctx, .{ .width = .fill, .gap = 12 });
    defer ui.end(ctx);
    var result: ?[]const u8 = null;
    for (background_names, 0..) |name, i| {
        if (i % cols == 0) ui.row(ctx, .{ .width = .fill, .gap = 12 });
        ui.key(ctx, name);
        ui.column(ctx, .{ .width = .{ .px = 104 }, .gap = 8, .align_items = .center });
        const tile = ctx.open(.{ .width = .{ .px = 104 }, .height = .{ .px = 68 }, .radius = 12, .clip = true, .control = true, .shadow = .{ .color = C.shadow(ctx), .blur = 4, .y = 2 } }, null);
        const hit = ctx.interact(tile, .{ .focusable = true });
        const first: u32 = @intCast(ctx.nodes.items.len);
        @import("interface-assets").wash(ctx, name);
        if (ctx.nodes.items.len > first) ctx.node(first).style = .{ .absolute = true, .width = .fill, .height = .fill };
        _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = 26, .y = 12 }, .width = .{ .px = 70 }, .height = .{ .px = 80 }, .radius = 7, .background = C.card(ctx) }, .none, null);
        _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = 8, .y = 20 }, .width = .{ .px = 12 }, .height = .{ .px = 4 }, .radius = 2, .background = ctx.theme.muted.alpha(0.5) }, .none, null);
        if (std.mem.eql(u8, selected, name)) {
            ui.column(ctx, .{ .absolute = true, .offset = .{ .x = 80, .y = 6 }, .width = .{ .px = 18 }, .height = .{ .px = 18 }, .radius = 9, .background = ctx.theme.accent, .justify = .center, .align_items = .center });
            const saved = ctx.theme.background;
            ctx.theme.background = .black;
            C.icon(ctx, .check, 12);
            ctx.theme.background = saved;
            ui.end(ctx);
        }
        ui.end(ctx);
        L.text(ctx, labels[i], .{ .size = 12.5, .weight = if (std.mem.eql(u8, selected, name)) .semibold else .regular, .color = if (std.mem.eql(u8, selected, name)) ctx.theme.text else ctx.theme.muted });
        ui.end(ctx);
        if (hit.clicked) result = name;
        if (i % cols == cols - 1 or i == background_names.len - 1) ui.end(ctx);
    }
    return result;
}
