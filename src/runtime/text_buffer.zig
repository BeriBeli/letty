//! Bounded UTF-8 editing with native Ghostty grapheme boundaries and owned undo.
const std = @import("std");
const ghostty = @import("ghostty-vt");
const A = std.mem.Allocator;
pub const Buffer = struct {
    text: []const u8 = "",
    caret: usize = 0,
    anchor: usize = 0,
    revision: u64 = 0,
    undo: std.ArrayList(Snapshot) = .empty,
    redo: std.ArrayList(Snapshot) = .empty,
    history_bytes: usize = 0,
    goal_column: ?usize = null,
    const Snapshot = struct { text: []const u8, caret: usize, anchor: usize };
    pub const limit = 1024 * 1024;
    pub fn init(a: A, text: []const u8) !Buffer {
        try valid(text);
        return .{ .text = try a.dupe(u8, text) };
    }
    pub fn deinit(self: *Buffer, a: A) void {
        a.free(self.text);
        self.clear(a, &self.undo);
        self.clear(a, &self.redo);
        self.* = .{};
    }
    fn clear(self: *Buffer, a: A, stack: *std.ArrayList(Snapshot)) void {
        for (stack.items) |item| {
            self.history_bytes -= item.text.len;
            a.free(item.text);
        }
        stack.deinit(a);
        stack.* = .empty;
    }
    pub fn selection(self: *const Buffer) [2]usize {
        return .{ @min(self.caret, self.anchor), @max(self.caret, self.anchor) };
    }
    pub fn insert(self: *Buffer, a: A, value: []const u8) !void {
        const range = self.selection();
        try self.replace(a, range[0], range[1], value);
    }
    pub fn replace(self: *Buffer, a: A, from: usize, to: usize, value: []const u8) !void {
        if (from > to or to > self.text.len or !boundary(self.text, from) or !boundary(self.text, to)) return error.InvalidEditRange;
        try valid(value);
        const length = self.text.len - (to - from) + value.len;
        if (length > limit) return error.EditLimit;
        const replacement = try a.alloc(u8, length);
        errdefer a.free(replacement);
        @memcpy(replacement[0..from], self.text[0..from]);
        @memcpy(replacement[from..][0..value.len], value);
        @memcpy(replacement[from + value.len ..], self.text[to..]);
        try self.undo.ensureUnusedCapacity(a, 1);
        self.clear(a, &self.redo);
        self.undo.appendAssumeCapacity(.{ .text = self.text, .caret = self.caret, .anchor = self.anchor });
        self.history_bytes += self.text.len;
        self.text = replacement;
        self.caret = from + value.len;
        self.anchor = self.caret;
        self.revision +%= 1;
        self.goal_column = null;
        self.trim(a);
    }
    fn trim(self: *Buffer, a: A) void {
        while (self.undo.items.len + self.redo.items.len > 64 or self.history_bytes > 8 * 1024 * 1024) {
            const stack = if (self.undo.items.len > 0) &self.undo else &self.redo;
            const old = stack.orderedRemove(0);
            self.history_bytes -= old.text.len;
            a.free(old.text);
        }
    }
    pub fn history(self: *Buffer, a: A, forward: bool) !void {
        const from = if (forward) &self.redo else &self.undo;
        const to = if (forward) &self.undo else &self.redo;
        if (from.items.len == 0) return;
        try to.ensureUnusedCapacity(a, 1);
        const item = from.pop().?;
        self.history_bytes -= item.text.len;
        self.history_bytes += self.text.len;
        to.appendAssumeCapacity(.{ .text = self.text, .caret = self.caret, .anchor = self.anchor });
        self.text = item.text;
        self.caret = item.caret;
        self.anchor = item.anchor;
        self.goal_column = null;
        self.trim(a);
        self.revision +%= 1;
    }
    pub fn move(self: *Buffer, to: usize, extend: bool) void {
        self.caret = @min(to, self.text.len);
        while (!boundary(self.text, self.caret)) self.caret -= 1;
        self.goal_column = null;
        if (!extend) self.anchor = self.caret;
    }
    pub fn previous(self: *const Buffer, at: usize) usize {
        if (at == 0) return 0;
        var pos = lineStart(self.text, at);
        if (pos == at) return at - 1;
        var previous_pos = pos;
        while (pos < at) {
            previous_pos = pos;
            pos = next(self.text, pos);
        }
        return previous_pos;
    }
    pub fn wordLeft(self: *const Buffer, at: usize) usize {
        // One forward pass avoids repeatedly rescanning the same long line
        // through previous() for every character of a word.
        var pos: usize = 0;
        var run: usize = 0;
        var last: usize = 0;
        var kind: enum { space, word, punctuation } = .space;
        while (pos < at) {
            const end = @min(at, next(self.text, pos));
            const value = self.text[pos..end];
            const current: @TypeOf(kind) = if (space(value)) .space else if (isWord(value)) .word else .punctuation;
            if (current != kind) run = pos;
            if (current != .space) last = run;
            kind = current;
            pos = end;
        }
        return last;
    }
    pub fn wordRight(self: *const Buffer, at: usize) usize {
        var pos = at;
        if (pos >= self.text.len) return pos;
        const word = isWord(self.text[pos..next(self.text, pos)]);
        while (pos < self.text.len) {
            const end = next(self.text, pos);
            if (space(self.text[pos..end]) or isWord(self.text[pos..end]) != word) break;
            pos = end;
        }
        while (pos < self.text.len) {
            const end = next(self.text, pos);
            if (!space(self.text[pos..end])) break;
            pos = end;
        }
        return pos;
    }
    pub fn vertical(self: *Buffer, down: bool, extend: bool) void {
        const start = lineStart(self.text, self.caret);
        const column = self.goal_column orelse visualColumn(self.text, start, self.caret);
        const target = if (down) blk: {
            const end = lineEnd(self.text, self.caret);
            if (end >= self.text.len) break :blk self.text.len;
            break :blk end + 1;
        } else if (start > 0) lineStart(self.text, start - 1) else 0;
        const end = lineEnd(self.text, target);
        var at = target;
        var cells: usize = 0;
        while (at < end) {
            const item = cluster(self.text, at);
            const width = if (self.text[at] == '\t') 4 - cells % 4 else item.width;
            if (cells + width > column) break;
            cells += width;
            at = item.end;
        }
        self.move(at, extend);
        self.goal_column = column;
    }
};
/// A native IME preedit is separate from the saved document and undo history.
/// Repeated set_marked operations replace only this owned preedit; commit is
/// one document edit, including replacement of the original selected range.
pub const Composition = struct {
    text: []const u8 = "",
    range: ?[2]usize = null,
    caret: usize = 0,
    anchor: usize = 0,
    pub const Display = struct { text: []const u8, caret: usize, anchor: usize, marked: ?[2]usize };
    pub fn clear(self: *Composition, a: A) void {
        a.free(self.text);
        self.* = .{};
    }
    pub fn set(self: *Composition, a: A, buffer: *const Buffer, value: []const u8, start: usize, length: usize) !void {
        if (value.len > 65536) return error.CompositionLimit;
        try valid(value);
        const range = self.range orelse buffer.selection();
        if (buffer.text.len - (range[1] - range[0]) + value.len > Buffer.limit) return error.EditLimit;
        const owned = try a.dupe(u8, value);
        a.free(self.text);
        self.text = owned;
        self.range = if (value.len > 0) range else null;
        self.anchor = snap(value, start);
        self.caret = snap(value, start +| length);
    }
    pub fn display(self: *const Composition, a: A, buffer: *const Buffer) !Display {
        if (self.range) |range| return .{
            .text = try std.mem.concat(a, u8, &.{ buffer.text[0..range[0]], self.text, buffer.text[range[1]..] }),
            .caret = range[0] + self.caret,
            .anchor = range[0] + self.anchor,
            .marked = .{ range[0], range[0] + self.text.len },
        };
        return .{ .text = buffer.text, .caret = buffer.caret, .anchor = buffer.anchor, .marked = null };
    }
    pub fn commit(self: *Composition, a: A, buffer: *Buffer, value: []const u8) !void {
        const range = self.range orelse buffer.selection();
        try buffer.replace(a, range[0], range[1], value);
        self.clear(a);
    }
    pub fn finish(self: *Composition, a: A, buffer: *Buffer) !void {
        if (self.range != null) try self.commit(a, buffer, self.text);
    }
};
fn snap(value: []const u8, position: usize) usize {
    var at = @min(value.len, position);
    while (!boundary(value, at)) at -= 1;
    return at;
}

