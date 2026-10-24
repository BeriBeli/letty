//! nanoui form with explicit intents. No native IO, PTY or clipboard access.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("nanoui").ui;
const schema = @import("schema.zig");
const Model = @import("model.zig").Model;
const config = @import("../config.zig");
const keys = @import("../keybindings.zig");
const catalogue = @import("../command_catalogue.zig");
const themes = @import("../theme_browser.zig");
const Text = @import("../fixed_text.zig").Text;
const chrome = @import("../chrome.zig");
const binding_text = @import("bindings.zig");
pub const Intent = enum { none, save, close, discard, preview, open_config, migration };
pub const Form = struct {
    ax: @import("accessibility.zig").Collector = .{},
    semantic_label: ?[]const u8 = null,
    semantic_value: []const u8 = "",
    semantic_selected: bool = false,
    focus_modal: bool = false,
    category: schema.Category = .general,
    query: ui.TextBuffer = .{},
    chord: ui.TextBuffer = .{},
    action: ui.TextBuffer = .{},
    advanced_binding: ui.TextBuffer = .{},
    shortcut_query: ui.TextBuffer = .{},
    binding_editor: bool = false,
    editing_trigger: Text(512) = .{},
    binding_actions: bool = false,
    binding_advanced: bool = false,
    advanced_overrides: bool = false,
    advanced_applied: bool = false,
    memory_input: ui.TextBuffer = .{},
    memory_source: Text(64) = .{},
    scroll_area: @import("scroll_area.zig").Area = .{},
    preview_scroll: @import("scroll_area.zig").Area = .{},
    recording: bool = false,
    confirm_discard: bool = false,
    show_themes: bool = false,
    choice_open: ?schema.Field = null,
    cell_options: bool = false,
    color_options: bool = false,
    workspace_options: bool = false,
    available_themes: ?*const themes.Catalog = null,
    preview_requested: bool = false,
    preview_stamp: ?u64 = null,
    theme_query: ui.TextBuffer = .{},
    show_fonts: bool = false,
    font_query: ui.TextBuffer = .{},
    font_names: []const []const u8 = &.{},
    font_catalog_available: bool = false,
    preview_font_available: bool = false,
    command_override: Text(4096) = .{},
    cwd_override: Text(4096) = .{},
    profile_override: Text(64) = .{},
    applied_values: [schema.fields.len]?[]const u8 = @splat(null),
    show_migration: bool = false,
    replace_conflict: bool = false,
    dark_preview: bool = false,
    focus_query: bool = true,
    focus_ids: [512]u64 = undefined,
    focus_count: usize = 0,
    enter: bool = false,
    composing: bool = false,
    save_id: u64 = 0,
    cancel_id: u64 = 0,
    scroll_id: u64 = 0,
    query_id: u64 = 0,
    drag_rect: ui.Rect = .{},
    choice_index: usize = 0,
    choice_anchor: ui.Rect = .{},
    choice_width: f32 = 170,
    choice_button: u64 = 0,
    popup_query: ui.TextBuffer = .{},
    popup_focus: bool = false,
    in_group: bool = false,
    group_rows: usize = 0,
    reveal_error: ?schema.Field = null,
    controls: [schema.fields.len]u64 = @splat(0),
    pub fn requestClose(self: *Form, m: *Model) Intent {
        if (m.dirtyCount() > 0) {
            self.confirm_discard = true;
            return .none;
        }
        return .close;
    }
    fn focusable(self: *Form, ctx: *ui.Context, id: u64) void {
        if (self.focus_count < self.focus_ids.len) {
            self.focus_ids[self.focus_count] = id;
            self.focus_count += 1;
        }
        if (ctx.focus == 0) ctx.focus = id;
    }
    fn button(self: *Form, ctx: *ui.Context, label: []const u8, primary: bool, disabled: bool) bool {
        const id = ctx.peekId(null);
        const action_label = self.semantic_label orelse label;
        self.ax.add(.{ .widget = id, .role = .button, .label = self.semantic_label orelse label, .value = self.semantic_value, .enabled = !disabled, .selected = self.semantic_selected });
        self.semantic_label = null;
        self.semantic_value = "";
        self.semantic_selected = false;
        if (!disabled) self.focusable(ctx, id);
        const it = chrome.button(ctx, label, .{ .variant = if (primary) .primary else .secondary, .disabled = disabled, .size = 12 });
        const keyboard_clicked = !disabled and ctx.focus == it.id and self.enter;
        if (keyboard_clicked) {
            self.enter = false;
            ctx.input.key = null;
            ctx.input.ops = &.{};
            ctx.changed = true;
        }
        var action_label_end = @min(action_label.len, @import("../accessibility.zig").max_label);
        while (action_label_end > 0 and action_label_end < action_label.len and action_label[action_label_end] & 0xc0 == 0x80) action_label_end -= 1;
        const ax_clicked = self.ax.pressed == id and self.ax.pressed_stamp == std.hash.Wyhash.hash(0, action_label[0..action_label_end]);
        if (ax_clicked) self.ax.pressed = 0;
        return !disabled and (it.clicked or keyboard_clicked or ax_clicked);
    }
    fn choiceButton(self: *Form, ctx: *ui.Context, label: []const u8) bool {
        const id = ctx.peekId(null);
        const semantic = self.semantic_label orelse label;
        if (self.choice_button == id) self.choice_anchor = ctx.rects.get(id) orelse self.choice_anchor;
        self.ax.add(.{ .widget = id, .role = .button, .label = semantic, .value = label });
        self.semantic_label = null;
        self.semantic_value = "";
        self.focusable(ctx, id);
        const it = chrome.control(ctx, .{ .direction = .row, .width = .fill, .height = .{ .px = 28 }, .padding = .{ .left = 10, .right = 3 }, .gap = 6, .align_items = .center, .radius = 14, .control = true, .background = if (ctx.focus == id) ctx.theme.text.alpha(0.065) else null }, ctx.theme.surface_hover);
        ui.text(ctx, chrome.ellipsize(ctx, label, @max(1, self.choice_width - 44), 13), .{ .size = 13 });
        ui.spacer(ctx);
        ui.column(ctx, .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .radius = 11, .align_items = .center, .justify = .center, .background = ctx.theme.text.alpha(0.065) });
        chrome.icon(ctx, .down, 14);
        ui.end(ctx);
        ui.end(ctx);
        const clicked = self.activated(ctx, it, semantic, false);
        if (clicked) {
            self.choice_button = id;
            self.choice_anchor = ctx.rects.get(id) orelse .{};
            self.choice_index = 0;
            self.popup_query.clear();
            self.popup_focus = true;
        }
        return clicked;
    }
    fn textField(self: *Form, ctx: *ui.Context, buffer: *ui.TextBuffer, options: ui.TextFieldOptions) @typeInfo(@TypeOf(ui.textField)).@"fn".return_type.? {
        const widget = ctx.peekId(null);
        const result = ui.textField(ctx, buffer, options);
        self.ax.add(.{ .widget = widget, .role = if (self.semantic_label != null) .text_field else .search, .label = self.semantic_label orelse options.placeholder, .value = buffer.text() });
        self.semantic_label = null;
        return result;
    }
    fn message(self: *Form, ctx: *ui.Context, label: []const u8, value: []const u8) void {
        self.ax.add(.{ .widget = ctx.peekId(null), .role = .label, .label = label, .value = value });
    }
    fn keyboard(self: *Form, ctx: *ui.Context, m: *Model) Intent {
        const composing = self.composing;
        self.enter = false;
        if (self.recording) {
            if (ctx.input.key == .escape) {
                self.recording = false;
                ctx.input.key = null;
                ctx.input.ops = &.{};
            }
            if (ctx.input.shortcut) |shortcut| {
                ctx.input.shortcut = null;
                ctx.shortcut_taken = true;
                ctx.input.ops = &.{};
                if (!shortcut.cmd and !shortcut.ctrl and !shortcut.alt) {
                    m.notice.set("The first key needs Command, Control, or Alt. Press Esc to cancel recording.");
                    return .none;
                }
                const formatted = binding_text.chord(m.gpa, .{ .key = shortcut.key, .cmd = shortcut.cmd, .ctrl = shortcut.ctrl, .shift = shortcut.shift, .alt = shortcut.alt }) catch return .none;
                defer m.gpa.free(formatted);
                self.chord.set(formatted);
                self.recording = false;
            }
            return .none;
        }
        if (!composing and (ctx.input.key == .escape or ctx.shortcut(.{ .key = ui.Shortcut.escape }))) {
            ctx.input.key = null;
            ctx.input.ops = &.{};
            if (self.choice_open != null) {
                self.choice_open = null;
                self.show_fonts = false;
                self.show_themes = false;
                return .none;
            }
            if (self.confirm_discard) {
                self.confirm_discard = false;
                return .none;
            }
            if (self.binding_editor) {
                self.binding_editor = false;
                self.binding_actions = false;
                self.replace_conflict = false;
                return .none;
            }
            return self.requestClose(m);
        }
        if (!composing and ctx.shortcut(.{ .key = 's', .cmd = true })) return .save;
        const shift_tab = !composing and ctx.shortcut(.{ .key = '\t', .shift = true });
        const tab = !composing and (ctx.input.key == .tab or ctx.shortcut(.{ .key = '\t' }));
        if ((tab or shift_tab) and self.focus_count > 0) {
            var at: usize = if (shift_tab) 0 else self.focus_count - 1;
            for (self.focus_ids[0..self.focus_count], 0..) |id, index| if (id == ctx.focus) {
                at = index;
                break;
            };
            at = if (shift_tab) (at + self.focus_count - 1) % self.focus_count else (at + 1) % self.focus_count;
            ctx.focus = self.focus_ids[at];
            ctx.input.key = null;
            ctx.input.ops = &.{};
            if (ctx.rects.get(ctx.focus)) |target| if (ctx.rects.get(self.scroll_id)) |viewport| {
                var offset = ctx.scroll.get(self.scroll_id) orelse 0;
                if (target.y < viewport.y) offset -= viewport.y - target.y;
                if (target.y + target.h > viewport.y + viewport.h) offset += target.y + target.h - viewport.y - viewport.h;
                ctx.scroll.put(ctx.gpa, self.scroll_id, @max(0, offset)) catch {};
            };
        }
        self.enter = !composing and (ctx.input.key == .enter or ctx.shortcut(.{ .key = '\r' }));
        return .none;
    }
    pub fn draw(self: *Form, ctx: *ui.Context, m: *Model, preview: ?config.Config, catalog: ?*const themes.Catalog) Intent {
        self.ax.count = 0;
        self.available_themes = catalog;
        self.preview_requested = false;
        if (self.reveal_error) |field| switch (field) {
            .width, .height => self.cell_options = true,
            .dark_theme => {
                self.color_options = true;
                self.show_themes = true;
                self.choice_open = .dark_theme;
            },
            .theme => {
                self.show_themes = true;
                self.choice_open = .theme;
            },
            .font => self.show_fonts = true,
            .shell, .directory => self.choice_open = field,
            .sidebar_git, .sidebar_ports => self.workspace_options = true,
            else => {},
        };
        defer self.ax.pressed = 0;
        defer if (self.reveal_error) |field| {
            const id = self.controls[@backingInt(field)];
            if (ctx.rects.get(id)) |target| {
                if (ctx.rects.get(self.scroll_id)) |viewport| {
                    var offset = ctx.scroll.get(self.scroll_id) orelse 0;
                    if (target.y < viewport.y) offset -= viewport.y - target.y;
                    if (target.y + target.h > viewport.y + viewport.h) offset += target.y + target.h - viewport.y - viewport.h;
                    ctx.scroll.put(ctx.gpa, self.scroll_id, @max(0, offset)) catch {};
                    ctx.focus = id;
                    self.reveal_error = null;
                    ctx.changed = true;
                } else ctx.animationFrame();
            } else ctx.animationFrame();
        };
        if (self.focus_modal != self.confirm_discard) {
            self.focus_modal = self.confirm_discard;
            self.focus_count = 0;
            ctx.focus = 0;
        }
        var intent = self.keyboard(ctx, m);
        self.focus_count = 0;
        if (self.confirm_discard) {
            @import("../rex_chrome.zig").backdrop(ctx, m.baseline.ui_background);
            _ = ctx.leaf(.{ .absolute = true, .width = .{ .px = ctx.size.w }, .height = .{ .px = ctx.size.h }, .background = @import("../rex_chrome.zig").overlay(ctx) }, .none, null);
            const width = @min(380, ctx.size.w - 32);
            ui.column(ctx, .{ .absolute = true, .offset = .{ .x = (ctx.size.w - width) / 2, .y = @max(16, (ctx.size.h - 162) / 2) }, .width = .{ .px = width }, .padding = .all(22), .gap = 8, .radius = 14, .background = ctx.theme.surface, .border = ctx.theme.border, .shadow = .{ .color = ui.Color.black.alpha(0.16), .blur = 24, .y = 8 } });
            defer ui.end(ctx);
            self.message(ctx, "Unsaved changes", "Discard this draft or keep editing. Configuration and terminal sessions remain unchanged until Save.");
            ui.text(ctx, "Unsaved changes", .{ .size = 15, .weight = .semibold });
            ui.text(ctx, "Discard the draft and close Settings?", .{ .size = 13, .color = ctx.theme.muted, .wrap = true });
            ui.row(ctx, .{ .width = .fill, .gap = 8, .padding = .{ .top = 8 } });
            ui.spacer(ctx);
            if (self.button(ctx, "Keep editing", true, false)) self.confirm_discard = false;
            const discard = self.button(ctx, "Discard and close", false, false);
            ui.end(ctx);
            if (discard) return .discard;
            return intent;
        }
        self.controls = @splat(0);
        const narrow = ctx.size.w < 700;
        const footer: f32 = 0;
        ui.column(ctx, .{ .width = .fill, .height = .fill, .clip = true });
        defer ui.end(ctx);
        @import("../rex_chrome.zig").backdrop(ctx, if (preview) |v| v.ui_background else m.baseline.ui_background);
        ui.row(ctx, .{ .width = .fill, .height = .fill, .clip = true, .padding = .{ .top = 8, .right = 8, .bottom = 8 } });
        ui.column(ctx, .{ .width = .{ .px = if (narrow) 170 else 212 }, .height = .fill, .padding = .{ .left = 10, .right = 10, .top = 52, .bottom = 4 }, .gap = 2 });
        self.search(ctx);
        _ = ctx.leaf(.{ .height = .{ .px = 8 } }, .none, null);
        self.navigation(ctx, m, false);
        ui.spacer(ctx);
        ui.key(ctx, "settings-open-config");
        const config_link_id = ctx.peekId(null);
        self.focusable(ctx, config_link_id);
        self.ax.add(.{ .widget = config_link_id, .role = .button, .label = "Open configuration file" });
        const config_link = chrome.control(ctx, .{ .direction = .row, .width = .fill, .height = .{ .px = 30 }, .padding = .xy(10, 6), .gap = 6, .radius = 7, .align_items = .center, .control = true }, ctx.theme.surface_hover);
        chrome.icon(ctx, .code, 13);
        ui.text(ctx, "Open configuration", .{ .size = 12.5, .color = ctx.theme.muted });
        ui.end(ctx);
        if (self.activated(ctx, config_link, "Open configuration file", false)) intent = .open_config;
        ui.end(ctx);
        ui.column(ctx, .{ .width = .fill, .height = .fill, .background = ctx.theme.background, .radius = 14, .border = @import("../rex_chrome.zig").edge(ctx), .shadow = .{ .color = @import("../rex_chrome.zig").shadow(ctx), .blur = 6, .y = 2 }, .clip = true });
        ui.row(ctx, .{ .width = .fill, .height = .{ .px = 44 }, .padding = .{ .left = 24, .right = if (builtin.os.tag == .linux) 108 else 24 }, .gap = 8, .align_items = .center });
        ui.text(ctx, if (self.query.len > 0) "Search results" else schema.categories[@backingInt(self.category)], .{ .size = 15, .weight = .semibold });
        ui.spacer(ctx);
        self.drag_rect = .{ .x = if (narrow) 170 else 212, .y = 8, .w = @max(0, ctx.size.w - (if (narrow) @as(f32, 170) else 212) - (if (m.dirtyCount() > 0) @as(f32, 210) else 16) - (if (builtin.os.tag == .linux) @as(f32, 84) else 0)), .h = 44 };
        if (m.dirtyCount() > 0) {
            ui.key(ctx, "settings-cancel");
            self.cancel_id = ctx.peekId(null);
            if (self.button(ctx, "Cancel", false, false)) intent = self.requestClose(m);
            ui.key(ctx, "settings-save");
            self.save_id = ctx.peekId(null);
            if (self.button(ctx, "Save and apply", true, m.read_only)) intent = .save;
        }
        ui.end(ctx);
        ui.column(ctx, .{ .width = .fill, .height = .fill, .padding = .{ .left = 24, .right = 24, .top = 16, .bottom = 28 }, .gap = 22, .clip = true });
        ui.key(ctx, "settings-scroll");
        self.scroll_id = ctx.peekId(null);
        self.scroll_area.begin(ctx, self.scroll_id, 4);
        if (m.read_only) {
            ui.text(ctx, if (m.metadata_unavailable) "File attributes unavailable: read-only in Settings" else if (m.json) "JSON configuration: read-only in Settings" else "Fix the configuration errors, then reopen Settings.", .{ .size = 14, .color = ctx.theme.danger, .wrap = true });
            ui.text(ctx, if (m.metadata_unavailable) "Your settings remain visible. Saving is disabled to preserve file permissions and attributes. See the diagnostic below." else if (m.json) "Your JSON and profiles are preserved. The migration preview does not change files or the selected path." else "Open the source file to fix errors. Diagnostics and paths are available under Advanced.", .{ .size = 12, .color = ctx.theme.muted, .wrap = true });
        }
        ui.column(ctx, .{ .width = .fill, .max_width = 620, .gap = 22 });
        var shown: usize = 0;
        const appearance_order = [_]schema.Field{ .font, .font_size, .ligatures, .theme, .dark_theme, .opacity, .cursor, .blink };
        if (self.category == .terminal and self.query.len == 0) {
            var group_open = false;
            self.drawPreview(ctx, preview orelse m.baseline, false);
            for (appearance_order) |id| {
                const heading: ?[]const u8 = switch (id) {
                    .font => "Typography",
                    .theme => "Color",
                    .cursor => "Cursor",
                    else => null,
                };
                if (heading) |title| {
                    if (group_open) {
                        ui.end(ctx);
                        ui.end(ctx);
                    }
                    self.in_group = false;
                    ui.column(ctx, .{ .width = .fill, .gap = 8 });
                    ui.row(ctx, .{ .width = .fill, .height = .{ .px = 14 }, .padding = .xy(4, 0), .align_items = .center });
                    ui.text(ctx, title, .{ .size = 12, .weight = .semibold, .color = ctx.theme.muted });
                    ui.end(ctx);
                    ui.column(ctx, .{ .width = .fill, .padding = .xy(16, 4), .radius = 12, .background = ctx.theme.text.alpha(0.045) });
                    group_open = true;
                    self.in_group = true;
                    self.group_rows = 0;
                }
                self.drawField(ctx, m, schema.descriptor(id));
                shown += 1;
            }
            if (group_open) {
                ui.end(ctx);
                ui.end(ctx);
            }
            self.in_group = false;
        } else if (self.query.len == 0 and self.category == .appearance) {
            self.backgroundTiles(ctx, m);
            shown = 1;
        } else if (self.query.len == 0 and self.category == .startup) {
            self.terminalFields(ctx, m);
            shown = 1;
        } else if (self.query.len == 0 and self.category == .clipboard) {
            self.clipboardFields(ctx, m);
            shown = 1;
        } else for (schema.fields) |field| {
            if (field.id == .navigation or field.id == .tab_bar) continue;
            if ((self.query.len == 0 and field.category != self.category) or !schema.matches(field, self.query.text())) continue;
            if (self.query.len == 0 and self.category == .keyboard) continue;
            self.drawField(ctx, m, field);
            shown += 1;
        }
        if (self.category == .keyboard) self.bindings(ctx, m) else if (self.query.len > 0) self.actionChoices(ctx);
        if (self.category == .advanced) self.advanced(ctx, m, &intent);
        if (shown == 0 and self.category != .keyboard and self.category != .advanced) ui.text(ctx, "No matching settings", .{ .size = 14, .color = ctx.theme.muted });
        ui.end(ctx);
        self.scroll_area.end(ctx);
        ui.end(ctx);
        ui.end(ctx);
        ui.end(ctx);
        _ = footer;
        if (m.notice.len > 0) {
            ui.column(ctx, .{ .absolute = true, .offset = .{ .x = if (narrow) 182 else 224, .y = @max(0, ctx.size.h - 66) }, .width = .{ .px = @max(1, ctx.size.w - (if (narrow) @as(f32, 194) else 236)) }, .padding = .all(12), .radius = 12, .background = ctx.theme.surface, .border = ctx.theme.border });
            self.message(ctx, if (m.notice_error) "Settings validation error" else "Settings status", m.notice.text());
            ui.text(ctx, m.notice.text(), .{ .size = 12, .color = if (m.notice_error) ctx.theme.danger else ctx.theme.muted, .wrap = true });
            ui.end(ctx);
        }
        self.popup(ctx, m);
        var draft_hash = std.hash.Wyhash.init(0);
        for (schema.fields) |field| if (field.category == .appearance or field.category == .terminal or field.id == .width or field.id == .height or field.id == .padding_x or field.id == .padding_y) {
            draft_hash.update(m.value(field.id).input.text());
            draft_hash.update(&.{0});
        };
        const stamp = draft_hash.final();
        if (self.preview_stamp) |previous| if (previous != stamp) {
            self.preview_requested = true;
        };
        self.composing = if (ctx.focused_text) |text| text.marked != null else false;
        if (!self.composing) {
            self.preview_stamp = stamp;
            if (self.preview_requested and !m.read_only and intent == .none) intent = .preview;
        }
        return intent;
    }
    fn popup(self: *Form, ctx: *ui.Context, m: *Model) void {
        const field = self.choice_open orelse return;
        const d = schema.descriptor(field);
        if (d.kind != .choice and field != .font and field != .font_size and field != .theme and field != .dark_theme) return;
        const searchable = field == .font or field == .theme or field == .dark_theme;
        const Option = struct { value: []const u8, label: []const u8 };
        const capacity = if (field == .font_size) 13 else if (field == .font) self.font_names.len + 1 else if (field == .theme or field == .dark_theme) (if (self.available_themes) |cat| cat.entries.len else 0) + 2 else d.choices.len;
        const options = ctx.alloc().alloc(Option, capacity) catch return;
        var count: usize = 0;
        if (field == .font_size) {
            var included = false;
            for ([_][]const u8{ "10", "11", "12", "13", "14", "15", "16", "18", "20", "22", "24", "28" }) |value| {
                options[count] = .{ .value = value, .label = ctx.print("{s} pt", .{value}) };
                included = included or std.mem.eql(u8, value, m.value(field).input.text());
                count += 1;
            }
            if (!included) {
                options[count] = .{ .value = m.value(field).input.text(), .label = ctx.print("{s} pt", .{m.value(field).input.text()}) };
                count += 1;
            }
        } else if (d.kind == .choice) {
            for (d.choices) |value| {
                if (field == .copy_select and builtin.os.tag != .linux and (std.mem.eql(u8, value, "primary") or std.mem.eql(u8, value, "both"))) continue;
                options[count] = .{ .value = value, .label = value };
                count += 1;
            }
        } else if (field == .font) {
            const current = m.value(field).input.text();
            var included = false;
            for (self.font_names) |name| {
                included = included or std.mem.eql(u8, name, current);
                if (!schema.contains(name, self.popup_query.text())) continue;
                options[count] = .{ .value = name, .label = name };
                count += 1;
            }
            if (!included and schema.contains(current, self.popup_query.text())) {
                options[count] = .{ .value = current, .label = current };
                count += 1;
            }
        } else {
            if (field == .dark_theme and schema.contains("Same as light", self.popup_query.text())) {
                options[count] = .{ .value = "", .label = "Same as light" };
                count += 1;
            }
            if (self.available_themes) |cat| {
                for (cat.entries) |entry| {
                    if (!schema.contains(entry.name, self.popup_query.text())) continue;
                    options[count] = .{ .value = entry.selector, .label = ctx.print("{s} ({s})", .{ entry.name, @tagName(entry.origin) }) };
                    count += 1;
                }
            } else if (schema.contains("Letty", self.popup_query.text())) {
                options[count] = .{ .value = "letty", .label = "Letty (builtin)" };
                count += 1;
            }
        }
        if (count > 0) self.choice_index = @min(self.choice_index, count - 1);
        const down = ctx.input.key == .down or ctx.shortcut(.{ .key = ui.Shortcut.down });
        const up = ctx.input.key == .up or ctx.shortcut(.{ .key = ui.Shortcut.up });
        if ((down or up) and count > 0) {
            self.choice_index = if (down) (self.choice_index + 1) % count else (self.choice_index + count - 1) % count;
            ctx.input.key = null;
            self.enter = false;
        }
        if (self.enter and count > 0) {
            m.value(field).input.set(options[self.choice_index].value);
            self.choice_open = null;
            self.enter = false;
            ctx.input.key = null;
            ctx.input.ops = &.{};
            ctx.changed = true;
            ctx.focus = self.choice_button;
            return;
        }
        const width = @min(if (field == .font_size) @as(f32, 90) else if (searchable) 240 else @max(170, self.choice_anchor.w), ctx.size.w - 16);
        const height = @min(@min(300, 10 + (if (searchable) @as(f32, 28) else 0) + @as(f32, @floatFromInt(@max(1, count))) * 24), ctx.size.h - 16);
        const rect: ui.Rect = .{ .x = std.math.clamp(self.choice_anchor.x + self.choice_anchor.w - width, 8, @max(8, ctx.size.w - width - 8)), .y = std.math.clamp(if (self.choice_anchor.y + self.choice_anchor.h + height + 8 <= ctx.size.h) self.choice_anchor.y + self.choice_anchor.h + 4 else self.choice_anchor.y - height - 4, 8, @max(8, ctx.size.h - height - 8)), .w = width, .h = height };
        if (ctx.input.pressed and !rect.contains(ctx.input.mouse) and !self.choice_anchor.contains(ctx.input.mouse)) {
            self.choice_open = null;
            return;
        }
        ui.key(ctx, "settings-popup-shield");
        const shield = ctx.open(.{ .absolute = true, .width = .{ .px = ctx.size.w }, .height = .{ .px = ctx.size.h } }, null);
        _ = ctx.interact(shield, .{});
        defer ctx.end();
        ui.key(ctx, "settings-floating-menu");
        ui.column(ctx, .{ .absolute = true, .offset = .{ .x = rect.x, .y = rect.y }, .width = .{ .px = width }, .height = .{ .px = height }, .padding = .all(5), .radius = 13, .background = ctx.theme.surface, .border = ctx.theme.border, .shadow = .{ .color = ui.Color.black.alpha(0.16), .blur = 18, .y = 6 }, .clip = true });
        defer ui.end(ctx);
        if (searchable) {
            ui.key(ctx, "settings-popup-search");
            self.focusable(ctx, ctx.peekId(null));
            if (self.popup_focus) {
                ctx.focus = ctx.peekId(null);
                self.popup_focus = false;
            }
            _ = self.textField(ctx, &self.popup_query, .{ .placeholder = "Search…", .width = .fill, .size = 13, .bare = true });
        }
        ui.key(ctx, "settings-popup-options");
        ui.scroll(ctx, .{ .width = .fill, .height = .fill, .clip = true });
        defer ui.end(ctx);
        if (count == 0) ui.text(ctx, "No results", .{ .size = 13, .color = ctx.theme.muted });
        for (options[0..count], 0..) |option, index| {
            ui.key(ctx, ctx.print("settings-popup-option-{d}", .{index}));
            const selected = std.mem.eql(u8, option.value, m.value(field).input.text());
            const id = ctx.peekId(null);
            if (!searchable and self.popup_focus) {
                ctx.focus = id;
                self.popup_focus = false;
            }
            self.focusable(ctx, id);
            self.ax.add(.{ .widget = id, .role = .button, .label = ctx.print("{s}: {s}", .{ d.title, option.label }), .selected = selected });
            const it = chrome.control(ctx, .{ .direction = .row, .width = .fill, .height = .{ .px = 24 }, .padding = .xy(7, 0), .gap = 7, .radius = 7, .control = true, .align_items = .center, .background = if (ctx.focus == id or self.choice_index == index) ctx.theme.surface_hover else null }, ctx.theme.surface_hover);
            ui.text(ctx, chrome.ellipsize(ctx, option.label, width - 42, 13), .{ .size = 13 });
            ui.spacer(ctx);
            if (selected) chrome.icon(ctx, .check, 13);
            ui.end(ctx);
            if (self.activated(ctx, it, ctx.print("{s}: {s}", .{ d.title, option.label }), false)) {
                m.value(field).input.set(option.value);
                self.choice_open = null;
                self.preview_requested = true;
                ctx.focus = self.choice_button;
            }
        }
    }
    fn backgroundTiles(self: *Form, ctx: *ui.Context, m: *Model) void {
        ui.column(ctx, .{ .width = .fill, .gap = 8 });
        defer ui.end(ctx);
        ui.text(ctx, "Background", .{ .size = 12, .weight = .semibold, .color = ctx.theme.muted });
        const names = [_][]const u8{ "Rex", "Mist", "Meadow", "Dusk", "Plain" };
        const values = [_][]const u8{ "rex", "mist", "meadow", "dusk", "plain" };
        const available = @min(620, @max(1, ctx.size.w - (if (ctx.size.w < 700) @as(f32, 170) else 212) - 56));
        const columns: usize = @intFromFloat(std.math.clamp(@floor((available + 12) / 116), 1, 5));
        for (0..(5 + columns - 1) / columns) |line| {
            ui.row(ctx, .{ .width = .fill, .gap = 12 });
            for (line * columns..@min(5, line * columns + columns)) |i| {
                ui.key(ctx, values[i]);
                const selected = std.mem.eql(u8, m.value(.background_style).input.text(), values[i]);
                const it = chrome.control(ctx, .{ .width = .{ .px = 104 }, .direction = .column, .gap = 8, .control = !m.read_only, .align_items = .center }, null);
                self.ax.add(.{ .widget = it.id, .role = .button, .label = names[i], .selected = selected, .enabled = !m.read_only });
                self.focusable(ctx, it.id);
                ui.column(ctx, .{ .width = .{ .px = 104 }, .height = .{ .px = 68 }, .radius = 12, .border = ctx.theme.border, .shadow = .{ .color = @import("../rex_chrome.zig").shadow(ctx), .blur = 4, .y = 1 }, .clip = true });
                @import("../rex_chrome.zig").wash(ctx, @fromBackingInt(@intCast(i)), 104, 68);
                _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = 26, .y = 12 }, .width = .{ .px = 70 }, .height = .{ .px = 62 }, .radius = 7, .background = ctx.theme.background }, .none, null);
                _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = 8, .y = 20 }, .width = .{ .px = 12 }, .height = .{ .px = 4 }, .radius = 2, .background = ctx.theme.muted.alpha(0.5) }, .none, null);
                if (selected) {
                    ui.column(ctx, .{ .absolute = true, .offset = .{ .x = 80, .y = 6 }, .width = .{ .px = 18 }, .height = .{ .px = 18 }, .radius = 9, .background = ctx.theme.accent, .align_items = .center, .justify = .center });
                    ui.text(ctx, "✓", .{ .size = 12, .color = .white });
                    ui.end(ctx);
                }
                ui.end(ctx);
                ui.text(ctx, names[i], .{ .size = 12.5, .weight = if (selected) .semibold else .regular, .color = if (selected) ctx.theme.text else ctx.theme.muted });
                ui.end(ctx);
                if (self.activated(ctx, it, names[i], m.read_only)) m.value(.background_style).input.set(values[i]);
            }
            ui.end(ctx);
        }
    }
    fn search(self: *Form, ctx: *ui.Context) void {
        ui.row(ctx, .{ .width = .fill, .height = .{ .px = 28 }, .padding = .xy(9, 0), .align_items = .center, .gap = 7, .radius = 9, .background = ctx.theme.text.alpha(0.045) });
        chrome.icon(ctx, .search, 14);
        ui.key(ctx, "settings-search");
        self.query_id = ctx.peekId(null);
        self.focusable(ctx, self.query_id);
        if (self.focus_query) {
            ctx.focus = self.query_id;
            self.focus_query = false;
        }
        const result = self.textField(ctx, &self.query, .{ .placeholder = "Search settings…", .width = .fill, .size = 12, .bare = true });
        if (result.changed) {
            ctx.scroll.put(ctx.gpa, self.scroll_id, 0) catch {};
            self.choice_open = null;
            self.binding_editor = false;
            self.recording = false;
        }
        ui.end(ctx);
    }
    fn themeChoices(self: *Form, ctx: *ui.Context, m: *Model, field: schema.Field) void {
        if (self.show_themes) {
            if (self.available_themes) |found| {
                ui.key(ctx, "settings-theme-search");
                self.focusable(ctx, ctx.peekId(null));
                _ = self.textField(ctx, &self.theme_query, .{ .placeholder = "Filter local themes...", .width = .fill, .size = 12 });
                var matched: usize = 0;
                for (found.entries, 0..) |entry, index| {
                    if (!schema.contains(entry.name, self.theme_query.text()) and !schema.contains(entry.selector, self.theme_query.text())) continue;
                    if (matched == 16) {
                        ui.text(ctx, "First 16 matches. Type to narrow the list.", .{ .size = 11, .color = ctx.theme.muted });
                        break;
                    }
                    matched += 1;
                    ui.key(ctx, ctx.print("settings-theme-{d}", .{index}));
                    const value = m.value(field);
                    if (self.button(ctx, ctx.print("{s} ({s})", .{ entry.name, @tagName(entry.origin) }), false, m.read_only or entry.selector.len > value.input.buf.len)) {
                        value.locked = false;
                        value.input.set(entry.selector);
                        self.show_themes = false;
                        self.preview_requested = true;
                    }
                }
                if (matched == 0) ui.text(ctx, "No matching local themes.", .{ .size = 12, .color = ctx.theme.muted });
            } else ui.text(ctx, "Theme catalog unavailable. Enter a name or path in the Theme field.", .{ .size = 12, .wrap = true, .color = ctx.theme.muted });
        }
    }
    fn navigation(self: *Form, ctx: *ui.Context, m: *Model, horizontal: bool) void {
        if (horizontal) ui.row(ctx, .{ .width = .fill, .gap = 2 }) else ui.column(ctx, .{ .width = .fill, .gap = 5 });
        defer ui.end(ctx);
        const icons = [_]chrome.Icon{ .settings, .paintbrush, .terminal, .code, .keyboard, .clipboard, .sliders };
        for (schema.categories, 0..) |label, index| {
            ui.key(ctx, ctx.print("settings-category-{d}", .{index}));
            const id = ctx.peekId(null);
            const selected = @backingInt(self.category) == index;
            self.ax.add(.{ .widget = id, .role = .button, .label = label, .selected = selected });
            self.focusable(ctx, id);
            const it = chrome.control(ctx, .{ .direction = .row, .width = if (horizontal) .auto else .fill, .height = .{ .px = 32 }, .padding = .xy(if (horizontal) 6 else 10, 0), .gap = 10, .align_items = .center, .radius = 8, .control = true, .background = if (selected) chrome.selected(ctx) else null, .border = if (ctx.focus == id) ctx.theme.accent else null }, ctx.theme.surface_hover);

            if (!horizontal) chrome.icon(ctx, icons[index], 15);
            ui.text(ctx, label, .{ .size = 13.5 });
            ui.end(ctx);
            if (self.activated(ctx, it, label, false)) {
                self.category = @fromBackingInt(@intCast(index));
                self.binding_editor = false;
                self.recording = false;
                self.query.clear();
                self.choice_open = null;
                ctx.scroll.put(ctx.gpa, self.scroll_id, 0) catch {};
                m.notice.set("");
            }
        }
    }
    fn activated(self: *Form, ctx: *ui.Context, it: ui.Interaction, label: []const u8, disabled: bool) bool {
        if (disabled) return false;
        const keyboard_clicked = ctx.focus == it.id and self.enter;
        if (keyboard_clicked) {
            self.enter = false;
            ctx.input.key = null;
            ctx.input.ops = &.{};
            ctx.changed = true;
        }
        var end = @min(label.len, @import("../accessibility.zig").max_label);
        while (end > 0 and end < label.len and label[end] & 0xc0 == 0x80) end -= 1;
        const ax_clicked = self.ax.pressed == it.id and self.ax.pressed_stamp == std.hash.Wyhash.hash(0, label[0..end]);
        if (ax_clicked) self.ax.pressed = 0;
        return it.clicked or keyboard_clicked or ax_clicked;
    }
    fn section(ctx: *ui.Context, title: []const u8, separated: bool) void {
        if (separated) {
            _ = ctx.leaf(.{ .height = .{ .px = 10 } }, .none, null);
            chrome.separator(ctx);
        }
        ui.column(ctx, .{ .width = .fill, .padding = .{ .top = 12, .bottom = 6 } });
        ui.text(ctx, title, .{ .size = 12, .weight = .semibold, .color = ctx.theme.muted });
        ui.end(ctx);
    }
    fn terminalFields(self: *Form, ctx: *ui.Context, m: *Model) void {
        section(ctx, "Startup", false);
        for ([_]schema.Field{ .shell, .command, .integration }) |field| self.drawField(ctx, m, schema.descriptor(field));
        ui.text(ctx, "Applies to new sessions.", .{ .size = 11, .color = ctx.theme.muted });
        section(ctx, "Working directory", true);
        self.drawField(ctx, m, schema.descriptor(.directory));
        ui.text(ctx, "Use the current directory for new sessions.", .{ .size = 11, .color = ctx.theme.muted });
        section(ctx, "History", true);
        for ([_]schema.Field{ .history_lines, .history_bytes }) |field| self.drawField(ctx, m, schema.descriptor(field));
        ui.text(ctx, "Both limits apply. Reducing a limit may discard older history.", .{ .size = 11, .color = ctx.theme.muted, .wrap = true });
    }
    fn clipboardFields(self: *Form, ctx: *ui.Context, m: *Model) void {
        section(ctx, "Copy", false);
        self.drawField(ctx, m, schema.descriptor(.copy_select));
        section(ctx, "Paste", true);
        self.drawField(ctx, m, schema.descriptor(.paste_protect));
        self.drawField(ctx, m, schema.descriptor(.bracketed_safe));
        section(ctx, "Terminal access", true);
        self.drawField(ctx, m, schema.descriptor(.clipboard_write));
        chrome.separator(ctx);
        ui.text(ctx, "Clipboard reading by terminal programs is not supported.", .{ .size = 11, .color = ctx.theme.muted, .wrap = true });
    }
    fn drawField(self: *Form, ctx: *ui.Context, m: *Model, d: schema.Descriptor) void {
        if (self.in_group) {
            if (self.group_rows > 0) _ = ctx.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = ctx.theme.text.alpha(0.06) }, .none, null);
            self.group_rows += 1;
        }
        const v = m.value(d.id);
        const sidebar = std.mem.eql(u8, m.value(.navigation).input.text(), "sidebar");
        const disabled = m.read_only or v.locked or (d.id == .tab_bar and sidebar) or (d.id == .navigation and !@hasField(config.Config, "workspace_navigation"));
        ui.key(ctx, ctx.print("settings-card-{s}", .{@tagName(d.id)}));
        ui.column(ctx, .{ .width = .fill, .padding = .xy(if (self.in_group) 0 else 16, 11), .gap = 3, .background = if (self.in_group) null else ctx.theme.text.alpha(if (@import("../rex_chrome.zig").light(ctx)) 0.045 else 0.07), .border = if (m.last_error_field == d.id) ctx.theme.danger else null, .radius = if (self.in_group) 0 else 12 });
        defer ui.end(ctx);
        const stacked = ctx.size.w < 600;
        if (!stacked) ui.row(ctx, .{ .width = .fill, .gap = 18, .align_items = .start });
        const simple = self.query.len == 0;
        const clipboard_row = simple and d.category == .clipboard;
        ui.column(ctx, .{ .width = .fill, .gap = 4, .padding = .{ .top = 5 } });
        ui.row(ctx, .{ .width = .fill, .gap = 6, .align_items = .center });
        const field_label = if (self.query.len > 0) d.title else switch (d.id) {
            .font => "Font",
            .font_size => "Size",
            .ligatures => "Ligatures",
            .theme => "Light windows",
            .dark_theme => "Dark windows",
            .navigation => "Navigation",
            .directory => "Default directory",
            .window_inherit => "New windows",
            .tab_inherit => "New tabs",
            .split_inherit => "New splits",
            .history_bytes => "Memory limit",
            .sequence_timeout => "Key sequence timeout",
            .bracketed_safe => "Safe bracketed paste",
            .clipboard_write => "Clipboard writes (OSC 52)",
            else => d.title,
        };
        ui.text(ctx, field_label, .{ .size = 13.5, .wrap = true });
        if (v.dirty()) ui.text(ctx, "•", .{ .size = 13, .color = ctx.theme.accent });
        ui.end(ctx);
        if (clipboard_row or self.query.len > 0 or m.last_error_field == d.id) ui.text(ctx, if (clipboard_row and d.id == .clipboard_write) "Allow terminal programs to copy text to the clipboard." else if (clipboard_row and d.id == .copy_select) "Automatically copy text when you select it." else d.hint, .{ .size = 11, .color = ctx.theme.muted, .wrap = true });
        ui.end(ctx);
        const control_width: f32 = switch (d.id) {
            .font, .theme, .dark_theme, .shell, .directory => 240,
            .font_size => 90,
            .cursor => 300,
            else => 170,
        };
        self.choice_width = control_width;
        ui.column(ctx, .{ .width = if (stacked) .fill else .{ .px = control_width }, .max_width = if (d.id == .command and simple and !stacked) 240 else std.math.inf(f32), .gap = 6, .clip = true, .align_items = if (stacked) .start else .end });
        ui.key(ctx, ctx.print("settings-value-{s}", .{@tagName(d.id)}));
        const control_id = ctx.peekId(null);
        self.controls[@backingInt(d.id)] = control_id;
        self.semantic_label = d.title;
        self.semantic_value = v.input.text();
        if (disabled) {
            self.ax.add(.{ .widget = control_id, .role = .label, .label = d.title, .value = v.original, .enabled = false });
            self.semantic_label = null;
            if (d.kind == .choice) {
                ui.row(ctx, .{ .width = .fill, .height = .{ .px = 30 }, .padding = .xy(10, 0), .align_items = .center, .radius = 6, .border = ctx.theme.border.alpha(0.6) });
                ui.text(ctx, if (std.mem.eql(u8, v.original, "auto")) "Automatic" else v.original, .{ .size = 12, .color = ctx.theme.muted });
                ui.spacer(ctx);
                chrome.icon(ctx, .down, 14);
                ui.end(ctx);
            } else ui.text(ctx, v.original, .{ .size = 13, .wrap = true });
            if (d.id == .tab_bar and sidebar) ui.text(ctx, "Available with top tabs.", .{ .size = 11, .color = ctx.theme.muted, .wrap = true });
            if (d.id == .navigation and !@hasField(config.Config, "workspace_navigation")) ui.text(ctx, "Workspace navigation is waiting for host support.", .{ .size = 11, .color = ctx.theme.muted, .wrap = true });
            if (v.locked) ui.text(ctx, "This value exceeds the form limit. Edit it in the source configuration.", .{ .size = 11, .color = ctx.theme.muted });
        } else if (d.kind == .toggle) {
            const enabled = std.mem.eql(u8, v.input.text(), "true");
            self.ax.add(.{ .widget = control_id, .role = .button, .label = d.title, .value = if (enabled) "On" else "Off", .selected = enabled });
            self.focusable(ctx, control_id);
            const it = chrome.control(ctx, .{ .width = .{ .px = 38 }, .height = .{ .px = 22 }, .radius = 11, .control = true, .background = if (enabled) ctx.theme.accent else ctx.theme.border, .border = if (ctx.focus == control_id) ctx.theme.text.alpha(0.5) else null, .padding = .{ .left = if (enabled) 18 else 2, .top = 2 } }, null);
            _ = ctx.leaf(.{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .radius = 9, .background = ui.Color.white }, .none, null);
            ui.end(ctx);
            if (self.activated(ctx, it, d.title, false)) v.input.set(schema.boolean(!enabled));
        } else if (d.id == .font_size and simple) {
            if (self.choiceButton(ctx, ctx.print("{s} pt", .{v.input.text()}))) self.choice_open = if (self.choice_open == d.id) null else d.id;
        } else if (d.kind == .choice) {
            if (d.id == .cursor and simple) {
                ui.row(ctx, .{ .padding = .all(3), .gap = 2, .radius = 8, .background = ctx.theme.text.alpha(0.045) });
                const labels = [_][]const u8{ "Block", "Bar", "Underline", "Outline" };
                for (d.choices, labels) |choice, label| {
                    ui.key(ctx, choice);
                    const selected = std.mem.eql(u8, choice, v.input.text());
                    const id = ctx.peekId(null);
                    self.focusable(ctx, id);
                    self.ax.add(.{ .widget = id, .role = .button, .label = ctx.print("Cursor shape: {s}", .{label}), .selected = selected });
                    const segment = chrome.control(ctx, .{ .height = .{ .px = 24 }, .padding = .xy(8, 0), .radius = 6, .control = true, .align_items = .center, .justify = .center, .background = if (selected) chrome.selected(ctx) else null }, ctx.theme.surface_hover);
                    ui.text(ctx, label, .{ .size = 12 });
                    ui.end(ctx);
                    if (self.activated(ctx, segment, ctx.print("Cursor shape: {s}", .{label}), false)) v.input.set(choice);
                }
                ui.end(ctx);
            } else if (d.id == .navigation) {
                ui.row(ctx, .{ .width = .fill, .gap = 4 });
                for ([_][]const u8{ "Top tabs", "Left sidebar" }, 0..) |label, index| {
                    ui.key(ctx, label);
                    self.semantic_label = ctx.print("Workspace navigation: {s}", .{label});
                    self.semantic_selected = sidebar == (index == 1);
                    if (self.button(ctx, label, self.semantic_selected, false)) v.input.set(if (index == 1) "sidebar" else "top");
                }
                ui.end(ctx);
            } else {
                const value_label = if (std.mem.eql(u8, v.input.text(), "none")) (if (d.id == .copy_select) "Off" else "Disabled") else if (std.mem.eql(u8, v.input.text(), "detect")) "Automatic" else if (std.mem.eql(u8, v.input.text(), "deny")) "Deny" else if (std.mem.eql(u8, v.input.text(), "ask")) "Ask" else if (std.mem.eql(u8, v.input.text(), "allow")) "Allow" else if (std.mem.eql(u8, v.input.text(), "clipboard")) "Clipboard" else v.input.text();
                if (simple and !stacked) ui.column(ctx, .{ .width = .{ .px = if (clipboard_row) 170 else 170 }, .gap = 4 });
                self.semantic_label = d.title;
                if (self.choiceButton(ctx, value_label)) self.choice_open = if (self.choice_open == d.id) null else d.id;
                if (simple and !stacked) ui.end(ctx);
            }
        } else if (d.id == .font and self.query.len == 0) {
            if (self.choiceButton(ctx, v.input.text())) self.choice_open = if (self.choice_open == d.id) null else d.id;
        } else if ((d.id == .theme or d.id == .dark_theme) and self.query.len == 0) {
            if (self.choiceButton(ctx, if (v.input.len == 0) "Default" else v.input.text())) self.choice_open = if (self.choice_open == d.id) null else d.id;
        } else if (simple and (d.id == .padding_x or d.id == .padding_y)) {
            ui.row(ctx, .{ .width = .{ .px = 170 }, .gap = 3, .align_items = .center });
            self.controls[@backingInt(d.id)] = ctx.peekId(null);
            self.focusable(ctx, ctx.peekId(null));
            _ = self.textField(ctx, &v.input, .{ .width = .{ .px = 76 }, .size = 13 });
            self.semantic_label = ctx.print("Decrease {s}", .{d.title});
            if (self.button(ctx, "−", false, false)) stepValue(ctx, &v.input, d.id, -1);
            self.semantic_label = ctx.print("Increase {s}", .{d.title});
            if (self.button(ctx, "+", false, false)) stepValue(ctx, &v.input, d.id, 1);
            ui.end(ctx);
        } else if (simple and (d.id == .shell or d.id == .directory)) {
            self.semantic_label = d.title;
            const automatic = v.input.len == 0;
            if (!stacked) ui.column(ctx, .{ .width = .{ .px = 240 }, .gap = 4 });
            if (self.choiceButton(ctx, if (automatic) (if (d.id == .shell) "System default" else "Automatic") else v.input.text())) self.choice_open = if (self.choice_open == d.id) null else d.id;
            if (self.choice_open == d.id) {
                self.semantic_label = if (d.id == .shell) "Use system shell" else "Use automatic directory";
                if (self.button(ctx, if (d.id == .shell) "System default" else "Automatic", false, false)) {
                    v.input.clear();
                    self.choice_open = null;
                }
                self.semantic_label = d.title;
                self.controls[@backingInt(d.id)] = ctx.peekId(null);
                self.focusable(ctx, ctx.peekId(null));
                _ = self.textField(ctx, &v.input, .{ .width = .fill, .size = 13, .placeholder = if (d.id == .shell) "/bin/zsh" else "~/Workarea" });
            }
            if (!stacked) ui.end(ctx);
        } else if (d.id == .history_bytes and simple) {
            if (!std.mem.eql(u8, self.memory_source.text(), v.input.text())) {
                self.memory_source.set(v.input.text());
                const bytes = std.fmt.parseInt(u64, v.input.text(), 10) catch 0;
                self.memory_input.set(ctx.print("{d}", .{@as(f64, @floatFromInt(bytes)) / 1048576}));
            }
            ui.row(ctx, .{ .gap = 8, .align_items = .center });
            self.controls[@backingInt(d.id)] = ctx.peekId(null);
            self.focusable(ctx, ctx.peekId(null));
            const before = std.hash.Wyhash.hash(0, self.memory_input.text());
            _ = self.textField(ctx, &self.memory_input, .{ .width = .{ .px = 106 }, .size = 13 });
            if (before != std.hash.Wyhash.hash(0, self.memory_input.text())) {
                const mib = std.fmt.parseFloat(f64, self.memory_input.text()) catch -1;
                v.input.set(if (!std.math.isFinite(mib) or mib < 0) "-" else if (mib > 128) "134217729" else ctx.print("{d}", .{@as(u64, @intFromFloat(@round(mib * 1048576)))}));
                self.memory_source.set(v.input.text());
            }
            ui.text(ctx, "MiB", .{ .size = 12, .color = ctx.theme.muted });
            ui.end(ctx);
        } else {
            self.focusable(ctx, control_id);
            _ = self.textField(ctx, &v.input, .{ .width = if (d.kind == .number) .{ .px = 106 } else .fill, .size = 13, .placeholder = if (d.id == .command) "Interactive shell" else "" });
            if (d.id == .sequence_timeout) ui.text(ctx, "Milliseconds", .{ .size = 11, .color = ctx.theme.muted });
        }
        self.semantic_label = null;
        self.semantic_value = "";
        if (v.dirty() or v.locked or self.query.len > 0) {
            ui.key(ctx, ctx.print("settings-reset-{s}", .{@tagName(d.id)}));
            self.semantic_label = ctx.print("Reset {s} to default", .{d.title});
            if (self.button(ctx, "Reset to default", false, m.read_only)) m.reset(d.id) catch |err| m.notice.set(@errorName(err));
        }
        if (self.query.len > 0) ui.text(ctx, ctx.print("{s} · {s}", .{ d.key, if (d.new_session) "new sessions" else if (d.id == .restore) "next startup" else "applies on save" }), .{ .size = 10, .color = ctx.theme.muted, .wrap = true });
        ui.end(ctx);
        if (!stacked) ui.end(ctx);
    }
    fn disclosure(self: *Form, ctx: *ui.Context, title: []const u8, value: []const u8, open: *bool) void {
        const id = ctx.peekId(null);
        self.ax.add(.{ .widget = id, .role = .button, .label = title, .value = value, .selected = open.* });
        self.focusable(ctx, id);
        const it = chrome.control(ctx, .{ .width = .fill, .min_height = 36, .direction = .row, .padding = .xy(4, 8), .gap = 10, .align_items = .center, .control = true, .radius = 4, .border = if (ctx.focus == id) ctx.theme.accent else null }, ctx.theme.surface_hover);
        chrome.icon(ctx, if (open.*) .down else .right, 14);
        ui.column(ctx, .{ .width = .fill });
        ui.text(ctx, title, .{ .size = 13, .wrap = true });
        ui.end(ctx);
        ui.text(ctx, value, .{ .size = 12, .color = ctx.theme.muted });
        ui.end(ctx);
        if (self.activated(ctx, it, title, false)) open.* = !open.*;
    }

    fn stepValue(ctx: *ui.Context, buffer: *ui.TextBuffer, field: schema.Field, delta: f32) void {
        var parts = std.mem.splitScalar(u8, buffer.text(), ',');
        const first = std.fmt.parseFloat(f32, parts.next() orelse "") catch return;
        const maximum: f32 = if (field == .font_size) 96 else 128;
        const minimum: f32 = if (field == .font_size) 8 else 0;
        if (!std.math.isFinite(first)) return;
        const next = std.math.clamp(first + delta, minimum, maximum);
        if (parts.next()) |second| {
            const trailing = std.fmt.parseFloat(f32, second) catch return;
            if (!std.math.isFinite(trailing) or parts.next() != null) return;
            buffer.set(ctx.print("{d},{d}", .{ next, std.math.clamp(trailing + delta, minimum, maximum) }));
        } else buffer.set(ctx.print("{d}", .{next}));
    }
    fn drawPreview(_: *Form, ctx: *ui.Context, original: config.Config, _: bool) void {
        const c = original.forAppearance(ctx.theme.dark);
        ui.column(ctx, .{ .width = .fill, .padding = .xy(18, 16), .gap = 0, .radius = 12, .background = ui.Color.hex(c.background), .border = ctx.theme.border, .clip = true });
        defer ui.end(ctx);
        const size = @min(c.font_size, 28);
        ui.row(ctx, .{ .width = .fill, .gap = 0, .clip = true });
        ui.text(ctx, " ~/dev/letty ", .{ .size = size, .mono = true, .color = ui.Color.hex(c.palette[4]) });
        ui.text(ctx, " main ", .{ .size = size, .mono = true, .color = ui.Color.hex(c.palette[5]) });
        ui.text(ctx, "❯ ", .{ .size = size, .mono = true, .color = ui.Color.hex(c.palette[2]) });
        ui.text(ctx, "git status", .{ .size = size, .mono = true, .color = ui.Color.hex(c.foreground) });
        ui.end(ctx);
        ui.row(ctx, .{ .width = .fill, .gap = 0 });
        ui.text(ctx, "modified:   ", .{ .size = size, .mono = true, .color = ui.Color.hex(c.foreground) });
        ui.text(ctx, "settings.zig", .{ .size = size, .mono = true, .color = ui.Color.hex(c.palette[1]) });
        ui.end(ctx);
        ui.row(ctx, .{ .width = .fill, .gap = 0, .clip = true });
        ui.text(ctx, "fn ", .{ .size = size, .mono = true, .color = ui.Color.hex(c.palette[5]) });
        ui.text(ctx, "main", .{ .size = size, .mono = true, .color = ui.Color.hex(c.palette[4]) });
        ui.text(ctx, "() { a != b and c >= d; }", .{ .size = size, .mono = true, .color = ui.Color.hex(c.foreground) });
        ui.end(ctx);
        ui.row(ctx, .{ .width = .fill, .gap = 4, .padding = .{ .top = 10 } });
        for (c.palette) |color| _ = ctx.leaf(.{ .width = .{ .px = 16 }, .height = .{ .px = 10 }, .radius = 3, .background = ui.Color.hex(color) }, .none, null);
        ui.end(ctx);
    }

    fn bindings(self: *Form, ctx: *ui.Context, m: *Model) void {
        if (self.binding_editor and !m.read_only) {
            self.bindingEditor(ctx, m);
            return;
        }
        ui.row(ctx, .{ .width = .fill, .gap = 10, .align_items = .center, .padding = .{ .top = 8, .bottom = 10 } });
        ui.key(ctx, "shortcut-search");
        self.focusable(ctx, ctx.peekId(null));
        const searched = self.textField(ctx, &self.shortcut_query, .{ .placeholder = "Search shortcuts…", .width = .fill, .size = 13 });
        if (searched.changed) ctx.scroll.put(ctx.gpa, self.scroll_id, 0) catch {};
        if (self.button(ctx, "+ Add shortcut", true, m.read_only)) {
            self.binding_editor = true;
            self.editing_trigger.set("");
            self.chord.clear();
            self.action.clear();
            self.replace_conflict = false;
            ctx.scroll.put(ctx.gpa, self.scroll_id, 0) catch {};
        }
        ui.end(ctx);
        ui.row(ctx, .{ .width = .fill, .padding = .xy(12, 8), .background = ctx.theme.surface });
        ui.column(ctx, .{ .width = .fill });
        ui.text(ctx, "Action", .{ .size = 12, .weight = .medium });
        ui.end(ctx);
        ui.column(ctx, .{ .width = .{ .px = if (ctx.size.w < 700) 150 else 280 } });
        ui.text(ctx, "Shortcut", .{ .size = 12, .weight = .medium });
        ui.end(ctx);
        ui.end(ctx);
        var edits: [64]keys.Binding = undefined;
        var edit_count: usize = 0;
        for (m.binding_edits.items) |spec| {
            edits[edit_count] = keys.parse(spec) catch continue;
            edit_count += 1;
        }
        var count: usize = 0;
        for ([_][]const u8{ "Windows & tabs", "Panes", "Navigation", "Clipboard", "Other actions" }, 0..) |group, group_index| {
            var heading = false;
            if (!m.baseline.clear_default_keybinds) for (keys.defaults, 0..) |binding, index| {
                if (overridden(binding, m.baseline.keybinds) or overridden(binding, edits[0..edit_count])) continue;
                if (bindingGroup(binding.action) != group_index or !self.bindingMatches(binding)) continue;
                if (!heading) {
                    bindingHeading(ctx, group);
                    heading = true;
                }
                ui.key(ctx, ctx.print("settings-default-binding-{d}", .{index}));
                self.bindingRow(ctx, m, binding, true);
                count += 1;
            };
            for (m.baseline.keybinds, 0..) |binding, index| {
                if (!keys.effectiveOverride(m.baseline.keybinds, index) or overridden(binding, edits[0..edit_count])) continue;
                if (bindingGroup(binding.action) != group_index or !self.bindingMatches(binding)) continue;
                if (!heading) {
                    bindingHeading(ctx, group);
                    heading = true;
                }
                ui.key(ctx, ctx.print("settings-custom-binding-{d}", .{index}));
                self.bindingRow(ctx, m, binding, false);
                count += 1;
            }
            for (edits[0..edit_count], 0..) |binding, index| {
                if (!keys.effectiveOverride(edits[0..edit_count], index)) continue;
                if (bindingGroup(binding.action) != group_index or !self.bindingMatches(binding)) continue;
                if (!heading) {
                    bindingHeading(ctx, group);
                    heading = true;
                }
                ui.key(ctx, ctx.print("settings-draft-binding-{d}", .{index}));
                self.bindingRow(ctx, m, binding, false);
                count += 1;
            }
        }
        if (count == 0) ui.text(ctx, "No matching shortcuts", .{ .size = 13, .color = ctx.theme.muted });
        section(ctx, "Sequences", true);
        self.drawField(ctx, m, schema.descriptor(.sequence_timeout));
        self.disclosure(ctx, "Advanced sequences and byte actions", if (self.binding_advanced) "Hide" else "Show", &self.binding_advanced);
        if (self.binding_advanced) self.advancedBinding(ctx, m);
        if (self.query.len > 0) self.actionChoices(ctx);
    }
    fn bindingHeading(ctx: *ui.Context, title: []const u8) void {
        ui.column(ctx, .{ .width = .fill, .padding = .xy(12, 7), .background = ctx.theme.surface });
        ui.text(ctx, title, .{ .size = 11, .weight = .medium, .color = ctx.theme.muted });
        ui.end(ctx);
    }
    fn overridden(binding: keys.Binding, overrides: []const keys.Binding) bool {
        for (overrides) |*other| if (keys.sameTrigger(&binding, other)) return true;
        return false;
    }
    fn bindingGroup(action: @import("../actions.zig").Action) usize {
        return switch (action) {
            .new_window, .close_window, .tab, .close_tab, .close_other_tabs, .next_tab, .previous_tab, .goto_tab, .move_tab, .rename_tab, .next_window, .previous_window, .toggle_tab_pin => 0,
            .horizontal, .vertical, .split_left, .split_up, .close, .focus_pane, .next_pane, .previous_pane, .resize_pane, .equalize, .toggle_zoom => 1,
            .copy, .paste, .paste_primary, .copy_link, .select_all => 3,
            .palette, .search, .search_next, .search_previous, .end_search, .open_settings, .toggle_sidebar, .prompt_previous, .prompt_next, .scroll_top, .scroll_bottom, .page_up, .page_down => 2,
            else => 4,
        };
    }
    fn bindingEditor(self: *Form, ctx: *ui.Context, m: *Model) void {
        if (self.button(ctx, "Back to shortcuts", false, false)) {
            self.binding_editor = false;
            self.recording = false;
            self.binding_actions = false;
            self.replace_conflict = false;
        }
        section(ctx, if (self.editing_trigger.len == 0) "Add shortcut" else "Edit shortcut", false);
        ui.text(ctx, "Shortcut", .{ .size = 13 });
        ui.row(ctx, .{ .width = .fill, .gap = 8 });
        ui.key(ctx, "settings-binding-chord");
        self.semantic_label = "Shortcut";
        self.focusable(ctx, ctx.peekId(null));
        _ = self.textField(ctx, &self.chord, .{ .placeholder = "Shortcut, e.g. ctrl+shift+r", .width = .fill, .size = 13 });
        if (self.button(ctx, if (self.recording) "Recording… Esc to cancel" else "Record shortcut", self.recording, false)) self.recording = !self.recording;
        ui.end(ctx);
        ui.text(ctx, "Action", .{ .size = 13 });
        ui.row(ctx, .{ .width = .fill, .gap = 8 });
        ui.key(ctx, "settings-binding-action");
        self.semantic_label = "Shortcut action";
        self.focusable(ctx, ctx.peekId(null));
        _ = self.textField(ctx, &self.action, .{ .placeholder = "Choose an action or enter its name", .width = .fill, .size = 13 });
        if (self.button(ctx, "Choose action…", false, false)) self.binding_actions = !self.binding_actions;
        ui.end(ctx);
        if (self.binding_actions) self.actionChoices(ctx);
        ui.row(ctx, .{ .width = .fill, .gap = 8, .padding = .{ .top = 12 } });
        if (self.button(ctx, "Apply shortcut", true, self.chord.len == 0 or self.action.len == 0)) self.addBinding(m, false);
        if (self.replace_conflict and self.button(ctx, "Replace conflicting binding", false, false)) self.addBinding(m, true);
        ui.end(ctx);
        if (self.editing_trigger.len > 0) {
            ui.row(ctx, .{ .width = .fill, .gap = 8 });
            if (self.button(ctx, "Remove binding", false, false)) {
                self.chord.set(self.editing_trigger.text());
                self.action.set("unbind");
                self.addBinding(m, true);
            }
            for (keys.defaults) |original| {
                const trigger = binding_text.trigger(ctx.alloc(), original) catch continue;
                if (!std.mem.eql(u8, trigger, self.editing_trigger.text())) continue;
                if (binding_text.request(original.request())) |spec| if (self.button(ctx, "Restore default binding", false, false)) {
                    self.chord.set(trigger);
                    self.action.set(spec);
                    self.addBinding(m, true);
                };
                break;
            }
            ui.end(ctx);
        }
        ui.text(ctx, "Changes stay in this draft until Save and apply.", .{ .size = 11, .color = ctx.theme.muted, .wrap = true });
    }
    fn advancedBinding(self: *Form, ctx: *ui.Context, m: *Model) void {
        ui.text(ctx, "Use > for a key sequence. Existing long byte actions remain preserved.", .{ .size = 11, .wrap = true, .color = ctx.theme.muted });
        ui.key(ctx, "settings-binding-advanced");
        self.semantic_label = "Advanced binding";
        self.focusable(ctx, ctx.peekId(null));
        _ = self.textField(ctx, &self.advanced_binding, .{ .placeholder = "ctrl+b>t=new_tab or ctrl+alt+x=text:hello", .width = .fill, .size = 12 });
        if (self.button(ctx, "Add advanced binding", false, m.read_only or self.advanced_binding.len == 0)) {
            m.addBinding(self.advanced_binding.text(), false) catch |err| {
                m.notice.set(@errorName(err));
                return;
            };
            self.advanced_binding.clear();
        }
    }
    fn bindingMatches(self: *Form, binding: keys.Binding) bool {
        const query = if (self.query.len > 0) self.query.text() else self.shortcut_query.text();
        if (query.len == 0 or schema.contains(binding.accelerator, query) or schema.contains(catalogue.title(binding.action), query)) return true;
        for (catalogue.entries) |entry| if (entry.request().same(binding.request()) and schema.contains(entry.keywords, query)) return true;
        return false;
    }
    fn actionChoices(self: *Form, ctx: *ui.Context) void {
        chrome.separator(ctx);
        ui.text(ctx, "Choose an action (use search to filter)", .{ .size = 14 });
        for (catalogue.entries, 0..) |entry, index| {
            const spec = binding_text.action(entry) orelse continue;
            if (self.query.len > 0 and !schema.contains(entry.title, self.query.text()) and !schema.contains(entry.keywords, self.query.text())) continue;
            ui.key(ctx, ctx.print("settings-action-{d}", .{index}));
            if (self.button(ctx, entry.title, false, false)) {
                self.action.set(spec);
                self.binding_editor = true;
                self.binding_actions = false;
                self.category = .keyboard;
                self.query.clear();
                ctx.focus = self.query_id;
                ctx.scroll.put(ctx.gpa, self.scroll_id, 0) catch {};
            }
        }
    }
    fn bindingRow(self: *Form, ctx: *ui.Context, m: *Model, binding: keys.Binding, default: bool) void {
        const label = ctx.print("Edit shortcut: {s} — {s}", .{ catalogue.title(binding.action), binding.accelerator });
        const id = ctx.peekId(null);
        self.ax.add(.{ .widget = id, .role = .button, .label = label, .value = binding.accelerator, .enabled = !m.read_only });
        if (!m.read_only) self.focusable(ctx, id);
        const it = chrome.control(ctx, .{ .width = .fill, .min_height = 38, .direction = .row, .padding = .xy(12, 8), .gap = 12, .align_items = .center, .control = !m.read_only, .border = if (ctx.focus == id) ctx.theme.accent else null }, ctx.theme.surface_hover);
        ui.column(ctx, .{ .width = .fill, .gap = 2 });
        ui.text(ctx, catalogue.title(binding.action), .{ .size = 13, .wrap = true });
        if (!default) ui.text(ctx, if (binding.action == .unbind) "Disabled" else "Custom", .{ .size = 10, .color = ctx.theme.muted });
        ui.end(ctx);
        ui.column(ctx, .{ .width = .{ .px = if (ctx.size.w < 700) 150 else 280 } });
        ui.column(ctx, .{ .padding = .xy(8, 4), .border = ctx.theme.border, .radius = 4, .background = ctx.theme.surface, .max_width = 260 });
        ui.text(ctx, binding.accelerator, .{ .size = 12, .wrap = true });
        ui.end(ctx);
        ui.end(ctx);
        ui.end(ctx);
        chrome.separator(ctx);
        if (self.activated(ctx, it, label, m.read_only)) {
            self.setTrigger(m, binding) catch |err| {
                m.notice.set(@errorName(err));
                return;
            };
            const action = binding_text.request(binding.request()) orelse {
                m.notice.set("Use Advanced sequences or the source file to edit this action.");
                return;
            };
            self.action.set(action);
            self.editing_trigger.set(self.chord.text());
            self.binding_editor = true;
            self.binding_actions = false;
            self.replace_conflict = false;
            ctx.scroll.put(ctx.gpa, self.scroll_id, 0) catch {};
        }
    }
    fn setTrigger(self: *Form, m: *Model, binding: keys.Binding) !void {
        const formatted = try binding_text.trigger(m.gpa, binding);
        defer m.gpa.free(formatted);
        if (formatted.len > self.chord.buf.len) return error.ShortcutTooLong;
        self.chord.set(formatted);
    }
    fn addBinding(self: *Form, m: *Model, replace: bool) void {
        const spec = std.fmt.allocPrint(m.gpa, "{s}={s}", .{ self.chord.text(), self.action.text() }) catch return;
        defer m.gpa.free(spec);
        const editing_same = self.editing_trigger.len > 0 and std.mem.eql(u8, self.editing_trigger.text(), self.chord.text());
        m.editBinding(if (editing_same) "" else self.editing_trigger.text(), spec, replace or editing_same) catch |err| {
            self.replace_conflict = err == error.ShortcutConflict;
            m.notice_error = true;
            m.notice.set(if (self.replace_conflict) "This shortcut is already assigned. Choose Replace conflicting binding to replace it, or record a different shortcut." else @errorName(err));
            return;
        };
        self.replace_conflict = false;
        self.binding_editor = false;
        self.binding_actions = false;
        self.editing_trigger.set("");
        m.notice_error = false;
        m.notice.set("Added to draft. Save to apply.");
    }
    fn advanced(self: *Form, ctx: *ui.Context, m: *Model, intent: *Intent) void {
        section(ctx, "Configuration", false);
        ui.row(ctx, .{ .width = .fill, .gap = 12, .align_items = .center });
        ui.column(ctx, .{ .width = .fill, .gap = 6 });
        ui.text(ctx, "Active configuration", .{ .size = 13 });
        ui.text(ctx, m.path, .{ .size = 13, .mono = true, .wrap = true });
        ui.end(ctx);
        self.semantic_label = "Open source configuration";
        if (self.button(ctx, "Open file", false, false)) intent.* = .open_config;
        ui.end(ctx);
        if (m.root) |r| if (!std.mem.eql(u8, r.path, m.path)) ui.text(ctx, ctx.print("Symbolic link target: {s}", .{r.path}), .{ .size = 11, .color = ctx.theme.muted, .wrap = true });
        ui.text(ctx, "Settings are saved to this file. Included files are preserved.", .{ .size = 11, .color = ctx.theme.muted, .wrap = true });
        if (m.root == null) ui.text(ctx, "Using built-in defaults. The first save creates this file.", .{ .size = 11, .color = ctx.theme.muted, .wrap = true });
        section(ctx, "Loaded sources", true);
        for (m.baseline.config_sources) |path| {
            ui.row(ctx, .{ .width = .fill, .padding = .xy(8, 8), .gap = 12, .align_items = .center });
            chrome.icon(ctx, .document, 18);
            ui.column(ctx, .{ .width = .fill, .gap = 4 });
            ui.text(ctx, std.fs.path.basename(path), .{ .size = 13, .weight = .medium });
            ui.text(ctx, path, .{ .size = 11, .color = ctx.theme.muted, .wrap = true });
            ui.end(ctx);
            ui.end(ctx);
            chrome.separator(ctx);
        }
        if (m.baseline.config_sources.len == 0) ui.text(ctx, "Built-in defaults", .{ .size = 13 });
        section(ctx, "Diagnostics", m.baseline.config_sources.len == 0);
        if (m.diagnostic.reason_len > 0) {
            const d = m.diagnostic;
            const text = ctx.print("{s}:{d} · {s}: {s}", .{ d.path[0..d.path_len], d.line, d.key[0..d.key_len], d.reason[0..d.reason_len] });
            self.message(ctx, "Configuration diagnostic", text);
            ui.text(ctx, text, .{ .size = 12, .wrap = true, .color = ctx.theme.danger });
            if (d.chain_len > 0) ui.text(ctx, d.chain[0..d.chain_len], .{ .size = 11, .wrap = true });
        } else {
            ui.row(ctx, .{ .gap = 10, .align_items = .center, .padding = .{ .top = 6, .bottom = 12 } });
            chrome.icon(ctx, .check, 18);
            ui.text(ctx, "No configuration errors.", .{ .size = 13 });
            ui.end(ctx);
        }
        var differences: usize = 0;
        for (self.applied_values, 0..) |value, index| if (value) |applied| {
            if (!std.mem.eql(u8, applied, m.values[index].original)) differences += 1;
        };
        const overrides = self.command_override.len > 0 or self.cwd_override.len > 0 or self.profile_override.len > 0;
        chrome.separator(ctx);
        self.disclosure(ctx, "Command-line overrides", if (overrides) "Active" else "None", &self.advanced_overrides);
        if (self.advanced_overrides) {
            if (!overrides) ui.text(ctx, "No command-line overrides.", .{ .size = 12, .color = ctx.theme.muted });
            if (self.command_override.len > 0) ui.text(ctx, ctx.print("--command={s}", .{self.command_override.text()}), .{ .size = 12, .mono = true, .wrap = true });
            if (self.cwd_override.len > 0) ui.text(ctx, ctx.print("--cwd={s}", .{self.cwd_override.text()}), .{ .size = 12, .mono = true, .wrap = true });
            if (self.profile_override.len > 0) ui.text(ctx, ctx.print("--profile={s}", .{self.profile_override.text()}), .{ .size = 12, .mono = true, .wrap = true });
            if (overrides) ui.text(ctx, "These launch overrides remain active after saving.", .{ .size = 11, .wrap = true, .color = ctx.theme.muted });
        }
        chrome.separator(ctx);
        self.disclosure(ctx, "Applied values that differ from file", if (differences == 0) "None" else ctx.print("{d}", .{differences}), &self.advanced_applied);
        if (self.advanced_applied) {
            ui.text(ctx, "Applied values when this window opened", .{ .size = 12, .color = ctx.theme.muted });
            for (self.applied_values, 0..) |value, index| if (value) |applied| {
                if (std.mem.eql(u8, applied, m.values[index].original)) continue;
                ui.text(ctx, ctx.print("{s}: applied {s}; file {s}", .{ schema.fields[index].key, applied, m.values[index].original }), .{ .size = 12, .wrap = true });
            };
        }
        if (m.json) {
            if (self.button(ctx, "Show migration preview", false, false)) {
                self.show_migration = !self.show_migration;
                intent.* = .migration;
            }
            if (self.show_migration) {
                ui.text(ctx, "Migration requires manually saving a text file and explicitly selecting its new path. Multiple JSON profiles have no equivalent text representation, so automatic migration is unavailable. The fields below are a preview only; the original JSON is preserved.", .{ .size = 12, .wrap = true });
                for (schema.fields, 0..) |d, index| if (d.id != .dark_theme) ui.text(ctx, ctx.print("{s} = {s}", .{ d.key, m.values[index].original }), .{ .size = 11, .wrap = true });
            }
        }
    }
};
