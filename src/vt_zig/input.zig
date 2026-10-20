const std = @import("std");
const ghostty = @import("ghostty-vt");
const Context = @import("context.zig").Context;
fn modifiers(bits: c_uint) ghostty.input.KeyMods {
    return .{ .shift = bits & 1 != 0, .ctrl = bits & 2 != 0, .alt = bits & 4 != 0, .super = bits & 8 != 0, .caps_lock = bits & 16 != 0, .num_lock = bits & 32 != 0 };
}
fn keyOf(code: c_uint) ghostty.input.Key {
    if (code >= 'a' and code <= 'z') return @fromBackingInt(@intCast(@backingInt(ghostty.input.Key.key_a) + @as(c_int, @intCast(code - 'a'))));
    if (code >= '0' and code <= '9') return @fromBackingInt(@intCast(@backingInt(ghostty.input.Key.digit_0) + @as(c_int, @intCast(code - '0'))));
    const special = [_]ghostty.input.Key{ .backspace, .delete, .arrow_left, .arrow_right, .arrow_up, .arrow_down, .home, .end, .enter, .tab, .escape, .page_up, .page_down, .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 };
    if (code >= 0x100 and code < 0x100 + special.len) return special[code - 0x100];
    return switch (code) {
        ' ' => .space,
        '[' => .bracket_left,
        ']' => .bracket_right,
        '\\' => .backslash,
        '/' => .slash,
        '-' => .minus,
        '=' => .equal,
        else => .unidentified,
    };
}
fn available(self: *Context) bool {
    if (self.fatal != null) return false;
    if (self.busy) {
        self.fail(error.ReentrantVt);
        return false;
    }
    return true;
}
pub fn key(self: *Context, code: c_uint, mods: c_uint, text: [*]const u8, len: usize, out: [*]u8, cap: usize, written: *usize) c_int {
    written.* = 0;
    if (!available(self)) return -7;
    const event: ghostty.input.KeyEvent = .{ .action = .press, .key = keyOf(code), .mods = modifiers(mods), .utf8 = text[0..len], .unshifted_codepoint = if (code < 0x100) @intCast(code) else 0 };
    const options = ghostty.input.KeyEncodeOptions.fromTerminal(&self.terminal);
    var writer: std.Io.Writer = .fixed(out[0..cap]);
    ghostty.input.encodeKey(&writer, event, options) catch {
        var count: std.Io.Writer.Discarding = .init(&.{});
        ghostty.input.encodeKey(&count.writer, event, options) catch unreachable;
        written.* = @intCast(count.count);
        return -3;
    };
    written.* = writer.end;
    return 0;
}
pub fn mouse(self: *Context, action: c_uint, button: c_uint, mods: c_uint, x: c_uint, y: c_uint, out: [*]u8, cap: usize, written: *usize) c_int {
    written.* = 0;
    if (!available(self)) return -7;
    if (action > 2 or button > 11) return -2;
    var options = ghostty.input.MouseEncodeOptions.fromTerminal(&self.terminal, .{
        .screen = .{ .width = std.math.mul(u32, self.terminal.cols, self.cell_width) catch std.math.maxInt(u32), .height = std.math.mul(u32, self.terminal.rows, self.cell_height) catch std.math.maxInt(u32) },
        .cell = .{ .width = self.cell_width, .height = self.cell_height },
        .padding = .{},
    });
    options.any_button_pressed = action != 1;
    // Match the existing bridge: it does not opt into motion de-duplication.
    options.last_cell = null;
    const event: ghostty.input.MouseEncodeEvent = .{ .action = @fromBackingInt(@intCast(action)), .button = @fromBackingInt(@intCast(button)), .mods = modifiers(mods), .pos = .{ .x = @as(f32, @floatFromInt(x)) * @as(f32, @floatFromInt(self.cell_width)) + 1, .y = @as(f32, @floatFromInt(y)) * @as(f32, @floatFromInt(self.cell_height)) + 1 } };
    var writer: std.Io.Writer = .fixed(out[0..cap]);
    ghostty.input.encodeMouse(&writer, event, options) catch {
        var count: std.Io.Writer.Discarding = .init(&.{});
        ghostty.input.encodeMouse(&count.writer, event, options) catch unreachable;
        written.* = @intCast(count.count);
        return -3;
    };
    written.* = writer.end;
    return 0;
}
pub fn focusEnabled(self: *Context) bool {
    return self.terminal.modes.get(.focus_event);
}
pub fn focus(self: *Context, focused: bool, out: [*]u8, cap: usize) usize {
    if (!available(self) or !focusEnabled(self)) return 0;
    var writer: std.Io.Writer = .fixed(out[0..cap]);
    ghostty.input.encodeFocus(&writer, if (focused) .gained else .lost) catch return 0;
    return writer.end;
}
pub fn paste(data: [*]u8, len: usize, bracketed: bool, output: [*]u8, cap: usize, written: *usize) c_int {
    const segments = ghostty.input.encodePaste(data[0..len], .{ .bracketed = bracketed });
    var total: usize = 0;
    for (segments) |segment| total = std.math.add(usize, total, segment.len) catch {
        written.* = std.math.maxInt(usize);
        return -6;
    };
    written.* = total;
    if (total > cap) return -3;
    var offset: usize = 0;
    for (segments) |segment| {
        @memcpy(output[offset..][0..segment.len], segment);
        offset += segment.len;
    }
    return 0;
}
