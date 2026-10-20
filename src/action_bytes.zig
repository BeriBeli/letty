//! Owned PTY byte actions. Never retain a slice into a configuration arena.
const std = @import("std");

pub const capacity = 4096;
pub const Kind = enum { text, csi, esc };
pub const Error = error{ UnsupportedByteAction, InvalidEscape, InvalidUnicode, TooLong };

pub const Payload = struct {
    kind: Kind = .text,
    data: [capacity]u8 = @splat(0),
    len: u16 = 0,

    /// Call on the stored value, rather than keeping a slice from a temporary.
    pub fn bytes(self: *const Payload) []const u8 {
        return self.data[0..self.len];
    }

    fn append(self: *Payload, value: []const u8) Error!void {
        if (value.len > capacity - self.len) return error.TooLong;
        @memcpy(self.data[self.len..][0..value.len], value);
        self.len += @intCast(value.len);
    }
};

/// `text:` follows Zig string escapes without enclosing quotes. CSI/ESC
/// accept the same escapes and prepend their protocol header exactly once.
/// Raw UTF-8 is validated; \xHH deliberately permits arbitrary byte values.
pub fn parse(spec: []const u8) Error!Payload {
    const colon = std.mem.indexOfScalar(u8, spec, ':') orelse return error.UnsupportedByteAction;
    const kind = std.meta.stringToEnum(Kind, spec[0..colon]) orelse return error.UnsupportedByteAction;
    return decode(kind, spec[colon + 1 ..]);
}

pub fn decode(kind: Kind, source: []const u8) Error!Payload {
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidUnicode;
    var result: Payload = .{ .kind = kind };
    switch (kind) {
        .text => {},
        .csi => try result.append("\x1b["),
        .esc => try result.append("\x1b"),
    }
    var i: usize = 0;
    while (i < source.len) {
        if (source[i] != '\\') {
            try result.append(source[i..][0..1]);
            i += 1;
            continue;
        }
        i += 1;
        if (i == source.len) return error.InvalidEscape;
        const escaped = source[i];
        i += 1;
        switch (escaped) {
            '\\', '\'', '"' => try result.append(&.{escaped}),
            'n' => try result.append("\n"),
            'r' => try result.append("\r"),
            't' => try result.append("\t"),
            'x' => {
                if (source.len - i < 2) return error.InvalidEscape;
                const hi = hex(source[i]) orelse return error.InvalidEscape;
                const lo = hex(source[i + 1]) orelse return error.InvalidEscape;
                try result.append(&.{(hi << 4) | lo});
                i += 2;
            },
            'u' => {
                if (i == source.len or source[i] != '{') return error.InvalidEscape;
                i += 1;
                var codepoint: u32 = 0;
                var digits: usize = 0;
                while (i < source.len and source[i] != '}') : (i += 1) {
                    if (digits == 6) return error.InvalidUnicode;
                    const digit = hex(source[i]) orelse return error.InvalidEscape;
                    codepoint = codepoint * 16 + digit;
                    digits += 1;
                }
                if (i == source.len or digits == 0) return error.InvalidEscape;
                i += 1;
                if (codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff)) return error.InvalidUnicode;
                var utf8: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(@intCast(codepoint), &utf8) catch return error.InvalidUnicode;
                try result.append(utf8[0..len]);
            },
            else => return error.InvalidEscape,
        }
    }
    return result;
}

fn hex(value: u8) ?u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        'A'...'F' => value - 'A' + 10,
        else => null,
    };
}

test "byte actions own exact Unicode, backslash, ESC and NUL bytes" {
    var source = "text:中文\\\\\\u{1f600}\\x1b\\x00tail".*;
    const value = try parse(&source);
    @memset(&source, 'x');
    try std.testing.expectEqualSlices(u8, "中文\\😀\x1b\x00tail", value.bytes());
    const csi = try parse("csi:31m");
    try std.testing.expectEqualSlices(u8, "\x1b[31m", csi.bytes());
    const esc = try parse("esc:c");
    try std.testing.expectEqualSlices(u8, "\x1bc", esc.bytes());
    const binary = try parse("text:\\xff\\r\\n\\t\\'\\\"");
    try std.testing.expectEqualSlices(u8, "\xff\r\n\t'\"", binary.bytes());
}

test "byte actions reject malformed escapes and Unicode before dispatch" {
    for ([_][]const u8{ "text:\\", "text:\\q", "text:\\x", "text:\\x0g", "text:\\u1234", "text:\\u{}", "text:\\u{ff", "text:\\0" }) |spec|
        try std.testing.expectError(error.InvalidEscape, parse(spec));
    for ([_][]const u8{ "text:\\u{d800}", "text:\\u{110000}", "text:\\u{0000000}", "text:\xff" }) |spec|
        try std.testing.expectError(error.InvalidUnicode, parse(spec));
    try std.testing.expectError(error.UnsupportedByteAction, parse("shell:echo hello"));
}

test "byte action limits count protocol prefixes and decoded bytes" {
    const raw: [capacity]u8 = @splat('a');
    const text = try decode(.text, &raw);
    try std.testing.expectEqual(@as(u16, capacity), text.len);
    try std.testing.expectError(error.TooLong, decode(.esc, &raw));
    const csi = try decode(.csi, raw[0 .. capacity - 2]);
    try std.testing.expectEqual(@as(u16, capacity), csi.len);
    const empty = try parse("text:");
    try std.testing.expectEqual(@as(u16, 0), empty.len);
}
