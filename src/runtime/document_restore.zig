//! Bounded metadata only: local paths and tab names, never drafts or PTYs.
const std = @import("std");
const documents = @import("document-native");
pub const limit = 1024 * 1024;
pub const Record = struct { window: u64, path: []const u8, name: []const u8 = "", active: bool = false };
pub const Data = struct { version: u8 = 1, files: []const Record = &.{} };
pub const Snapshot = struct {
    parsed: std.json.Parsed(Data),
    pub fn deinit(self: *Snapshot) void {
        self.parsed.deinit();
    }
    pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Snapshot {
        if (bytes.len > limit) return error.DocumentRestoreMetadataLimit;
        const parsed = try std.json.parseFromSlice(Data, a, bytes, .{ .ignore_unknown_fields = true });
        errdefer parsed.deinit();
        if (parsed.value.version != 1) return error.DocumentRestoreVersion;
        for (parsed.value.files) |file| {
            try documents.loader.validatePath(file.path);
            if (file.name.len > 16384 or !std.unicode.utf8ValidateSlice(file.name)) return error.DocumentRestoreName;
        }
        return .{ .parsed = parsed };
    }
};
pub fn encode(a: std.mem.Allocator, files: []const Record) ![]const u8 {
    var budget: usize = 64;
    for (files) |file| {
        // JSON can escape each input byte. Refuse excess before allocating;
        // runtime collections still have no count ceiling and are not evicted.
        const requested = (file.path.len +| file.name.len) *| 6 +| 128;
        if (requested > limit -| budget) return error.DocumentRestoreMetadataLimit;
        budget += requested;
    }
    return std.json.Stringify.valueAlloc(a, Data{ .files = files }, .{ .whitespace = .indent_2 });
}
test "file restore metadata retains window grouping order names and missing paths" {
    const a = std.testing.allocator;
    const encoded = try encode(a, &.{ .{ .window = 0, .path = "/missing/report.md", .name = "本地 report", .active = true }, .{ .window = 900000, .path = "/private/second.zig" } });
    defer a.free(encoded);
    var snapshot = try Snapshot.parse(a, encoded);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 2), snapshot.parsed.value.files.len);
    try std.testing.expect(snapshot.parsed.value.files[0].active);
    try std.testing.expectEqualStrings("本地 report", snapshot.parsed.value.files[0].name);
    try std.testing.expectEqual(@as(u64, 900000), snapshot.parsed.value.files[1].window);
    try std.testing.expectError(error.InvalidPreviewPath, Snapshot.parse(a, "{\"files\":[{\"window\":0,\"path\":\"https://remote/a.md\"}]}"));
}
