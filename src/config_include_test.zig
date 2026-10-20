const std = @import("std");
const include = @import("config_include.zig");
const File = struct { path: []const u8, text: []const u8, alias: ?[]const u8 = null, denied: bool = false };
const Fs = struct {
    files: []const File,
    fn canonical(raw: *anyopaque, a: std.mem.Allocator, path: []const u8) !?[]const u8 {
        const self: *Fs = @ptrCast(@alignCast(raw));
        for (self.files) |file| if (std.mem.eql(u8, file.path, path)) {
            if (file.denied) return error.AccessDenied;
            return try a.dupe(u8, file.alias orelse file.path);
        };
        const normalized = try std.fs.path.resolveAlloc(a, &.{path});
        for (self.files) |file| if (std.mem.eql(u8, file.path, normalized)) {
            if (file.denied) return error.AccessDenied;
            return try a.dupe(u8, file.alias orelse file.path);
        };
        return null;
    }
    fn read(raw: *anyopaque, a: std.mem.Allocator, path: []const u8, limit: usize) !?[]const u8 {
        const self: *Fs = @ptrCast(@alignCast(raw));
        for (self.files) |file| if (std.mem.eql(u8, file.path, path)) {
            if (file.denied) return error.AccessDenied;
            if (file.text.len > limit) return error.FileSize;
            return try a.dupe(u8, file.text);
        };
        return null;
    }
    fn reader(self: *Fs) include.Reader {
        return .{ .context = self, .canonicalize = canonical, .read = read, .home = "/home/test" };
    }
};

