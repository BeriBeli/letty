//! Owned OpenType settings; an absent tag retains the font/shaper default.
const std = @import("std");
pub const capacity = 32;
pub const Error = error{ InvalidFeature, InvalidTag, InvalidValue, TooManyFeatures, DuplicateFeature };
pub const Feature = struct { tag: [4]u8, value: u32 };
pub const Set = struct {
    entries: [capacity]Feature = @splat(.{ .tag = @splat(0), .value = 0 }),
    len: u8 = 0,

    /// Validate typed JSON/direct callers before any bounded-array slice.
    pub fn validate(self: *const Set) Error!void {
        if (self.len > capacity) return error.TooManyFeatures;
        for (self.entries[0..self.len], 0..) |feature, index| {
            try validateTag(feature.tag);
            for (self.entries[0..index]) |previous| if (std.mem.eql(u8, &previous.tag, &feature.tag)) return error.DuplicateFeature;
        }
    }
    /// Rendering policy is applied last. `true` preserves explicit -liga/-calt;
    /// `false` overrides even explicit positive tags. The declared set stays raw
    /// so a later true override cannot inherit synthetic disabled features.
    pub fn effective(self: Set, ligatures: bool) Error!Set {
        try self.validate();
        var result = self;
        if (!ligatures) try result.setLigatures(false);
        return result.canonical();
    }
    pub fn items(self: *const Set) []const Feature {
        return self.entries[0..self.len];
    }

    pub fn get(self: *const Set, tag: [4]u8) ?u32 {
        for (self.items()) |feature| if (std.mem.eql(u8, &tag, &feature.tag)) return feature.value;
        return null;
    }

    /// Repeated tags use the last value, including explicit zero. No slices
    /// refer to the source. Failed updates leave all previous values intact.
    pub fn put(self: *Set, feature: Feature) Error!void {
        if (self.len > capacity) return error.TooManyFeatures;
        try validateTag(feature.tag);
        for (self.entries[0..self.len]) |*existing| {
            if (std.mem.eql(u8, &feature.tag, &existing.tag)) {
                existing.* = feature;
                return;
            }
        }
        if (self.len == capacity) return error.TooManyFeatures;
        self.entries[self.len] = feature;
        self.len += 1;
    }

    /// Comma-separated Ghostty/CSS-style settings, strict on malformed input.
    /// Empty value resets overrides; repeated nonempty declarations append.
    pub fn apply(self: *Set, source: []const u8) Error!void {
        if (std.mem.trim(u8, source, " \t").len == 0) {
            self.* = .{};
            return;
        }
        try self.validate();
        var pending = self.*;
        var parts = std.mem.splitScalar(u8, source, ',');
        while (parts.next()) |part| try pending.put(try parse(part));
        self.* = pending;
    }

    pub fn parseList(source: []const u8) Error!Set {
        var result: Set = .{};
        try result.apply(source);
        return result;
    }

    /// An explicit UI ligature toggle overrides all three common ligature
    /// tags. It does not imply the backend supports GSUB or contextual lookup.
    pub fn setLigatures(self: *Set, enabled: bool) Error!void {
        var pending = self.*;
        for ([_][4]u8{ "liga".*, "calt".*, "dlig".* }) |tag| try pending.put(.{ .tag = tag, .value = @intFromBool(enabled) });
        self.* = pending;
    }

    /// Canonical order makes cache identity independent of declaration order.
    pub fn canonical(self: Set) Set {
        var result = self;
        std.mem.sort(Feature, result.entries[0..result.len], {}, struct {
            fn less(_: void, a: Feature, b: Feature) bool {
                return std.mem.order(u8, &a.tag, &b.tag) == .lt;
            }
        }.less);
        return result;
    }

    pub fn hash(self: Set) u64 {
        const sorted = self.canonical();
        var hasher = std.hash.Wyhash.init(0);
        for (sorted.items()) |feature| {
            hasher.update(&feature.tag);
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, feature.value, .little);
            hasher.update(&bytes);
        }
        return hasher.final();
    }
};

pub fn parse(source: []const u8) Error!Feature {
    var remaining = std.mem.trim(u8, source, " \t");
    if (remaining.len == 0) return error.InvalidFeature;
    var sign: ?bool = null;
    if (remaining[0] == '+' or remaining[0] == '-') {
        sign = remaining[0] == '+';
        remaining = std.mem.trimStart(u8, remaining[1..], " \t");
    }
    var tag: [4]u8 = undefined;
    if (remaining.len != 0 and (remaining[0] == '\'' or remaining[0] == '"')) {
        if (remaining.len < 6 or remaining[5] != remaining[0]) return error.InvalidTag;
        @memcpy(&tag, remaining[1..5]);
        remaining = remaining[6..];
    } else {
        if (remaining.len < 4) return error.InvalidTag;
        @memcpy(&tag, remaining[0..4]);
        remaining = remaining[4..];
    }
    try validateTag(tag);
    // The fifth character must separate the value from the four-byte tag.
    if (remaining.len > 0 and remaining[0] != '=' and remaining[0] != ' ' and remaining[0] != '\t') return error.InvalidTag;
    remaining = std.mem.trim(u8, remaining, " \t");
    if (remaining.len > 0 and remaining[0] == '=') {
        remaining = std.mem.trim(u8, remaining[1..], " \t");
        if (remaining.len == 0) return error.InvalidValue;
    }
    const value: u32 = if (remaining.len == 0) (if (sign == false) 0 else 1) else if (std.ascii.eqlIgnoreCase(remaining, "on")) 1 else if (std.ascii.eqlIgnoreCase(remaining, "off")) 0 else blk: {
        for (remaining) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidValue;
        break :blk std.fmt.parseInt(u32, remaining, 10) catch return error.InvalidValue;
    };
    if (sign) |enabled| if ((enabled and value == 0) or (!enabled and value != 0)) return error.InvalidValue;
    return .{ .tag = tag, .value = value };
}

