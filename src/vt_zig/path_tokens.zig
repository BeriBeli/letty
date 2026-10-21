//! Copy one bounded visible logical line, preserving UTF-8 graphemes and the
//! byte-to-cell mapping. Wide-cell tails are never interpreted as delimiters.
const std = @import("std");
const ghostty = @import("ghostty-vt");
const Context = @import("context.zig").Context;
const types = @import("../vt_types.zig");
const parser = @import("../terminal_path_token.zig");
const max_bytes = 8192;
fn pin(self: *Context, pos: usize) ?ghostty.Pin {
    const cols: usize = self.terminal.cols;
    return self.terminal.screens.active.pages.pin(.{ .viewport = .{ .x = @intCast(pos % cols), .y = @intCast(pos / cols) } });
}
fn flag(self: *Context, row: usize, comptime field: []const u8) bool {
    const p = pin(self, row * @as(usize, self.terminal.cols)) orelse return false;
    return @field(p.rowAndCell().row, field);
}
const Line = struct {
    bytes: [max_bytes]u8 = undefined,
    first: [max_bytes]u32 = undefined,
    last: [max_bytes]u32 = undefined,
    len: usize = 0,
    cursor: ?usize = null,
    fn append(line: *Line, cp: u21, start: usize, end: usize, clicked: usize) bool {
        var encoded: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &encoded) catch return false;
        if (line.len + len > max_bytes) return false;
        if (line.cursor == null and clicked >= start and clicked <= end) line.cursor = line.len;
        @memcpy(line.bytes[line.len..][0..len], encoded[0..len]);
        @memset(line.first[line.len..][0..len], @intCast(start));
        @memset(line.last[line.len..][0..len], @intCast(end));
        line.len += len;
        return true;
    }
};
pub fn at(self: *Context, x: c_uint, y: c_uint, out: [*]u8, cap: usize, len: *usize, span: *types.Link) c_int {
    len.* = 0;
    span.* = .{};
    const cols: usize = self.terminal.cols;
    const rows: usize = self.terminal.rows;
    if (x >= cols or y >= rows or self.busy or self.fatal != null) return -1;
    var first_row: usize = y;
    var last_row: usize = y;
    while (first_row > 0 and flag(self, first_row - 1, "wrap")) first_row -= 1;
    while (last_row + 1 < rows and flag(self, last_row, "wrap")) last_row += 1;
    // A path cut off by viewport boundaries is not a complete local target.
    if ((first_row == 0 and flag(self, 0, "wrap_continuation")) or
        (last_row + 1 == rows and flag(self, last_row, "wrap")) or
        (last_row - first_row + 1) * cols > max_bytes) return -1;
    const clicked = @as(usize, y) * cols + x;
    var line: Line = .{};
    for (first_row * cols..(last_row + 1) * cols) |pos| {
        const p = pin(self, pos) orelse return -1;
        const cell = p.rowAndCell().cell;
        if (cell.wide == .spacer_head or cell.wide == .spacer_tail) continue;
        const cp = if (cell.hasText()) cell.codepoint() else ' ';
        const end = pos + @as(usize, if (cell.wide == .wide) 1 else 0);
        if (!line.append(if (cp < 32 or cp == 127) ' ' else cp, pos, end, clicked)) return -1;
        if (cell.hasGrapheme()) if (p.node.page().lookupGrapheme(cell)) |extra| {
            for (extra) |part| if (!line.append(part, pos, end, clicked)) return -1;
        };
    }
    const cursor = line.cursor orelse return -1;
    const found = parser.find(line.bytes[0..line.len], cursor, out[0..cap]) orelse return -1;
    len.* = found.len;
    span.* = .{ .first = line.first[found.first], .last = line.last[found.end - 1], .osc8 = false };
    return 0;
}
