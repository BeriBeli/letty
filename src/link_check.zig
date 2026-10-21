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
    try unicodePaths(gpa, io);
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

fn unicodePaths(gpa: std.mem.Allocator, io: std.Io) !void {
    const v = try vt_api.create(gpa, io, 80, 6, 1000, 1024 * 1024, reply, null);
    defer vt_api.lt_vt_free(v);
    var buffer: [2048]u8 = undefined;
    var len: usize = 0;
    var link: vt_api.Link = .{};
    feed(v, "中文.md  Register Specification Standard.pdf  后续.md");
    for ([_]u32{ 0, 1, 2, 3, 4, 5, 6 }) |x| {
        try check(vt_api.lt_vt_token_at(v, x, 0, &buffer, buffer.len, &len, &link) == 0 and std.mem.eql(u8, buffer[0..len], "中文.md") and link.first == 0 and link.last == 6, "UTF-8 path resolves from both halves of Chinese cells with a cell-based span");
    }
    for ([_]u32{ 9, 20, 30, 43 }) |x| {
        try check(vt_api.lt_vt_token_at(v, x, 0, &buffer, buffer.len, &len, &link) == 0 and std.mem.eql(u8, buffer[0..len], "Register Specification Standard.pdf") and link.first == 9 and link.last == 43, "ls column preserves spaces without merging neighboring filenames");
    }
    vt_api.lt_vt_reset(v);
    feed(v, "'目录/中文  文档.md'  ./中文\\ 文件.md  e\u{301}.md");
    try check(vt_api.lt_vt_token_at(v, 4, 0, &buffer, buffer.len, &len, &link) == 0 and std.mem.eql(u8, buffer[0..len], "目录/中文  文档.md"), "quoted Unicode path keeps repeated spaces");
    try check(vt_api.lt_vt_token_at(v, 28, 0, &buffer, buffer.len, &len, &link) == 0 and std.mem.eql(u8, buffer[0..len], "./中文 文件.md"), "shell-escaped space resolves to a literal filename");
    try check(vt_api.lt_vt_token_at(v, 39, 0, &buffer, buffer.len, &len, &link) == 0 and std.mem.eql(u8, buffer[0..len], "e\u{301}.md"), "combining grapheme bytes remain part of the filename");
    const wrapped = try vt_api.create(gpa, io, 7, 6, 1000, 1024 * 1024, reply, null);
    defer vt_api.lt_vt_free(wrapped);
    feed(wrapped, "./中文/文档.md");
    try check(vt_api.lt_vt_token_at(wrapped, 2, 1, &buffer, buffer.len, &len, &link) == 0 and std.mem.eql(u8, buffer[0..len], "./中文/文档.md"), "soft-wrapped wide Unicode path retains complete UTF-8 bytes");
    vt_api.lt_vt_reset(v);
    feed(v, "中文.md");
    try check(vt_api.lt_vt_token_at(v, 1, 0, &buffer, 4, &len, &link) != 0 and len == 0, "short target buffer rejects the whole UTF-8 path instead of truncating it");
}