fn validateTag(tag: [4]u8) Error!void {
    for (tag) |byte| if (byte < 0x20 or byte > 0x7e or byte == '\'' or byte == '"' or byte == ',' or byte == '=') return error.InvalidTag;
}

test "feature settings retain explicit zero, alternate values and last override" {
    const values = try Set.parseList("liga, -calt, 'ss01' 3, \"cv02\"=4, liga off");
    try std.testing.expectEqual(@as(?u32, 0), values.get("liga".*));
    try std.testing.expectEqual(@as(?u32, 0), values.get("calt".*));
    try std.testing.expectEqual(@as(?u32, 3), values.get("ss01".*));
    try std.testing.expectEqual(@as(?u32, 4), values.get("cv02".*));
    try std.testing.expect(values.get("kern".*) == null);
    try std.testing.expectEqual(@as(u8, 4), values.len);
}

test "feature parsing is bounded, owned and transactional" {
    var source = "liga=0".*;
    var values = try Set.parseList(&source);
    @memset(&source, 'x');
    try std.testing.expectEqual(@as(?u32, 0), values.get("liga".*));
    const old_hash = values.hash();
    try std.testing.expectError(error.InvalidValue, values.apply("liga=1, ss01=-1"));
    try std.testing.expectEqual(old_hash, values.hash());
    for (0..capacity - 1) |index| {
        const tag: [4]u8 = .{ 'a', 'b', 'A' + @as(u8, @intCast(index / 26)), 'a' + @as(u8, @intCast(index % 26)) };
        try values.put(.{ .tag = tag, .value = 1 });
    }
    try std.testing.expectError(error.TooManyFeatures, values.put(.{ .tag = "xxxx".*, .value = 1 }));
    try values.apply("");
    try std.testing.expectEqual(@as(u8, 0), values.len);
}

test "feature syntax rejects malformed tags, conflicting signs and overflow" {
    for ([_][]const u8{ "lig", "ligaa", "'liga", "\"lig\"", "li\x00a" }) |value| try std.testing.expectError(error.InvalidTag, parse(value));
    for ([_][]const u8{ "liga=-1", "liga=", "liga=4294967296", "liga=1x", "+liga off", "-liga=1" }) |value| try std.testing.expectError(error.InvalidValue, parse(value));
    try std.testing.expectError(error.InvalidFeature, Set.parseList("liga,"));
    try std.testing.expectEqual(@as(u32, 1), (try parse("+liga")).value);
    try std.testing.expectEqual(@as(u32, 0), (try parse("calt = 0")).value);
}

test "feature identity is canonical and ligature toggle is explicit" {
    var a = try Set.parseList("liga=0, ss01=2");
    const b = try Set.parseList("ss01=2, liga=0");
    try std.testing.expectEqual(a.hash(), b.hash());
    try a.setLigatures(false);
    for ([_][4]u8{ "liga".*, "calt".*, "dlig".* }) |tag| try std.testing.expectEqual(@as(?u32, 0), a.get(tag));
    try std.testing.expectEqual(@as(?u32, 2), a.get("ss01".*));
}

test "effective ligature policy never re-enables explicit feature disables" {
    const declared = try Set.parseList("-liga,calt=2,ss01=3");
    const enabled = try declared.effective(true);
    try std.testing.expectEqual(@as(?u32, 0), enabled.get("liga".*));
    try std.testing.expectEqual(@as(?u32, 2), enabled.get("calt".*));
    const disabled = try declared.effective(false);
    for ([_][4]u8{ "liga".*, "calt".*, "dlig".* }) |tag| try std.testing.expectEqual(@as(?u32, 0), disabled.get(tag));
    try std.testing.expectEqual(@as(?u32, 3), disabled.get("ss01".*));
    try std.testing.expectEqual(@as(?u32, 2), declared.get("calt".*));
    try std.testing.expect(declared.get("dlig".*) == null);
}
test "typed invalid sets are rejected before slices and effective additions remain bounded" {
    var invalid: Set = .{ .len = 33 };
    try std.testing.expectError(error.TooManyFeatures, invalid.validate());
    try std.testing.expectError(error.TooManyFeatures, invalid.effective(false));
    invalid = try Set.parseList("liga");
    invalid.entries[1] = invalid.entries[0];
    invalid.len = 2;
    try std.testing.expectError(error.DuplicateFeature, invalid.validate());
    var full: Set = .{};
    for (0..capacity) |i| try full.put(.{ .tag = .{ 'a', 'b', 'A' + @as(u8, @intCast(i / 26)), 'a' + @as(u8, @intCast(i % 26)) }, .value = 1 });
    try std.testing.expectError(error.TooManyFeatures, full.effective(false));
}
