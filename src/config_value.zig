//! Shared quoted-value handling for direct parsing and include expansion.
const std = @import("std");
pub fn unquote(raw: []const u8) []const u8 {
    const value = std.mem.trim(u8, raw, " \t\r");
    if (value.len < 2 or value[0] != '"') return value;
    var escaped = false;
    for (value[1..], 1..) |byte, index| {
        if (byte == '"' and !escaped) {
            const rest = std.mem.trim(u8, value[index + 1 ..], " \t\r");
            if (rest.len == 0 or rest[0] == '#') return value[1..index];
            return value;
        }
        escaped = byte == '\\' and !escaped;
    }
    return value;
}
test "quoted trailing comments preserve literal hashes and escaped quotes" {
    try std.testing.expectEqualStrings("path # name", unquote(" \"path # name\" # keep\r"));
    try std.testing.expectEqualStrings("a\\\"b", unquote("\"a\\\"b\" # comment"));
    try std.testing.expectEqualStrings("#123456", unquote("#123456"));
    try std.testing.expectEqualStrings("\"unfinished", unquote("\"unfinished"));
    try std.testing.expectEqualStrings("\"valid\" junk", unquote("\"valid\" junk"));
}
