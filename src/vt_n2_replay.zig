//! Native N2 acceptance script. Only the public facade is used: no engine
//! values, tracked-pin addresses, revisions or allocation counters are compared.
//! N2RESULT values are compared with the fixed accepted golden records.
const std = @import("std");
const vt = @import("vt.zig");

const Cell = struct { x: u32, y: u32, width: u32, flags: u32, text: []const u8 };
const Snapshot = struct {
    cells: []const Cell,
    cursor: vt.Cursor,
    scroll: vt.Scroll,
    search: vt.SearchInfo,
    selected: bool,
    copy_ok: bool,
    copied: []const u8,
    bracketed: bool,
};
const Summary = struct { highlights: usize = 0, current: usize = 0, selection: usize = 0 };
var checks: usize = 0;
var records: usize = 0;

fn require(ok: bool, label: []const u8) !void {
    std.debug.print("{s} N2 REPLAY {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.N2ReplayMismatch;
    checks += 1;
}
fn reply(_: ?*anyopaque, _: [*]const u8, _: usize) callconv(.c) void {}
fn create(a: std.mem.Allocator, io: std.Io, cols: u16, rows: u16, lines: usize, bytes: usize) !*vt.Vt {
    return vt.create(a, io, cols, rows, lines, bytes, reply, null);
}
/// A fixed seed generates representative fragments inside UTF-8 and escapes.
fn feed(v: *vt.Vt, text: []const u8) !void {
    var seed: u32 = 0x51ec_7102;
    var offset: usize = 0;
    while (offset < text.len) {
        seed = seed *% 1664525 +% 1013904223;
        const count = @min(text.len - offset, 1 + @as(usize, seed % 7));
        try vt.feed(v, text[offset..][0..count]);
        offset += count;
    }
}
fn copied(a: std.mem.Allocator, v: *vt.Vt) !?[]const u8 {
    var buffer: [65536]u8 = undefined;
    var len: usize = 0;
    if (vt.lt_vt_copy(v, &buffer, buffer.len, &len) != 0) return null;
    if (len > buffer.len) return error.CopyLimit;
    return try a.dupe(u8, buffer[0..len]);
}
fn equalCopy(a: std.mem.Allocator, v: *vt.Vt, expected: []const u8) !bool {
    return if (try copied(a, v)) |text| std.mem.eql(u8, text, expected) else false;
}
fn settle(v: *vt.Vt) !vt.SearchInfo {
    for (0..4096) |_| {
        var total: usize = 0;
        const rc = vt.lt_vt_search_tick(v, &total);
        if (rc < 0) return error.SearchTick;
        var info: vt.SearchInfo = .{};
        vt.lt_vt_search_info(v, &info);
        // One extra tick after completion also consumes deferred initial
        // selection/feed work; do not serialize scheduler-dependent tick counts.
        if (rc == 0 and !info.running) {
            const last = vt.lt_vt_search_tick(v, &total);
            if (last < 0) return error.SearchTick;
            vt.lt_vt_search_info(v, &info);
            if (last == 0 and !info.running) return info;
        }
    }
    return error.SearchDidNotSettle;
}
fn snapshot(a: std.mem.Allocator, v: *vt.Vt) !Snapshot {
    var cursor: vt.Cursor = .{};
    if (vt.lt_vt_frame(v, &cursor) != 0) return error.Frame;
    var cells: std.ArrayList(Cell) = .empty;
    var raw: vt.Cell = undefined;
    while (vt.lt_vt_next(v, &raw)) {
        if (cells.items.len >= 65536 or raw.len > 4096) return error.FrameLimit;
        try cells.append(a, .{ .x = raw.x, .y = raw.y, .width = raw.width, .flags = raw.flags, .text = try a.dupe(u8, if (raw.len == 0) "" else raw.text.?[0..raw.len]) });
    }
    vt.lt_vt_frame_end(v);
    if (vt.lt_vt_failed(v)) return error.VtFailed;
    var scroll: vt.Scroll = .{};
    vt.lt_vt_scroll_info(v, &scroll);
    var search: vt.SearchInfo = .{};
    vt.lt_vt_search_info(v, &search);
    const text = try copied(a, v);
    return .{ .cells = cells.items, .cursor = cursor, .scroll = scroll, .search = search, .selected = vt.lt_vt_has_selection(v), .copy_ok = text != null, .copied = text orelse "", .bracketed = vt.lt_vt_bracketed(v) };
}
fn record(a: std.mem.Allocator, name: []const u8, v: *vt.Vt) !Snapshot {
    const value = try snapshot(a, v);
    const json = try std.json.Stringify.valueAlloc(a, .{ .fixture = name, .state = value }, .{});
    std.debug.print("N2RESULT {s}\n", .{json});
    records += 1;
    return value;
}
fn flags(value: Snapshot) Summary {
    var result: Summary = .{};
    for (value.cells) |cell| {
        if (cell.flags & 16 != 0) result.selection += 1;
        if (cell.flags & 32 != 0) result.highlights += 1;
        if (cell.flags & 64 != 0) result.current += 1;
    }
    return result;
}
fn link(a: std.mem.Allocator, name: []const u8, v: *vt.Vt, x: c_uint, y: c_uint, expected: []const u8, osc8: bool) !void {
    var uri: [2048]u8 = undefined;
    var len: usize = 0;
    var span: vt.Link = .{};
    const rc = vt.lt_vt_link_at(v, x, y, &uri, uri.len, &len, &span);
    try require(rc == 0 and len <= uri.len and std.mem.eql(u8, uri[0..len], expected) and span.osc8 == osc8, name);
    const json = try std.json.Stringify.valueAlloc(a, .{ .fixture = name, .uri = uri[0..len], .span = span }, .{});
    std.debug.print("N2RESULT {s}\n", .{json});
    records += 1;
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    std.debug.print("N2 facade replay backend={s}; seed=0x51ec7102; clear tests host CSI policy; shell redraw has separate PTY acceptance\n", .{vt.backend_name});

    // Accepted baseline expectation: inclusive cell endpoints include the wide
    // glyph once, retain the combining mark and unwrap the soft row boundary.
    const text = "A中e\xcc\x81123456789";
    const unicode = try create(init.gpa, init.io, 12, 4, 128, 1024 * 1024);
    defer vt.destroy(unicode);
    try feed(unicode, text);
    vt.lt_vt_select(unicode, 0, 0, 0);
    vt.lt_vt_select(unicode, 0, 1, 1);
    try require(try equalCopy(a, unicode, text), "wide, combining and soft-wrap copy has exact UTF8 without inserted newline");
    _ = try record(a, "selection-unicode-soft-wrap", unicode);
    vt.lt_vt_clear_selection(unicode);
    try require(!vt.lt_vt_has_selection(unicode), "clear selection removes ordinary selection");
    _ = try record(a, "selection-cleared", unicode);

    const history = try create(init.gpa, init.io, 12, 3, 128, 1024 * 1024);
    defer vt.destroy(history);
    try feed(history, "alpha\r\nbeta\r\ngamma");
    vt.lt_vt_select(history, 0, 0, 0);
    try feed(history, "\r\ndelta");
    vt.lt_vt_select(history, 3, 0, 1);
    try require(try equalCopy(a, history, "alpha\nbeta"), "tracked drag anchor survives output scrolling into history");
    _ = try record(a, "tracked-anchor-after-output", history);
    vt.lt_vt_scroll_to(history, 0);
    const top = try record(a, "history-top", history);
    try require(top.scroll.offset == 0 and top.scroll.total > top.scroll.len, "absolute scroll reaches history start");
    vt.lt_vt_scroll(history, 1);
    _ = try record(a, "history-relative-scroll", history);
    vt.lt_vt_bottom(history);
    const bottom = try record(a, "history-bottom", history);
    try require(bottom.scroll.offset + bottom.scroll.len == bottom.scroll.total, "bottom scroll reaches final visible rows");
    try require(vt.lt_vt_select_all(history) == 0 and try equalCopy(a, history, "alpha\nbeta\ngamma\ndelta"), "select all includes retained history in text order");
    _ = try record(a, "history-select-all", history);

    // The fixed engine enforces history limits at whole-page boundaries and
    // permits at least one standard page. At only 12 columns that page holds
    // over 2048 rows, so the original narrow fixture never reached pruning.
    // Use the standard page's 215-column grid: its capacity is 215 rows, and
    // this workload crosses several complete historical pages on both APIs.
    const bounded = try create(init.gpa, init.io, 215, 3, 8, 65536);
    defer vt.destroy(bounded);
    try feed(bounded, "old-sentinel\r\n");
    for (0..2048) |_| try feed(bounded, "fresh\r\n");
    try require(vt.lt_vt_select_all(bounded) == 0, "bounded history remains selectable after pruning");
    const retained = (try copied(a, bounded)) orelse return error.MissingBoundedSelection;
    var bar: vt.Scroll = .{};
    vt.lt_vt_scroll_info(bounded, &bar);
    try require(std.mem.indexOf(u8, retained, "old-sentinel") == null and std.mem.indexOf(u8, retained, "fresh") != null and bar.total < 2048, "line and byte bounded history prunes old text without keeping a mirror");
    _ = try record(a, "history-budget-pruned", bounded);

    const search = try create(init.gpa, init.io, 24, 5, 128, 1024 * 1024);
    defer vt.destroy(search);
    try feed(search, "needle xxx needle\r\nother needle");
    vt.lt_vt_select(search, 0, 0, 0);
    vt.lt_vt_select(search, 5, 0, 1);
    try require(vt.lt_vt_search(search, "needle", 6) == 0, "search accepts owned UTF8 query");
    var found = try settle(search);
    try require(found.total == 3 and found.current > 0 and !found.running and try equalCopy(a, search, "needle"), "search completion keeps ordinary selection independent");
    const ready = try record(a, "search-three-matches", search);
    const marked = flags(ready);
    try require(marked.highlights == 18 and marked.current == 6 and marked.selection == 6, "viewport flags distinguish all matches, current match and ordinary selection");
    const original_current = found.current;
    vt.lt_vt_search_next(search, false);
    found = try settle(search);
    try require(found.total == 3 and found.current != original_current, "search next changes selected result");
    _ = try record(a, "search-next", search);
    vt.lt_vt_search_next(search, true);
    found = try settle(search);
    try require(found.current == original_current, "search previous returns to original result");
    _ = try record(a, "search-previous", search);
    try feed(search, "\r\nneedle");
    found = try settle(search);
    try require(found.total == 4, "new PTY output rescans a completed search");
    _ = try record(a, "search-after-new-output", search);
    try require(vt.lt_vt_resize(search, 16, 6, 8, 18) == 0, "search viewport resize succeeds");
    found = try settle(search);
    try require(found.total == 4, "resize preserves logical search matches");
    _ = try record(a, "search-after-resize", search);
    try feed(search, "\x1b[?1049h\x1b[Hneedle ALT");
    found = try settle(search);
    vt.lt_vt_scroll_info(search, &bar);
    try require(bar.alternate and found.total == 1, "alternate screen search uses alternate contents");
    try require(vt.lt_vt_clear_screen(search) != 0, "clear refuses alternate screen");
    _ = try record(a, "search-alternate-screen", search);
    try feed(search, "\x1b[?1049l");
    found = try settle(search);
    vt.lt_vt_scroll_info(search, &bar);
    try require(!bar.alternate and found.total == 4, "returning to primary restores its search results");
    _ = try record(a, "search-primary-restored", search);
    vt.lt_vt_search_close(search);
    found = try settle(search);
    const closed = try record(a, "search-closed", search);
    const unmarked = flags(closed);
    try require(found.total == 0 and found.current == 0 and !found.running and unmarked.highlights == 0 and unmarked.current == 0, "closing search releases results and removes viewport flags");
    // Reopen/close cycles exercise ownership; allocator diagnostics belong to
    // each executable's runtime and are not encoded as engine internals.
    for (0..8) |_| {
        if (vt.lt_vt_search(search, "needle", 6) != 0) return error.SearchSet;
        _ = try settle(search);
        vt.lt_vt_search_close(search);
    }
    try feed(search, "\x1b[?2004h");
    try require(vt.lt_vt_clear_screen(search) == 0 and vt.lt_vt_bracketed(search) and !vt.lt_vt_has_selection(search), "clear erases text and selection while preserving terminal modes");
    _ = try record(a, "clear-preserves-mode", search);
    vt.lt_vt_reset(search);
    found = try settle(search);
    try require(!vt.lt_vt_bracketed(search) and !vt.lt_vt_has_selection(search) and found.total == 0, "reset clears modes, selection and search");
    _ = try record(a, "reset-clears-mode", search);

    const links = try create(init.gpa, init.io, 12, 5, 128, 1024 * 1024);
    defer vt.destroy(links);
    try feed(links, "\x1b]8;;https://actual.example/a?x=1\x1b\\click\x1b]8;;\x1b\\\r\nhttps://example.com/path. ");
    try link(a, "OSC8 returns actual URI rather than display label", links, 2, 0, "https://actual.example/a?x=1", true);
    try link(a, "wrapped URL spans soft rows and trims terminal punctuation", links, 3, 2, "https://example.com/path", false);
    _ = try record(a, "links-visible-screen", links);
    std.debug.print("All N2 VT facade replay checks passed (backend={s}, checks={d}, records={d}).\n", .{ vt.backend_name, checks, records });
}
