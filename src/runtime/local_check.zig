//! Standalone acceptance fixture: private local PTYs, no visible UI or sockets.
const std = @import("std");
const p = @import("platform.zig");
const Pty = @import("pty.zig").Pty;
pub fn main(init: std.process.Init) !void {
    const a = std.heap.smp_allocator;
    var temp_buffer: [256]u8 = undefined;
    const temporary = try std.fmt.bufPrintSentinel(&temp_buffer, "{s}/letty-local-pty-XXXXXX", .{if (@import("builtin").os.tag == .macos) "/private/tmp" else "/tmp"}, 0);
    const home = p.c.mkdtemp(temporary.ptr) orelse return error.PrivateDirectory;
    defer _ = p.c.rmdir(home);
    _ = p.c.setenv("HOME", home, 1);
    _ = p.c.setenv("XDG_CONFIG_HOME", home, 1);
    _ = p.c.setenv("HISTFILE", "/dev/null", 1);
    _ = p.c.unsetenv("BASH_ENV");
    _ = p.c.unsetenv("ENV");
    const session = try Pty.create(a, init.io, 1, std.mem.span(home), "/bin/sh", &.{ "/bin/sh", "-c", "printf 'LOCAL_VT_MARKER\\n'; exit 7" }, 4 * 1024 * 1024);
    defer session.destroy();
    const until = p.millis() + 5000;
    while (session.terminal.command_exit == null and p.millis() < until) {
        var poll: p.c.pollfd = .{ .fd = session.fd, .events = p.c.POLLIN, .revents = 0 };
        _ = p.c.poll(@ptrCast(&poll), 1, 25);
        _ = try session.read();
        _ = try session.flush();
    }
    if (session.terminal.command_exit != 7) return error.CommandExitNotReported;
    const text = try session.terminal.text(a, true);
    defer a.free(text);
    if (std.mem.indexOf(u8, text, "LOCAL_VT_MARKER") == null) return error.OutputMissing;
    try session.resize(100, 30, 8, 18);
    if (session.terminal.terminal.cols != 100 or session.terminal.terminal.rows != 30) return error.ResizeFailed;
    _ = try session.send("printf '\\033]7501;state=blocked:kind=permission:msg=QXBwcm92ZQ==\\033\\\\'\r");
    const deadline = p.millis() + 5000;
    while (session.terminal.records.leading() == null and p.millis() < deadline) {
        p.sleep(20);
        _ = try session.read();
        _ = try session.flush();
    }
    const record = session.terminal.records.leading() orelse return error.StatusMissing;
    if (!std.mem.eql(u8, record.state, "blocked") or !std.mem.eql(u8, record.msg, "Approve")) return error.StatusIncorrect;
    _ = try session.send("exit\r");
    const exit_deadline = p.millis() + 5000;
    while (!session.reap() and session.pid > 0 and p.millis() < exit_deadline) {
        _ = try session.read();
        p.sleep(20);
    }
    if (session.pid != 0) return error.ChildNotReaped;
    try p.output("PASS Local PTY command output\nPASS Local command exit status\nPASS Local PTY resize\nPASS Local OSC 7501 status\nPASS Local child reaping\nAll core checks passed (5 checks).\n");
}