test "nested includes keep exact expansion order, origin line and owned text" {
    var fs = Fs{ .files = &.{
        .{ .path = "/cfg/config", .text = "# comment\nfont-size=10\nconfig-file = child/colors\nfont-size = 20\n" },
        .{ .path = "/cfg/child/colors", .text = "background=#abcdef\nconfig-file=../extra\nfont-size=15" },
        .{ .path = "/cfg/extra", .text = "font-size=12" },
    } };
    var document = try include.load(std.testing.allocator, fs.reader(), "/cfg/config", .{}, null);
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, 5), document.entries.len);
    try std.testing.expectEqualStrings("10", document.entries[0].value);
    try std.testing.expectEqualStrings("#abcdef", document.entries[1].value);
    try std.testing.expectEqualStrings("12", document.entries[2].value);
    try std.testing.expectEqualStrings("15", document.entries[3].value);
    try std.testing.expectEqualStrings("20", document.entries[4].value);
    const from = document.entries[2].source;
    try std.testing.expectEqualStrings("/cfg/extra", from.path);
    try std.testing.expectEqual(@as(usize, 1), from.line);
    try std.testing.expectEqual(@as(usize, 2), from.chain.len);
    try std.testing.expectEqualStrings("/cfg/config", from.chain[0].path);
    try std.testing.expectEqual(@as(usize, 3), from.chain[0].line);
    try std.testing.expectEqual(@as(usize, 2), from.chain[1].line);
    try std.testing.expectEqual(@as(usize, 3), document.sources.len);
}
test "symlink aliases detect cycles and diagnostics retain complete origin" {
    var fs = Fs{ .files = &.{
        .{ .path = "/cfg/config", .text = "# one\nconfig-file=child\n" },
        .{ .path = "/cfg/child", .text = "# two\nconfig-file=alias" },
        .{ .path = "/cfg/alias", .text = "", .alias = "/cfg/config" },
    } };
    var diagnostic = include.Diagnostic{};
    try std.testing.expectError(error.IncludeCycle, include.load(std.testing.allocator, fs.reader(), "/cfg/config", .{}, &diagnostic));
    try std.testing.expectEqualStrings("/cfg/child", diagnostic.path[0..diagnostic.path_len]);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expectEqualStrings("config-file", diagnostic.key[0..diagnostic.key_len]);
    try std.testing.expectEqualStrings("/cfg/config:2\n", diagnostic.chain[0..diagnostic.chain_len]);
}
test "optional files skip only missing and remain present in source inventory" {
    var fs = Fs{ .files = &.{
        .{ .path = "/cfg/config", .text = "config-file = ?not-here\nconfig-file = \"?~/optional\"\nfont-size=16" },
    } };
    var document = try include.load(std.testing.allocator, fs.reader(), "/cfg/config", .{}, null);
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, 1), document.entries.len);
    try std.testing.expectEqual(@as(usize, 3), document.sources.len);
    try std.testing.expect(document.sources[1].missing and document.sources[1].optional);
    try std.testing.expectEqualStrings("/home/test/optional", document.sources[2].path);
    fs.files = &.{
        .{ .path = "/cfg/config", .text = "config-file=?denied" },
        .{ .path = "/cfg/denied", .text = "", .denied = true },
    };
    try std.testing.expectError(error.AccessDenied, include.load(std.testing.allocator, fs.reader(), "/cfg/config", .{}, null));
    fs.files = &.{.{ .path = "/cfg/config", .text = "config-file=required" }};
    try std.testing.expectError(error.ConfigNotFound, include.load(std.testing.allocator, fs.reader(), "/cfg/config", .{}, null));
}
test "an included file can be replayed after leaving stack, not treated as cycle" {
    var fs = Fs{ .files = &.{
        .{ .path = "/cfg/config", .text = "config-file=child\nfont-size=15\nconfig-file=child" },
        .{ .path = "/cfg/child", .text = "font-size=12" },
    } };
    var document = try include.load(std.testing.allocator, fs.reader(), "/cfg/config", .{}, null);
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, 3), document.entries.len);
    try std.testing.expectEqualStrings("12", document.entries[2].value);
}
test "depth, files, entries, and byte budgets fail transactionally" {
    var fs = Fs{ .files = &.{
        .{ .path = "/cfg/config", .text = "config-file=child\nfont-size=15" },
        .{ .path = "/cfg/child", .text = "font-size=12" },
    } };
    try std.testing.expectError(error.IncludeDepth, include.load(std.testing.allocator, fs.reader(), "/cfg/config", .{ .depth = 1 }, null));
    try std.testing.expectError(error.TooManyConfigFiles, include.load(std.testing.allocator, fs.reader(), "/cfg/config", .{ .files = 1 }, null));
    try std.testing.expectError(error.TooManyConfigEntries, include.load(std.testing.allocator, fs.reader(), "/cfg/config", .{ .entries = 1 }, null));
    try std.testing.expectError(error.ConfigFileSize, include.load(std.testing.allocator, fs.reader(), "/cfg/config", .{ .file_bytes = 4 }, null));
    try std.testing.expectError(error.ConfigTotalSize, include.load(std.testing.allocator, fs.reader(), "/cfg/config", .{ .total_bytes = 35 }, null));
}
test "parse failure and consumer semantic failure identify included line and chain" {
    var fs = Fs{ .files = &.{
        .{ .path = "/cfg/config", .text = "config-file=child" },
        .{ .path = "/cfg/child", .text = "# comment\nnot valid" },
    } };
    var diagnostic = include.Diagnostic{};
    try std.testing.expectError(error.InvalidConfigLine, include.load(std.testing.allocator, fs.reader(), "/cfg/config", .{}, &diagnostic));
    try std.testing.expectEqualStrings("/cfg/child", diagnostic.path[0..diagnostic.path_len]);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expectEqualStrings("/cfg/config:1\n", diagnostic.chain[0..diagnostic.chain_len]);
    fs.files = &.{
        .{ .path = "/cfg/config", .text = "config-file=child" },
        .{ .path = "/cfg/child", .text = "font-size=nan" },
    };
    var document = try include.load(std.testing.allocator, fs.reader(), "/cfg/config", .{}, null);
    defer document.deinit();
    const entry = document.entries[0];
    diagnostic.set(entry.source, entry.key, error.InvalidFontSize);
    try std.testing.expectEqualStrings("InvalidFontSize", diagnostic.reason[0..diagnostic.reason_len]);
    try std.testing.expectEqualStrings("/cfg/config:1\n", diagnostic.chain[0..diagnostic.chain_len]);
}
test "root JSON retained, included JSON and invalid text rejected" {
    var fs = Fs{ .files = &.{.{ .path = "/cfg/config", .text = "  {\"font_size\": 17}" }} };
    var document = try include.load(std.testing.allocator, fs.reader(), "/cfg/config", .{}, null);
    defer document.deinit();
    try std.testing.expectEqualStrings("  {\"font_size\": 17}", document.json.?);
    try std.testing.expectEqual(@as(usize, 0), document.entries.len);
    fs.files = &.{
        .{ .path = "/cfg/config", .text = "config-file=child" },
        .{ .path = "/cfg/child", .text = "{}" },
    };
    try std.testing.expectError(error.IncludedJsonUnsupported, include.load(std.testing.allocator, fs.reader(), "/cfg/config", .{}, null));
    fs.files = &.{.{ .path = "/cfg/config", .text = "font-size=\x00" }};
    try std.testing.expectError(error.InvalidConfigText, include.load(std.testing.allocator, fs.reader(), "/cfg/config", .{}, null));
}
test "relative names retain symlink dot-dot semantics until reader canonicalization" {
    var fs = Fs{ .files = &.{
        .{ .path = "/cfg/config", .text = "config-file=link/../sibling" },
        .{ .path = "/cfg/link/../sibling", .text = "", .alias = "/physical/sibling" },
        .{ .path = "/physical/sibling", .text = "font-size=12" },
        .{ .path = "/cfg/sibling", .text = "font-size=99" },
    } };
    var document = try include.load(std.testing.allocator, fs.reader(), "/cfg/config", .{}, null);
    defer document.deinit();
    try std.testing.expectEqualStrings("12", document.entries[0].value);
    try std.testing.expectEqualStrings("/physical/sibling", document.entries[0].source.path);
}

