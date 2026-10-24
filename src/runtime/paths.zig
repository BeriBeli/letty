//! Local OSC 7/OSC 8 and printed-path handling; no remote file service.
const std = @import("std");
pub fn directory(a: std.mem.Allocator, raw: ?[]const u8, fallback: []const u8) ![]const u8 {
    const value = raw orelse return a.dupe(u8, fallback);
    if (std.fs.path.isAbsolute(value)) return a.dupe(u8, value);
    if (std.mem.startsWith(u8, value, "file://")) {
        const rest = value[7..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return a.dupe(u8, fallback);
        if (!localAuthority(rest[0..slash])) return a.dupe(u8, fallback);
        const path = decode(a, rest[slash..]) catch return a.dupe(u8, fallback);
        if (std.fs.path.isAbsolute(path)) return path;
        a.free(path);
    }
    return a.dupe(u8, fallback);
}
pub fn decode(a: std.mem.Allocator, value: []const u8) ![]u8 {
    if (value.len > 65536) return error.PathLimit;
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        var ch = value[i];
        if (ch == '%') {
            if (i + 2 >= value.len) return error.InvalidUri;
            ch = std.fmt.parseInt(u8, value[i + 1 .. i + 3], 16) catch return error.InvalidUri;
            i += 2;
        }
        if (ch == 0) return error.InvalidUri;
        try result.append(a, ch);
    }
    return result.toOwnedSlice(a);
}
pub fn stripLine(raw: []const u8) []const u8 {
    var value = raw;
    for (0..2) |_| {
        const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse break;
        const tail = value[colon + 1 ..];
        if (tail.len == 0) break;
        var numeric = true;
        for (tail) |ch| if (!std.ascii.isDigit(ch)) {
            numeric = false;
            break;
        };
        if (!numeric) break;
        value = value[0..colon];
    }
    return value;
}
pub fn resolve(a: std.mem.Allocator, link: []const u8, cwd: []const u8, home: []const u8) ![]const u8 {
    const clean = stripLine(link);
    if (std.mem.startsWith(u8, clean, "file://")) {
        const rest = clean[7..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidUri;
        if (!localAuthority(rest[0..slash])) return error.RemoteFileUri;
        return decode(a, rest[slash..]);
    }
    if (std.mem.startsWith(u8, clean, "~/")) return std.fs.path.resolve(a, &.{ home, clean[2..] });
    return std.fs.path.resolve(a, &.{ cwd, clean });
}
pub fn web(link: []const u8) bool {
    return std.mem.startsWith(u8, link, "https://") or std.mem.startsWith(u8, link, "http://") or std.mem.startsWith(u8, link, "mailto:");
}
pub fn image(path: []const u8) bool {
    const ext = std.fs.path.extension(stripLine(path));
    for ([_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp" }) |suffix| if (std.ascii.eqlIgnoreCase(ext, suffix)) return true;
    return false;
}
test "OSC cwd percent decoding and printed line suffixes remain local paths" {
    const a = std.testing.allocator;
    const cwd = try directory(a, "file://localhost/tmp/中文%20space", "/fallback");
    defer a.free(cwd);
    try std.testing.expectEqualStrings("/tmp/中文 space", cwd);
    const file = try resolve(a, "src/a.zig:12:3", cwd, "/home/private");
    defer a.free(file);
    try std.testing.expectEqualStrings("/tmp/中文 space/src/a.zig", file);
    try std.testing.expectError(error.InvalidUri, decode(a, "/tmp/%00bad"));
    try std.testing.expect(!web("javascript:alert(1)") and image("x.PNG:23"));
}

fn localAuthority(host: []const u8) bool {
    if (host.len == 0 or std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    var name: [256]u8 = @splat(0);
    if (gethostname(&name, name.len) != 0) return false;
    return std.ascii.eqlIgnoreCase(host, std.mem.sliceTo(&name, 0));
}
extern "c" fn gethostname([*]u8, usize) c_int;
test "remote file authorities do not become local working directories or file targets" {
    const a = std.testing.allocator;
    const value = try directory(a, "file://unknown.remote.invalid/tmp/foreign", "/fallback");
    defer a.free(value);
    try std.testing.expectEqualStrings("/fallback", value);
    try std.testing.expectError(error.RemoteFileUri, resolve(a, "file://unknown.remote.invalid/etc/passwd", "/tmp", "/home"));
}
