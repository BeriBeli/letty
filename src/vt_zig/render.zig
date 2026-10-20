const std = @import("std");
const ghostty = @import("ghostty-vt");
const types = @import("../vt_types.zig");
const context = @import("context.zig");
const Context = context.Context;
const selection_api = @import("selection.zig");
const search = @import("search.zig");
pub fn frame(self: *Context, output: *types.Cursor) c_int {
    if (!self.enter()) return -7;
    defer self.leave();
    selection_api.validateLocked(self);
    // Search quotas are a local diagnostic. Real backing allocation failure
    // is independently observed by Context.status; normal text still renders.
    search.prepareLocked(self) catch {};
    self.render.update(self.gpa, &self.terminal) catch |err| {
        self.fail(err);
        return -1;
    };
    self.frame_x = 0;
    self.frame_y = 0;
    const cursor = self.render.cursor;
    output.* = .{
        .x = if (cursor.viewport) |p| p.x else 0,
        .y = if (cursor.viewport) |p| p.y else 0,
        .style = @intCast(@backingInt(cursor.visual_style)),
        .visible = cursor.visible and cursor.viewport != null,
        .blinking = cursor.blinking,
        .color = context.packRgb(self.render.colors.cursor orelse self.render.colors.foreground),
        .bg = context.packRgb(self.render.colors.background),
    };
    self.frame_open = true;
    return self.status();
}
pub fn next(self: *Context, output: *types.Cell) bool {
    if (self.fatal != null or !self.frame_open or self.busy) return false;
    while (self.frame_y < self.render.rows) {
        if (self.frame_x >= self.render.cols) {
            self.frame_y += 1;
            self.frame_x = 0;
            continue;
        }
        const y = self.frame_y;
        const x = self.frame_x;
        self.frame_x += 1;
        const row = self.render.viewportStart() + y;
        const cells = self.render.row_data.items(.cells)[row];
        const raw = cells.items(.raw)[x];
        const style: ghostty.Style = if (raw.hasStyling()) cells.items(.style)[x] else .{};
        var foreground = style.fg(.{ .default = self.render.colors.foreground, .palette = &self.render.colors.palette });
        var background = style.bg(&raw, &self.render.colors.palette) orelse self.render.colors.background;
        if (style.flags.inverse) std.mem.swap(ghostty.color.RGB, &foreground, &background);
        if (style.flags.faint) {
            foreground.r = @intCast((@as(u16, foreground.r) + background.r) / 2);
            foreground.g = @intCast((@as(u16, foreground.g) + background.g) / 2);
            foreground.b = @intCast((@as(u16, foreground.b) + background.b) / 2);
        }
        const selection = self.render.row_data.items(.selection)[row];
        const selected = if (selection) |range| x >= range[0] and x <= range[1] else false;
        self.text.clearRetainingCapacity();
        if (raw.hasText() and !style.flags.invisible and raw.wide != .spacer_head and raw.wide != .spacer_tail) {
            append(self, raw.codepoint()) catch |err| {
                self.fail(err);
                return false;
            };
            if (raw.content_tag == .codepoint_grapheme) for (cells.items(.grapheme)[x]) |cp| {
                append(self, cp) catch |err| {
                    self.fail(err);
                    return false;
                };
            };
        }
        output.* = .{
            .x = @intCast(x),
            .y = @intCast(y),
            .width = switch (raw.wide) {
                .wide => 2,
                .spacer_head, .spacer_tail => 0,
                .narrow => 1,
            },
            .flags = @as(c_uint, if (style.flags.bold) 1 else 0) | @as(c_uint, if (style.flags.italic) 2 else 0) | @as(c_uint, if (style.flags.underline != .none) 4 else 0) | @as(c_uint, if (style.flags.strikethrough) 8 else 0) | @as(c_uint, if (selected) 16 else 0) | search.flags(self, x, y) | @as(c_uint, if (style.flags.overline) 128 else 0) | @as(c_uint, if (style.flags.invisible) 256 else 0),
            .underline = @intCast(@backingInt(style.flags.underline)),
            .underline_color = context.packRgb(style.underlineColor(&self.render.colors.palette) orelse foreground),
            .fg = context.packRgb(foreground),
            .bg = context.packRgb(background),
            .text = self.text.items.ptr,
            .len = self.text.items.len,
        };
        return true;
    }
    return false;
}
fn append(self: *Context, cp: u21) !void {
    var bytes: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(cp, &bytes);
    try self.text.appendSlice(self.gpa, bytes[0..n]);
}
pub fn end(self: *Context) void {
    if (self.frame_open) self.render.clean();
    self.frame_open = false;
    self.text.clearRetainingCapacity();
}
