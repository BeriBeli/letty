//! Copies OSC 8 targets and printed links directly from the native VT pages.
const std = @import("std");
const ghostty = @import("ghostty-vt");
const paths = @import("paths.zig");
pub const Link = struct { text: []const u8, first: ghostty.Coordinate, last: ghostty.Coordinate };
fn cell(t: *ghostty.Terminal, x: u16, y: u16) ?struct { page: *ghostty.Page, value: *ghostty.page.Cell, wrapped: bool } {
    const pin = t.screens.active.pages.pin(.{ .viewport = .{ .x = x, .y = y } }) orelse return null;
    const page = pin.node.page();
    const rc = page.getRowAndCell(x, pin.y);
    return .{ .page = page, .value = rc.cell, .wrapped = rc.row.wrap };
}
fn uri(t: *ghostty.Terminal, x: u16, y: u16) ?[]const u8 {
    const current = cell(t, x, y) orelse return null;
    const id = current.page.lookupHyperlink(current.value) orelse return null;
    return current.page.hyperlink_set.get(current.page.memory, id).uri.slice(current.page.memory);
}
pub fn at(a: std.mem.Allocator, t: *ghostty.Terminal, x: u16, y: u16) !?Link {
    if (x >= t.cols or y >= t.rows) return null;
    if (uri(t, x, y)) |value| {
        if (value.len == 0 or value.len > 8192 or !supported(value)) return null;
        var first = x;
        var last = x;
        while (first > 0) {
            const other = uri(t, first - 1, y) orelse break;
            if (!std.mem.eql(u8, value, other)) break;
            first -= 1;
        }
        while (last + 1 < t.cols) {
            const other = uri(t, last + 1, y) orelse break;
            if (!std.mem.eql(u8, value, other)) break;
            last += 1;
        }
        return .{ .text = try a.dupe(u8, value), .first = .{ .x = first, .y = y }, .last = .{ .x = last, .y = y } };
    }
    var first_y = y;
    var last_y = y;
    while (first_y > 0 and y - first_y < 8) {
        const c = cell(t, 0, first_y - 1) orelse break;
        if (!c.wrapped) break;
        first_y -= 1;
    }
    while (last_y + 1 < t.rows and last_y - first_y < 16) {
        const c = cell(t, 0, last_y) orelse break;
        if (!c.wrapped) break;
        last_y += 1;
    }
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    const Span = struct { offset: usize, point: ghostty.Coordinate };
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(a);
    var clicked: usize = 0;
    var row = first_y;
    while (row <= last_y) : (row += 1) {
        var col: u16 = 0;
        while (col < t.cols) : (col += 1) {
            if (text.items.len >= 8192) return null;
            const c = cell(t, col, row) orelse return null;
            if (col == x and row == y) clicked = text.items.len;
            if (c.value.wide == .spacer_head or c.value.wide == .spacer_tail) continue;
            try spans.append(a, .{ .offset = text.items.len, .point = .{ .x = col, .y = row } });
            var bytes: [4]u8 = undefined;
            const cp: u21 = if (c.value.hasText()) c.value.codepoint() else ' ';
            const n = try std.unicode.utf8Encode(cp, &bytes);
            try text.appendSlice(a, bytes[0..n]);
            if (c.page.lookupGrapheme(c.value)) |extra| for (extra) |part| {
                const count = try std.unicode.utf8Encode(part, &bytes);
                try text.appendSlice(a, bytes[0..count]);
            };
        }
    }
    if (clicked >= text.items.len) return null;
    var start = clicked;
    var end = clicked;
    while (start > 0 and !boundary(text.items[start - 1])) start -= 1;
    while (end < text.items.len and !boundary(text.items[end])) end += 1;
    // Printed prose commonly wraps URLs in punctuation. Preserve balanced URL parentheses.
    while (end > start and std.mem.indexOfScalar(u8, ".,;!?)]}:", text.items[end - 1]) != null) {
        const ch = text.items[end - 1];
        if (ch == ')' and std.mem.count(u8, text.items[start..end], "(") >= std.mem.count(u8, text.items[start..end], ")")) break;
        end -= 1;
    }
    if (clicked >= end or start == end or !supported(text.items[start..end])) return null;
    var first: ghostty.Coordinate = .{ .x = x, .y = y };
    var last = first;
    for (spans.items) |span| {
        if (span.offset == start) first = span.point;
        if (span.offset >= start and span.offset < end) last = span.point;
    }
    return .{ .text = try a.dupe(u8, text.items[start..end]), .first = first, .last = last };
}
fn boundary(ch: u8) bool {
    return std.ascii.isWhitespace(ch) or std.mem.indexOfScalar(u8, "\"'`<>|", ch) != null;
}
pub fn supported(value: []const u8) bool {
    if (paths.web(value) or std.mem.startsWith(u8, value, "file://")) return std.mem.indexOfAny(u8, value, "\r\n\x00") == null;
    const clean = paths.stripLine(value);
    if (std.mem.indexOfScalar(u8, clean, ':') != null or std.mem.indexOfAny(u8, clean, "\r\n\x00") == null and clean.len == 0) return false;
    return std.mem.indexOfScalar(u8, clean, '/') != null or std.fs.path.extension(clean).len > 1;
}
test "native links copy OSC targets and find soft-wrapped printed URLs without retaining page memory" {
    const a = std.testing.allocator;
    var t = try ghostty.Terminal.init(std.testing.io, a, .{ .cols = 20, .rows = 4 });
    defer t.deinit(a);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b]8;;https://example.com/private?q=1\x07label\x1b]8;;\x07\r\nhttps://example.com/long/path\r\n");
    const explicit = (try at(a, &t, 1, 0)).?;
    defer a.free(explicit.text);
    try std.testing.expectEqualStrings("https://example.com/private?q=1", explicit.text);
    const printed = (try at(a, &t, 2, 2)).?;
    defer a.free(printed.text);
    try std.testing.expectEqualStrings("https://example.com/long/path", printed.text);
    stream.nextSlice("\x1b[2J\x1b[Hchanged");
    try std.testing.expectEqualStrings("https://example.com/private?q=1", explicit.text);
    try std.testing.expect(!supported("javascript:alert(1)"));
}
