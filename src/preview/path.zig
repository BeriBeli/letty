//! Local preview paths. No stat, read, shell expansion or URL policy changes.
const std = @import("std");
const Text = @import("../fixed_text.zig").Text;
pub const Resolved = struct { path: Text(4096) = .{}, line: usize = 0, column: usize = 0 };
fn valid(value: []const u8) bool {
    if (value.len == 0 or value.len >= 4096 or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |b| if (b < 32 or b == 127) return false;
    return true;
}
pub fn resolve(raw: []const u8, base: []const u8, local_host: []const u8) !Resolved {
    var value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) value = value[1 .. value.len - 1];
    if (!valid(value)) return error.InvalidPreviewPath;
    var decoded: @import("../cwd.zig").Decoded = undefined;
    if (std.mem.startsWith(u8, value, "file://")) {
        decoded = @import("../cwd.zig").decode(value) orelse return error.InvalidFileUri;
        const host = std.mem.sliceTo(&decoded.host, 0);
        if (host.len > 0 and !std.ascii.eqlIgnoreCase(host, "localhost") and !(local_host.len > 0 and std.ascii.eqlIgnoreCase(host, local_host))) return error.RemotePreviewUnsupported;
        value = decoded.path[0..decoded.len];
    } else if (std.mem.indexOf(u8, value, "://") != null) return error.UnsupportedPreviewScheme;
    if (value[0] != '/' and (!valid(base) or base[0] != '/')) return error.LocalPreviewBaseRequired;
    var combined: [8192]u8 = undefined;
    const joined = if (value[0] == '/') value else try std.fmt.bufPrint(&combined, "{s}/{s}", .{ base, value });
    var result: Resolved = .{};
    result.path.buf[0] = '/';
    result.path.len = 1;
    var marks: [512]usize = undefined;
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, joined, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (count > 0) {
                count -= 1;
                result.path.len = marks[count];
            }
            continue;
        }
        if (count == marks.len) return error.PreviewPathTooDeep;
        const previous = result.path.len;
        const separator: usize = if (previous > 1) 1 else 0;
        if (previous + separator + part.len >= result.path.buf.len) return error.PreviewPathTooLong;
        if (separator == 1) result.path.buf[result.path.len] = '/';
        result.path.len += separator;
        @memcpy(result.path.buf[result.path.len..][0..part.len], part);
        result.path.len += part.len;
        marks[count] = previous;
        count += 1;
    }
    return result;
}
/// Try only AFTER the complete literal filename was reported missing.
pub fn locationFallback(original: Resolved) ?Resolved {
    const path = original.path.text();
    const last = std.mem.lastIndexOfScalar(u8, path, ':') orelse return null;
    if (last == 0 or last + 1 == path.len) return null;
    const final = std.fmt.parseInt(usize, path[last + 1 ..], 10) catch return null;
    if (final == 0 or final > 1_000_000) return null;
    var out = original;
    var cut = last;
    out.line = final;
    if (std.mem.lastIndexOfScalar(u8, path[0..last], ':')) |previous| {
        const line = std.fmt.parseInt(usize, path[previous + 1 .. last], 10) catch 0;
        if (line > 0 and line <= 1_000_000) {
            cut = previous;
            out.line = line;
            out.column = final;
        }
    }
    out.path.set(path[0..cut]);
    return out;
}
pub fn directory(path: []const u8) []const u8 {
    const at = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return if (at == 0) "/" else path[0..at];
}
pub fn localImage(document_path: []const u8, target: []const u8, local_host: []const u8) !Resolved {
    const base = directory(document_path);
    const out = try resolve(target, base, local_host);
    const path = out.path.text();
    if (!std.mem.startsWith(u8, path, base) or (base.len > 1 and (path.len <= base.len or path[base.len] != '/'))) return error.PreviewResourceOutsideDirectory;
    return out;
}
test "preview paths preserve literal colon percent spaces and local URI" {
    try std.testing.expectEqualStrings("/a/中文 100%:12", (try resolve("./中文 100%:12", "/a", "host")).path.text());
    try std.testing.expectEqualStrings("/a/b c", (try resolve("file://localhost/a/b%20c", "", "host")).path.text());
    try std.testing.expectEqualStrings("/a/d", (try resolve("../d", "/a/b", "")).path.text());
    try std.testing.expectError(error.RemotePreviewUnsupported, resolve("file://remote/a", "/", "host"));
    try std.testing.expectError(error.UnsupportedPreviewScheme, resolve("https://a/b", "/", ""));
    try std.testing.expectError(error.InvalidFileUri, resolve("file:///a/%00", "/", ""));
    try std.testing.expectError(error.LocalPreviewBaseRequired, resolve("relative", "", ""));
}
test "preview location fallback and image directory isolation" {
    const full = try resolve("/a/file:12:3", "", "");
    const fallback = locationFallback(full).?;
    try std.testing.expectEqualStrings("/a/file", fallback.path.text());
    try std.testing.expectEqual(@as(usize, 12), fallback.line);
    try std.testing.expectEqual(@as(usize, 3), fallback.column);
    try std.testing.expect(locationFallback(try resolve("/a/file:no", "", "")) == null);
    try std.testing.expectEqualStrings("/a/img.png", (try localImage("/a/doc.md", "./img.png", "")).path.text());
    try std.testing.expectError(error.PreviewResourceOutsideDirectory, localImage("/a/doc.md", "../img.png", ""));
}
pub fn percentDecoded(value: []const u8) !Text(4096) {
    var out: Text(4096) = .{};
    var at: usize = 0;
    while (at < value.len) : (at += 1) {
        var byte = value[at];
        if (byte == '%') {
            if (at + 2 >= value.len) return error.InvalidPreviewEscape;
            byte = std.fmt.parseInt(u8, value[at + 1 ..][0..2], 16) catch return error.InvalidPreviewEscape;
            at += 2;
        }
        if (out.len >= out.buf.len or byte < 32 or byte == 127) return error.InvalidPreviewEscape;
        out.buf[out.len] = byte;
        out.len += 1;
    }
    if (!std.unicode.utf8ValidateSlice(out.text())) return error.InvalidPreviewEscape;
    return out;
}
