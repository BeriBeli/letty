const std = @import("std");
const browser = @import("theme_browser.zig");
const edit = @import("config_edit.zig");
const config = @import("config.zig");
const Dir = struct { path: []const u8, names: []const []const u8, denied: bool = false };
const File = struct { path: []const u8, bytes: []const u8 };
const Fs = struct {
    dirs: []const Dir = &.{},
    files: []const File = &.{},
    reads: usize = 0,
    fn canonical(raw: *anyopaque, a: std.mem.Allocator, path: []const u8) !?[]const u8 {
        const self: *Fs = @ptrCast(@alignCast(raw));
        const normalized = try std.fs.path.resolveAlloc(a, &.{path});
        for (self.dirs) |dir| if (std.mem.eql(u8, dir.path, normalized)) {
            if (dir.denied) return error.AccessDenied;
            return try a.dupe(u8, dir.path);
        };
        for (self.files) |file| if (std.mem.eql(u8, file.path, normalized)) return try a.dupe(u8, file.path);
        return null;
    }
    fn scan(raw: *anyopaque, _: std.mem.Allocator, path: []const u8, limit: usize, visitor: browser.Visitor) !browser.ScanResult {
        const self: *Fs = @ptrCast(@alignCast(raw));
        for (self.dirs) |dir| if (std.mem.eql(u8, dir.path, path)) {
            var count: usize = 0;
            for (dir.names) |name| {
                if (count == limit) return .{ .scanned = count, .truncated = true };
                count += 1;
                visitor.visit(visitor.context, name) catch |err| {
                    if (err == error.CatalogLimit) return .{ .scanned = count, .truncated = true };
                    return err;
                };
            }
            return .{ .scanned = count };
        };
        return error.ThemeDirectoryNotFound;
    }
    fn read(raw: *anyopaque, a: std.mem.Allocator, path: []const u8, limit: usize) !?[]const u8 {
        const self: *Fs = @ptrCast(@alignCast(raw));
        self.reads += 1;
        for (self.files) |file| if (std.mem.eql(u8, file.path, path)) {
            if (file.bytes.len > limit) return error.FileSize;
            return try a.dupe(u8, file.bytes);
        };
        return null;
    }
    fn scanner(self: *Fs) browser.Reader {
        return .{ .context = self, .canonicalize = canonical, .scan = scan };
    }
    fn reader(self: *Fs) config.includes.Reader {
        return .{ .context = self, .canonicalize = canonical, .read = read, .home = "/home/test" };
    }
};
fn snapshot(bytes: []const u8) edit.Snapshot {
    return .{ .allocator = std.testing.allocator, .path = "/cfg/config", .bytes = bytes, .sha256 = edit.digest(bytes), .identity = .{ .device = 1, .inode = 2, .mode = 0o100600, .uid = 501, .gid = 20, .size = bytes.len, .mtime_sec = 0, .mtime_nsec = 0, .ctime_sec = 0, .ctime_nsec = 0 } };
}
test "catalog reads configured and bundled roots with owned names sorted search and physical identity" {
    var fs: Fs = .{ .dirs = &.{
        .{ .path = "/cfg/themes", .names = &.{ "Night 中", "bad\xff", "bad/name", "Day" } },
        .{ .path = "/bundle/themes", .names = &.{"Night 中"} },
    } };
    var catalog = try browser.Catalog.scan(std.testing.allocator, &.{ .{ .directory = "/cfg/themes", .origin = .user }, .{ .directory = "/bundle/themes", .origin = .bundled }, .{ .directory = "/missing", .origin = .user } }, fs.scanner(), .{});
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 5), catalog.entries.len);
    try std.testing.expectEqual(@as(usize, 5), catalog.scanned);
    try std.testing.expect(!catalog.truncated);
    var output: [8]usize = undefined;
    const count = try catalog.filter("nIGHT", &output);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(!std.mem.eql(u8, catalog.entries[output[0]].selector, catalog.entries[output[1]].selector));
    try std.testing.expectEqual(@as(usize, 2), try catalog.filter("中", &output));
    try std.testing.expectEqual(@as(usize, 1), try catalog.filter("paper", &output));
    try std.testing.expectError(error.ResultBufferTooSmall, catalog.filter("", output[0..1]));
}
test "catalog entry name byte and visited-entry limits are explicit bounded partial results" {
    var fs: Fs = .{ .dirs = &.{.{ .path = "/themes", .names = &.{ "a", "b", "c", "d" } }} };
    for ([_]browser.Limits{ .{ .entries = 1 }, .{ .entries = 2 }, .{ .scanned = 2 }, .{ .name_bytes = 1 } }) |limits| {
        var catalog = try browser.Catalog.scan(std.testing.allocator, &.{.{ .directory = "/themes", .origin = .user }}, fs.scanner(), limits);
        defer catalog.deinit();
        try std.testing.expect(catalog.truncated);
        try std.testing.expect(catalog.entries.len <= limits.entries);
        try std.testing.expect(catalog.scanned <= limits.scanned);
    }
    try std.testing.expectError(error.InvalidCatalogLimits, browser.Catalog.scan(std.testing.allocator, &.{}, fs.scanner(), .{ .entries = 0 }));
    try std.testing.expectError(error.ThemeDirectoryNotFound, browser.Catalog.scan(std.testing.allocator, &.{.{ .directory = "/missing", .origin = .user, .optional = false }}, fs.scanner(), .{}));
    fs.dirs = &.{.{ .path = "/denied", .names = &.{}, .denied = true }};
    try std.testing.expectError(error.AccessDenied, browser.Catalog.scan(std.testing.allocator, &.{.{ .directory = "/denied", .origin = .user }}, fs.scanner(), .{}));
}
test "preview uses owned in-memory edited root and only copies visual fields without writing" {
    var fs: Fs = .{ .files = &.{.{ .path = "/themes/night", .bytes = "background=#112233\nforeground=#abcdef\nui-accent=#445566" }} };
    const old = snapshot("# keep\nfont-size=17\ntheme=paper\nkeybind=ctrl+t=new_tab\n");
    var candidate = try browser.Candidate.prepare(std.testing.allocator, old, .{ .name = "Night", .selector = "/themes/night", .origin = .user }, fs.reader(), null);
    defer candidate.deinit();
    const current: config.Config = .{ .font_size = 31, .padding_x = .{ 9, 10 }, .command = "unchanged command" };
    const next = candidate.preview(current, true);
    try std.testing.expectEqual(@as(u24, 0x112233), next.background);
    try std.testing.expectEqual(@as(f32, 31), next.font_size);
    try std.testing.expectEqual([2]f32{ 9, 10 }, next.padding_x);
    try std.testing.expectEqualStrings("unchanged command", next.command);
    try std.testing.expectEqual(@as(usize, 0), next.keybinds.len);
    try std.testing.expectEqualStrings("# keep\nfont-size=17\ntheme=paper\nkeybind=ctrl+t=new_tab\n", old.bytes);
    try std.testing.expectEqual(@as(usize, 1), fs.reads);
    try std.testing.expectEqualStrings("/themes/night", next.forAppearance(false).theme);
}
test "include override and JSON reject preview explicitly without a fake successful selection" {
    var fs: Fs = .{ .files = &.{
        .{ .path = "/themes/night", .bytes = "background=#112233" },
        .{ .path = "/cfg/child", .bytes = "theme=paper" },
    } };
    const selected: browser.Entry = .{ .name = "Night", .selector = "/themes/night", .origin = .bundled };
    try std.testing.expectError(error.ThemeOverriddenByInclude, browser.Candidate.prepare(std.testing.allocator, snapshot("theme=paper\nconfig-file=child"), selected, fs.reader(), null));
    try std.testing.expectError(error.UnsupportedJsonRoot, browser.Candidate.prepare(std.testing.allocator, snapshot("{\"theme\":\"paper\"}"), selected, fs.reader(), null));
    var candidate = try browser.Candidate.prepare(std.testing.allocator, snapshot("config-file=child\ntheme=paper"), selected, fs.reader(), null);
    defer candidate.deinit();
}
test "controller preview cancel and apply have distinct ownership and no implicit save" {
    var fs: Fs = .{ .files = &.{.{ .path = "/themes/night", .bytes = "background=#112233" }} };
    const candidate = try browser.Candidate.prepare(std.testing.allocator, snapshot("theme=paper"), .{ .name = "Night", .selector = "/themes/night", .origin = .user }, fs.reader(), null);
    var controller: browser.Controller = .{};
    defer controller.deinit();
    try std.testing.expectError(error.NoThemePreview, controller.apply());
    try controller.preview(candidate);
    try std.testing.expectEqual(browser.Phase.preview, controller.phase);
    var applied = try controller.apply();
    defer applied.deinit();
    try std.testing.expect(controller.candidate == null);
    try std.testing.expectEqual(browser.Phase.applied, controller.phase);
    try std.testing.expectEqual(@as(u24, 0x112233), applied.cfg.background);
    var cancelled: browser.Controller = .{};
    const original: config.Config = .{ .font_size = 29 };
    try cancelled.preview(try browser.Candidate.prepare(std.testing.allocator, snapshot("theme=paper"), .{ .name = "Night", .selector = "/themes/night", .origin = .user }, fs.reader(), null));
    // The root restores this original before cancel releases preview storage.
    try std.testing.expectEqual(@as(f32, 29), original.font_size);
    cancelled.cancel();
    try std.testing.expectEqual(browser.Phase.cancelled, cancelled.phase);
    try std.testing.expect(cancelled.candidate == null);
}
fn allocationCase(gpa: std.mem.Allocator) !void {
    var fs: Fs = .{ .dirs = &.{.{ .path = "/themes", .names = &.{ "Night", "Day" } }}, .files = &.{.{ .path = "/themes/Night", .bytes = "background=#112233" }} };
    var catalog = try browser.Catalog.scan(gpa, &.{.{ .directory = "/themes", .origin = .user }}, fs.scanner(), .{});
    defer catalog.deinit();
    var candidate = try browser.Candidate.prepare(gpa, snapshot("theme=paper"), .{ .name = "Night", .selector = "/themes/Night", .origin = .user }, fs.reader(), null);
    defer candidate.deinit();
}
test "all catalog and preview allocation failures release owned candidate resources" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
test "native bounded directory enumeration compiles without reading a user directory" {
    std.mem.doNotOptimizeAway(&browser.nativeReader);
}

