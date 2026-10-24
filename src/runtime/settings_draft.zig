//! Owned settings draft: preview changes never overwrite the on-disk baseline.
const std = @import("std");
const Config = @import("settings.zig").Config;
const A = std.mem.Allocator;
pub const Draft = struct {
    id: u64 = 0,
    baseline: []const u8 = "",
    config: ?Config = null,
    baseline_themes: ?@import("themes.zig").Set = null,
    pub fn deinit(self: *Draft, a: A) void {
        if (self.config) |*value| value.deinit(a);
        a.free(self.baseline);
        self.* = .{};
    }
    pub fn begin(self: *Draft, a: A, source: []const u8) !void {
        var next: Draft = .{ .baseline = try a.dupe(u8, source) };
        errdefer next.deinit(a);
        next.config = try Config.parse(a, source);
        self.deinit(a);
        self.* = next;
    }
    pub fn dirty(self: *const Draft) bool {
        return if (self.config) |value| !std.mem.eql(u8, self.baseline, value.source) else false;
    }
    pub fn adopt(self: *Draft, a: A, candidate: Config) void {
        if (self.config) |*value| value.deinit(a);
        self.config = candidate;
    }
};
test "settings draft owns candidate strings and discards without changing baseline" {
    const a = std.testing.allocator;
    var draft: Draft = .{};
    defer draft.deinit(a);
    try draft.begin(a, "# retained\nfont-size = 13\n");
    const changed = try Config.change(a, draft.config.?.source, "font-size", "17");
    defer a.free(changed);
    draft.adopt(a, try Config.parse(a, changed));
    try std.testing.expect(draft.dirty());
    try std.testing.expectEqual(@as(f32, 17), draft.config.?.settings.@"font-size");
    try std.testing.expectEqualStrings("# retained\nfont-size = 13\n", draft.baseline);
    try draft.begin(a, draft.baseline);
    try std.testing.expect(!draft.dirty());
}
