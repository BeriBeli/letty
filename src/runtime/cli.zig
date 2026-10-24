//! Local launch/configuration commands. No terminal-server control interface.
const std = @import("std");
const os = @import("platform.zig");
const Config = @import("settings.zig").Config;
pub const Options = struct { directory: ?[]const u8 = null, shell: []const u8 = "", command: []const []const u8 = &.{}, check: bool = false, ui_checks: bool = false, config: ?[]const u8 = null };
pub fn parse(args: []const []const u8) !Options {
    var out: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--") or std.mem.eql(u8, arg, "-e")) {
            out.command = args[i + 1 ..];
            if (out.command.len == 0) return error.ExpectedCommand;
            break;
        }
        if (std.mem.startsWith(u8, arg, "--cwd=")) out.directory = arg[6..] else if (std.mem.startsWith(u8, arg, "--shell=")) out.shell = arg[8..] else if (std.mem.eql(u8, arg, "--cwd") or std.mem.eql(u8, arg, "--shell")) {
            i += 1;
            if (i >= args.len) return error.ExpectedArgument;
            if (std.mem.eql(u8, arg, "--cwd")) out.directory = args[i] else out.shell = args[i];
        } else if (std.mem.eql(u8, arg, "--check-config")) out.check = true else if (std.mem.eql(u8, arg, "--ui-checks")) out.ui_checks = true else if (std.mem.startsWith(u8, arg, "--nanoui-")) continue else return error.UnknownOption;
    }
    return out;
}
pub fn config(a: std.mem.Allocator, args: []const []const u8) !void {
    const path = try Config.path(a);
    defer a.free(path);
    const sub = if (args.len > 0) args[0] else "path";
    if (std.mem.eql(u8, sub, "path")) {
        try os.output(path);
        try os.output("\n");
        return;
    }
    if (std.mem.eql(u8, sub, "edit")) {
        if (std.fs.path.dirname(path)) |dir| try os.mkdirs(a, dir);
        const z = try a.dupeSentinel(u8, path, 0);
        defer a.free(z);
        const fd = os.c.open(z, os.c.O_WRONLY | os.c.O_CREAT | os.c.O_CLOEXEC | os.c.O_NOFOLLOW, @as(c_uint, 0o600));
        if (fd < 0) return error.OpenFile;
        _ = os.c.close(fd);
        return @import("desktop_open.zig").open(path, false);
    }
    const source = os.readFile(a, path, 1024 * 1024) catch |err| blk: {
        if (err != error.OpenFile) return err;
        break :blk try a.dupe(u8, "");
    };
    defer a.free(source);
    var parsed = try Config.parse(a, source);
    defer parsed.deinit(a);
    if (std.mem.eql(u8, sub, "check")) {
        try os.output("Configuration valid\n");
        return;
    }
    if (std.mem.eql(u8, sub, "show")) {
        const defaults = args.len > 1 and std.mem.eql(u8, args[1], "--defaults");
        const settings = if (defaults) @import("settings.zig").Settings{} else parsed.settings;
        var output: std.Io.Writer.Allocating = .init(a);
        defer output.deinit();
        inline for (@typeInfo(@TypeOf(settings)).@"struct".field_names) |name| {
            const value = @field(settings, name);
            if (@TypeOf(value) == []const u8) try output.writer.print("{s} = \"{s}\"\n", .{ name, value }) else try output.writer.print("{s} = {any}\n", .{ name, value });
        }
        if (!defaults) {
            for (parsed.env.items) |value| try output.writer.print("env = {s}\n", .{value});
            for (parsed.keybind.items) |value| try output.writer.print("keybind = {s}\n", .{value});
        }
        try os.output(output.written());
        return;
    }
    return error.UnknownConfigCommand;
}
test "local CLI preserves literal command arguments and rejects daemon/browser controls" {
    const out = try parse(&.{ "--cwd", "/private/example", "--shell=/bin/sh", "--", "printf", "a b" });
    try std.testing.expectEqualStrings("/private/example", out.directory.?);
    try std.testing.expectEqualStrings("a b", out.command[1]);
    try std.testing.expectError(error.UnknownOption, parse(&.{"attach"}));
    try std.testing.expectError(error.UnknownOption, parse(&.{"--url=https://example.com"}));
}
