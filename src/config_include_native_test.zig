const std = @import("std");
const include = @import("config_include.zig");
test "native Reader resolves real source, bounds reads and distinguishes missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const reader = include.nativeReader("");
    const path = (try reader.canonicalize(reader.context, a, "src/config_include.zig")).?;
    try std.testing.expect(std.fs.path.isAbsolute(path));
    const data = (try reader.read(reader.context, a, path, 64 * 1024)).?;
    try std.testing.expect(std.mem.startsWith(u8, data, "//! Bounded"));
    try std.testing.expectError(error.FileSize, reader.read(reader.context, a, path, 1));
    try std.testing.expectEqual(@as(?[]const u8, null), try reader.canonicalize(reader.context, a, "/letty-nonexistent-config-test/absent"));
    try std.testing.expectEqual(@as(?[]const u8, null), try reader.read(reader.context, a, "/letty-nonexistent-config-test/absent", 1));
}
