const std = @import("std");
const c = @import("platform_ffi.zig");
const paper = @import("theme.zig");
const builtin_palette = @import("builtin_palette.zig");
const keys = @import("keybindings.zig");
pub const includes = @import("config_include.zig");
const conditional = @import("conditional_theme.zig");
pub const features = @import("font_features.zig");
const color_fields = .{ "foreground", "background", "cursor", "explicit_cursor", "explicit_selection_fg", "explicit_selection_bg", "selection_foreground", "selection_background", "palette", "ui_panel", "ui_border", "ui_accent", "split_divider_color", "font_features", "font_ligatures" };
/// Arena-owned immutable appearance snapshots. No Config-by-value recursion.
pub const ThemeColors = struct {
    theme: []const u8,
    foreground: u24,
    background: u24,
    cursor: u24,
    explicit_cursor: bool,
    explicit_selection_fg: bool,
    explicit_selection_bg: bool,
    selection_foreground: u24,
    selection_background: u24,
    palette: [16]u24,
    ui_panel: ?u24,
    ui_border: ?u24,
    ui_accent: ?u24,
    split_divider_color: ?u24,
    font_features: features.Set,
    font_ligatures: bool,
    fn capture(config: Config) ThemeColors {
        var value: ThemeColors = undefined;
        value.theme = config.theme;
        inline for (color_fields) |field| @field(value, field) = @field(config, field);
        return value;
    }
};
pub const ThemeBranches = struct { light: ThemeColors, dark: ThemeColors };
pub const CursorStyle = enum(u32) { bar = 0, block = 1, underline = 2, block_hollow = 3 };
pub const CopyOnSelect = @import("clipboard_model.zig").CopyOnSelect;
pub const ClosePolicy = @import("close_request.zig").Policy;
pub const ShellIntegration = enum { detect, none };
pub const TabBar = enum { auto, always, never };
pub const WorkspaceNavigation = enum { top, sidebar };
pub const BackgroundStyle = enum { rex, mist, meadow, dusk, plain };
pub const Adjustment = struct {
    value: f32 = 0,
    percent: bool = false,
    pub fn parse(v: []const u8) !Adjustment {
        const percent = std.mem.endsWith(u8, v, "%");
        const n = try std.fmt.parseFloat(f32, if (percent) v[0 .. v.len - 1] else v);
        if (!std.math.isFinite(n) or n < -50 or n > 200) return error.InvalidCellAdjustment;
        return .{ .value = n, .percent = percent };
    }
    pub fn apply(v: Adjustment, size: f32) f32 {
        return @max(1, if (v.percent) size * (1 + v.value / 100) else size + v.value);
    }
};
pub const Profile = struct { name: []const u8 = "Local", command: []const u8 = "", cwd: []const u8 = "" };
pub const Config = struct {
    font: []const u8 = "Maple Mono Normal NL NF CN",
    @"font-family": ?[]const u8 = null,
    theme: []const u8 = "letty",
    font_size: f32 = 13,
    font_features: features.Set = .{},
    font_ligatures: bool = true,
    /// Letty extension: repeated font-family retains old last-wins behavior.
    /// font-family-fallback appends; empty value clears; at most 16 families.
    font_fallbacks: []const []const u8 = &.{},
    foreground: u24 = builtin_palette.foreground,
    background: u24 = builtin_palette.background,
    cursor: u24 = builtin_palette.foreground,
    explicit_cursor: bool = false,
    explicit_selection_fg: bool = false,
    explicit_selection_bg: bool = false,
    selection_foreground: u24 = builtin_palette.selection_foreground,
    selection_background: u24 = builtin_palette.selection_background,
    palette: [16]u24 = builtin_palette.palette,
    padding_x: [2]f32 = .{ 4, 4 },
    padding_y: [2]f32 = .{ 4, 4 },
    adjust_cell_width: Adjustment = .{},
    adjust_cell_height: Adjustment = .{},
    cursor_style: CursorStyle = .block,
    cursor_blink: bool = false,
    unfocused_split_opacity: f32 = 0.7,
    tab_bar: TabBar = .auto,
    workspace_navigation: WorkspaceNavigation = .sidebar,
    ui_background: BackgroundStyle = .rex,
    sidebar_show_git: bool = false,
    sidebar_show_ports: bool = false,
    ui_panel: ?u24 = null,
    ui_border: ?u24 = null,
    ui_accent: ?u24 = null,
    split_divider_color: ?u24 = null,
    services: @import("application_services_config.zig").Settings = .{},
    keybinds: []const keys.Binding = &.{},
    clear_default_keybinds: bool = false,
    keybind_sequence_timeout: u16 = 1000,
    config_sources: []const []const u8 = &.{},
    theme_branches: ?*const ThemeBranches = null,
    command: []const u8 = "",
    working_directory: []const u8 = "",
    window_inherit_working_directory: bool = true,
    tab_inherit_working_directory: bool = true,
    split_inherit_working_directory: bool = true,
    shell_integration: ShellIntegration = .detect,
    scrollback_lines: usize = 10000,
    scrollback_bytes: usize = 16 * 1024 * 1024,
    shell: []const u8 = "",
    restore_layout: bool = true,
    confirm_close: ClosePolicy = .prompt,
    copy_on_select: CopyOnSelect = if (@import("builtin").os.tag == .linux) .primary else .none,
    paste_protection: bool = true,
    bracketed_paste_safe: bool = true,
    /// Letty opt-in: bounded direct Kitty RGB/RGBA/PNG static images.
    kitty_graphics: bool = false,
    clipboard_write: @import("osc52_model.zig").Policy = .deny,
    clipboard_read: enum { deny } = .deny,
    profiles: []const Profile = &.{.{}},
    /// Select only cached appearance properties; preserve temporary font scaling.
    pub fn forAppearance(s: Config, dark: bool) Config {
        var value = s;
        if (s.theme_branches) |branches| {
            const colors = if (dark) branches.dark else branches.light;
            value.theme = colors.theme;
            inline for (color_fields) |field| @field(value, field) = @field(colors, field);
        }
        return value;
    }
    pub fn effectiveFontFeatures(s: Config) features.Error!features.Set {
        return s.font_features.effective(s.font_ligatures);
    }
    pub fn resolveColors(s: *Config) void {
        if (!s.explicit_cursor) s.cursor = s.foreground;
        if (!s.explicit_selection_fg) s.selection_foreground = s.background;
        if (!s.explicit_selection_bg) s.selection_background = s.foreground;
    }
    pub fn validate(s: Config) !void {
        try s.services.validate();
        if (s.font.len == 0 or s.theme.len == 0) return error.InvalidString;
        _ = try conditional.parse(s.theme);
        try validateFamily(s.font);
        if (s.font_fallbacks.len > 16) return error.TooManyFontFallbacks;
        for (s.font_fallbacks) |family| try validateFamily(family);
        _ = try s.effectiveFontFeatures();
        for (s.padding_x ++ s.padding_y) |p| if (!std.math.isFinite(p) or p < 0 or p > 128) return error.InvalidPadding;
        if (!std.math.isFinite(s.unfocused_split_opacity) or s.unfocused_split_opacity < 0.15 or s.unfocused_split_opacity > 1) return error.InvalidOpacity;
        for ([_]Adjustment{ s.adjust_cell_width, s.adjust_cell_height }) |v| if (!std.math.isFinite(v.value) or v.value < -50 or v.value > 200) return error.InvalidCellAdjustment;
        if (!std.math.isFinite(s.font_size) or s.font_size < 8 or s.font_size > 96) return error.InvalidFontSize;
        if (s.scrollback_lines > 100000 or s.scrollback_bytes > 128 * 1024 * 1024) return error.InvalidHistoryBudget;
        if (s.keybind_sequence_timeout < 50 or s.keybind_sequence_timeout > 5000) return error.InvalidSequenceTimeout;
        if (s.keybinds.len > 128) return error.TooManyKeybindings;
        for (s.keybinds) |*binding| try keys.validate(binding);
        if (s.profiles.len == 0 or s.profiles.len > 16) return error.InvalidProfiles;
        for ([_][]const u8{ s.shell, s.font, s.theme, s.command, s.working_directory }) |v| if (std.mem.indexOfScalar(u8, v, 0) != null) return error.InvalidString;
        for (s.profiles, 0..) |p, i| {
            if (p.name.len == 0 or p.name.len > 64 or p.command.len > 4096 or p.cwd.len > 4096) return error.InvalidProfile;
            for ([_][]const u8{ p.name, p.command, p.cwd }) |v| if (std.mem.indexOfScalar(u8, v, 0) != null) return error.InvalidString;
            for (s.profiles[0..i]) |prior| if (std.mem.eql(u8, p.name, prior.name)) return error.DuplicateProfile;
        }
    }
};
pub const Diagnostic = includes.Diagnostic;
pub fn read(a: std.mem.Allocator, path: []const u8, limit: usize) !?[]u8 {
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    const fd = c.lt_config_open(z);
    if (fd < 0) return null;
    defer c.lt_close(fd);
    const n = c.lt_length(fd);
    if (n < 0 or n > limit) return error.FileSize;
    const data = try a.alloc(u8, @intCast(n));
    errdefer a.free(data);
    var at: usize = 0;
    while (at < data.len) {
        const got = c.lt_pread(fd, data[at..].ptr, data.len - at, at);
        if (got <= 0) return error.ShortRead;
        at += @intCast(got);
    }
    return data;
}
fn validateFamily(name: []const u8) !void {
    if (std.mem.trim(u8, name, " \t").len == 0 or name.len > 255 or !std.unicode.utf8ValidateSlice(name)) return error.InvalidFontFamily;
    for (name) |ch| if (ch == 0 or ch == '\r' or ch == '\n') return error.InvalidFontFamily;
}
fn unquote(value: []const u8) []const u8 {
    return @import("config_value.zig").unquote(value);
}
pub fn parseColor(value: []const u8) !u24 {
    const v = if (std.mem.startsWith(u8, value, "#")) value[1..] else value;
    if (v.len != 6) return error.InvalidColor;
    for (v) |digit| if (!std.ascii.isHex(digit)) return error.InvalidColor;
    return std.fmt.parseInt(u24, v, 16) catch return error.InvalidColor;
}
fn boolean(v: []const u8) !bool {
    if (std.mem.eql(u8, v, "true")) return true;
    if (std.mem.eql(u8, v, "false")) return false;
    return error.InvalidBoolean;
}
fn padding(value: []const u8) ![2]f32 {
    var parts = std.mem.splitScalar(u8, value, ',');
    const first = try std.fmt.parseFloat(f32, std.mem.trim(u8, parts.next().?, " \t"));
    const second = if (parts.next()) |v| try std.fmt.parseFloat(f32, std.mem.trim(u8, v, " \t")) else first;
    if (parts.next() != null) return error.InvalidPadding;
    return .{ first, second };
}
fn assignColor(cfg: *Config, key: []const u8, value: []const u8) !bool {
    if (std.mem.eql(u8, key, "cursor-color")) cfg.explicit_cursor = true;
    if (std.mem.eql(u8, key, "selection-foreground")) cfg.explicit_selection_fg = true;
    if (std.mem.eql(u8, key, "selection-background")) cfg.explicit_selection_bg = true;
    const names = .{ .{ "foreground", "foreground" }, .{ "background", "background" }, .{ "cursor-color", "cursor" }, .{ "selection-foreground", "selection_foreground" }, .{ "selection-background", "selection_background" }, .{ "ui-panel", "ui_panel" }, .{ "ui-border", "ui_border" }, .{ "ui-accent", "ui_accent" }, .{ "split-divider-color", "split_divider_color" } };
    inline for (names) |pair| if (std.mem.eql(u8, key, pair[0])) {
        @field(cfg, pair[1]) = try parseColor(value);
        return true;
    };
    if (std.mem.eql(u8, key, "palette")) {
        const eq = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidPalette;
        const index = try std.fmt.parseInt(usize, std.mem.trim(u8, value[0..eq], " \t"), 10);
        if (index >= 16) return error.InvalidPalette;
        cfg.palette[index] = try parseColor(std.mem.trim(u8, value[eq + 1 ..], " \t"));
        return true;
    }
    return false;
}
fn parseInto(a: std.mem.Allocator, data: []const u8, initial: Config, theme_only: bool, diagnostic: ?*Diagnostic) !Config {
    var cfg = initial;
    var bindings: std.ArrayList(keys.Binding) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw| {
        line_number += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            if (diagnostic) |d| d.fail(line_number, "", error.InvalidConfigLine);
            return error.InvalidConfigLine;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = unquote(line[eq + 1 ..]);
        apply(a, &cfg, &bindings, key, value, theme_only) catch |err| {
            if (diagnostic) |d| d.fail(line_number, key, err);
            std.debug.print("configuration line {d}, {s}: {s}\n", .{ line_number, key, @errorName(err) });
            return err;
        };
    }
    cfg.keybinds = try bindings.toOwnedSlice(a);
    cfg.resolveColors();
    try cfg.validate();
    return cfg;
}
fn apply(a: std.mem.Allocator, cfg: *Config, bindings: *std.ArrayList(keys.Binding), key: []const u8, value: []const u8, theme_only: bool) !void {
    if (try assignColor(cfg, key, value)) return;
    // Theme feature declarations are replayed before root overrides. Keep raw
    // tags here; force-off policy is applied only by Set.effective at render.
    if (std.mem.eql(u8, key, "font-feature")) {
        try cfg.font_features.apply(value);
        try cfg.validate();
        return;
    }
    if (std.mem.eql(u8, key, "font-ligatures")) {
        cfg.font_ligatures = try boolean(value);
        try cfg.validate();
        return;
    }
    if (theme_only) return error.UnsupportedThemeKey;
    if (std.mem.eql(u8, key, "ui-background")) {
        cfg.ui_background = std.meta.stringToEnum(BackgroundStyle, value) orelse return error.InvalidBackgroundStyle;
        return;
    }
    if (std.mem.eql(u8, key, "workspace-navigation")) {
        cfg.workspace_navigation = std.meta.stringToEnum(WorkspaceNavigation, value) orelse return error.InvalidWorkspaceNavigation;
        return;
    }
    if (std.mem.eql(u8, key, "sidebar-show-git")) {
        cfg.sidebar_show_git = try boolean(value);
        return;
    }
    if (std.mem.eql(u8, key, "sidebar-show-ports")) {
        cfg.sidebar_show_ports = try boolean(value);
        return;
    }
    if (try @import("application_services_config.zig").apply(&cfg.services, key, value)) return;
    const eql = std.mem.eql;
    if (eql(u8, key, "clipboard-write")) {
        cfg.clipboard_write = std.meta.stringToEnum(@import("osc52_model.zig").Policy, value) orelse return error.InvalidClipboardPolicy;
        return;
    }
    if (eql(u8, key, "clipboard-read")) {
        if (!eql(u8, value, "deny")) return error.UnsupportedSynchronousClipboardRead;
        return;
    }
    if (eql(u8, key, "kitty-graphics")) {
        cfg.kitty_graphics = try boolean(value);
        return;
    }
    if (eql(u8, key, "font-family-fallback")) {
        if (value.len == 0) cfg.font_fallbacks = &.{} else {
            try validateFamily(value);
            if (cfg.font_fallbacks.len == 16) return error.TooManyFontFallbacks;
            const families = try a.alloc([]const u8, cfg.font_fallbacks.len + 1);
            @memcpy(families[0..cfg.font_fallbacks.len], cfg.font_fallbacks);
            families[cfg.font_fallbacks.len] = try a.dupe(u8, value);
            cfg.font_fallbacks = families;
        }
    } else if (eql(u8, key, "font-family")) cfg.font = try a.dupe(u8, value) else if (eql(u8, key, "theme")) cfg.theme = try a.dupe(u8, value) else if (eql(u8, key, "font-size")) cfg.font_size = try std.fmt.parseFloat(f32, value) else if (eql(u8, key, "window-padding-x")) cfg.padding_x = try padding(value) else if (eql(u8, key, "window-padding-y")) cfg.padding_y = try padding(value) else if (eql(u8, key, "adjust-cell-width")) cfg.adjust_cell_width = try Adjustment.parse(value) else if (eql(u8, key, "adjust-cell-height")) cfg.adjust_cell_height = try Adjustment.parse(value) else if (eql(u8, key, "cursor-style")) cfg.cursor_style = std.meta.stringToEnum(CursorStyle, value) orelse return error.InvalidCursorStyle else if (eql(u8, key, "cursor-style-blink")) cfg.cursor_blink = try boolean(value) else if (eql(u8, key, "unfocused-split-opacity")) cfg.unfocused_split_opacity = try std.fmt.parseFloat(f32, value) else if (eql(u8, key, "tab-bar")) cfg.tab_bar = std.meta.stringToEnum(TabBar, value) orelse return error.InvalidTabBar else if (eql(u8, key, "scrollback-lines")) cfg.scrollback_lines = try std.fmt.parseInt(usize, value, 10) else if (eql(u8, key, "scrollback-bytes") or eql(u8, key, "scrollback-limit")) cfg.scrollback_bytes = try std.fmt.parseInt(usize, value, 10) else if (eql(u8, key, "shell")) cfg.shell = try a.dupe(u8, value) else if (eql(u8, key, "command")) cfg.command = try a.dupe(u8, value) else if (eql(u8, key, "working-directory")) cfg.working_directory = try a.dupe(u8, value) else if (eql(u8, key, "window-inherit-working-directory")) cfg.window_inherit_working_directory = try boolean(value) else if (eql(u8, key, "tab-inherit-working-directory")) cfg.tab_inherit_working_directory = try boolean(value) else if (eql(u8, key, "split-inherit-working-directory")) cfg.split_inherit_working_directory = try boolean(value) else if (eql(u8, key, "shell-integration")) cfg.shell_integration = std.meta.stringToEnum(ShellIntegration, value) orelse return error.InvalidShellIntegration else if (eql(u8, key, "copy-on-select")) cfg.copy_on_select = if (eql(u8, value, "true")) (if (@import("builtin").os.tag == .linux) .primary else .clipboard) else if (eql(u8, value, "false")) .none else std.meta.stringToEnum(CopyOnSelect, value) orelse return error.InvalidCopyOnSelect else if (eql(u8, key, "clipboard-paste-protection")) cfg.paste_protection = try boolean(value) else if (eql(u8, key, "clipboard-paste-bracketed-safe")) cfg.bracketed_paste_safe = try boolean(value) else if (eql(u8, key, "confirm-close-surface")) cfg.confirm_close = if (eql(u8, value, "true")) .prompt else if (eql(u8, value, "false")) .never else if (eql(u8, value, "always")) .always else return error.InvalidClosePolicy else if (eql(u8, key, "restore-layout")) cfg.restore_layout = try boolean(value) else if (eql(u8, key, "keybind-sequence-timeout")) cfg.keybind_sequence_timeout = try std.fmt.parseInt(u16, value, 10) else if (eql(u8, key, "keybind")) {
        if (eql(u8, value, "clear") or value.len == 0) {
            bindings.clearRetainingCapacity();
            cfg.clear_default_keybinds = value.len != 0;
        } else {
            const owned = try a.dupe(u8, value);
            if (bindings.items.len >= 128) return error.TooManyKeybindings;
            var binding = try keys.parse(owned);
            binding.accelerator = try keys.formatBindingAccelerator(a, binding);
            try bindings.append(a, binding);
        }
    } else return error.UnknownConfigKey;
    try cfg.validate();
}
pub fn parseText(a: std.mem.Allocator, data: []const u8) !Config {
    return parseInto(a, data, .{}, false, null);
}
pub fn parseTheme(a: std.mem.Allocator, data: []const u8) !Config {
    return parseInto(a, data, .{}, true, null);
}
fn parseDocument(a: std.mem.Allocator, data: []const u8, initial: Config, diagnostic: ?*Diagnostic) !Config {
    if (!std.mem.startsWith(u8, std.mem.trimStart(u8, data, " \t\r\n"), "{")) return parseInto(a, data, initial, false, diagnostic);
    // Keep the original JSON form for profiles and existing installations.
    const parsed = try std.json.parseFromSlice(Config, a, data, .{ .allocate = .alloc_always });
    var cfg = parsed.value;
    cfg.theme_branches = null;
    cfg.config_sources = &.{};
    if (cfg.@"font-family") |name| cfg.font = name;
    // JSON colour overrides must beat theme values, too.
    const explicit = try std.json.parseFromSlice(std.json.Value, a, data, .{});
    const fields = .{ "foreground", "background", "cursor", "selection_foreground", "selection_background", "palette", "ui_panel", "ui_border", "ui_accent", "split_divider_color" };
    inline for (fields) |field| if (!explicit.value.object.contains(field)) {
        @field(cfg, field) = @field(initial, field);
    };
    if (!explicit.value.object.contains("font_ligatures")) cfg.font_ligatures = initial.font_ligatures;
    const declared_features = cfg.font_features;
    if (!explicit.value.object.contains("font_features")) cfg.font_features = initial.font_features else {
        try declared_features.validate();
        // Explicit empty JSON Set resets overrides, exactly like font-feature=.
        if (declared_features.len != 0) {
            cfg.font_features = initial.font_features;
            for (declared_features.items()) |feature| try cfg.font_features.put(feature);
        }
    }
    cfg.explicit_cursor = explicit.value.object.contains("cursor") or initial.explicit_cursor;
    cfg.explicit_selection_fg = explicit.value.object.contains("selection_foreground") or initial.explicit_selection_fg;
    cfg.explicit_selection_bg = explicit.value.object.contains("selection_background") or initial.explicit_selection_bg;
    cfg.resolveColors();
    try cfg.validate();
    return cfg;
}
pub fn load(a: std.mem.Allocator, path: []const u8) !Config {
    return loadDetailed(a, path, null);
}
pub fn loadDetailed(a: std.mem.Allocator, path: []const u8, diagnostic: ?*Diagnostic) !Config {
    return loadWithReaderDetailed(a, includes.nativeReader(env("HOME")), path, .{}, diagnostic);
}
/// Candidate storage belongs to caller (normally one reload arena). Documents
/// are temporary: all strings escaping this function are copied to that storage.
pub fn loadWithReaderDetailed(a: std.mem.Allocator, reader: includes.Reader, path: []const u8, limits: includes.Limits, diagnostic: ?*Diagnostic) !Config {
    if (diagnostic) |d| {
        d.* = .{};
        d.setPath(path);
    }
    return loadWithReader(a, reader, path, limits, diagnostic) catch |err| {
        if (diagnostic) |d| if (d.reason_len == 0) d.fail(0, "", err);
        return err;
    };
}
const Builder = struct {
    a: std.mem.Allocator,
    reader: includes.Reader,
    limits: includes.Limits,
    diagnostic: ?*Diagnostic,
    document: *const includes.Document,
    theme_source: includes.Location,
    sources: std.ArrayList([]const u8) = .empty,
    total_bytes: usize,
    total_files: usize,

    fn remember(self: *Builder, document: *const includes.Document) !void {
        for (document.sources) |source| try self.sources.append(self.a, try self.a.dupe(u8, source.path));
    }
    fn semantic(self: *Builder, source: includes.Location, key: []const u8, err: anyerror) anyerror {
        if (self.diagnostic) |d| d.set(source, key, err);
        return err;
    }
    fn overlay(self: *Builder, initial: Config) !Config {
        if (self.document.json) |json| return parseDocument(self.a, json, initial, self.diagnostic) catch |err| return self.semantic(self.theme_source, "", err);
        var config = initial;
        var bindings: std.ArrayList(keys.Binding) = .empty;
        for (self.document.entries) |entry| {
            apply(self.a, &config, &bindings, entry.key, entry.value, false) catch |err| return self.semantic(entry.source, entry.key, err);
        }
        config.keybinds = try bindings.toOwnedSlice(self.a);
        config.resolveColors();
        try config.validate();
        return config;
    }
    fn themeLocation(self: *Builder, a: std.mem.Allocator, location: includes.Location) !includes.Location {
        const chain = try a.alloc(includes.Frame, self.theme_source.chain.len + 1 + location.chain.len);
        @memcpy(chain[0..self.theme_source.chain.len], self.theme_source.chain);
        chain[self.theme_source.chain.len] = .{ .path = self.theme_source.path, .line = self.theme_source.line };
        @memcpy(chain[self.theme_source.chain.len + 1 ..], location.chain);
        return .{ .path = location.path, .line = location.line, .chain = chain };
    }
    fn loadTheme(self: *Builder, name: []const u8) !Config {
        var config: Config = .{};
        config.theme = try self.a.dupe(u8, name);
        if (std.ascii.eqlIgnoreCase(name, "letty") or std.ascii.eqlIgnoreCase(name, "kero") or std.ascii.eqlIgnoreCase(name, "custom")) return config;
        if (std.ascii.eqlIgnoreCase(name, "paper")) {
            config.foreground = paper.foreground;
            config.background = paper.background;
            config.cursor = paper.foreground;
            config.selection_foreground = paper.background;
            config.selection_background = paper.foreground;
            config.palette = paper.palette;
            return config;
        }
        const expanded = try homeWith(self.a, name, self.reader.home);
        const dir = std.fs.path.dirname(self.theme_source.path) orelse ".";
        const path = if (std.fs.path.isAbsolute(expanded)) expanded else if (std.mem.indexOfScalar(u8, expanded, '/') != null)
            try std.fs.path.join(self.a, &.{ dir, expanded })
        else
            try std.fs.path.join(self.a, &.{ dir, "themes", expanded });
        var bounds = self.limits;
        bounds.total_bytes -= self.total_bytes;
        bounds.files -= self.total_files;
        var theme_diagnostic: Diagnostic = .{};
        var document = includes.load(self.a, self.reader, path, bounds, &theme_diagnostic) catch |err| {
            if (self.diagnostic) |d| {
                const source: includes.Location = .{ .path = theme_diagnostic.path[0..theme_diagnostic.path_len], .line = theme_diagnostic.line };
                d.set(try self.themeLocation(self.a, source), theme_diagnostic.key[0..theme_diagnostic.key_len], err);
                // Keep nested include frames supplied by the theme loader too.
                const remaining = d.chain.len - d.chain_len;
                const n = @min(remaining, theme_diagnostic.chain_len);
                @memcpy(d.chain[d.chain_len..][0..n], theme_diagnostic.chain[0..n]);
                d.chain_len += n;
                d.chain_truncated = d.chain_truncated or theme_diagnostic.chain_truncated or n != theme_diagnostic.chain_len;
            }
            return err;
        };
        defer document.deinit();
        self.total_bytes += document.total_bytes;
        self.total_files += document.sources.len;
        try self.remember(&document);
        if (document.json != null) return self.semantic(try self.themeLocation(self.a, .{ .path = document.sources[0].path, .line = 0 }), "", error.UnsupportedThemeFormat);
        var bindings: std.ArrayList(keys.Binding) = .empty;
        for (document.entries) |entry| {
            apply(self.a, &config, &bindings, entry.key, entry.value, true) catch |err| return self.semantic(try self.themeLocation(self.a, entry.source), entry.key, err);
        }
        config.resolveColors();
        return config;
    }
};
fn loadWithReader(a: std.mem.Allocator, reader: includes.Reader, path: []const u8, limits: includes.Limits, diagnostic: ?*Diagnostic) !Config {
    var document = try includes.load(a, reader, path, limits, diagnostic);
    defer document.deinit();
    var builder: Builder = .{ .a = a, .reader = reader, .limits = limits, .diagnostic = diagnostic, .document = &document, .theme_source = .{ .path = document.sources[0].path, .line = 0 }, .total_bytes = document.total_bytes, .total_files = document.sources.len };
    try builder.remember(&document);
    var selection: []const u8 = (Config{}).theme;
    if (document.json) |json| {
        const parsed = try builder.overlay(.{});
        selection = parsed.theme;
        _ = json;
    } else for (document.entries) |entry| if (std.mem.eql(u8, entry.key, "theme")) {
        selection = entry.value;
        builder.theme_source = entry.source;
    };
    const selector = (conditional.parse(selection) catch |err| return builder.semantic(builder.theme_source, "theme", err)).clone(a) catch |err| return builder.semantic(builder.theme_source, "theme", err);
    const light_theme = try builder.loadTheme(selector.light);
    const same = std.mem.eql(u8, selector.light, selector.dark);
    const dark_theme = if (same) light_theme else try builder.loadTheme(selector.dark);
    var light = try builder.overlay(light_theme);
    var dark = if (same) light else try builder.overlay(dark_theme);
    light.theme = selector.light;
    dark.theme = selector.dark;
    const branches = try a.create(ThemeBranches);
    branches.* = .{ .light = ThemeColors.capture(light), .dark = ThemeColors.capture(dark) };
    light.theme_branches = branches;
    light.config_sources = try builder.sources.toOwnedSlice(a);
    light.working_directory = try homeWith(a, light.working_directory, reader.home);
    const profiles = try a.dupe(Profile, light.profiles);
    for (profiles) |*profile| profile.cwd = try homeWith(a, profile.cwd, reader.home);
    light.profiles = profiles;
    try light.validate();
    return light;
}
fn homeWith(a: std.mem.Allocator, value: []const u8, home: []const u8) ![]const u8 {
    if (std.mem.eql(u8, value, "~") or std.mem.startsWith(u8, value, "~/")) {
        if (home.len == 0) return error.HomeMissing;
        return std.fmt.allocPrint(a, "{s}{s}", .{ home, value[1..] });
    }
    return value;
}
pub fn expandHome(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (std.mem.eql(u8, value, "~")) return a.dupe(u8, env("HOME"));
    if (std.mem.startsWith(u8, value, "~/")) return std.fmt.allocPrint(a, "{s}/{s}", .{ env("HOME"), value[2..] });
    return value;
}
pub fn selectPath(a: std.mem.Allocator, explicit: ?[]const u8) ![]const u8 {
    if (explicit) |path| return path;
    const dir = try configDir(a);
    const text = try std.fmt.allocPrint(a, "{s}/config", .{dir});
    const json = try std.fmt.allocPrint(a, "{s}/config.json", .{dir});
    if (exists(text)) return text;
    if (exists(json)) return json;
    return text;
}
/// True also for an unusable preferred path: only ENOENT/ENOTDIR permit
/// config.json/default fallback. Opening is nonblocking and rejects nonregular
/// files; loadDetailed will then report EACCES/EINVAL/LOOP rather than hide it.
pub fn exists(path: []const u8) bool {
    if (path.len > 4095 or std.mem.indexOfScalar(u8, path, 0) != null) return true;
    var z: [4096]u8 = undefined;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const fd = c.lt_config_open(@ptrCast(&z));
    if (fd < 0) return switch (std.c.errno(@as(c_int, -1))) {
        .NOENT, .NOTDIR => false,
        else => true,
    };
    c.lt_close(fd);
    return true;
}
pub fn env(name: [:0]const u8) []const u8 {
    return std.mem.span(c.lt_env(name));
}
pub fn configDir(a: std.mem.Allocator) ![]const u8 {
    const xdg = env("XDG_CONFIG_HOME");
    if (xdg.len > 0 and std.fs.path.isAbsolute(xdg)) return std.fmt.allocPrint(a, "{s}/letty", .{xdg});
    const home = env("HOME");
    if (home.len == 0) return error.HomeMissing;
    return std.fmt.allocPrint(a, "{s}/.config/letty", .{home});
}
test "reject resource explosions, invalid fonts and duplicate profile names" {
    try std.testing.expectError(error.InvalidHistoryBudget, (Config{ .scrollback_lines = 99999999 }).validate());
    try std.testing.expectError(error.InvalidFontSize, (Config{ .font_size = std.math.nan(f32) }).validate());
    try std.testing.expectError(error.DuplicateProfile, (Config{ .profiles = &.{ .{}, .{} } }).validate());
}

