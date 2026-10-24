//! The editable subset of Config; defaults and validation remain in config.zig.
const std = @import("std");
const config = @import("../config.zig");
pub const Category = enum { general, appearance, terminal, startup, keyboard, clipboard, advanced };
pub const categories = [_][]const u8{ "General", "Appearance", "Terminal", "Shell", "Keyboard", "Clipboard", "Advanced" };
pub const Kind = enum { text, number, toggle, choice };
pub const Field = enum { background_style, font, font_size, theme, dark_theme, ligatures, width, height, padding_x, padding_y, cursor, blink, tab_bar, navigation, sidebar_git, sidebar_ports, opacity, shell, command, directory, window_inherit, tab_inherit, split_inherit, integration, restore, history_lines, history_bytes, sequence_timeout, copy_select, paste_protect, bracketed_safe, clipboard_write };
pub const Descriptor = struct { id: Field, key: []const u8, title: []const u8, hint: []const u8, category: Category, kind: Kind = .text, choices: []const []const u8 = &.{}, new_session: bool = false };
pub const fields = [_]Descriptor{
    .{ .id = .background_style, .key = "ui-background", .title = "Background", .hint = "Choose the window background.", .category = .appearance, .kind = .choice, .choices = &.{ "rex", "mist", "meadow", "dusk", "plain" } },
    .{ .id = .font, .key = "font-family", .title = "Terminal font", .hint = "Choose an installed font family, or enter its name. Existing fallback fonts are preserved.", .category = .terminal },
    .{ .id = .font_size, .key = "font-size", .title = "Font size", .hint = "8–96 pt", .category = .terminal, .kind = .number },
    .{ .id = .theme, .key = "theme", .title = "Theme / light theme", .hint = "Choose a local theme or enter its name or path. Explicit color overrides take priority.", .category = .terminal },
    .{ .id = .dark_theme, .key = "theme", .title = "Dark theme", .hint = "Leave empty to use the theme above. Set both to follow system appearance.", .category = .terminal },
    .{ .id = .ligatures, .key = "font-ligatures", .title = "Font ligatures", .hint = "Preserves explicit OpenType features when enabled. Actual glyphs depend on the font.", .category = .terminal, .kind = .toggle },
    .{ .id = .width, .key = "adjust-cell-width", .title = "Cell width adjustment", .hint = "-50 to 200 pt or percent, such as 2 or 10%", .category = .advanced },
    .{ .id = .height, .key = "adjust-cell-height", .title = "Cell height adjustment", .hint = "-50 to 200 pt or percent; the final cell is at least 1 pt.", .category = .advanced },
    .{ .id = .padding_x, .key = "window-padding-x", .title = "Horizontal padding", .hint = "0-128 pt; use 8,12 for separate leading and trailing values.", .category = .advanced },
    .{ .id = .padding_y, .key = "window-padding-y", .title = "Vertical padding", .hint = "0-128 pt; use 8,12 for separate leading and trailing values.", .category = .advanced },
    .{ .id = .cursor, .key = "cursor-style", .title = "Cursor shape", .hint = "Terminal programs can override the default cursor.", .category = .terminal, .kind = .choice, .choices = &.{ "block", "bar", "underline", "block_hollow" } },
    .{ .id = .blink, .key = "cursor-style-blink", .title = "Blink cursor", .hint = "Set the default cursor blinking behavior.", .category = .terminal, .kind = .toggle },
    .{ .id = .tab_bar, .key = "tab-bar", .title = "Top tab bar", .hint = "auto hides the bar on macOS when there is only one tab.", .category = .appearance, .kind = .choice, .choices = &.{ "auto", "always", "never" } },
    .{ .id = .navigation, .key = "workspace-navigation", .title = "Workspace navigation", .hint = "Top tabs or a left sidebar. Saving switches every window and keeps existing sessions.", .category = .appearance, .kind = .choice, .choices = &.{ "top", "sidebar" } },
    .{ .id = .sidebar_git, .key = "sidebar-show-git", .title = "Show Git status in sidebar", .hint = "Collect real branch and dirty status for trusted local directories. Only active in sidebar mode; disabled by default.", .category = .general, .kind = .toggle },
    .{ .id = .sidebar_ports, .key = "sidebar-show-ports", .title = "Show listening ports in sidebar", .hint = "Collect TCP listeners owned by this session and its same-terminal descendants. Only active in sidebar mode; disabled by default.", .category = .general, .kind = .toggle },
    .{ .id = .opacity, .key = "unfocused-split-opacity", .title = "Inactive split opacity", .hint = "0.15-1; use 1 to keep inactive splits fully opaque.", .category = .terminal, .kind = .number },
    .{ .id = .shell, .key = "shell", .title = "Shell", .hint = "Leave empty for the account shell, or enter a path such as /bin/zsh.", .category = .startup, .new_session = true },
    .{ .id = .command, .key = "command", .title = "Startup command", .hint = "Leave empty for an interactive shell. Profiles and command-line arguments can override this.", .category = .startup, .new_session = true },
    .{ .id = .directory, .key = "working-directory", .title = "Working directory", .hint = "Leave empty for automatic selection, or use home, inherit, ~, or an absolute path.", .category = .startup, .new_session = true },
    .{ .id = .window_inherit, .key = "window-inherit-working-directory", .title = "New windows inherit directory", .hint = "Use the latest directory reported by the local shell. An explicit profile directory takes priority.", .category = .general, .kind = .toggle, .new_session = true },
    .{ .id = .tab_inherit, .key = "tab-inherit-working-directory", .title = "New tabs inherit directory", .hint = "Existing session directories are unchanged.", .category = .general, .kind = .toggle, .new_session = true },
    .{ .id = .split_inherit, .key = "split-inherit-working-directory", .title = "New splits inherit directory", .hint = "Existing session directories are unchanged.", .category = .general, .kind = .toggle, .new_session = true },
    .{ .id = .integration, .key = "shell-integration", .title = "Shell integration", .hint = "detect enables bundled integration only for supported local interactive shells.", .category = .startup, .kind = .choice, .choices = &.{ "detect", "none" }, .new_session = true },
    .{ .id = .restore, .key = "restore-layout", .title = "Restore layout at startup", .hint = "Applies at next startup. Restoring a layout creates new processes.", .category = .general, .kind = .toggle },
    .{ .id = .history_lines, .key = "scrollback-lines", .title = "Scrollback lines", .hint = "0-100000. Lowering the limit can immediately discard older history.", .category = .startup, .kind = .number },
    .{ .id = .history_bytes, .key = "scrollback-bytes", .title = "Scrollback budget (bytes)", .hint = "0-134217728. Both the line and memory limits apply.", .category = .startup, .kind = .number },
    .{ .id = .sequence_timeout, .key = "keybind-sequence-timeout", .title = "Key sequence timeout (ms)", .hint = "50–5000 ms", .category = .keyboard, .kind = .number },
    .{ .id = .copy_select, .key = "copy-on-select", .title = "Copy on selection", .hint = "PRIMARY is available on Linux. Use clipboard or none on macOS.", .category = .clipboard, .kind = .choice, .choices = &.{ "none", "primary", "clipboard", "both" } },
    .{ .id = .paste_protect, .key = "clipboard-paste-protection", .title = "Paste protection", .hint = "Ask before pasting multiple lines or control characters.", .category = .clipboard, .kind = .toggle },
    .{ .id = .bracketed_safe, .key = "clipboard-paste-bracketed-safe", .title = "Allow safe bracketed paste", .hint = "Paste directly when bracketed paste is active and no dangerous control characters are present.", .category = .clipboard, .kind = .toggle },
    .{ .id = .clipboard_write, .key = "clipboard-write", .title = "Clipboard writes (OSC 52)", .hint = "deny is the default. Reading the clipboard is not supported.", .category = .clipboard, .kind = .choice, .choices = &.{ "deny", "ask", "allow" } },
};
comptime {
    for (fields, 0..) |field, index| std.debug.assert(@backingInt(field.id) == index);
}
pub fn descriptor(id: Field) Descriptor {
    return fields[@backingInt(id)];
}
pub fn format(a: std.mem.Allocator, id: Field, c: config.Config) ![]const u8 {
    return switch (id) {
        .background_style => a.dupe(u8, @tagName(c.ui_background)),
        .font => a.dupe(u8, c.font),
        .font_size => std.fmt.allocPrint(a, "{d}", .{c.font_size}),
        .theme => a.dupe(u8, if (c.theme_branches) |b| b.light.theme else c.theme),
        .dark_theme => a.dupe(u8, if (c.theme_branches) |b| (if (std.mem.eql(u8, b.light.theme, b.dark.theme)) "" else b.dark.theme) else ""),
        .ligatures => a.dupe(u8, boolean(c.font_ligatures)),
        .width, .height => blk: {
            const v = if (id == .width) c.adjust_cell_width else c.adjust_cell_height;
            break :blk std.fmt.allocPrint(a, "{d}{s}", .{ v.value, if (v.percent) "%" else "" });
        },
        .padding_x, .padding_y => blk: {
            const p = if (id == .padding_x) c.padding_x else c.padding_y;
            break :blk std.fmt.allocPrint(a, "{d},{d}", .{ p[0], p[1] });
        },
        .cursor => a.dupe(u8, @tagName(c.cursor_style)),
        .blink => a.dupe(u8, boolean(c.cursor_blink)),
        .tab_bar => a.dupe(u8, @tagName(c.tab_bar)),
        .navigation => a.dupe(u8, if (@hasField(config.Config, "workspace_navigation")) @tagName(c.workspace_navigation) else "top"),
        .sidebar_git => a.dupe(u8, boolean(c.sidebar_show_git)),
        .sidebar_ports => a.dupe(u8, boolean(c.sidebar_show_ports)),
        .opacity => std.fmt.allocPrint(a, "{d}", .{c.unfocused_split_opacity}),
        .shell => a.dupe(u8, c.shell),
        .command => a.dupe(u8, c.command),
        .directory => a.dupe(u8, c.working_directory),
        .window_inherit => a.dupe(u8, boolean(c.window_inherit_working_directory)),
        .tab_inherit => a.dupe(u8, boolean(c.tab_inherit_working_directory)),
        .split_inherit => a.dupe(u8, boolean(c.split_inherit_working_directory)),
        .integration => a.dupe(u8, @tagName(c.shell_integration)),
        .restore => a.dupe(u8, boolean(c.restore_layout)),
        .history_lines => std.fmt.allocPrint(a, "{d}", .{c.scrollback_lines}),
        .history_bytes => std.fmt.allocPrint(a, "{d}", .{c.scrollback_bytes}),
        .sequence_timeout => std.fmt.allocPrint(a, "{d}", .{c.keybind_sequence_timeout}),
        .copy_select => a.dupe(u8, @tagName(c.copy_on_select)),
        .paste_protect => a.dupe(u8, boolean(c.paste_protection)),
        .bracketed_safe => a.dupe(u8, boolean(c.bracketed_paste_safe)),
        .clipboard_write => a.dupe(u8, @tagName(c.clipboard_write)),
    };
}
pub fn boolean(v: bool) []const u8 {
    return if (v) "true" else "false";
}
pub fn matches(d: Descriptor, query: []const u8) bool {
    if (query.len == 0) return true;
    for ([_][]const u8{ d.title, d.key, d.hint, categories[@backingInt(d.category)] }) |value| if (contains(value, query)) return true;
    return false;
}

