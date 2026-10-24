//! Letty key=value configuration, isolated from the recovery configuration.
const std = @import("std");
const platform = @import("platform.zig");
pub const Settings = struct {
    @"new-session-directory": []const u8 = "current",
    @"session-name": []const u8 = "focused",
    @"focus-follows-mouse": bool = false,
    @"confirm-close": bool = true,
    @"window-theme": []const u8 = "system",
    language: []const u8 = "system",
    background: []const u8 = "rex",
    @"window-translucent": bool = true,
    @"font-family": []const u8 = "",
    @"font-size": f32 = 13,
    @"font-weight": u16 = 400,
    @"line-height": f32 = 1.22,
    @"font-ligatures": bool = true,
    @"font-thicken": bool = false,
    @"minimum-contrast": f32 = 3,
    @"dim-unfocused-terminals": bool = true,
    @"cursor-style": []const u8 = "block",
    @"cursor-style-blink": bool = true,
    theme: []const u8 = "letty",
    @"macos-option-as-alt": bool = false,
    @"copy-on-select": bool = false,
    @"clipboard-read": []const u8 = "ask",
    @"right-click-action": []const u8 = "context-menu",
    command: []const u8 = "",
    @"scrollback-limit": u16 = 4,
    @"notify-on-waiting": bool = true,
    @"notify-on-done": bool = true,
    @"notify-on-error": bool = true,
    @"notify-sound": bool = false,
    @"dock-badge": bool = true,
    @"dock-bounce": bool = false,
    @"git-status": bool = true,
    @"diff-layout": []const u8 = "auto",
};
pub const Config = struct {
    settings: Settings = .{},
    env: std.ArrayList([]const u8) = .empty,
    keybind: std.ArrayList([]const u8) = .empty,
    source: []const u8 = "",
    pub fn deinit(self: *Config, a: std.mem.Allocator) void {
        self.env.deinit(a);
        self.keybind.deinit(a);
        a.free(self.source);
        self.* = .{};
    }
    pub fn parse(a: std.mem.Allocator, source: []const u8) !Config {
        if (source.len > 1024 * 1024 or !std.unicode.utf8ValidateSlice(source)) return error.ConfigLimit;
        var result: Config = .{ .source = try a.dupe(u8, source) };
        errdefer result.deinit(a);
        var lines = std.mem.splitScalar(u8, result.source, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfigLine;
            const name = std.mem.trim(u8, line[0..eq], " \t");
            var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (value.len > 1 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
            if (std.mem.eql(u8, name, "env")) {
                const at = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidEnvironment;
                if (at == 0 or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidEnvironment;
                for (value[0..at], 0..) |ch, i| if (!(std.ascii.isAlphabetic(ch) or ch == '_' or (i > 0 and std.ascii.isDigit(ch)))) return error.InvalidEnvironment;
                try result.env.append(a, value);
                continue;
            }
            if (std.mem.eql(u8, name, "keybind")) {
                const at = std.mem.lastIndexOfScalar(u8, value, '=') orelse return error.InvalidBinding;
                if (!std.mem.eql(u8, std.mem.trim(u8, value[0..at], " \t"), "none")) _ = try @import("actions.zig").parse(std.mem.trim(u8, value[0..at], " \t"), true);
                const action = std.mem.trim(u8, value[at + 1 ..], " \t");
                if (!std.mem.eql(u8, action, "unbind") and !@import("actions.zig").known(action)) return error.InvalidBinding;
                try result.keybind.append(a, value);
                continue;
            }
            var known = false;
            inline for (@typeInfo(Settings).@"struct".field_names) |field| {
                if (std.mem.eql(u8, name, field)) {
                    const T = @FieldType(Settings, field);
                    @field(result.settings, field) = if (T == bool) (if (std.mem.eql(u8, value, "true")) true else if (std.mem.eql(u8, value, "false")) false else return error.InvalidBoolean) else if (T == []const u8) value else if (T == f32) try std.fmt.parseFloat(f32, value) else try std.fmt.parseInt(T, value, 10);
                    known = true;
                }
            }
            if (!known) return error.UnknownConfigKey;
        }
        const s = result.settings;
        _ = try @import("themes.zig").name(s.theme, false);
        _ = try @import("themes.zig").name(s.theme, true);
        const choices = .{
            .{ "new-session-directory", &[_][]const u8{ "current", "project", "home" } },
            .{ "session-name", &[_][]const u8{ "focused", "lead", "folder" } },
            .{ "language", &[_][]const u8{ "system", "en", "zh-Hans" } },
            .{ "window-theme", &[_][]const u8{ "system", "light", "dark" } },
            .{ "background", &[_][]const u8{ "petal", "rex", "mist", "meadow", "dusk", "plain" } },
            .{ "cursor-style", &[_][]const u8{ "block", "bar", "underline" } },
            .{ "clipboard-read", &[_][]const u8{ "ask", "allow", "deny" } },
            .{ "right-click-action", &[_][]const u8{ "context-menu", "paste", "copy-or-paste" } },
            .{ "diff-layout", &[_][]const u8{ "auto", "split", "unified" } },
        };
        inline for (choices) |choice| {
            var valid = false;
            for (choice[1]) |value| if (std.mem.eql(u8, @field(s, choice[0]), value)) {
                valid = true;
                break;
            };
            if (!valid) return error.InvalidConfigChoice;
        }
        if (!std.math.isFinite(s.@"font-size") or s.@"font-size" < 6 or s.@"font-size" > 72 or !std.math.isFinite(s.@"line-height") or s.@"line-height" < 1 or s.@"line-height" > 3 or s.@"font-weight" < 100 or s.@"font-weight" > 900 or s.@"scrollback-limit" > 128 or !std.math.isFinite(s.@"minimum-contrast") or s.@"minimum-contrast" < 1 or s.@"minimum-contrast" > 21) return error.InvalidConfigRange;
        return result;
    }
    /// Update a scalar in place, preserving comments, unknown keys and list order.
    /// A complete parse is required by the caller before this reaches disk.
    pub fn change(a: std.mem.Allocator, source: []const u8, name: []const u8, value: []const u8) ![]const u8 {
        if (std.mem.indexOfAny(u8, value, "\r\n\x00") != null) return error.InvalidConfigValue;
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, source, "\n"), '\n');
        var emitted = false;
        while (lines.next()) |line| {
            if (source.len == 0) break;
            const raw = std.mem.trim(u8, line, " \t\r");
            const at = std.mem.indexOfScalar(u8, raw, '=');
            if (raw.len > 0 and raw[0] != '#' and at != null and std.mem.eql(u8, std.mem.trim(u8, raw[0..at.?], " \t"), name)) {
                if (emitted) continue;
                try out.writer.print("{s} = {s}\n", .{ name, value });
                emitted = true;
            } else try out.writer.print("{s}\n", .{line});
        }
        if (!emitted) try out.writer.print("{s} = {s}\n", .{ name, value });
        return out.toOwnedSlice();
    }
    /// Replace one repeated field without disturbing comments or unrelated values.
    pub fn list(a: std.mem.Allocator, source: []const u8, name: []const u8, values: []const []const u8) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, source, "\n"), '\n');
        while (lines.next()) |line| {
            if (source.len == 0) break;
            const raw = std.mem.trim(u8, line, " \t\r");
            const at = std.mem.indexOfScalar(u8, raw, '=');
            if (raw.len > 0 and raw[0] != '#' and at != null and std.mem.eql(u8, std.mem.trim(u8, raw[0..at.?], " \t"), name)) continue;
            try out.writer.print("{s}\n", .{line});
        }
        for (values) |value| {
            if (std.mem.indexOfAny(u8, value, "\r\n\x00") != null) return error.InvalidConfigValue;
            try out.writer.print("{s} = {s}\n", .{ name, value });
        }
        return out.toOwnedSlice();
    }
    pub fn binding(self: *const Config, a: std.mem.Allocator, id: []const u8, chord: []const u8) ![]const u8 {
        if (!@import("actions.zig").known(id)) return error.InvalidBinding;
        var values: std.ArrayList([]const u8) = .empty;
        defer values.deinit(a);
        for (self.keybind.items) |value| {
            const at = std.mem.lastIndexOfScalar(u8, value, '=') orelse continue;
            if (!std.mem.eql(u8, std.mem.trim(u8, value[at + 1 ..], " \t"), id)) try values.append(a, value);
        }
        const next = try std.fmt.allocPrint(a, "{s}={s}", .{ chord, id });
        defer a.free(next);
        if (chord.len > 0) try values.append(a, next);
        return list(a, self.source, "keybind", values.items);
    }
    pub fn format(a: std.mem.Allocator, source: []const u8, settings: Settings) ![]const u8 {
        var current = try a.dupe(u8, source);
        errdefer a.free(current);
        const defaults: Settings = .{};
        inline for (@typeInfo(Settings).@"struct".field_names) |name| {
            const value = @field(settings, name);
            const same = if (@TypeOf(value) == []const u8) std.mem.eql(u8, value, @field(defaults, name)) else value == @field(defaults, name);
            if (!same or hasKey(source, name)) {
                const text = if (@TypeOf(value) == []const u8) try std.fmt.allocPrint(a, "\"{s}\"", .{value}) else try std.fmt.allocPrint(a, "{any}", .{value});
                defer a.free(text);
                const replacement = try change(a, current, name, text);
                a.free(current);
                current = @constCast(replacement);
            }
        }
        return current;
    }
    fn hasKey(source: []const u8, name: []const u8) bool {
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            const raw = std.mem.trim(u8, line, " \t\r");
            if (raw.len == 0 or raw[0] == '#') continue;
            const at = std.mem.indexOfScalar(u8, raw, '=') orelse continue;
            if (std.mem.eql(u8, std.mem.trim(u8, raw[0..at], " \t"), name)) return true;
        }
        return false;
    }
    pub fn path(a: std.mem.Allocator) ![]const u8 {
        if (platform.env("LETTY_CONFIG")) |value| return a.dupe(u8, value);
        if (platform.env("XDG_CONFIG_HOME")) |value| return pathIn(a, value);
        const base = try std.fmt.allocPrint(a, "{s}/.config", .{platform.env("HOME") orelse return error.NoHome});
        defer a.free(base);
        return pathIn(a, base);
    }
    fn pathIn(a: std.mem.Allocator, base: []const u8) ![]const u8 {
        const current = try std.fmt.allocPrint(a, "{s}/letty/config", .{base});
        errdefer a.free(current);
        if (try exists(a, current)) return current;
        // Keep existing installations on their saved file until explicitly moved.
        const legacy = try std.fmt.allocPrint(a, "{s}/letty/kero-config", .{base});
        errdefer a.free(legacy);
        if (try exists(a, legacy)) {
            a.free(current);
            return legacy;
        }
        a.free(legacy);
        return current;
    }
    fn exists(a: std.mem.Allocator, file: []const u8) !bool {
        const z = try a.dupeSentinel(u8, file, 0);
        defer a.free(z);
        return std.c.access(z.ptr, 0) == 0;
    }
};
test "canonical configuration takes precedence while existing files remain compatible" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buffer: [256]u8 = undefined;
    const template = try std.fmt.bufPrintSentinel(&buffer, "{s}/letty-config-name-XXXXXX", .{if (@import("builtin").os.tag == .macos) "/private/tmp" else "/tmp"}, 0);
    const base = platform.c.mkdtemp(template.ptr) orelse return error.PrivateDirectory;
    defer _ = platform.c.rmdir(base);
    const directory = try std.fmt.allocPrintSentinel(a, "{s}/letty", .{base}, 0);
    try platform.mkdirs(a, directory);
    defer _ = platform.c.rmdir(directory.ptr);
    const current = try std.fmt.allocPrintSentinel(a, "{s}/config", .{directory}, 0);
    const legacy = try std.fmt.allocPrintSentinel(a, "{s}/kero-config", .{directory}, 0);
    defer _ = platform.c.unlink(current.ptr);
    defer _ = platform.c.unlink(legacy.ptr);
    try std.testing.expectEqualStrings(current, try Config.pathIn(a, std.mem.span(base)));
    try platform.atomicFile(a, legacy, "font-size = 15\n");
    try std.testing.expectEqualStrings(legacy, try Config.pathIn(a, std.mem.span(base)));
    try platform.atomicFile(a, current, "font-size = 16\n");
    try std.testing.expectEqualStrings(current, try Config.pathIn(a, std.mem.span(base)));
    try std.testing.expectEqualStrings("font-size = 15\n", try platform.readFile(a, legacy, 1024));
}
test "Letty configuration preserves repeated values and rejects daemon keys" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = try Config.parse(a, "# user comment\nfont-size = 15\nfont-ligatures = false\nenv = A=1\nenv = B=2\n");
    try std.testing.expectEqual(@as(f32, 15), cfg.settings.@"font-size");
    try std.testing.expect(!cfg.settings.@"font-ligatures");
    try std.testing.expectEqual(@as(usize, 2), cfg.env.items.len);
    try std.testing.expectError(error.UnknownConfigKey, Config.parse(a, "listen = tailnet://:7373"));
    try std.testing.expectError(error.InvalidConfigRange, Config.parse(a, "font-size = nan"));
}