test "user font-family and default Letty config syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parseText(arena.allocator(), "font-family = Maple Mono Normal NL NF CN\ntheme = letty\n");
    try std.testing.expectEqualStrings("Maple Mono Normal NL NF CN", cfg.font);
    try std.testing.expectEqual(@as(u24, 0xffffff), cfg.background);
    try std.testing.expectEqual(@as(u24, 0xd3302f), cfg.palette[1]);
}

test "common customization parses padding, metrics, cursor, palette and repeated bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parseText(arena.allocator(),
        \\font-family = Maple Mono Normal NL NF CN
        \\font-size = 18
        \\background = #101820
        \\foreground = #eaeaea
        \\palette = 1=#ff5555
        \\window-padding-x = 12, 18
        \\window-padding-y = 10
        \\adjust-cell-height = 15%
        \\cursor-style = bar
        \\cursor-style-blink = true
        \\unfocused-split-opacity = 0.6
        \\tab-bar = always
        \\keybind = clear
        \\keybind = ctrl+shift+t=new_tab
        \\keybind = ctrl+shift+t=ignore
    );
    try std.testing.expectEqual([2]f32{ 12, 18 }, cfg.padding_x);
    try std.testing.expectEqual([2]f32{ 10, 10 }, cfg.padding_y);
    try std.testing.expectApproxEqAbs(@as(f32, 23), cfg.adjust_cell_height.apply(20), 0.001);
    try std.testing.expectEqual(CursorStyle.bar, cfg.cursor_style);
    try std.testing.expect(cfg.cursor_blink and cfg.clear_default_keybinds);
    try std.testing.expectEqual(@as(u24, 0xeaeaea), cfg.cursor);
    try std.testing.expectEqual(cfg.background, cfg.selection_foreground);
    try std.testing.expectEqual(@as(u24, 0xff5555), cfg.palette[1]);
    try std.testing.expectEqual(keys.Action.ignore, keys.lookup(cfg.keybinds, cfg.clear_default_keybinds, .{ .key = 't', .ctrl = true, .shift = true }).?.action);
}
test "invalid customization does not silently fall back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidPadding, parseText(a, "window-padding-x = nan"));
    try std.testing.expectError(error.InvalidPalette, parseText(a, "palette = 16=#ffffff"));
    try std.testing.expectError(error.InvalidOpacity, parseText(a, "unfocused-split-opacity = 2"));
    try std.testing.expectError(error.UnsupportedKeybindAction, parseText(a, "keybind = super+k=unknown_action"));
    try std.testing.expectError(error.UnknownConfigKey, parseText(a, "font-features = -calt"));
    try std.testing.expectError(error.UnsupportedThemeKey, parseTheme(a, "command = echo unsupported"));
}