pub fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |at| if (std.ascii.eqlIgnoreCase(haystack[at..][0..needle.len], needle)) return true;
    return false;
}
pub fn validationMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidCharacter, error.Overflow => "Enter a valid number in the highlighted field, within the range shown below its label.",
        error.InvalidFontSize => "Font size must be between 8 and 96 pt.",
        error.InvalidPadding => "Padding must be between 0 and 128 pt. Use one value or a pair such as 8,12.",
        error.InvalidCellAdjustment => "Cell adjustment must be between -50 and 200, in points or percent.",
        error.InvalidOpacity => "Inactive split opacity must be between 0.15 and 1.",
        error.InvalidHistoryBudget => "Use at most 100000 scrollback lines and 134217728 bytes.",
        error.InvalidSequenceTimeout => "Key sequence timeout must be between 50 and 5000 milliseconds.",
        error.InvalidFontFamily => "Enter a nonempty font family name, at most 255 UTF-8 bytes.",
        error.InvalidSettingText => "Use one valid line of text for this field.",
        error.UnrepresentableSettingText => "This value cannot be represented exactly by the current config format. Your draft is preserved.",
        error.InvalidWorkspaceNavigation => "Choose Top tabs or Left sidebar.",
        error.UnsupportedKeybindAction => "This action is not supported as a shortcut. Choose an action from the list.",
        error.InvalidKeybind, error.UnsupportedKeybindKey, error.UnsupportedKeybindModifier => "The shortcut is invalid. Record it again or check the advanced sequence syntax.",
        error.TooManyKeybindings => "The configuration allows at most 128 custom bindings. Remove unused entries in the source file before adding more.",
        error.ConfigCreateFailed => "The selected configuration could not be created. Check its directory and permissions. Your draft is preserved.",
        error.AccessDenied => "Permission denied. The previous file and settings are unchanged; your draft is preserved.",
        error.ConfigNotFound => "A configuration, include, or theme file was not found. See Advanced for its path.",
        error.OpenProfileRemoved, error.ProfileInUse => "A profile is still used by an open terminal. Keep that profile before saving.",
        error.SaveBusy => "Another writer is saving this configuration. Try again after it finishes.",
        else => @errorName(err),
    };
}
