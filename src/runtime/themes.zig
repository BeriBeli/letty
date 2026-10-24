//! Kero colors plus the checksum-pinned Ghostty/iTerm2 catalog and user themes.
const std = @import("std");
const ghostty = @import("ghostty-vt");
const os = @import("platform.zig");
const A = std.mem.Allocator;
pub const Colors = struct {
    name: []const u8 = "letty",
    foreground: u24,
    background: u24,
    cursor: u24,
    cursor_text: u24,
    selection: u24,
    selection_text: u24,
    palette: [16]u24,
    pub fn fingerprint(self: Colors) u64 {
        var hash = std.hash.Wyhash.init(0);
        for ([_]u24{ self.foreground, self.background, self.cursor, self.cursor_text, self.selection, self.selection_text }) |value| std.hash.autoHash(&hash, value);
        for (self.palette) |value| std.hash.autoHash(&hash, value);
        return hash.final();
    }
};
pub const Set = struct { light: Colors = builtin(false), dark: Colors = builtin(true) };
pub fn builtin(dark: bool) Colors {
    return if (dark) .{ .foreground = 0xe6e6ea, .background = 0x232328, .cursor = 0xe6e6ea, .cursor_text = 0x161618, .selection = 0x2f4170, .selection_text = 0xffffff, .palette = .{ 0x3a3a40, 0xff6b64, 0x4fd17a, 0xf2c14e, 0x6b9bff, 0xd07cf0, 0x4cc9e0, 0xc9c9cf, 0x6c6c78, 0xff8a84, 0x74e397, 0xffd479, 0x8fb3ff, 0xe09cf7, 0x7fdcec, 0xf5f5f7 } } else .{ .foreground = 0x1d1d1f, .background = 0xffffff, .cursor = 0x1d1d1f, .cursor_text = 0xffffff, .selection = 0xcfdcfb, .selection_text = 0x1d1d1f, .palette = .{ 0x1d1d1f, 0xd3302f, 0x22863a, 0xb08800, 0x2f5bd8, 0xa033c4, 0x0f8199, 0x8e8e93, 0x5f5f66, 0xef4444, 0x2fa84f, 0xd4a017, 0x3b82f6, 0xc04ee0, 0x14a3bf, 0xb4b4bb } };
}
const Payload = struct { entries: []Colors };
pub const Catalog = struct {
    parsed: std.json.Parsed(Payload),
    pub fn init(a: A) !Catalog {
        return .{ .parsed = try std.json.parseFromSlice(Payload, a, @embedFile("theme_catalog"), .{ .ignore_unknown_fields = true }) };
    }
    pub fn deinit(self: *Catalog) void {
        self.parsed.deinit();
    }
    pub fn load(self: *const Catalog, a: A, spec: []const u8) !Set {
        return .{ .light = try self.resolve(a, try name(spec, false), false), .dark = try self.resolve(a, try name(spec, true), true) };
    }
    pub fn resolve(self: *const Catalog, a: A, value: []const u8, dark: bool) !Colors {
        // Previous configuration files used the source palette's name.
        if (value.len == 0 or std.mem.eql(u8, value, "letty") or std.mem.eql(u8, value, "kero")) return builtin(dark);
        if (std.fs.path.isAbsolute(value)) {
            const data = try os.readFile(a, value, 65536);
            defer a.free(data);
            var result = try parse(data, dark);
            result.name = value;
            return result;
        }
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const ta = arena.allocator();
        var roots: std.ArrayList([]const u8) = .empty;
        if (os.env("LETTY_THEME_DIR")) |path| try roots.append(ta, path);
        if (os.env("XDG_CONFIG_HOME")) |path| try roots.append(ta, try std.fmt.allocPrint(ta, "{s}/ghostty/themes", .{path}));
        if (os.env("HOME")) |path| try roots.append(ta, try std.fmt.allocPrint(ta, "{s}/.config/ghostty/themes", .{path}));
        for (roots.items) |root| {
            const path = try std.fmt.allocPrint(ta, "{s}/{s}", .{ root, value });
            const data = os.readFile(ta, path, 65536) catch |err| {
                if (err == error.OpenFile) continue;
                return err;
            };
            var result = try parse(data, dark);
            result.name = value;
            return result;
        }
        for (self.parsed.value.entries) |entry| if (std.mem.eql(u8, entry.name, value)) return entry;
        return error.UnknownTheme;
    }
};
pub fn name(spec: []const u8, dark: bool) ![]const u8 {
    if (std.mem.indexOfScalar(u8, spec, ':') == null) return std.mem.trim(u8, spec, " \t");
    var result: []const u8 = "letty";
    var parts = std.mem.splitScalar(u8, spec, ',');
    while (parts.next()) |part| {
        const colon = std.mem.indexOfScalar(u8, part, ':') orelse return error.InvalidTheme;
        const key = std.mem.trim(u8, part[0..colon], " \t");
        const value = std.mem.trim(u8, part[colon + 1 ..], " \t");
        if (!std.mem.eql(u8, key, "light") and !std.mem.eql(u8, key, "dark")) return error.InvalidTheme;
        if (value.len == 0) return error.InvalidTheme;
        if (std.mem.eql(u8, key, if (dark) "dark" else "light")) result = value;
    }
    return result;
}
pub fn parse(source: []const u8, dark: bool) !Colors {
    var colors = builtin(dark);
    var recognized = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t\"");
        if (std.mem.eql(u8, key, "palette")) {
            const index_eq = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidTheme;
            const index = try std.fmt.parseInt(u16, std.mem.trim(u8, value[0..index_eq], " \t"), 10);
            if (index < 16) colors.palette[index] = try hex(value[index_eq + 1 ..]);
            recognized = true;
            continue;
        }
        inline for (.{ .{ "foreground", "foreground" }, .{ "background", "background" }, .{ "cursor-color", "cursor" }, .{ "cursor-text", "cursor_text" }, .{ "selection-background", "selection" }, .{ "selection-foreground", "selection_text" } }) |mapping| if (std.mem.eql(u8, key, mapping[0])) {
            @field(colors, mapping[1]) = try hex(value);
            recognized = true;
        };
    }
    if (!recognized) return error.InvalidTheme;
    return colors;
}
fn hex(value: []const u8) !u24 {
    var raw = std.mem.trim(u8, value, " \t\"");
    if (raw.len > 0 and raw[0] == '#') raw = raw[1..];
    if (raw.len != 6) return error.InvalidTheme;
    return std.fmt.parseInt(u24, raw, 16);
}
pub fn rgb(value: u24) ghostty.color.RGB {
    return .{ .r = @truncate(value >> 16), .g = @truncate(value >> 8), .b = @truncate(value) };
}
/// Match the pinned Ghostty renderer/cell.zig graphics exemption. These
/// foreground colors are parts of a picture, not text needing contrast.
pub fn graphicsElement(cp: u21) bool {
    return switch (cp) {
        0x2500...0x259F, 0xE0B0...0xE0D7, 0x1FB00...0x1FBFF, 0x1CC00...0x1CEBF => true,
        else => false,
    };
}
pub fn terminalForeground(cp: u21, foreground: ghostty.color.RGB, background: ghostty.color.RGB, minimum: f32) ghostty.color.RGB {
    return if (graphicsElement(cp)) foreground else contrast(foreground, background, minimum);
}
/// Preserve hue as far as possible while meeting the requested native WCAG ratio.
pub fn contrast(foreground: ghostty.color.RGB, background: ghostty.color.RGB, minimum: f32) ghostty.color.RGB {
    if (minimum <= 1 or foreground.contrast(background) >= minimum) return foreground;
    const black = rgb(0);
    const white = rgb(0xffffff);
    const target = if (black.contrast(background) > white.contrast(background)) black else white;
    if (target.contrast(background) < minimum) return target;
    var low: f32 = 0;
    var high: f32 = 1;
    var result = target;
    for (0..16) |_| {
        const mid = (low + high) / 2;
        const candidate = mix(foreground, target, mid);
        if (candidate.contrast(background) >= minimum) {
            result = candidate;
            high = mid;
        } else low = mid;
    }
    return result;
}
pub fn mix(left: ghostty.color.RGB, right: ghostty.color.RGB, amount: f32) ghostty.color.RGB {
    return .{ .r = channel(left.r, right.r, amount), .g = channel(left.g, right.g, amount), .b = channel(left.b, right.b, amount) };
}
fn channel(left: u8, right: u8, amount: f32) u8 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(left)) + (@as(f32, @floatFromInt(right)) - @as(f32, @floatFromInt(left))) * amount));
}
test "pinned Ghostty theme catalog, light/dark routing, user palettes and contrast" {
    const a = std.testing.allocator;
    var catalog = try Catalog.init(a);
    defer catalog.deinit();
    try std.testing.expect(catalog.parsed.value.entries.len > 700);
    try std.testing.expectEqualStrings("Gruvbox Dark", try name("light:letty,dark:Gruvbox Dark", true));
    const theme = try catalog.load(a, "light:letty,dark:Gruvbox Dark");
    try std.testing.expectEqual(@as(u24, 0x282828), theme.dark.background);
    const legacy = try catalog.load(a, "light:kero,dark:kero");
    try std.testing.expectEqualStrings("letty", legacy.light.name);
    try std.testing.expectEqual(builtin(false).fingerprint(), legacy.light.fingerprint());
    try std.testing.expectEqual(builtin(true).fingerprint(), legacy.dark.fingerprint());
    const custom = try parse("background = #112233\npalette=2=#445566\n", false);
    try std.testing.expectEqual(@as(u24, 0x445566), custom.palette[2]);
    try std.testing.expect(contrast(rgb(0xeeeeee), rgb(0xffffff), 3).contrast(rgb(0xffffff)) >= 3);
    try std.testing.expectError(error.InvalidTheme, name("light:", false));
}
test "terminal graphics preserve Starship colors while adjacent text keeps minimum contrast" {
    const fg = rgb(0xf9e2af);
    const bg = rgb(0xa6e3a1);
    for ([_]u21{ 0x2500, 0x259f, 0xe0b0, 0xe0d7, 0x1fb00, 0x1fbff, 0x1cc00, 0x1cebf }) |cp| {
        try std.testing.expectEqual(fg, terminalForeground(cp, fg, bg, 3));
    }
    for ([_]u21{ 'A', 'B', 0xe0af, 0xe0d8, 0x1ceC0 }) |cp| {
        try std.testing.expect(terminalForeground(cp, fg, bg, 3).contrast(bg) >= 3);
    }
}