fn valid(text: []const u8) !void {
    if (text.len > Buffer.limit or !std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidEditText;
}
fn boundary(text: []const u8, at: usize) bool {
    return at == text.len or at == 0 or (text[at] & 0xc0) != 0x80;
}
pub fn lineStart(text: []const u8, at: usize) usize {
    return if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |i| i + 1 else 0;
}
pub fn lineEnd(text: []const u8, at: usize) usize {
    return at + (std.mem.indexOfScalar(u8, text[at..], '\n') orelse (text.len - at));
}
pub fn next(text: []const u8, at: usize) usize {
    return cluster(text, at).end;
}
const Cluster = struct { end: usize, width: usize };
fn cluster(text: []const u8, at: usize) Cluster {
    if (at >= text.len) return .{ .end = text.len, .width = 0 };
    if (text[at] < 32 or text[at] == 0x7f) return .{ .end = at + 1, .width = 0 };
    if (text[at] < 128 and (at + 1 == text.len or text[at + 1] < 128)) return .{ .end = at + 1, .width = ghostty.unicode.codepointWidth(@intCast(text[at])) };
    // Stream the official native break/width kernel: a valid cluster may
    // contain any number of combining characters within the document limit.
    var state: ghostty.unicode.GraphemeBreakState = .default;
    var iter = std.unicode.Utf8View.initUnchecked(text[at..]).iterator();
    const first = iter.nextCodepointSlice().?;
    var previous_cp = std.unicode.utf8Decode(first) catch unreachable;
    if (previous_cp >= 0x7f and previous_cp <= 0x9f) return .{ .end = at + first.len, .width = 0 };
    var width: usize = ghostty.unicode.codepointWidth(previous_cp);
    var end = at + first.len;
    while (iter.nextCodepointSlice()) |raw| {
        const cp = std.unicode.utf8Decode(raw) catch unreachable;
        if (cp < 32 or (cp >= 0x7f and cp <= 0x9f)) break;
        const before = state;
        if (ghostty.unicode.graphemeBreak(previous_cp, cp, &state)) break;
        switch (ghostty.unicode.graphemeWidthEffect(previous_cp, cp)) {
            .ignore => state = before,
            .no_change => previous_cp = cp,
            .wide => {
                width = 2;
                previous_cp = cp;
            },
            .narrow => {
                width = 1;
                previous_cp = cp;
            },
        }
        end += raw.len;
    }
    return .{ .end = end, .width = width };
}
fn visualColumn(text: []const u8, start: usize, end: usize) usize {
    var cells: usize = 0;
    var at = start;
    while (at < end) {
        const item = cluster(text, at);
        cells += if (text[at] == '\t') 4 - cells % 4 else item.width;
        at = item.end;
    }
    return cells;
}
test "native grapheme edits and undo retain composed Unicode and reject oversized replacements" {
    const a = std.testing.allocator;
    var b = try Buffer.init(a, "e\xcc\x81中文\nlast");
    defer b.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), next(b.text, 0));
    b.caret = 3;
    b.anchor = 3;
    try b.replace(a, b.previous(b.caret), b.caret, "");
    try std.testing.expectEqualStrings("中文\nlast", b.text);
    try b.history(a, false);
    try std.testing.expectEqualStrings("e\xcc\x81中文\nlast", b.text);
    try b.history(a, true);
    try std.testing.expectEqualStrings("中文\nlast", b.text);
    try std.testing.expectError(error.InvalidEditRange, b.replace(a, 1, 2, "x"));
}

