//! Foreground argv inspection on output/attention events, never an idle scan.
const std = @import("std");
const os = @import("platform.zig");
pub const agents = [_][]const u8{ "claude", "codex", "gemini", "opencode", "amp", "aider", "cursor-agent", "droid", "qwen", "goose", "crush", "copilot", "kiro-cli", "cline", "auggie", "kimi", "pi" };
extern "c" fn sysctl([*]const c_int, c_uint, ?*anyopaque, *usize, ?*anyopaque, usize) c_int;
pub fn detectAgent(arguments: []const u8) []const u8 {
    var words = std.mem.splitScalar(u8, arguments, 0);
    var index: usize = 0;
    while (words.next()) |argument| : (index += 1) {
        if (index > 2) break;
        const raw = std.fs.path.basename(argument);
        const extension = std.fs.path.extension(raw);
        const name = if (extension.len > 0) raw[0 .. raw.len - extension.len] else raw;
        for (agents) |agent| if (std.ascii.eqlIgnoreCase(name, agent) or (!std.mem.eql(u8, agent, "pi") and name.len > agent.len and std.ascii.startsWithIgnoreCase(name, agent) and name[agent.len] == '-')) return agent;
    }
    words = std.mem.splitScalar(u8, arguments, 0);
    index = 0;
    while (words.next()) |argument| : (index += 1) {
        if (index > 2) break;
        for (agents) |agent| {
            if (agent.len <= 3) continue;
            var buffer: [64]u8 = undefined;
            const needle = std.fmt.bufPrint(&buffer, "/{s}/", .{agent}) catch continue;
            if (std.mem.indexOf(u8, argument, needle) != null) return agent;
            const npm = std.fmt.bufPrint(&buffer, "/{s}-code/", .{agent}) catch continue;
            if (std.mem.indexOf(u8, argument, npm) != null) return agent;
        }
    }
    return "";
}
pub fn foreground(a: std.mem.Allocator, fd: c_int, shell_pid: c_int) ![]const u8 {
    const group = os.c.tcgetpgrp(fd);
    if (group <= 0 or group == shell_pid) return "";
    if (@import("builtin").os.tag == .macos) {
        const mib = [_]c_int{ 1, 49, group };
        var buffer: [65536]u8 = undefined;
        var length: usize = buffer.len;
        if (sysctl(&mib, mib.len, &buffer, &length, null, 0) != 0 or length < 5 or length > buffer.len) return "";
        const argc = std.mem.readInt(u32, buffer[0..4], .little);
        const end = std.mem.indexOfScalarPos(u8, buffer[0..length], 4, 0) orelse return "";
        var start = end;
        while (start < length and buffer[start] == 0) start += 1;
        var at = start;
        var n: usize = 0;
        while (at < length and n < argc) : (n += 1) {
            const e = std.mem.indexOfScalarPos(u8, buffer[0..length], at, 0) orelse return "";
            at = e + 1;
        }
        return detectAgent(buffer[start..at]);
    } else {
        const path = try std.fmt.allocPrint(a, "/proc/{d}/cmdline", .{group});
        defer a.free(path);
        const args = os.readFile(a, path, 65536) catch return "";
        defer a.free(args);
        return detectAgent(args);
    }
}
test "Letty foreground agent names and npm runtime wrappers" {
    try std.testing.expectEqualStrings("codex", detectAgent("/usr/bin/node\x00/lib/node_modules/@openai/codex/bin/codex.js\x00"));
    try std.testing.expectEqualStrings("claude", detectAgent("node\x00/lib/node_modules/@anthropic-ai/claude-code/cli.js\x00"));
    try std.testing.expectEqualStrings("", detectAgent("python\x00pictures.py\x00"));
}
