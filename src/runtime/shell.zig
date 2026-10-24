//! Port of Kero's shell quoting and command-launch construction.
const std = @import("std");
pub fn quote(a: std.mem.Allocator, name: []const u8, value: []const u8) ![]const u8 {
    if (value.len > 0) {
        var safe = true;
        for (value) |ch| if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "-_./=:,+@%", ch) == null) {
            safe = false;
            break;
        };
        if (safe) return a.dupe(u8, value);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.append(a, '\'');
    for (value) |ch| {
        if (ch == '\'') try out.appendSlice(a, if (std.mem.eql(u8, name, "fish")) "\\'" else if (std.mem.eql(u8, name, "pwsh") or std.mem.eql(u8, name, "powershell")) "''" else "'\\''") else if (ch == '\\' and std.mem.eql(u8, name, "fish")) try out.appendSlice(a, "\\\\") else try out.append(a, ch);
    }
    try out.append(a, '\'');
    return out.toOwnedSlice(a);
}
pub fn join(a: std.mem.Allocator, name: []const u8, args: []const []const u8) ![]const u8 {
    if (args.len == 1 and std.mem.indexOfAny(u8, args[0], " ;|&") != null) return a.dupe(u8, args[0]);
    var parts: std.ArrayList([]const u8) = .empty;
    defer {
        for (parts.items) |p| a.free(p);
        parts.deinit(a);
    }
    for (args) |arg| {
        const part = try quote(a, name, arg);
        parts.append(a, part) catch |err| {
            a.free(part);
            return err;
        };
    }
    return std.mem.join(a, " ", parts.items);
}
pub fn command(a: std.mem.Allocator, shell_path: []const u8, args: []const []const u8) ![]const u8 {
    const name = std.fs.path.basename(shell_path);
    const joined = try join(a, name, args);
    defer a.free(joined);
    const again = try quote(a, name, shell_path);
    defer a.free(again);
    return std.fmt.allocPrint(a, "printf '\\033]133;C\\007'; {s}; printf '\\033]133;D;%s\\007' {s}; exec {s} -l", .{ joined, if (std.mem.eql(u8, name, "fish")) "$status" else "\"$?\"", again });
}
test "shell quoting preserves metacharacters and fish backslashes" {
    const a = std.testing.allocator;
    const q = try quote(a, "sh", "a'b $(bad)");
    defer a.free(q);
    try std.testing.expectEqualStrings("'a'\\''b $(bad)'", q);
    const f = try quote(a, "fish", "a\\b'c");
    defer a.free(f);
    try std.testing.expectEqualStrings("'a\\\\b\\'c'", f);
}
