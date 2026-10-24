//! Shared bounded unified-patch model for Git and SVN, including properties.
const std = @import("std");
const A = std.mem.Allocator;
pub const Line = struct { kind: enum { meta, context, removed, added }, text: []const u8, old: ?u32 = null, new: ?u32 = null };
pub const Pair = struct { left: ?usize = null, right: ?usize = null };
pub const Model = struct {
    version: ?u64 = null,
    source: []const u8 = "",
    lines: std.ArrayList(Line) = .empty,
    pairs: std.ArrayList(Pair) = .empty,
    pub fn deinit(self: *Model, a: A) void {
        if (self.source.len > 0) a.free(self.source);
        self.lines.deinit(a);
        self.pairs.deinit(a);
    }
    pub fn load(self: *Model, a: A, source: []const u8, version: u64) !void {
        if (self.version == version) return;
        var replacement: Model = .{ .version = version };
        errdefer replacement.deinit(a);
        replacement.source = if (source.len > 0) try a.dupe(u8, source) else "";
        var old: Range = .{};
        var new: Range = .{};
        var properties = false;
        var iterator = std.mem.splitScalar(u8, replacement.source, '\n');
        while (iterator.next()) |text| {
            if (replacement.lines.items.len >= 100000) return error.DiffLineLimit;
            var line: Line = .{ .kind = .meta, .text = text };
            if (text.len > 0 and (old.left > 0 or new.left > 0)) {
                // Hunk length, not header-like text, determines whether a line
                // is content. Source lines can themselves start with ---/+++.
                if (text[0] == '-' and old.left > 0) {
                    line = .{ .kind = .removed, .text = text[1..], .old = if (properties) null else old.number };
                    old.advance();
                } else if (text[0] == '+' and new.left > 0) {
                    line = .{ .kind = .added, .text = text[1..], .new = if (properties) null else new.number };
                    new.advance();
                } else if (text[0] == ' ' and old.left > 0 and new.left > 0) {
                    line = .{ .kind = .context, .text = text[1..], .old = if (properties) null else old.number, .new = if (properties) null else new.number };
                    old.advance();
                    new.advance();
                }
            } else if (std.mem.startsWith(u8, text, "@@ -") or std.mem.startsWith(u8, text, "## -")) {
                properties = text[0] == '#';
                var parts = std.mem.tokenizeScalar(u8, text[3..], ' ');
                old = parseRange(parts.next() orelse "");
                new = parseRange(parts.next() orelse "");
            }
            try replacement.lines.append(a, line);
        }
        var i: usize = 0;
        while (i < replacement.lines.items.len) {
            if (replacement.lines.items[i].kind == .removed) {
                const start = i;
                while (i < replacement.lines.items.len and replacement.lines.items[i].kind == .removed) : (i += 1) {}
                const added = i;
                while (i < replacement.lines.items.len and replacement.lines.items[i].kind == .added) : (i += 1) {}
                for (0..@max(added - start, i - added)) |n| try replacement.pairs.append(a, .{ .left = if (n < added - start) start + n else null, .right = if (n < i - added) added + n else null });
            } else {
                try replacement.pairs.append(a, .{ .left = if (replacement.lines.items[i].kind != .added) i else null, .right = i });
                i += 1;
            }
        }
        self.deinit(a);
        self.* = replacement;
    }
};
const Range = struct {
    number: u32 = 0,
    left: u32 = 0,
    fn advance(self: *Range) void {
        self.left -|= 1;
        self.number +|= 1;
    }
};
fn parseRange(raw: []const u8) Range {
    if (raw.len < 2 or (raw[0] != '-' and raw[0] != '+')) return .{};
    var parts = std.mem.splitScalar(u8, raw[1..], ',');
    const number = std.fmt.parseInt(u32, parts.next() orelse return .{}, 10) catch return .{};
    const left = if (parts.next()) |count| std.fmt.parseInt(u32, count, 10) catch return .{} else 1;
    if (parts.next() != null) return .{};
    return .{ .number = number, .left = left };
}
test "Git and SVN unified hunks share line numbers and split pairs" {
    const a = std.testing.allocator;
    var model: Model = .{};
    defer model.deinit(a);
    try model.load(a, "Index: module.sv\n===\n--- module.sv\t(revision 2)\n+++ module.sv\t(working copy)\n@@ -3,2 +3,3 @@\n--- source\n+++ source\n+new\n context\n", 1);
    try std.testing.expectEqualStrings("-- source", model.lines.items[5].text);
    try std.testing.expectEqual(@as(?u32, 3), model.lines.items[5].old);
    try std.testing.expectEqual(@as(?u32, 3), model.lines.items[6].new);
    try std.testing.expectEqual(@as(?u32, 4), model.lines.items[8].old);
    try std.testing.expectEqual(@as(?u32, 5), model.lines.items[8].new);
    try std.testing.expectEqual(@as(?usize, 5), model.pairs.items[5].left);
    try std.testing.expectEqual(@as(?usize, 6), model.pairs.items[5].right);
    try std.testing.expectEqual(@as(?usize, null), model.pairs.items[6].left);
}
test "SVN properties and binary notices stay metadata without invented file line numbers" {
    var model: Model = .{};
    defer model.deinit(std.testing.allocator);
    try model.load(std.testing.allocator, "Property changes on: .\n__________________\nModified: test:prop\n## -1 +1 ##\n-before\n+after\nCannot display: binary file\n--- separator\n", 1);
    try std.testing.expect(model.lines.items[4].kind == .removed and model.lines.items[4].old == null);
    try std.testing.expect(model.lines.items[5].kind == .added and model.lines.items[5].new == null);
    try std.testing.expect(model.lines.items[7].kind == .meta);
    try model.load(std.testing.allocator, "", 2);
    try std.testing.expectEqualStrings("", model.source);
}

