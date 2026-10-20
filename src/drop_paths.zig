//! File drops become quoted text for a recognized shell. They never append Return, invoke
//! a shell, read files, resolve symlinks, or accept remote file authorities.
const std = @import("std");
pub const Shell = enum { unknown, posix, fish };
/// Only the shell actually launched is useful here; command overrides can run
/// another program or a remote shell and therefore never inherit quoting rules.
pub fn classifyShell(shell: []const u8, command: ?[]const u8) Shell {
    if (command) |value| if (value.len > 0) return .unknown;
    const name = std.fs.path.basename(shell);
    for ([_][]const u8{ "sh", "bash", "zsh", "ksh", "dash", "ash" }) |known|
        if (std.mem.eql(u8, name, known)) return .posix;
    return if (std.mem.eql(u8, name, "fish")) .fish else .unknown;
}
pub const max_paths = 16;
pub const max_path_bytes = 4095;
pub const max_output_bytes = 64 * 1024;
fn validate(path: []const u8) !void {
    if (path.len == 0 or path.len > max_path_bytes or path[0] != '/' or !std.unicode.utf8ValidateSlice(path)) return error.InvalidDropPath;
    for (path, 0..) |byte, i| {
        if (byte < 0x20 or byte == 0x7f) return error.InvalidDropPath;
        // The validated UTF-8 spelling of C1 controls is exactly C2 80..9F.
        if (byte == 0xc2 and i + 1 < path.len and path[i + 1] >= 0x80 and path[i + 1] <= 0x9f) return error.InvalidDropPath;
    }
}
pub fn quotePaths(gpa: std.mem.Allocator, paths: []const []const u8) ![]u8 {
    return quoteForShell(gpa, paths, .posix);
}
pub fn quoteForShell(gpa: std.mem.Allocator, paths: []const []const u8, shell: Shell) ![]u8 {
    if (shell == .unknown) return error.UnsupportedDropShell;
    if (paths.len == 0 or paths.len > max_paths) return error.DropPathLimit;
    var size: usize = 0;
    for (paths) |path| {
        try validate(path);
        // One pair of quotes and a trailing space per pathname.
        size += path.len + 3;
        for (path) |byte| {
            if (byte == '\'') size += if (shell == .fish) 1 else 3;
            if (byte == '\\' and shell == .fish) size += 1;
        }
        if (size > max_output_bytes) return error.DropTextLimit;
    }
    const output = try gpa.alloc(u8, size);
    var at: usize = 0;
    for (paths) |path| {
        output[at] = '\'';
        at += 1;
        for (path) |byte| {
            if (byte == '\'') {
                if (shell == .fish) {
                    @memcpy(output[at..][0..2], "\\'");
                    at += 2;
                } else {
                    @memcpy(output[at..][0..4], "'\\''");
                    at += 4;
                }
            } else {
                if (shell == .fish and byte == '\\') {
                    output[at] = '\\';
                    at += 1;
                }
                output[at] = byte;
                at += 1;
            }
        }
        output[at] = '\'';
        output[at + 1] = ' ';
        at += 2;
    }
    std.debug.assert(at == size);
    return output;
}
fn uriPath(gpa: std.mem.Allocator, uri: []const u8) ![]u8 {
    if (uri.len > max_path_bytes * 3 + 32 or !std.mem.startsWith(u8, uri, "file://")) return error.InvalidDropUri;
    const rest = uri[7..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidDropUri;
    const host = rest[0..slash];
    if (host.len > 0 and !std.ascii.eqlIgnoreCase(host, "localhost")) return error.RemoteDropUri;
    const encoded = rest[slash..];
    if (std.mem.indexOfAny(u8, encoded, "?#\x00\r\n") != null) return error.InvalidDropUri;
    // Admission before allocating: even a fully percent-encoded path is <=4095.
    var length: usize = 0;
    var index: usize = 0;
    while (index < encoded.len) {
        if (encoded[index] == '%') {
            if (encoded.len - index < 3 or !std.ascii.isHex(encoded[index + 1]) or !std.ascii.isHex(encoded[index + 2])) return error.InvalidDropUri;
            index += 3;
        } else index += 1;
        length += 1;
        if (length > max_path_bytes) return error.DropPathLimit;
    }
    const path = try gpa.alloc(u8, length);
    errdefer gpa.free(path);
    index = 0;
    var at: usize = 0;
    while (index < encoded.len) : (at += 1) {
        if (encoded[index] == '%') {
            path[at] = std.fmt.parseInt(u8, encoded[index + 1 ..][0..2], 16) catch return error.InvalidDropUri;
            index += 3;
        } else {
            path[at] = encoded[index];
            index += 1;
        }
    }
    try validate(path);
    return path;
}
pub fn quoteUris(gpa: std.mem.Allocator, uris: []const []const u8) ![]u8 {
    return quoteUrisForShell(gpa, uris, .posix);
}
pub fn quoteUrisForShell(gpa: std.mem.Allocator, uris: []const []const u8, shell: Shell) ![]u8 {
    if (uris.len == 0 or uris.len > max_paths) return error.DropPathLimit;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var paths: [max_paths][]const u8 = undefined;
    for (uris, 0..) |uri, i| paths[i] = try uriPath(arena.allocator(), uri);
    return quoteForShell(gpa, paths[0..uris.len], shell);
}

test "drops quote spaces quotes metacharacters and Unicode without Return" {
    const a = std.testing.allocator;
    const got = try quotePaths(a, &.{ "/tmp/a b", "/tmp/it's;$(no)中文", "/tmp/-x" });
    defer a.free(got);
    try std.testing.expectEqualStrings("'/tmp/a b' '/tmp/it'\\''s;$(no)中文' '/tmp/-x' ", got);
    try std.testing.expect(std.mem.indexOfAny(u8, got, "\r\n\x00") == null);
}
test "local file URI decoding preserves plus and rejects remote malformed or control paths" {
    const a = std.testing.allocator;
    const got = try quoteUris(a, &.{ "file:///tmp/a%20b%27c", "file://LOCALHOST/tmp/%E4%B8%AD%E6%96%87+plus" });
    defer a.free(got);
    try std.testing.expectEqualStrings("'/tmp/a b'\\''c' '/tmp/中文+plus' ", got);
    for ([_][]const u8{ "https://host/a", "file:///tmp/a%", "file:///tmp/a%G0", "file:///tmp/a#fragment", "file:///tmp/a?query" }) |uri|
        try std.testing.expectError(error.InvalidDropUri, uriPath(a, uri));
    for ([_][]const u8{ "file:///tmp/a%00", "file:///tmp/a%0a", "file:///tmp/%ff", "file:///tmp/%C2%9B" }) |uri|
        try std.testing.expectError(error.InvalidDropPath, uriPath(a, uri));
    try std.testing.expectError(error.RemoteDropUri, quoteUris(a, &.{"file://remote/tmp/a"}));
}
test "drop admission rejects an entire mixed list and enforces all bounds" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidDropPath, quotePaths(a, &.{ "/tmp/ok", "relative" }));
    try std.testing.expectError(error.InvalidDropPath, quotePaths(a, &.{"/tmp/a\nreturn"}));
    try std.testing.expectError(error.InvalidDropPath, quotePaths(a, &.{"/tmp/a\u{0085}next"}));
    try std.testing.expectError(error.DropPathLimit, quotePaths(a, &.{}));
    const many: [17][]const u8 = @splat("/tmp/a");
    try std.testing.expectError(error.DropPathLimit, quotePaths(a, &many));
    const path = try a.alloc(u8, max_path_bytes);
    defer a.free(path);
    @memset(path, '\'');
    path[0] = '/';
    const repeated: [max_paths][]const u8 = @splat(path);
    try std.testing.expectError(error.DropTextLimit, quotePaths(a, &repeated));
}