test "Ghostty working directory special values and inheritance switches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parseText(arena.allocator(), "working-directory = inherit\nwindow-inherit-working-directory = false\ntab-inherit-working-directory = false\nsplit-inherit-working-directory = false\n");
    try std.testing.expectEqualStrings("inherit", cfg.working_directory);
    try std.testing.expect(!cfg.window_inherit_working_directory and !cfg.tab_inherit_working_directory and !cfg.split_inherit_working_directory);
    const home = try parseText(arena.allocator(), "working-directory = home\n");
    try std.testing.expectEqualStrings("home", home.working_directory);
    try std.testing.expect(home.window_inherit_working_directory and home.tab_inherit_working_directory and home.split_inherit_working_directory);
}

test {
    _ = @import("config_loader_test.zig");
}

// Public color parsing never exposes numeric-parser details to config users.
test "invalid six digit colors consistently report InvalidColor" {
    for ([_][]const u8{ "broken", "gggggg", "#12zz34", "#ffffffx", "#", "+abcde", "ab_cd0", "0x1234" }) |value|
        try std.testing.expectError(error.InvalidColor, parseColor(value));
    try std.testing.expectEqual(@as(u24, 0xabcdef), try parseColor("#AbCdEf"));
}

test "workspace navigation defaults sidebar and sidebar ignores top visibility policy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(WorkspaceNavigation.sidebar, (Config{}).workspace_navigation);
    const cfg = try parseText(arena.allocator(), "workspace-navigation = sidebar\ntab-bar = never\nsidebar-show-git = true\nsidebar-show-ports = true\n");
    try std.testing.expectEqual(WorkspaceNavigation.sidebar, cfg.workspace_navigation);
    try std.testing.expect(cfg.tab_bar == .never and cfg.sidebar_show_git and cfg.sidebar_show_ports);
    try std.testing.expectError(error.InvalidWorkspaceNavigation, parseText(arena.allocator(), "workspace-navigation = unknown"));
}