test "candidate preview transfers theme font features while preserving temporary zoom" {
    var fs: Fs = .{ .files = &.{.{ .path = "/themes/night", .bytes = "background=#112233\nfont-feature=ss01=3,calt=0\nfont-ligatures=false" }} };
    var candidate = try browser.Candidate.prepare(std.testing.allocator, snapshot("theme=paper"), .{ .name = "Night", .selector = "/themes/night", .origin = .user }, fs.reader(), null);
    defer candidate.deinit();
    const next = candidate.preview(.{ .font_size = 27, .font_ligatures = true }, true);
    try std.testing.expectEqual(@as(f32, 27), next.font_size);
    try std.testing.expect(!next.font_ligatures);
    try std.testing.expect(std.meta.eql(candidate.cfg.font_features, next.font_features));
}

test "theme preview preserves quoted inline comment through configuration reload" {
    var fs: Fs = .{ .files = &.{.{ .path = "/themes/night", .bytes = "background=#112233" }} };
    var candidate = try browser.Candidate.prepare(std.testing.allocator, snapshot("# keep\ntheme = \"paper\"  # root comment\n"), .{ .name = "Night", .selector = "/themes/night", .origin = .user }, fs.reader(), null);
    defer candidate.deinit();
    try std.testing.expectEqualStrings("# keep\ntheme = \"/themes/night\"  # root comment\n", candidate.replacement);
    try std.testing.expectEqual(@as(u24, 0x112233), candidate.cfg.background);
}
