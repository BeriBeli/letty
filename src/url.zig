//! The opener accepts explicit HTTP(S) targets, with no shell interpretation.
const std = @import("std");
pub fn allowed(value: []const u8) bool {
    const prefix: usize = if (value.len >= 8 and std.ascii.eqlIgnoreCase(value[0..8], "https://")) 8 else if (value.len >= 7 and std.ascii.eqlIgnoreCase(value[0..7], "http://")) 7 else return false;
    if (value.len <= prefix or value.len > 2048 or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (byte <= 0x20 or byte == 0x7f) return false;
    const host = std.mem.sliceTo(value[prefix..], '/');
    return host.len > 0;
}
test "URL opener rejects non-web schemes, controls and empty authorities" {
    try std.testing.expect(allowed("https://example.com/path?q=中文"));
    try std.testing.expect(allowed("HTTP://example.com"));
    for ([_][]const u8{ "file:///etc/passwd", "javascript:alert(1)", "https://", "https:///path", "https://example.com\n--flag", "https://bad space" }) |bad| try std.testing.expect(!allowed(bad));
}
