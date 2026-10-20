//! theme = plain-name OR light:paper,dark:dark-name (either branch order).
//! Load and validate BOTH branches transactionally at config load, then replay
//! explicit config entries over EACH branch. This ensures explicit colors/font
//! features override the theme regardless of the theme directive's line position.
//! Store resolved Branches(Config); appearance events select the cached branch
//! once and never reread files, restart PTYs, or clear temporary font scaling.
const std = @import("std");
pub const Appearance = enum { light, dark };
pub const Selector = struct {
    light: []const u8,
    dark: []const u8,
    conditional: bool,
    pub fn selected(self: Selector, appearance: Appearance) []const u8 {
        return if (appearance == .light) self.light else self.dark;
    }
    pub fn clone(self: Selector, a: std.mem.Allocator) !Selector {
        const light = try a.dupe(u8, self.light);
        errdefer a.free(light);
        return .{ .light = light, .dark = try a.dupe(u8, self.dark), .conditional = self.conditional };
    }
};
fn checked(raw: []const u8) ![]const u8 {
    const name = std.mem.trim(u8, raw, " \t\r");
    if (name.len == 0 or name.len > 4095 or std.mem.indexOfScalar(u8, name, 0) != null or !std.unicode.utf8ValidateSlice(name)) return error.InvalidTheme;
    return name;
}
pub fn parse(raw: []const u8) !Selector {
    const value = try checked(raw);
    const first_colon = std.mem.indexOfScalar(u8, value, ':');
    const first_mode = if (first_colon) |i| std.mem.trim(u8, value[0..i], " \t") else "";
    if (!std.mem.eql(u8, first_mode, "light") and !std.mem.eql(u8, first_mode, "dark")) return .{ .light = value, .dark = value, .conditional = false };
    var light: ?[]const u8 = null;
    var dark: ?[]const u8 = null;
    var pieces = std.mem.splitScalar(u8, value, ',');
    while (pieces.next()) |piece| {
        const field = std.mem.trim(u8, piece, " \t\r");
        const colon = std.mem.indexOfScalar(u8, field, ':') orelse return error.InvalidConditionalTheme;
        const mode = std.mem.trim(u8, field[0..colon], " \t");
        const name = try checked(field[colon + 1 ..]);
        if (std.mem.eql(u8, mode, "light")) {
            if (light != null) return error.DuplicateThemeAppearance;
            light = name;
        } else if (std.mem.eql(u8, mode, "dark")) {
            if (dark != null) return error.DuplicateThemeAppearance;
            dark = name;
        } else return error.InvalidConditionalTheme;
    }
    return .{ .light = light orelse return error.MissingThemeAppearance, .dark = dark orelse return error.MissingThemeAppearance, .conditional = true };
}
pub const AppearanceState = struct {
    current: Appearance = .light,
    /// Returns true only if the effective theme name changed; duplicate OS events
    /// and equal light/dark names need no visual invalidation.
    pub fn update(self: *AppearanceState, selector: Selector, appearance: Appearance) bool {
        const changed = !std.mem.eql(u8, selector.selected(self.current), selector.selected(appearance));
        self.current = appearance;
        return changed;
    }
};
pub fn Branches(comptime T: type) type {
    return struct {
        light: T,
        dark: T,
        pub fn selected(self: *const @This(), appearance: Appearance) *const T {
            return if (appearance == .light) &self.light else &self.dark;
        }
    };
}

/// Build both immutable branch values before publishing either of them.
/// The builder owns one candidate arena and provides loadTheme(name)!T and
/// applyExplicit(*T)!void. It must not mutate the live configuration. Caller
/// discards that entire arena on any error; this module never adopts it.
/// Load/validate both themes first, then apply the SAME explicit entry stream
/// to each branch, regardless of where the theme directive appeared. Equal
/// branch names load/apply once and share an immutable arena-owned value.
pub fn resolve(comptime T: type, selector: Selector, builder: anytype) !Branches(T) {
    var light = try builder.loadTheme(selector.light);
    const equal = std.mem.eql(u8, selector.light, selector.dark);
    var dark = if (equal) light else try builder.loadTheme(selector.dark);
    try builder.applyExplicit(&light);
    if (equal) dark = light else try builder.applyExplicit(&dark);
    return .{ .light = light, .dark = dark };
}

