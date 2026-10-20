//! M2 checks exercise real libghostty-vt public API semantics and bounded snapshots.
const std = @import("std");
const vt_api = @import("vt.zig");
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.NavigationCheck;
}
fn reply(_: ?*anyopaque, _: [*]const u8, _: usize) callconv(.c) void {}
fn feed(v: *vt_api.Vt, text: []const u8) void {
    vt_api.lt_vt_feed(v, text.ptr, text.len);
}
fn finish(v: *vt_api.Vt) usize {
    var total: usize = 0;
    for (0..10000) |_| if (vt_api.lt_vt_search_tick(v, &total) <= 0) break;
    return total;
}
pub fn run(gpa: std.mem.Allocator, io: std.Io) !void {
    const v = try vt_api.create(gpa, io, 16, 4, 100000, 16 * 1024 * 1024, reply, null);
    defer vt_api.lt_vt_free(v);
    for (0..40) |_| feed(v, "hit 中é hit\r\n");
    var info: vt_api.Scroll = .{};
    vt_api.lt_vt_scroll_info(v, &info);
    try check(info.total > info.len and info.offset > 0 and !info.alternate, "VT exposes primary history scrollbar position");
    _ = vt_api.lt_vt_select_all(v);
    var before: [4096]u8 = undefined;
    var before_len: usize = 0;
    try check(vt_api.lt_vt_copy(v, &before, before.len, &before_len) == 0, "select_all formats bounded history without mirroring it");
    _ = vt_api.lt_vt_search(v, "hit", 3);
    try check(finish(v) == 80, "incremental search finds repeated history matches");
    var search: vt_api.SearchInfo = .{};
    vt_api.lt_vt_search_info(v, &search);
    try check(search.current > 0 and search.current <= search.total, "search exposes one-based selected index");
    var cursor: vt_api.Cursor = .{};
    var cell: vt_api.Cell = undefined;
    _ = vt_api.lt_vt_frame(v, &cursor);
    var matched: usize = 0;
    var current: usize = 0;
    while (vt_api.lt_vt_next(v, &cell)) {
        if (cell.flags & 32 != 0) matched += 1;
        if (cell.flags & 64 != 0) current += 1;
    }
    vt_api.lt_vt_frame_end(v);
    try check(matched > current and current > 0, "all visible matches and selected match have independent cell flags");
    vt_api.lt_vt_search_next(v, true);
    _ = finish(v);
    var after: [4096]u8 = undefined;
    var after_len: usize = 0;
    _ = vt_api.lt_vt_copy(v, &after, after.len, &after_len);
    try check(std.mem.eql(u8, before[0..before_len], after[0..after_len]), "search navigation leaves ordinary terminal selection unchanged");
    vt_api.lt_vt_search_close(v);
    try check(vt_api.lt_vt_has_selection(v), "closing search preserves ordinary selection");
    _ = vt_api.lt_vt_search(v, "中é", "中é".len);
    _ = finish(v);
    _ = vt_api.lt_vt_frame(v, &cursor);
    matched = 0;
    while (vt_api.lt_vt_next(v, &cell)) if (cell.flags & 32 != 0 and cell.len > 0) {
        matched += 1;
    };
    vt_api.lt_vt_frame_end(v);
    try check(matched >= 2, "wide and combining grapheme matches reach visible cell highlights");
    vt_api.lt_vt_search_close(v);
    vt_api.lt_vt_scroll_to(v, 0);
    vt_api.lt_vt_scroll_info(v, &info);
    try check(info.offset == 0, "absolute scrollbar row reaches top");
    feed(v, "new background line\r\n");
    vt_api.lt_vt_scroll_info(v, &info);
    try check(info.offset == 0, "new output preserves viewport while browsing history");
    _ = vt_api.lt_vt_resize(v, 13, 3, 8, 18);
    vt_api.lt_vt_scroll_to(v, std.math.maxInt(u64));
    vt_api.lt_vt_scroll_info(v, &info);
    try check(info.offset + info.len == info.total, "absolute row clamps after resize and reflow");
    feed(v, "\x1b[?1049h");
    vt_api.lt_vt_scroll_info(v, &info);
    try check(info.alternate and info.total == info.len and vt_api.lt_vt_clear_screen(v) != 0, "alternate screen suppresses primary scrollbar and clear_screen");
    feed(v, "\x1b[?1049l\x1b[?2004h");
    try check(vt_api.lt_vt_clear_screen(v) == 0 and vt_api.lt_vt_bracketed(v), "clear_screen erases primary content while preserving terminal modes");
    vt_api.lt_vt_scroll_info(v, &info);
    try check(info.total == info.len, "clear_screen removes scrollback");
    vt_api.lt_vt_reset(v);
    vt_api.lt_vt_scroll_info(v, &info);
    try check(!vt_api.lt_vt_bracketed(v) and info.len == 3, "full reset clears modes and retains resized dimensions");
}
