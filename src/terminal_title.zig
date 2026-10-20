//! A profile selects launch settings; it is never the automatic tab title.
const std = @import("std");
pub fn automatic(title: []const u8, cwd: []const u8, home: []const u8, initial: []const u8) []const u8 {
    if (title.len > 0) return title;
    if (cwd.len > 0) return if (home.len > 0 and std.mem.eql(u8, cwd, home)) "~" else cwd;
    return if (initial.len > 0) initial else "Terminal";
}
pub fn validPrefix(text: []const u8) []const u8 {
    var n = text.len;
    while (n > 0 and !std.unicode.utf8ValidateSlice(text[0..n])) n -= 1;
    return text[0..n];
}
test "automatic titles prefer terminal reports, then directory, then launch command" {
    try std.testing.expectEqualStrings("vim file.txt", automatic("vim file.txt", "/tmp", "/home/me", "zsh"));
    try std.testing.expectEqualStrings("~", automatic("", "/home/me", "/home/me", "zsh"));
    try std.testing.expectEqualStrings("/tmp/项目 space", automatic("", "/tmp/项目 space", "/home/me", "zsh"));
    try std.testing.expectEqualStrings("/", automatic("", "/", "/home/me", "zsh"));
    try std.testing.expectEqualStrings("ssh example", automatic("", "", "/home/me", "ssh example"));
    try std.testing.expectEqualStrings("Terminal", automatic("", "", "", ""));
}
test "bounded terminal titles keep a valid UTF8 prefix" {
    const text = "work/项目";
    try std.testing.expectEqualStrings("work/项", validPrefix(text[0 .. text.len - 1]));
    try std.testing.expectEqualStrings(text, validPrefix(text));
}