const FixtureConfig = struct { foreground: u24, background: u24, font_features: bool = true };
const FixtureBuilder = struct {
    loads: usize = 0,
    overlays: usize = 0,
    fn loadTheme(self: *FixtureBuilder, name: []const u8) !FixtureConfig {
        self.loads += 1;
        if (std.mem.eql(u8, name, "missing")) return error.ThemeNotFound;
        return if (std.mem.eql(u8, name, "paper")) .{ .foreground = 0x111111, .background = 0xffffff } else .{ .foreground = 0xeeeeee, .background = 0 };
    }
    fn applyExplicit(self: *FixtureBuilder, config: *FixtureConfig) !void {
        self.overlays += 1;
        config.background = 0xabcdef;
        config.font_features = false;
    }
};
test "cached branches keep theme colors but explicit colors and font features win in both" {
    var builder: FixtureBuilder = .{};
    const branches = try resolve(FixtureConfig, try parse("light:paper,dark:night"), &builder);
    try std.testing.expectEqual(@as(usize, 2), builder.loads);
    try std.testing.expectEqual(@as(usize, 2), builder.overlays);
    try std.testing.expectEqual(@as(u24, 0x111111), branches.light.foreground);
    try std.testing.expectEqual(@as(u24, 0xeeeeee), branches.dark.foreground);
    try std.testing.expectEqual(@as(u24, 0xabcdef), branches.light.background);
    try std.testing.expectEqual(branches.light.background, branches.dark.background);
    try std.testing.expect(!branches.light.font_features and !branches.dark.font_features);
}
test "missing inactive theme fails before either explicit branch can be published" {
    var builder: FixtureBuilder = .{};
    try std.testing.expectError(error.ThemeNotFound, resolve(FixtureConfig, try parse("light:paper,dark:missing"), &builder));
    try std.testing.expectEqual(@as(usize, 2), builder.loads);
    try std.testing.expectEqual(@as(usize, 0), builder.overlays);
}
test "identical conditional themes load once and duplicate appearance events do no work" {
    var builder: FixtureBuilder = .{};
    const selector = try parse("light:paper,dark:paper");
    const branches = try resolve(FixtureConfig, selector, &builder);
    try std.testing.expectEqual(@as(usize, 1), builder.loads);
    try std.testing.expectEqual(@as(usize, 1), builder.overlays);
    var appearance: AppearanceState = .{};
    for (0..8) |_| {
        try std.testing.expect(!appearance.update(selector, .dark));
        try std.testing.expect(!appearance.update(selector, .light));
    }
    try std.testing.expectEqual(branches.light, branches.dark);
    try std.testing.expectEqual(@as(usize, 1), builder.loads);
}
test "plain and paired themes, Unicode paths and either ordering" {
    const plain = try parse("~/themes/纸");
    try std.testing.expect(!plain.conditional);
    try std.testing.expectEqualStrings("~/themes/纸", plain.selected(.dark));
    const pair = try parse("dark : Night, light: Paper");
    try std.testing.expect(pair.conditional);
    try std.testing.expectEqualStrings("Night", pair.selected(.dark));
    try std.testing.expectEqualStrings("Paper", pair.selected(.light));
}
test "bad pairs fail instead of silently choosing a fallback" {
    try std.testing.expectError(error.DuplicateThemeAppearance, parse("light:a,light:b,dark:c"));
    try std.testing.expectError(error.MissingThemeAppearance, parse("dark:a"));
    try std.testing.expectError(error.InvalidTheme, parse("light:a,dark:"));
    try std.testing.expectError(error.InvalidConditionalTheme, parse("light:a,other:b"));
    try std.testing.expectError(error.InvalidTheme, parse("dark:a,light:b\x00c"));
}
test "appearance updates are idempotent and use prevalidated branches" {
    var state = AppearanceState{};
    const selector = try parse("light:paper,dark:night");
    try std.testing.expect(!state.update(selector, .light));
    try std.testing.expect(state.update(selector, .dark));
    try std.testing.expect(!state.update(selector, .dark));
    const same = try parse("light:paper,dark:paper");
    try std.testing.expect(!state.update(same, .light));
    const branches = Branches(u24){ .light = 0xffffff, .dark = 0 };
    try std.testing.expectEqual(@as(u24, 0xffffff), branches.selected(.light).*);
    try std.testing.expectEqual(@as(u24, 0), branches.selected(.dark).*);
}
