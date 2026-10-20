//! Native facade regression against fixed golden records. JSON contains
//! values only, without engine revisions or internal allocation addresses.
const std = @import("std");
const vt = @import("vt.zig");
const theme = @import("theme.zig");
const Replies = struct {
    data: [16384]u8 = undefined,
    len: usize = 0,
    calls: usize = 0,
    limit: usize = 16384,
    failed: bool = false,
    fn receive(ctx: ?*anyopaque, data: [*]const u8, len: usize) callconv(.c) void {
        const r: *Replies = @ptrCast(@alignCast(ctx.?));
        r.calls += 1;
        if (len > r.limit - r.len) {
            r.failed = true;
            return;
        }
        @memcpy(r.data[r.len..][0..len], data[0..len]);
        r.len += len;
    }
    fn text(r: *const Replies) []const u8 {
        return r.data[0..r.len];
    }
};
const Cell = struct { x: u32, y: u32, width: u32, flags: u32, fg: u32, bg: u32, text: []const u8 };
fn require(ok: bool, label: []const u8) !void {
    std.debug.print("{s} REPLAY {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.ReplayMismatch;
}
fn create(gpa: std.mem.Allocator, io: std.Io, replies: *Replies) !*vt.Vt {
    const v = try vt.create(gpa, io, 20, 4, 1000, 2 * 1024 * 1024, Replies.receive, replies);
    errdefer vt.destroy(v);
    vt.lt_vt_colors(v, theme.foreground, theme.background);
    var palette: [16]u32 = undefined;
    for (theme.palette, 0..) |rgb, i| palette[i] = rgb;
    vt.lt_vt_palette(v, &palette, theme.foreground);
    if (vt.lt_vt_settings(v, 1, false, 1000, 2 * 1024 * 1024) != 0) return error.Settings;
    return v;
}
fn state(a: std.mem.Allocator, v: *vt.Vt, replies: *Replies) ![]const u8 {
    var cursor: vt.Cursor = .{};
    if (vt.lt_vt_frame(v, &cursor) != 0) return error.Frame;
    defer vt.lt_vt_frame_end(v);
    var cells: std.ArrayList(Cell) = .empty;
    defer cells.deinit(a);
    var cell: vt.Cell = undefined;
    while (vt.lt_vt_next(v, &cell)) {
        if (cells.items.len >= 16384 or cell.len > 32768) return error.SnapshotLimit;
        try cells.append(a, .{ .x = cell.x, .y = cell.y, .width = cell.width, .flags = cell.flags, .fg = cell.fg, .bg = cell.bg, .text = try a.dupe(u8, if (cell.len == 0) "" else cell.text.?[0..cell.len]) });
    }
    var title: [256]u8 = undefined;
    const title_len = vt.lt_vt_title(v, &title, title.len);
    var pwd: [4096]u8 = undefined;
    const pwd_len = vt.lt_vt_pwd(v, &pwd, pwd.len);
    var events: vt.Events = .{};
    vt.lt_vt_events(v, &events);
    return std.json.Stringify.valueAlloc(a, .{ .cells = cells.items, .cursor = cursor, .title = title[0..title_len], .pwd = pwd[0..pwd_len], .events = events, .replies = replies.text(), .reply_calls = replies.calls, .reply_overflow = replies.failed }, .{});
}
fn record(a: std.mem.Allocator, name: []const u8, v: *vt.Vt, replies: *Replies) ![]const u8 {
    const json = try state(a, v, replies);
    const name_json = try std.json.Stringify.valueAlloc(a, name, .{});
    std.debug.print("RESULT {{\"fixture\":{s},\"state\":{s}}}\n", .{ name_json, json });
    return json;
}
fn encoded(a: std.mem.Allocator, name: []const u8, bytes: []const u8) !void {
    const json = try std.json.Stringify.valueAlloc(a, .{ .fixture = name, .bytes = bytes }, .{});
    std.debug.print("RESULT {s}\n", .{json});
}
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    std.debug.print("VT facade replay; backend={s}; Zig=0.17.0; ghostty=5064b3265e500d55f5f44ff48ca59b8685543bb8; simd=false; fixed golden regression\n", .{vt.backend_name});
    var replies: Replies = .{};
    const v = try create(init.gpa, init.io, &replies);
    defer vt.destroy(v);
    const input = "\x1b[31;1mA\x1b[0m中e\xcc\x81";
    try vt.feed(v, input);
    const baseline = try record(a, "ansi-graphemes", v, &replies);
    // Every possible two-chunk split, including inside UTF-8 and CSI.
    for (0..input.len + 1) |cut| {
        var r: Replies = .{};
        const other = try create(init.gpa, init.io, &r);
        defer vt.destroy(other);
        try vt.feed(other, input[0..cut]);
        try vt.feed(other, input[cut..]);
        const current = try state(a, other, &r);
        if (!std.mem.eql(u8, baseline, current)) return error.FragmentedInputMismatch;
    }
    try require(true, "all byte split points preserve CSI, CJK and combining graphemes");
    try vt.feed(v, "\x1b[?1049hALT\x1b[?1049l");
    _ = try record(a, "alternate-restores-primary", v, &replies);
    if (vt.lt_vt_resize(v, 12, 6, 8, 18) != 0) return error.Resize;
    _ = try record(a, "resize-reflow", v, &replies);
    replies.len = 0;
    replies.calls = 0;
    try vt.feed(v, "\x1b[6n");
    try require(replies.calls == 1 and std.mem.eql(u8, replies.text(), "\x1b[1;5R"), "DSR reply has the exact cursor and occurs once");
    _ = try record(a, "dsr-once", v, &replies);
    // A callback's text must be copied before a later parser call changes it.
    try vt.feed(v, "\x1b]2;Owned title\x07\x07\x1b]7;file://localhost/private/tmp\x07\x1b]133;A\x07$ \x1b]133;B\x07\x1b]133;C\x07output\r\n\x1b]133;D;7\x07\x1b]133;A\x07\x1b]9;4;1;42\x07");
    var events: vt.Events = .{};
    vt.lt_vt_events(v, &events);
    try require(events.bells == 1 and events.pwd == 1 and events.prompts == 2 and events.starts == 1 and events.ends == 1 and events.exit_code == 7 and events.has_exit and events.at_prompt and events.progress_state == 1 and events.progress == 42, "host effects preserve BEL, PWD, semantic exit and progress");
    _ = try record(a, "host-effects", v, &replies);
    var out: [256]u8 = undefined;
    var len: usize = 0;
    if (vt.lt_vt_key(v, 'c', 2, "", 0, &out, out.len, &len) != 0) return error.Key;
    try require(std.mem.eql(u8, out[0..len], "\x03"), "Ctrl-C encoding");
    try encoded(a, "key-ctrl-c", out[0..len]);
    try vt.feed(v, "\x1b[?1h");
    if (vt.lt_vt_key(v, 0x104, 0, "", 0, &out, out.len, &len) != 0) return error.Key;
    try require(std.mem.eql(u8, out[0..len], "\x1bOA"), "application cursor encoding");
    try encoded(a, "key-application-up", out[0..len]);
    var paste = [_]u8{ 'A', 0x1b, 'B', '\n' };
    if (vt.lt_vt_paste(&paste, paste.len, true, &out, out.len, &len) != 0) return error.Paste;
    try require(std.mem.startsWith(u8, out[0..len], "\x1b[200~") and std.mem.endsWith(u8, out[0..len], "\x1b[201~"), "bracketed paste boundaries");
    try encoded(a, "paste-controls", out[0..len]);
    try require(vt.lt_vt_focus(v, true, &out, out.len) == 0, "disabled focus emits zero bytes");
    try vt.feed(v, "\x1b[?1004h\x1b[?2004h");
    try require(vt.lt_vt_bracketed(v) and vt.lt_vt_focus_enabled(v), "mode flags reach facade");
    len = vt.lt_vt_focus(v, true, &out, out.len);
    try encoded(a, "focus-gained", out[0..len]);
    len = vt.lt_vt_focus(v, false, &out, out.len);
    try encoded(a, "focus-lost", out[0..len]);
    // The host owns queue backpressure. Reject the entire reply, never a prefix.
    replies.len = 0;
    replies.calls = 0;
    replies.limit = 1;
    try vt.feed(v, "\x1b[6n");
    try require(replies.failed and replies.calls == 1 and replies.len == 0, "bounded reply sink rejects whole packet without reentering parser");
    _ = try record(a, "reply-backpressure", v, &replies);
    std.debug.print("All VT facade replay checks passed (backend={s}).\n", .{vt.backend_name});
}
