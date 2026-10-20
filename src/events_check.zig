//! Verify public callbacks/encoders against real VT parsing, no second OSC parser.
const std = @import("std");
const vt_api = @import("vt.zig");
const c = @import("platform_ffi.zig");
fn reply(_: ?*anyopaque, _: [*]const u8, _: usize) callconv(.c) void {}
fn feed(v: *vt_api.Vt, text: []const u8) void {
    vt_api.lt_vt_feed(v, text.ptr, text.len);
}
fn check(ok: bool, name: []const u8) !void {
    std.debug.print("{s} {s}\n", .{ if (ok) "PASS" else "FAIL", name });
    if (!ok) return error.EventsCheck;
}
pub fn run(gpa: std.mem.Allocator, io: std.Io) !void {
    const v = try vt_api.create(gpa, io, 24, 4, 1000, 1024 * 1024, reply, null);
    defer vt_api.lt_vt_free(v);
    feed(v, "\x07\x1b]7;file://localhost/private/tmp\x07\x1b]133;A\x07$ \x1b]133;B\x07");
    var e: vt_api.Events = .{};
    vt_api.lt_vt_events(v, &e);
    var buf: [4096]u8 = undefined;
    const n = vt_api.lt_vt_pwd(v, &buf, buf.len);
    try check(e.bells == 1 and e.pwd == 1 and e.prompts == 1 and e.at_prompt and std.mem.eql(u8, buf[0..n], "file://localhost/private/tmp"), "BEL, PWD and prompt callbacks snapshot parsed VT events");
    feed(v, "\x1b]133;C\x07output\r\n\x1b]133;D;7\x07\x1b]133;A\x07");
    vt_api.lt_vt_events(v, &e);
    try check(e.starts == 1 and e.ends == 1 and e.has_exit and e.exit_code == 7 and e.prompts == 2, "semantic command start/end retains exit status");
    feed(v, "\x1b]9;4;1;42\x07");
    vt_api.lt_vt_events(v, &e);
    try check(e.progress_state == 1 and e.progress == 42, "OSC 9;4 determinate progress is exposed");
    feed(v, "\x1b]9;4;0\x07");
    vt_api.lt_vt_events(v, &e);
    try check(e.progress_state == 0, "progress removal stops displaying its badge");
    try check(vt_api.lt_vt_focus(v, true, &buf, buf.len) == 0, "disabled focus mode produces no bytes");
    feed(v, "\x1b[?1004h");
    const gained = vt_api.lt_vt_focus(v, true, &buf, buf.len);
    try check(std.mem.eql(u8, buf[0..gained], "\x1b[I"), "enabled focus mode encodes gained");
    const lost = vt_api.lt_vt_focus(v, false, &buf, buf.len);
    try check(std.mem.eql(u8, buf[0..lost], "\x1b[O"), "enabled focus mode encodes lost");
    for (0..40) |_| feed(v, "\x1b]133;A\x07prompt\r\n\x1b]133;B\x07cmd\x1b]133;C\x07\r\noutput\r\n\x1b]133;D;0\x07");
    vt_api.lt_vt_bottom(v);
    var before: vt_api.Scroll = .{};
    var after: vt_api.Scroll = .{};
    vt_api.lt_vt_scroll_info(v, &before);
    vt_api.lt_vt_prompt_jump(v, -1);
    vt_api.lt_vt_scroll_info(v, &after);
    try check(after.offset < before.offset, "previous prompt uses VT semantic history navigation");
    _ = vt_api.lt_vt_resize(v, 12, 3, 8, 18);
    for (0..50) |_| vt_api.lt_vt_prompt_jump(v, 1);
    vt_api.lt_vt_scroll_info(v, &after);
    try check(after.offset + after.len <= after.total, "prompt navigation remains bounded after resize");
    try check(c.lt_local_directory("localhost", "/tmp") and !c.lt_local_directory("unrelated-remote.invalid", "/tmp"), "remote OSC 7 authorities cannot be inherited as local directories");
}