fn space(value: []const u8) bool {
    return value.len == 1 and std.ascii.isWhitespace(value[0]);
}
fn isWord(value: []const u8) bool {
    return value.len > 0 and (value[0] >= 128 or value[0] == '_' or std.ascii.isAlphanumeric(value[0]));
}

test "vertical editor movement retains visual columns across short Unicode lines" {
    const a = std.testing.allocator;
    var buffer = try Buffer.init(a, "e\xcc\x81中X\nq\nab中z");
    defer buffer.deinit(a);
    buffer.move(6, false);
    buffer.vertical(true, false);
    try std.testing.expectEqual(@as(usize, 9), buffer.caret);
    buffer.vertical(true, false);
    try std.testing.expectEqual(@as(usize, 12), buffer.caret);
    buffer.vertical(false, false);
    buffer.vertical(false, false);
    try std.testing.expectEqual(@as(usize, 6), buffer.caret);
    buffer.move(4, false); // Inside 中 snaps to a valid UTF-8 boundary.
    try std.testing.expectEqual(@as(usize, 3), buffer.caret);
}
test "undo and redo never grow the retained history past its byte budget" {
    const a = std.testing.allocator;
    const text = try a.alloc(u8, Buffer.limit);
    defer a.free(text);
    @memset(text, 'x');
    var buffer = try Buffer.init(a, text[0 .. 3 * Buffer.limit / 4]);
    defer buffer.deinit(a);
    for (0..7) |_| try buffer.replace(a, 0, buffer.text.len, text);
    try buffer.replace(a, 0, buffer.text.len, text[0 .. Buffer.limit / 4]);
    try buffer.replace(a, 0, buffer.text.len, text);
    try std.testing.expectEqual(@as(usize, 8 * Buffer.limit), buffer.history_bytes);
    try buffer.history(a, false);
    try std.testing.expect(buffer.history_bytes <= 8 * Buffer.limit);
    try buffer.history(a, true);
    try std.testing.expect(buffer.history_bytes <= 8 * Buffer.limit);
}