/// Bounded raw preview for unknown shells or remote URI authorities. These
/// bytes are diagnostic text only and must never be passed to terminal paste.
pub fn preview(gpa: std.mem.Allocator, entries: []const []const u8, uris: bool) ![]u8 {
    if (entries.len == 0 or entries.len > max_paths) return error.DropPathLimit;
    var size: usize = 0;
    for (entries) |entry| {
        if (uris) {
            if (!std.mem.startsWith(u8, entry, "file://") or entry.len > max_path_bytes * 3 + 32 or !std.unicode.utf8ValidateSlice(entry)) return error.InvalidDropUri;
            for (entry) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidDropUri;
        } else try validate(entry);
        size += entry.len + 1;
        if (size > max_output_bytes) return error.DropTextLimit;
    }
    const out = try gpa.alloc(u8, size);
    var at: usize = 0;
    for (entries) |entry| {
        @memcpy(out[at..][0..entry.len], entry);
        at += entry.len;
        out[at] = '\n';
        at += 1;
    }
    return out;
}
test "drop shell classification uses actual launch and refuses command overrides" {
    try std.testing.expectEqual(Shell.posix, classifyShell("/bin/bash", null));
    try std.testing.expectEqual(Shell.fish, classifyShell("/usr/local/bin/fish", ""));
    try std.testing.expectEqual(Shell.unknown, classifyShell("/bin/sh", "ssh remote"));
    try std.testing.expectEqual(Shell.unknown, classifyShell("/bin/nushell", null));
}
test "fish escapes quote and backslash without POSIX quote splicing" {
    const a = std.testing.allocator;
    const out = try quoteForShell(a, &.{"/tmp/a'\\b;$(no)中文"}, .fish);
    defer a.free(out);
    try std.testing.expectEqualStrings("'/tmp/a\\'\\\\b;$(no)中文' ", out);
    try std.testing.expectError(error.UnsupportedDropShell, quoteForShell(a, &.{"/tmp/a"}, .unknown));
}
test "drop raw fallback preserves paths and remote URI without shell text" {
    const a = std.testing.allocator;
    const out = try preview(a, &.{"file://remote/tmp/a%20b"}, true);
    defer a.free(out);
    try std.testing.expectEqualStrings("file://remote/tmp/a%20b\n", out);
    try std.testing.expectError(error.InvalidDropUri, preview(a, &.{"file://remote/tmp/a\nB"}, true));
}
