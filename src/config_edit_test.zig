const std = @import("std");
const edit = @import("config_edit.zig");
test "root theme editing preserves earlier directives comments unknown content and CRLF" {
    const source = "# keep verbatim\r\ntheme=older\r\nfuture-key = untouched\\opaque\r\n  theme\t= \t\"old theme\"   # preserve comment\r\n# theme=ignored\r\nfont-size=17\r\n";
    const result = try edit.replaceTheme(std.testing.allocator, source, "Maple Night 中");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("# keep verbatim\r\ntheme=older\r\nfuture-key = untouched\\opaque\r\n  theme\t= \t\"Maple Night 中\"   # preserve comment\r\n# theme=ignored\r\nfont-size=17\r\n", result);
}
test "missing directive appends without rewriting prior bytes or EOF newline style" {
    const cases = .{
        .{ "", "theme = \"night\"\n" },
        .{ "font-size=16", "font-size=16\ntheme = \"night\"\n" },
        .{ "# keep\r\nfont-size=16", "# keep\r\nfont-size=16\r\ntheme = \"night\"\r\n" },
        .{ "# theme=comment\n", "# theme=comment\ntheme = \"night\"\n" },
        .{ "theme-file=other\n", "theme-file=other\ntheme = \"night\"\n" },
    };
    inline for (cases) |case| {
        const result = try edit.replaceTheme(std.testing.allocator, case[0], "night");
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings(case[1], result);
    }
}
test "last theme empty or without newline is replaced and quoted hash remains part of name" {
    for ([_][]const u8{ "theme=", "theme=old", "theme=\"old # name\"" }) |source| {
        const result = try edit.replaceTheme(std.testing.allocator, source, "/tmp/a # theme");
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings("theme=\"/tmp/a # theme\"", result);
    }
}
test "JSON roots malformed text injected names and byte growth fail explicitly" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedJsonRoot, edit.replaceTheme(a, " \n{\"theme\":\"paper\"}", "night"));
    try std.testing.expectError(error.UnsupportedJsonRoot, edit.replaceTheme(a, "[]", "night"));
    try std.testing.expectError(error.InvalidConfigText, edit.replaceTheme(a, "theme=\xff", "night"));
    try std.testing.expectError(error.InvalidConfigText, edit.replaceTheme(a, "theme=\x00", "night"));
    for ([_][]const u8{ "", "injected\ncommand=oops", "bad\rname", "bad\"name", "bad\x00name", "\xff" }) |name|
        try std.testing.expectError(error.InvalidThemeName, edit.replaceTheme(a, "theme=paper", name));
    const full = try a.alloc(u8, edit.max_bytes);
    defer a.free(full);
    @memset(full, '#');
    try std.testing.expectError(error.FileSize, edit.replaceTheme(a, full, "night"));
}
fn allocationCase(a: std.mem.Allocator) !void {
    const result = try edit.replaceTheme(a, "# immutable\nunknown = 123\ntheme=paper\n", "Night 中");
    defer a.free(result);
    try std.testing.expectEqualStrings("# immutable\nunknown = 123\ntheme=\"Night 中\"\n", result);
}
test "allocation failure leaves caller source untouched with no partial output" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
test "snapshot equality checks exact bytes identity path and digest" {
    const identity: edit.Identity = .{ .device = 1, .inode = 2, .mode = 0o100640, .uid = 501, .gid = 20, .size = 3, .mtime_sec = 5, .mtime_nsec = 6, .ctime_sec = 7, .ctime_nsec = 8 };
    const first: edit.Snapshot = .{ .allocator = std.testing.allocator, .path = "/tmp/config", .bytes = "old", .sha256 = edit.digest("old"), .identity = identity };
    var second = first;
    try std.testing.expect(first.matches(second));
    second.bytes = "new";
    try std.testing.expect(!first.matches(second));
    second = first;
    second.identity.inode += 1;
    try std.testing.expect(!first.matches(second));
    second = first;
    second.identity.mode = 0o100600;
    try std.testing.expect(!first.matches(second));
    second = first;
    second.identity.mtime_nsec += 1;
    try std.testing.expect(!first.matches(second));
    second = first;
    second.sha256[0] ^= 1;
    try std.testing.expect(!first.matches(second));
}
test "native capture and checked save compile without performing filesystem operations" {
    std.mem.doNotOptimizeAway(&edit.Native.capture);
    std.mem.doNotOptimizeAway(&edit.Native.save);
}
