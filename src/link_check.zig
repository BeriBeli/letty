//! Link tests distinguish literal visible URLs from OSC-8 target metadata.
const std = @import("std");
const vt_api = @import("vt.zig");
fn reply(_: ?*anyopaque, _: [*]const u8, _: usize) callconv(.c) void {}
fn feed(v: *vt_api.Vt, text: []const u8) void {
    vt_api.lt_vt_feed(v, text.ptr, text.len);
}
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.LinkCheck;
}
pub fn run(gpa: std.mem.Allocator, io: std.Io) !void {
    const v = try vt_api.create(gpa, io, 12, 6, 1000, 1024 * 1024, reply, null);
    defer vt_api.lt_vt_free(v);
    var buffer: [2048]u8 = undefined;
    var len: usize = 0;
    var link: vt_api.Link = .{};
    feed(v, "中https://example.com/a中文");
    try check(vt_api.lt_vt_link_at(v, 8, 0, &buffer, buffer.len, &len, &link) == 0 and std.mem.eql(u8, buffer[0..len], "https://example.com/a") and !link.osc8 and link.first == 2 and link.last > 12, "plain URL crosses soft wrap without including neighboring Chinese cells");
    try check(vt_api.lt_vt_link_at(v, 5, 1, &buffer, buffer.len, &len, &link) == 0 and std.mem.eql(u8, buffer[0..len], "https://example.com/a"), "wrapped URL tail resolves to the complete visible target");
    vt_api.lt_vt_reset(v);
    feed(v, "\x1b]8;;https://real.example/target\x1b\\label 中\x1b]8;;\x1b\\");
    try check(vt_api.lt_vt_link_at(v, 1, 0, &buffer, buffer.len, &len, &link) == 0 and std.mem.eql(u8, buffer[0..len], "https://real.example/target") and link.osc8 and link.first == 0, "OSC 8 exposes its real URI rather than its display label");
    vt_api.lt_vt_reset(v);
    feed(v, "https://exa\r\nmple.com");
    try check(vt_api.lt_vt_link_at(v, 3, 1, &buffer, buffer.len, &len, &link) != 0, "hard line breaks are not joined into a URL");
    vt_api.lt_vt_reset(v);
    feed(v, "\x1b]8;;file:///etc/passwd\x1b\\unsafe\x1b]8;;\x1b\\");
    _ = vt_api.lt_vt_link_at(v, 1, 0, &buffer, buffer.len, &len, &link);
    try check(!@import("url.zig").allowed(buffer[0..len]), "non-HTTP OSC 8 target is rejected by opener policy");
    vt_api.lt_vt_reset(v);
    feed(v, "see src/a.zig:3: x");
    try check(vt_api.lt_vt_link_at(v, 6, 0, &buffer, buffer.len, &len, &link) != 0, "plain path text is never reported as a web link");
    try check(vt_api.lt_vt_token_at(v, 6, 0, &buffer, buffer.len, &len, &link) == 0 and std.mem.eql(u8, buffer[0..len], "src/a.zig:3:") and !link.osc8 and link.first == 4, "path-like token crosses soft wrap for host-side classification");
    try check(@import("terminal_paths.zig").classify(@import("terminal_paths.zig").trimPlain(buffer[0..len]), false) == .file, "compiler-style location token classifies as a local file");
}
