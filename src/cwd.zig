//! Decode OSC working-directory reports without interpreting remote paths locally.
const std = @import("std");
pub const Decoded = struct { host: [256:0]u8 = @splat(0), path: [4096:0]u8 = @splat(0), len: usize = 0 };
pub fn decode(raw: []const u8) ?Decoded {
    var out: Decoded = .{};
    var path = raw;
    const encoded = std.mem.startsWith(u8, raw, "file://");
    if (std.mem.startsWith(u8, raw, "file://")) {
        const rest = raw[7..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        if (slash >= out.host.len) return null;
        @memcpy(out.host[0..slash], rest[0..slash]);
        path = rest[slash..];
    } else if (!std.mem.startsWith(u8, raw, "/")) return null;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        var ch = path[i];
        if (encoded and ch == '%') {
            if (i + 2 >= path.len) return null;
            ch = std.fmt.parseInt(u8, path[i + 1 ..][0..2], 16) catch return null;
            i += 2;
        }
        if (ch < 32 or ch == 127 or out.len >= out.path.len - 1) return null;
        out.path[out.len] = ch;
        out.len += 1;
    }
    if (out.len == 0 or !std.unicode.utf8ValidateSlice(out.path[0..out.len])) return null;
    return out;
}
test "working directory URI decodes spaces and retains remote authority" {
    const d = decode("file://remote.example/tmp/a%20b").?;
    try std.testing.expectEqualStrings("remote.example", std.mem.sliceTo(&d.host, 0));
    try std.testing.expectEqualStrings("/tmp/a b", d.path[0..d.len]);
    try std.testing.expect(decode("file:///tmp/%00") == null);
    try std.testing.expect(decode("file:///tmp/%xx") == null);
    try std.testing.expect(decode("https://example/tmp") == null);
    const bare = decode("/tmp/100%").?;
    try std.testing.expectEqualStrings("/tmp/100%", bare.path[0..bare.len]);
    try std.testing.expectEqualStrings("/tmp", decode("/tmp").?.path[0..4]);
}