test "repeated includes charge total bytes each time and exact limit succeeds" {
    const root = "config-file=child\nconfig-file=child";
    const child = "font-size=12";
    var fs = Fs{ .files = &.{
        .{ .path = "/cfg/config", .text = root },
        .{ .path = "/cfg/child", .text = child },
    } };
    const total = root.len + 2 * child.len;
    try std.testing.expectError(error.ConfigTotalSize, include.load(std.testing.allocator, fs.reader(), "/cfg/config", .{ .total_bytes = total - 1 }, null));
    var document = try include.load(std.testing.allocator, fs.reader(), "/cfg/config", .{ .total_bytes = total }, null);
    defer document.deinit();
    try std.testing.expectEqual(total, document.total_bytes);
    try std.testing.expectEqual(@as(usize, 2), document.entries.len);
}

test "failed replacement leaves previously owned document and action bytes intact" {
    var fs = Fs{ .files = &.{
        .{ .path = "/cfg/config", .text = "config-file=child" },
        .{ .path = "/cfg/child", .text = "keybind=ctrl+b>t=text:A\\x00\\u{4e2d}\\e\nfont-size=15" },
    } };
    var previous = try include.load(std.testing.allocator, fs.reader(), "/cfg/config", .{}, null);
    defer previous.deinit();
    fs.files = &.{.{ .path = "/cfg/config", .text = "font-size=19\nconfig-file=missing" }};
    var diagnostic = include.Diagnostic{};
    try std.testing.expectError(error.ConfigNotFound, include.load(std.testing.allocator, fs.reader(), "/cfg/config", .{}, &diagnostic));
    try std.testing.expectEqualStrings("ctrl+b>t=text:A\\x00\\u{4e2d}\\e", previous.entries[0].value);
    try std.testing.expectEqualStrings("15", previous.entries[1].value);
    try std.testing.expectEqualStrings("/cfg/config", diagnostic.path[0..diagnostic.path_len]);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
}

fn allocationScenario(a: std.mem.Allocator) !void {
    var fs = Fs{ .files = &.{
        .{ .path = "/cfg/config", .text = "config-file=child\nfont-size=15" },
        .{ .path = "/cfg/child", .text = "config-file=leaf\nfont-size=14" },
        .{ .path = "/cfg/leaf", .text = "font-size=13" },
    } };
    var diagnostic = include.Diagnostic{};
    var document = try include.load(a, fs.reader(), "/cfg/config", .{}, &diagnostic);
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, 3), document.entries.len);
}
test "every expansion allocation failure rolls back without leaked partial document" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}

test "diagnostic chain truncation is bounded and explicitly reported" {
    const path: [4095]u8 = @splat('p');
    const chain: [5]include.Frame = @splat(.{ .path = &path, .line = 9999 });
    var diagnostic = include.Diagnostic{};
    diagnostic.set(.{ .path = "/cfg/leaf", .line = 7, .chain = &chain }, "theme", error.ThemeNotFound);
    try std.testing.expect(diagnostic.chain_truncated);
    try std.testing.expectEqual(diagnostic.chain.len, diagnostic.chain_len);
    try std.testing.expectEqualStrings("/cfg/leaf", diagnostic.path[0..diagnostic.path_len]);
    try std.testing.expectEqual(@as(usize, 7), diagnostic.line);
}