test "long native graphemes remain indivisible and word-left scans a bounded document" {
    const a = std.testing.allocator;
    var sequence: std.ArrayList(u8) = .empty;
    defer sequence.deinit(a);
    try sequence.append(a, 'e');
    for (0..4096) |_| try sequence.appendSlice(a, "\xcc\x81");
    const cluster_end = sequence.items.len;
    try sequence.appendSlice(a, "中 x");
    var buffer = try Buffer.init(a, sequence.items);
    defer buffer.deinit(a);
    try std.testing.expectEqual(cluster_end, next(buffer.text, 0));
    try std.testing.expectEqual(@as(usize, 0), buffer.previous(cluster_end));
    try std.testing.expectEqual(@as(usize, 0), buffer.wordLeft(cluster_end + 3));
    try std.testing.expectEqual(cluster_end + 4, buffer.wordLeft(buffer.text.len));
    try buffer.replace(a, 0, cluster_end, "");
    try std.testing.expectEqualStrings("中 x", buffer.text);
    const long = try a.alloc(u8, Buffer.limit);
    defer a.free(long);
    @memset(long, 'w');
    var word = try Buffer.init(a, long);
    defer word.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), word.wordLeft(word.text.len));
}

test "IME preedit retains selection, uses byte offsets and commits once into undo" {
    const a = std.testing.allocator;
    var buffer = try Buffer.init(a, "before OLD after");
    defer buffer.deinit(a);
    buffer.move(7, false);
    buffer.move(10, true);
    var composition: Composition = .{};
    defer composition.clear(a);
    try composition.set(a, &buffer, "ni", 2, 0);
    try composition.set(a, &buffer, "你好", 3, 3);
    try std.testing.expectEqual(@as(usize, 0), buffer.undo.items.len);
    try std.testing.expectEqualStrings("before OLD after", buffer.text);
    const display = try composition.display(a, &buffer);
    defer a.free(display.text);
    try std.testing.expectEqualStrings("before 你好 after", display.text);
    try std.testing.expectEqual(@as(usize, 13), display.caret);
    try std.testing.expectEqual(@as(usize, 10), display.anchor);
    try std.testing.expectEqual([2]usize{ 7, 13 }, display.marked.?);
    try composition.finish(a, &buffer);
    try std.testing.expect(composition.range == null);
    try std.testing.expectEqualStrings("before 你好 after", buffer.text);
    try std.testing.expectEqual(@as(usize, 1), buffer.undo.items.len);
    try buffer.history(a, false);
    try std.testing.expectEqualStrings("before OLD after", buffer.text);
    try composition.set(a, &buffer, "你好", 1, 1);
    try std.testing.expectEqual(@as(usize, 0), composition.anchor);
    try std.testing.expectEqual(@as(usize, 0), composition.caret);
    try std.testing.expectError(error.InvalidEditText, composition.set(a, &buffer, "\xff", 0, 0));
    try std.testing.expectEqualStrings("你好", composition.text);
    composition.clear(a);
    try std.testing.expectEqualStrings("before OLD after", buffer.text);
}
