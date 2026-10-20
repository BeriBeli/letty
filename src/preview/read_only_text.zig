//! Owned immutable UTF-8 text and grapheme-safe selection/search. No UI or IO.
const std = @import("std");
const unicode = @import("ghostty-vt").unicode;
pub const max_bytes = 2 * 1024 * 1024;
pub const max_lines = 50000;
/// Bound a single shaping call; long lines are rejected, never silently copied partially.
pub const max_line_bytes = 16384;
pub const max_matches = 512;
pub const Line = struct { start: usize, end: usize };
pub const Match = struct { start: usize, end: usize };
pub const Document = struct {
    gpa: std.mem.Allocator,
    text: []u8,
    lines: []Line,
    /// One bit per byte avoids a 4/8-byte index for every ASCII character.
    boundaries: []u8,
    pub fn init(gpa: std.mem.Allocator, bytes: []const u8) !Document {
        if (bytes.len > max_bytes) return error.PreviewTextLimit;
        var line_bytes: usize = 0;
        for (bytes) |byte| {
            if (byte == '\n') line_bytes = 0 else line_bytes += 1;
            if (line_bytes > max_line_bytes) return error.PreviewLongLineLimit;
        }
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        const text = try gpa.dupe(u8, bytes);
        errdefer gpa.free(text);
        const boundaries = try gpa.alloc(u8, (text.len + 8) / 8);
        errdefer gpa.free(boundaries);
        @memset(boundaries, 0);
        var cps: std.ArrayList(u21) = .empty;
        defer cps.deinit(gpa);
        var iter = (try std.unicode.Utf8View.init(text)).iterator();
        while (iter.nextCodepoint()) |cp| try cps.append(gpa, cp);
        var at: usize = 0;
        var cp_at: usize = 0;
        var run_end: usize = 0;
        while (cp_at < cps.items.len) {
            setBoundary(boundaries, at);
            const cp = cps.items[cp_at];
            const count = if (cp < 0x20 or (cp >= 0x7f and cp < 0xa0)) 1 else count: {
                if (run_end <= cp_at) {
                    run_end = cp_at;
                    while (run_end < cps.items.len and cps.items[run_end] >= 0x20 and !(cps.items[run_end] >= 0x7f and cps.items[run_end] < 0xa0)) : (run_end += 1) {}
                }
                break :count unicode.graphemeWidth(u21, cps.items[cp_at..run_end]).len;
            };
            for (cps.items[cp_at..][0..count]) |value| at += if (value < 0x80) @as(usize, 1) else if (value < 0x800) @as(usize, 2) else if (value < 0x10000) @as(usize, 3) else @as(usize, 4);
            cp_at += count;
        }
        setBoundary(boundaries, text.len);
        var lines: std.ArrayList(Line) = .empty;
        errdefer lines.deinit(gpa);
        var start: usize = 0;
        for (text, 0..) |byte, index| if (byte == '\n') {
            if (lines.items.len == max_lines) return error.PreviewLineLimit;
            try lines.append(gpa, .{ .start = start, .end = index });
            start = index + 1;
        };
        if (lines.items.len == max_lines) return error.PreviewLineLimit;
        try lines.append(gpa, .{ .start = start, .end = text.len });
        return .{ .gpa = gpa, .text = text, .lines = try lines.toOwnedSlice(gpa), .boundaries = boundaries };
    }
    pub fn deinit(self: *Document) void {
        self.gpa.free(self.text);
        self.gpa.free(self.lines);
        self.gpa.free(self.boundaries);
        self.* = undefined;
    }
    pub fn boundary(self: *const Document, at: usize) bool {
        return at <= self.text.len and self.boundaries[at / 8] & (@as(u8, 1) << @as(u3, @intCast(at % 8))) != 0;
    }
    pub fn floor(self: *const Document, offset: usize) usize {
        var at = @min(offset, self.text.len);
        while (at > 0 and !self.boundary(at)) at -= 1;
        return at;
    }
    pub fn ceil(self: *const Document, offset: usize) usize {
        var at = @min(offset, self.text.len);
        while (at < self.text.len and !self.boundary(at)) at += 1;
        return at;
    }
    pub fn previous(self: *const Document, at: usize) usize {
        return self.floor(@min(at, self.text.len) -| 1);
    }
    pub fn next(self: *const Document, at: usize) usize {
        return self.ceil(@min(at +| 1, self.text.len));
    }
    pub fn lineAt(self: *const Document, at: usize) usize {
        var low: usize = 0;
        var high = self.lines.len;
        while (low + 1 < high) {
            const middle = (low + high) / 2;
            if (self.lines[middle].start <= at) low = middle else high = middle;
        }
        return low;
    }
    pub fn find(self: *const Document, query: []const u8, out: []Match) usize {
        if (query.len == 0 or !std.unicode.utf8ValidateSlice(query)) return 0;
        var offset: usize = 0;
        var count: usize = 0;
        while (std.mem.indexOfPos(u8, self.text, offset, query)) |at| {
            if (count == out.len) break;
            const end = at + query.len;
            if (self.boundary(at) and self.boundary(end)) {
                out[count] = .{ .start = at, .end = end };
                count += 1;
            }
            offset = at + 1;
        }
        return count;
    }
};
fn setBoundary(bytes: []u8, at: usize) void {
    bytes[at / 8] |= @as(u8, 1) << @as(u3, @intCast(at % 8));
}
pub const Selection = struct {
    anchor: usize = 0,
    caret: usize = 0,
    dragging: bool = false,
    pub fn range(self: Selection) Match {
        return .{ .start = @min(self.anchor, self.caret), .end = @max(self.anchor, self.caret) };
    }
    pub fn selected(self: Selection, doc: *const Document) []const u8 {
        const span = self.range();
        return doc.text[@min(span.start, doc.text.len)..@min(span.end, doc.text.len)];
    }
    pub fn place(self: *Selection, doc: *const Document, at: usize, extend: bool) void {
        self.caret = doc.floor(at);
        if (!extend) self.anchor = self.caret;
    }
    pub fn all(self: *Selection, doc: *const Document) void {
        self.anchor = 0;
        self.caret = doc.text.len;
    }
    pub fn move(self: *Selection, doc: *const Document, direction: enum { left, right, up, down, home, end, start, finish }, extend: bool) void {
        const line = doc.lineAt(self.caret);
        const current = doc.lines[line];
        const at = switch (direction) {
            .left => doc.previous(self.caret),
            .right => doc.next(self.caret),
            .home => current.start,
            .end => current.end,
            .start => 0,
            .finish => doc.text.len,
            .up, .down => blk: {
                const target = doc.lines[if (direction == .up) line -| 1 else @min(line + 1, doc.lines.len - 1)];
                break :blk target.start + @min(self.caret - current.start, target.end - target.start);
            },
        };
        self.place(doc, at, extend);
    }
};
test "read-only selection uses owned grapheme boundaries across CJK emoji combining and blocks" {
    var d = try Document.init(std.testing.allocator, "# title\n中👩‍💻é\ncode\n");
    defer d.deinit();
    var selection: Selection = .{};
    selection.place(&d, 11, false);
    selection.move(&d, .right, true);
    try std.testing.expectEqualStrings("👩‍💻", selection.selected(&d));
    selection.move(&d, .right, true);
    try std.testing.expectEqualStrings("👩‍💻é", selection.selected(&d));
    selection.all(&d);
    try std.testing.expectEqualStrings(d.text, selection.selected(&d));
    try std.testing.expectEqual(@as(usize, 4), d.lines.len);
}
test "read-only find rejects matches inside a composed grapheme and retains absolute offsets" {
    var d = try Document.init(std.testing.allocator, "中 é\n中");
    defer d.deinit();
    var matches: [8]Match = undefined;
    try std.testing.expectEqual(@as(usize, 0), d.find("e", &matches));
    try std.testing.expectEqual(@as(usize, 2), d.find("中", &matches));
    try std.testing.expectEqual(@as(usize, 0), matches[0].start);
    try std.testing.expectEqual(@as(usize, 1), d.lineAt(matches[1].start));
}