pub const Match = struct { line: usize, start: usize, end: usize };
pub const Search = struct {
    matches: std.ArrayList(Match) = .empty,
    selected: usize = 0,
    limited: bool = false,
    pub fn deinit(self: *Search, a: A) void {
        self.matches.deinit(a);
    }
    pub fn find(self: *Search, a: A, lines: []const Line, query: []const u8) !void {
        self.matches.clearRetainingCapacity();
        self.selected = 0;
        self.limited = false;
        if (query.len == 0 or query.len > 4096) return;
        for (lines, 0..) |line, index| {
            var offset: usize = 0;
            while (std.ascii.findIgnoreCase(line.text[offset..], query)) |found| {
                if (self.matches.items.len == 8192) {
                    self.limited = true;
                    return;
                }
                const start = offset + found;
                try self.matches.append(a, .{ .line = index, .start = start, .end = start + query.len });
                offset = start + query.len;
            }
        }
    }
    pub fn next(self: *Search, backwards: bool) void {
        const count = self.matches.items.len;
        if (count == 0) return;
        self.selected = if (backwards) (self.selected + count - 1) % count else (self.selected + 1) % count;
    }
};
test "diff search wraps, finds Unicode and bounds dense results" {
    const a = std.testing.allocator;
    var search: Search = .{};
    defer search.deinit(a);
    try search.find(a, &.{ .{ .kind = .added, .text = "Hello 你好 hello" }, .{ .kind = .removed, .text = "hello" } }, "HELLO");
    try std.testing.expectEqual(@as(usize, 3), search.matches.items.len);
    search.next(true);
    try std.testing.expectEqual(@as(usize, 2), search.selected);
    search.next(false);
    try std.testing.expectEqual(@as(usize, 0), search.selected);
    try search.find(a, &.{.{ .kind = .context, .text = "你好" }}, "好");
    try std.testing.expectEqual(@as(usize, 3), search.matches.items[0].start);
    const many = try a.alloc(u8, 9000);
    defer a.free(many);
    @memset(many, 'x');
    try search.find(a, &.{.{ .kind = .context, .text = many }}, "x");
    try std.testing.expect(search.limited and search.matches.items.len == 8192);
}