test "configuration edits preserve comments and repeated values and validate before publish" {
    const a = std.testing.allocator;
    const original = "# keep me\nfont-size = 13\nenv = A=one\n\n# another\nenv = B=two\n";
    const changed = try Config.change(a, original, "font-size", "16");
    defer a.free(changed);
    try std.testing.expect(std.mem.indexOf(u8, changed, "# another\nenv = B=two") != null);
    var parsed = try Config.parse(a, changed);
    defer parsed.deinit(a);
    try std.testing.expectEqual(@as(f32, 16), parsed.settings.@"font-size");
    try std.testing.expectEqual(@as(usize, 2), parsed.env.items.len);
    try std.testing.expectError(error.InvalidConfigChoice, Config.parse(a, "cursor-style = triangle"));
    try std.testing.expectError(error.InvalidBinding, Config.parse(a, "keybind = cmd+x=daemon.attach"));
}

test "list editors preserve scalar comments and action resets" {
    const a = std.testing.allocator;
    var cfg = try Config.parse(a, "# private\nfont-size=14\nenv=A=1\nkeybind=Cmd+X=session.new\n");
    defer cfg.deinit(a);
    const changed = try cfg.binding(a, "session.new", "none");
    defer a.free(changed);
    var next = try Config.parse(a, changed);
    defer next.deinit(a);
    try std.testing.expect(std.mem.startsWith(u8, changed, "# private\nfont-size=14\n"));
    try std.testing.expectEqualStrings("A=1", next.env.items[0]);
    try std.testing.expect(@import("actions.zig").match(.{ .key = 't', .cmd = true }, next.keybind.items, true) == null);
    const reset = try next.binding(a, "session.new", "");
    defer a.free(reset);
    try std.testing.expect(std.mem.indexOf(u8, reset, "keybind") == null);
}
