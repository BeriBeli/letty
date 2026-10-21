//! Bounded, filesystem-free parsing of visible terminal path candidates.
//! Byte ranges map back to VT cells in vt_zig/path_tokens.zig.
const std = @import("std");
const paths = @import("terminal_paths.zig");
pub const Match = struct { first: usize, end: usize, len: usize };
fn boundary(ch: u8) bool {
    return ch <= 32 or std.mem.indexOfScalar(u8, "\"'<>`|()[]{}", ch) != null;
}
fn escaped(text: []const u8, at: usize) bool {
    var start = at;
    while (start > 0 and text[start - 1] == '\\') start -= 1;
    return (at - start) % 2 == 1;
}
fn copy(text: []const u8, first: usize, end: usize, quote: u8, out: []u8) ?Match {
    var at = first;
    var len: usize = 0;
    while (at < end) : (at += 1) {
        if (text[at] == '\\' and quote != '\'' and at + 1 < end and
            (quote == 0 or std.mem.indexOfScalar(u8, "\\\"$`", text[at + 1]) != null)) at += 1;
        if (len == out.len) return null;
        out[len] = text[at];
        len += 1;
    }
    if (!std.unicode.utf8ValidateSlice(out[0..len]) or !paths.isPath(out[0..len])) return null;
    return .{ .first = first, .end = end, .len = len };
}
fn anchored(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "/") or std.mem.startsWith(u8, text, "./") or
        std.mem.startsWith(u8, text, "../") or std.mem.startsWith(u8, text, "~/");
}
fn column(text: []const u8, start: usize, end: usize) bool {
    const before = std.mem.trim(u8, text[0..start], " \t");
    const after = std.mem.trim(u8, text[end..], " \t");
    return (before.len > 0 and start >= 2 and text[start - 1] == ' ' and text[start - 2] == ' ') or
        (after.len > 0 and end + 1 < text.len and text[end] == ' ' and text[end + 1] == ' ') or
        (before.len > 0 and start > 0 and text[start - 1] == '\t') or
        (after.len > 0 and end < text.len and text[end] == '\t');
}
fn trimmedEnd(text: []const u8, start: usize, end: usize) usize {
    var result = end;
    while (result > start and std.mem.indexOfScalar(u8, ".,;!", text[result - 1]) != null) result -= 1;
    return result;
}
/// Quotes and shell-escaped spaces are explicit. Unquoted single spaces are
/// accepted within ls-style columns (separated by two spaces or tabs).
/// Ambiguous prose should quote a path or use an OSC 8 file URI.
pub fn find(text: []const u8, cursor: usize, out: []u8) ?Match {
    if (cursor >= text.len) return null;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const quote = text[index];
        if ((quote != '\'' and quote != '"') or escaped(text, index)) continue;
        const start = index + 1;
        var end = start;
        while (end < text.len and (text[end] != quote or (quote == '"' and escaped(text, end)))) : (end += 1) {}
        if (cursor >= index and cursor <= end) {
            if (end == text.len) return null; // never open a fragment of an incomplete quote
            return copy(text, start, end, quote, out);
        }
        index = end;
    }
    // Column padding is not a target, including the second space of a gap.
    if (text[cursor] == ' ' and !escaped(text, cursor) and
        ((cursor > 0 and text[cursor - 1] == ' ' and !escaped(text, cursor - 1)) or
            (cursor + 1 < text.len and text[cursor + 1] == ' ' and !escaped(text, cursor + 1)))) return null;
    // Keep filenames with spaces together, without merging adjacent ls columns.
    var start: usize = cursor;
    while (start > 0) {
        const ch = text[start - 1];
        if (ch == '\t' or (boundary(ch) and ch != ' ' and !escaped(text, start - 1))) break;
        if (ch == ' ' and start >= 2 and text[start - 2] == ' ' and !escaped(text, start - 1)) break;
        start -= 1;
    }
    var end = cursor;
    while (end < text.len) : (end += 1) {
        const ch = text[end];
        if (ch == '\t' or (boundary(ch) and ch != ' ' and !escaped(text, end))) break;
        if (ch == ' ' and end + 1 < text.len and text[end + 1] == ' ' and !escaped(text, end)) break;
    }
    while (start < end and text[start] == ' ') start += 1;
    while (end > start and text[end - 1] == ' ') end -= 1;
    // A label before an anchored path is not part of that path.
    var candidate = start;
    for (start..end) |i| {
        if (i > start and text[i - 1] == ' ' and !escaped(text, i - 1) and
            (text[i] == '/' or std.mem.startsWith(u8, text[i..end], "./") or
                std.mem.startsWith(u8, text[i..end], "../") or std.mem.startsWith(u8, text[i..end], "~/")))
        {
            candidate = i;
            break;
        }
    }
    const column_end = trimmedEnd(text, candidate, end);
    if (cursor >= candidate and cursor < column_end and
        (anchored(text[candidate..column_end]) or column(text, start, end)) and
        std.mem.indexOfScalar(u8, text[candidate..column_end], ' ') != null)
    {
        if (copy(text, candidate, column_end, 0, out)) |found| return found;
        // A complete candidate that exceeds the output limit must not become
        // a shorter filename merely because the user clicked its last word.
        if (column_end - candidate > out.len and paths.isPath(text[candidate..column_end])) return null;
    }
    // Ordinary single tokens keep the previous behavior in compiler/prose output.
    start = cursor;
    while (start > 0 and (!boundary(text[start - 1]) or escaped(text, start - 1))) start -= 1;
    end = cursor;
    while (end < text.len and (!boundary(text[end]) or escaped(text, end))) : (end += 1) {}
    end = trimmedEnd(text, start, end);
    if (cursor < start or cursor >= end) return null;
    return copy(text, start, end, 0, out);
}

