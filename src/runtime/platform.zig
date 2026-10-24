//! POSIX system boundary. Product logic lives in Zig; libc supplies OS calls.
const std = @import("std");
pub const c = @import("libc.zig");
pub const Allocator = std.mem.Allocator;
/// GUI launches on macOS inherit a 256-descriptor soft limit. Dynamic local
/// PTYs and document watchers should use the allowance already granted by the
/// host, without changing the hard limit or any system-wide setting.
pub fn prepareFileDescriptors() void {
    var limit: std.c.rlimit = undefined;
    if (std.c.getrlimit(.NOFILE, &limit) != 0) return;
    const wanted = if (@import("builtin").os.tag == .macos) @min(limit.max, std.c.OPEN_MAX) else limit.max;
    if (wanted <= limit.cur) return;
    limit.cur = wanted;
    _ = std.c.setrlimit(.NOFILE, &limit);
}
pub fn errNo() c_int {
    return if (@import("builtin").os.tag == .macos) c.__error().* else c.__errno_location().*;
}
pub fn env(name: [:0]const u8) ?[]const u8 {
    const p = c.getenv(name) orelse return null;
    return std.mem.span(p);
}
pub fn millis() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}
pub fn sleep(ms: u32) void {
    _ = c.poll(null, 0, @intCast(ms));
}
pub fn nonblock(fd: c_int) !void {
    const flags = c.fcntl(fd, c.F_GETFL);
    if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.FileFlags;
}
pub fn cloexec(fd: c_int) !void {
    if (c.fcntl(fd, c.F_SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return error.FileFlags;
}
pub fn writeAll(fd: c_int, bytes: []const u8) !void {
    var at: usize = 0;
    while (at < bytes.len) {
        const n = c.write(fd, bytes[at..].ptr, bytes.len - at);
        if (n < 0) {
            if (errNo() == c.EINTR) continue;
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed;
        at += @intCast(n);
    }
}
pub fn output(bytes: []const u8) !void {
    try writeAll(1, bytes);
}
pub fn diagnostic(bytes: []const u8) void {
    writeAll(2, bytes) catch {};
}
pub fn mkdirs(a: Allocator, path: []const u8) !void {
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    for (z, 0..) |ch, i| if (ch == '/' and i > 0) {
        z[i] = 0;
        const result = c.mkdir(z.ptr, 0o700);
        z[i] = '/';
        if (result != 0 and errNo() != c.EEXIST) return error.CreateDirectory;
    };
    if (c.mkdir(z, 0o700) != 0 and errNo() != c.EEXIST) return error.CreateDirectory;
}
pub fn readFile(a: Allocator, path: []const u8, limit: usize) ![]u8 {
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    const fd = c.open(z.ptr, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK | c.O_NOFOLLOW);
    if (fd < 0) return error.OpenFile;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or (st.mode & c.S_IFMT) != c.S_IFREG or st.size < 0 or st.size > limit) return error.FileLimit;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) {
            if (errNo() == c.EINTR) continue;
            return error.ReadFile;
        }
        if (n == 0) break;
        if (out.items.len + @as(usize, @intCast(n)) > limit) return error.FileLimit;
        try out.appendSlice(a, buf[0..@intCast(n)]);
    }
    return out.toOwnedSlice(a);
}
pub fn atomicFile(a: Allocator, path: []const u8, bytes: []const u8) !void {
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    const tmp = try std.fmt.allocPrintSentinel(a, "{s}.XXXXXX", .{path}, 0);
    defer a.free(tmp);
    const fd = c.mkstemp(tmp.ptr);
    if (fd < 0) return error.CreateFile;
    defer _ = c.close(fd);
    defer _ = c.unlink(tmp.ptr);
    try writeAll(fd, bytes);
    if (c.fsync(fd) != 0 or c.rename(tmp.ptr, z.ptr) != 0) return error.SaveFile;
}
pub fn shell() []const u8 {
    if (c.getpwuid(c.getuid())) |account| if (account.*.shell) |value| {
        if (value[0] != 0) return std.mem.span(value);
    };
    return env("SHELL") orelse "/bin/sh";
}
pub fn cwd(a: Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    if (c.getcwd(&buf, buf.len) == null) return error.WorkingDirectory;
    return a.dupe(u8, std.mem.sliceTo(&buf, 0));
}
