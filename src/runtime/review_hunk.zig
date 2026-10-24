//! Reverse one verified text hunk, retaining every byte outside that hunk.
const std = @import("std");
const A = std.mem.Allocator;
pub fn revert(a: A, patch: []const u8, header_offset: usize, current: []const u8) ![]const u8 {
    if (header_offset >= patch.len or (header_offset > 0 and patch[header_offset - 1] != '\n') or !std.mem.startsWith(u8, patch[header_offset..], "@@ -")) return error.InvalidHunk;
    var lines = std.mem.splitScalar(u8, patch[header_offset..], '\n');
    const header = lines.next().?;
    var parts = std.mem.tokenizeScalar(u8, header[3..], ' ');
    const old = try range(parts.next() orelse return error.InvalidHunk);
    const new = try range(parts.next() orelse return error.InvalidHunk);
    var old_left = old.count;
    var new_left = new.count;
    var old_bytes: std.ArrayList(u8) = .empty;
    defer old_bytes.deinit(a);
    var new_bytes: std.ArrayList(u8) = .empty;
    defer new_bytes.deinit(a);
    var last: u8 = 0;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "\\ No newline")) {
            if ((last == '-' or last == ' ') and old_bytes.items.len > 0) _ = old_bytes.pop();
            if ((last == '+' or last == ' ') and new_bytes.items.len > 0) _ = new_bytes.pop();
            continue;
        }
        if (old_left == 0 and new_left == 0) break;
        if (line.len == 0) return error.InvalidHunk;
        last = line[0];
        if (last == '-' or last == ' ') {
            if (old_left == 0) return error.InvalidHunk;
            old_left -= 1;
            try old_bytes.appendSlice(a, line[1..]);
            try old_bytes.append(a, '\n');
        }
        if (last == '+' or last == ' ') {
            if (new_left == 0) return error.InvalidHunk;
            new_left -= 1;
            try new_bytes.appendSlice(a, line[1..]);
            try new_bytes.append(a, '\n');
        }
        if (last != '-' and last != '+' and last != ' ') return error.InvalidHunk;
    }
    if (old_left != 0 or new_left != 0) return error.InvalidHunk;
    const line_number = if (new.count == 0) new.start else new.start -| 1;
    var offset: usize = 0;
    for (0..line_number) |_| {
        const next = std.mem.indexOfScalar(u8, current[offset..], '\n') orelse return error.HunkChangedExternally;
        offset += next + 1;
    }
    if (new_bytes.items.len > current.len - offset or !std.mem.eql(u8, new_bytes.items, current[offset..][0..new_bytes.items.len])) return error.HunkChangedExternally;
    if (current.len - new_bytes.items.len + old_bytes.items.len > 1024 * 1024) return error.EditLimit;
    return std.mem.concat(a, u8, &.{ current[0..offset], old_bytes.items, current[offset + new_bytes.items.len ..] });
}
const Range = struct { start: usize, count: usize };
fn range(raw: []const u8) !Range {
    if (raw.len < 2) return error.InvalidHunk;
    var parts = std.mem.splitScalar(u8, raw[1..], ',');
    const start = try std.fmt.parseInt(usize, parts.next().?, 10);
    const count = if (parts.next()) |value| try std.fmt.parseInt(usize, value, 10) else 1;
    if (start > 1024 * 1024 or count > 1024 * 1024) return error.InvalidHunk;
    return .{ .start = start, .count = count };
}
test "hunk reversal preserves unrelated text and rejects stale hunk content" {
    const a = std.testing.allocator;
    const patch = "@@ -2,2 +2,2 @@\n-old\n+new\n same\n";
    const result = try revert(a, patch, 0, "before\nnew\nsame\nafter\n");
    defer a.free(result);
    try std.testing.expectEqualStrings("before\nold\nsame\nafter\n", result);
    try std.testing.expectError(error.HunkChangedExternally, revert(a, patch, 0, "before\nexternally changed\nsame\nafter\n"));
    const tail = try revert(a, "@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n", 0, "new");
    defer a.free(tail);
    try std.testing.expectEqualStrings("old", tail);
    const deleted = try revert(a, "@@ -2 +1,0 @@\n-deleted\n", 0, "first\n");
    defer a.free(deleted);
    try std.testing.expectEqualStrings("first\ndeleted\n", deleted);
}
