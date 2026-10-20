const std = @import("std");
const vt_api = @import("vt.zig");
const c = @import("platform_ffi.zig");
var replies: [4096]u8 = undefined;
var reply_len: usize = 0;
fn reply(_: ?*anyopaque, p: [*]const u8, n: usize) callconv(.c) void {
    if (reply_len + n <= replies.len) {
        @memcpy(replies[reply_len..][0..n], p[0..n]);
        reply_len += n;
    }
}
fn feed(v: *vt_api.Vt, s: []const u8) void {
    vt_api.lt_vt_feed(v, s.ptr, s.len);
}
fn expect(ok: bool, name: []const u8) !void {
    if (!ok) {
        std.debug.print("FAIL {s}\n", .{name});
        return error.CheckFailed;
    }
    std.debug.print("PASS {s}\n", .{name});
}
fn cellAt(v: *vt_api.Vt, x: u32, y: u32, buf: []u8, fg: ?*u32, flags: ?*u32) !usize {
    var cursor: vt_api.Cursor = .{};
    if (vt_api.lt_vt_frame(v, &cursor) != 0) return error.Frame;
    defer vt_api.lt_vt_frame_end(v);
    var cell: vt_api.Cell = undefined;
    while (vt_api.lt_vt_next(v, &cell)) {
        if (cell.x != x or cell.y != y) continue;
        if (cell.len > buf.len) return error.ShortBuffer;
        if (cell.len > 0) @memcpy(buf[0..cell.len], cell.text.?[0..cell.len]);
        if (fg) |p| p.* = cell.fg;
        if (flags) |p| p.* = cell.flags;
        return cell.len;
    }
    return error.MissingCell;
}
pub fn main(init: std.process.Init) !void {
    const v = try vt_api.create(init.gpa, init.io, 20, 4, 1000, 2 * 1024 * 1024, reply, null);
    defer vt_api.lt_vt_free(v);
    var buf: [256]u8 = undefined;
    var fg: u32 = 0;
    var flags: u32 = 0;
    feed(v, "\x1b[31;1mA\x1b[0m中e\xcc\x81");
    var n = try cellAt(v, 0, 0, &buf, &fg, &flags);
    try expect(std.mem.eql(u8, buf[0..n], "A") and flags & 1 != 0 and fg != 0, "ANSI colors and bold");
    n = try cellAt(v, 1, 0, &buf, null, null);
    try expect(std.mem.eql(u8, buf[0..n], "中"), "UTF-8 wide character");
    n = try cellAt(v, 3, 0, &buf, null, null);
    try expect(std.mem.eql(u8, buf[0..n], "e\xcc\x81"), "combining grapheme");
    feed(v, "\x1b[?1049hALT\x1b[?1049l");
    n = try cellAt(v, 0, 0, &buf, null, null);
    try expect(std.mem.eql(u8, buf[0..n], "A"), "alternate screen restores primary");
    reply_len = 0;
    feed(v, "\x1b[6n");
    try expect(reply_len > 0 and std.mem.indexOf(u8, replies[0..reply_len], "R") != null, "cursor query replies once");
    try expect(vt_api.lt_vt_resize(v, 30, 8, 8, 18) == 0, "VT resize and reflow");
    var encoded: [256]u8 = undefined;
    var len: usize = 0;
    try expect(vt_api.lt_vt_key(v, 'c', 2, "", 0, &encoded, encoded.len, &len) == 0 and len == 1 and encoded[0] == 3, "Ctrl-C input encoding");
    feed(v, "\x1b[?1h");
    _ = vt_api.lt_vt_key(v, 0x104, 0, "", 0, &encoded, encoded.len, &len);
    try expect(std.mem.eql(u8, encoded[0..len], "\x1bOA"), "application cursor keys");
    feed(v, "\x1b[?2004h");
    try expect(vt_api.lt_vt_bracketed(v), "bracketed paste mode");
    feed(v, "\x1b[?1000h\x1b[?1006h");
    _ = vt_api.lt_vt_mouse(v, 0, 1, 0, 2, 1, &encoded, encoded.len, &len);
    try expect(std.mem.eql(u8, encoded[0..len], "\x1b[<0;3;2M"), "SGR mouse encoding");
    feed(v, "\r\nerror: sample\r\nsecond ERROR\r\n");
    _ = vt_api.lt_vt_search(v, "error", 5);
    var total: usize = 0;
    var ticks: usize = 0;
    while (vt_api.lt_vt_search_tick(v, &total) > 0 and ticks < 10000) : (ticks += 1) {}
    try expect(total == 2, "incremental history search");
    feed(v, "third error\r\n");
    ticks = 0;
    while (vt_api.lt_vt_search_tick(v, &total) > 0 and ticks < 10000) : (ticks += 1) {}
    try expect(total == 3, "completed search updates after new terminal output");
    vt_api.lt_vt_search_next(v, false);
    _ = vt_api.lt_vt_select_all(v);
    len = 0;
    _ = vt_api.lt_vt_copy(v, &buf, buf.len, &len);
    try expect(std.mem.indexOf(u8, buf[0..len], "error") != null, "all-selection formatting includes terminal history");
    var paste = [_]u8{ 'A', 0x1b, 'B', '\n' };
    len = 0;
    try expect(vt_api.lt_vt_paste(&paste, paste.len, true, &encoded, encoded.len, &len) == 0 and std.mem.startsWith(u8, encoded[0..len], "\x1b[200~") and std.mem.endsWith(u8, encoded[0..len], "\x1b[201~") and std.mem.indexOfScalar(u8, encoded[6 .. len - 6], 0x1b) == null, "paste encoder brackets and neutralizes embedded controls");
    try @import("navigation_check.zig").run(init.gpa, init.io);
    try @import("link_check.zig").run(init.gpa, init.io);
    try @import("events_check.zig").run(init.gpa, init.io);
    try ptyCheck();
    std.debug.print("All core checks passed; CentOS GUI/VDI acceptance remains separate.\n", .{});
}
fn ptyCheck() !void {
    var pid: c_int = 0;
    const fd = c.lt_spawn("/bin/sh", "stty size; printf '\\033[6n'; IFS= read -r line; printf 'ECHO:%s\\n' \"$line\"", "", 83, 27, &pid);
    try expect(fd >= 0, "PTY spawn");
    defer c.lt_close(fd);
    var status: c_int = 0;
    var reaped = false;
    defer {
        if (!reaped) {
            c.lt_signal(pid, 9);
            lt_reap(pid);
        }
    }
    const tx = "input中文\n";
    var at: usize = 0;
    var out: [16384]u8 = undefined;
    var used: usize = 0;
    const deadline = c.lt_millis() + 5000;
    while (c.lt_millis() < deadline) {
        if (at < tx.len) {
            const wrote = c.lt_write(fd, tx.ptr + at, tx.len - at);
            if (wrote > 0) at += @intCast(wrote);
        }
        const n = c.lt_read(fd, out[used..].ptr, out.len - used);
        if (n > 0) used += @intCast(n);
        if (c.lt_wait(pid, &status) == pid) {
            reaped = true;
            break;
        }
        lt_pause_ms(2);
    }
    // Read bytes left in the PTY after the child has exited.
    while (used < out.len) {
        const n = c.lt_read(fd, out[used..].ptr, out.len - used);
        if (n <= 0) break;
        used += @intCast(n);
    }
    const ok = reaped and status == 0 and std.mem.indexOf(u8, out[0..used], "27 83") != null and std.mem.indexOf(u8, out[0..used], "ECHO:input中文") != null;
    if (!ok) std.debug.print("PTY reaped={any} status={d} output={s}\n", .{ reaped, status, out[0..used] });
    try expect(ok, "PTY size, UTF-8 round trip and child reaping");
}
extern "c" fn lt_reap(c_int) void;
extern "c" fn lt_pause_ms(c_uint) void;