test "quoted escaped UTF-8 and ls-column paths retain complete filenames" {
    var buffer: [2048]u8 = undefined;
    const Case = struct { line: []const u8, needle: []const u8, path: []const u8 };
    for ([_]Case{
        .{ .line = "a.zip  Register Specification Standard.pdf  b.md", .needle = "Specification", .path = "Register Specification Standard.pdf" },
        .{ .line = "Device 寄存器列表.xlsx  寄存器使用说明.md", .needle = "寄", .path = "Device 寄存器列表.xlsx" },
        .{ .line = "'目录/中文  文档.md' other", .needle = "文档", .path = "目录/中文  文档.md" },
        .{ .line = "cat \"中文 文件.md\"", .needle = "文件", .path = "中文 文件.md" },
        .{ .line = "./中文\\ 文件.md  next", .needle = "文件", .path = "./中文 文件.md" },
        .{ .line = "FILE /tmp/中文 文件.md", .needle = "文件", .path = "/tmp/中文 文件.md" },
        .{ .line = "see src/中文.zig:3: x", .needle = "中文", .path = "src/中文.zig:3:" },
        .{ .line = "BIN blob.bin", .needle = "blob", .path = "blob.bin" },
        .{ .line = "see README.md", .needle = "README", .path = "README.md" },
        .{ .line = "中文.md", .needle = "中文", .path = "中文.md" },
        .{ .line = "说明.文档", .needle = "说明", .path = "说明.文档" },
        .{ .line = "e\u{301}.md", .needle = "e", .path = "e\u{301}.md" },
    }) |case| {
        const found = find(case.line, std.mem.indexOf(u8, case.line, case.needle).?, &buffer) orelse {
            std.debug.print("missing path in {s}\n", .{case.line});
            return error.TestExpectedPath;
        };
        try std.testing.expectEqualStrings(case.path, buffer[0..found.len]);
    }
    try std.testing.expect(find("'unfinished 中文.md", 4, &buffer) == null);
    try std.testing.expect(find("and/or", 2, &buffer) == null);
    try std.testing.expect(find("./long.md", 3, buffer[0..3]) == null);
    try std.testing.expect(find("a.md  Long name.md  b.md", 14, buffer[0..8]) == null);
    try std.testing.expect(find("a.md  b.md", 4, &buffer) == null);
    try std.testing.expect(find("a.md  b.md", 5, &buffer) == null);
}
