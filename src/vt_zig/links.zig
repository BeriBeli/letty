//! On-demand native viewport links. No ANSI parsing, history mirror or retained
//! Pin: the returned URI and span are caller-owned values.
const std = @import("std");
const ghostty = @import("ghostty-vt");
const Context = @import("context.zig").Context;
const types = @import("../vt_types.zig");
fn pin(self: *Context, pos: usize) ?ghostty.Pin {
    const cols: usize = self.terminal.cols;
    if (pos >= cols * @as(usize, self.terminal.rows)) return null;
    return self.terminal.screens.active.pages.pin(.{ .viewport = .{ .x = @intCast(pos % cols), .y = @intCast(pos / cols) } });
}
fn rowFlag(self: *Context, y: usize, comptime field: []const u8) bool {
    const p = pin(self, y * @as(usize, self.terminal.cols)) orelse return false;
    return @field(p.rowAndCell().row, field);
}
fn character(self: *Context, pos: usize) ?u8 {
    const p = pin(self, pos) orelse return null;
    const cell = p.rowAndCell().cell;
    if (!cell.hasText() or cell.hasGrapheme()) return null;
    const cp = cell.codepoint();
    if (cp < 0x21 or cp > 0x7e) return null;
    return switch (cp) {
        '"', '\'', '<', '>', '`', '|', '(', ')', '[', ']', '{', '}' => null,
        else => @intCast(cp),
    };
}
fn hyperlink(self: *Context, pos: usize) ?[]const u8 {
    const p = pin(self, pos) orelse return null;
    const page = p.node.page();
    const cell = p.rowAndCell().cell;
    if (!cell.hyperlink) return null;
    const id = page.lookupHyperlink(cell) orelse return null;
    const entry = page.hyperlink_set.get(page.memory, id);
    return entry.uri.slice(page.memory);
}
fn sameUri(self: *Context, pos: usize, uri: []const u8) bool {
    const other = hyperlink(self, pos) orelse return false;
    return other.len <= 2048 and std.mem.eql(u8, other, uri);
}
pub fn at(self: *Context, x: c_uint, y: c_uint, uri: [*]u8, cap: usize, len: *usize, out: *types.Link) c_int {
    return scan(self, x, y, uri, cap, len, out, true);
}
/// Same visible-token scan without the HTTP(S) prefix requirement, for
/// path-like text; OSC 8 metadata still wins. The caller classifies the token.
pub fn token(self: *Context, x: c_uint, y: c_uint, uri: [*]u8, cap: usize, len: *usize, out: *types.Link) c_int {
    return scan(self, x, y, uri, cap, len, out, false);
}
fn scan(self: *Context, x: c_uint, y: c_uint, uri: [*]u8, cap: usize, len: *usize, out: *types.Link, web: bool) c_int {
    len.* = 0;
    out.* = .{};
    const cols: usize = self.terminal.cols;
    const rows: usize = self.terminal.rows;
    if (x >= cols or y >= rows or self.busy or self.fatal != null) return -1;
    const pos: usize = @as(usize, y) * cols + x;
    var first = pos;
    var last = pos;
    if (hyperlink(self, pos)) |target| {
        if (target.len > cap) return -1;
        @memcpy(uri[0..target.len], target);
        if (target.len > 0) {
            while (first > 0 and pos - first < 2048 and sameUri(self, first - 1, target)) first -= 1;
            while (last + 1 < cols * rows and last - pos < 2048 and sameUri(self, last + 1, target)) last += 1;
            len.* = target.len;
            out.* = .{ .first = @intCast(first), .last = @intCast(last), .osc8 = true };
            return 0;
        }
    }
    _ = character(self, pos) orelse return -1;
    while (first > 0) {
        if (first % cols == 0 and !rowFlag(self, first / cols - 1, "wrap")) break;
        _ = character(self, first - 1) orelse break;
        if (pos - first >= cap) return -1;
        first -= 1;
    }
    if (first == 0 and rowFlag(self, 0, "wrap_continuation")) return -1;
    while (last + 1 < cols * rows) {
        if ((last + 1) % cols == 0 and !rowFlag(self, last / cols, "wrap")) break;
        _ = character(self, last + 1) orelse break;
        if (last - first + 1 >= cap) return -1;
        last += 1;
    }
    if (last + 1 == cols * rows and rowFlag(self, last / cols, "wrap")) return -1;
    var count = last - first + 1;
    if (count > cap) return -1;
    for (0..count) |i| uri[i] = character(self, first + i) orelse return -1;
    while (count > 0 and std.mem.indexOfScalar(u8, ".,;!", uri[count - 1]) != null) {
        count -= 1;
        last -|= 1;
    }
    if (pos > last or count == 0) return -1;
    if (web and (count < 8 or (!std.ascii.eqlIgnoreCase(uri[0..7], "http://") and !std.ascii.eqlIgnoreCase(uri[0..8], "https://")))) return -1;
    len.* = count;
    out.* = .{ .first = @intCast(first), .last = @intCast(last), .osc8 = false };
    return 0;
}
