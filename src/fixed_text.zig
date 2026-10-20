//! Bounded owned text for diagnostics and modal content; truncation keeps UTF-8 valid.
pub fn Text(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        buf: [capacity]u8 = undefined,
        len: usize = 0,
        pub fn set(s: *Self, value: []const u8) void {
            var count = @min(value.len, capacity);
            while (count > 0 and count < value.len and value[count] & 0xc0 == 0x80) count -= 1;
            @memcpy(s.buf[0..count], value[0..count]);
            s.len = count;
        }
        pub fn text(s: *const Self) []const u8 {
            return s.buf[0..s.len];
        }
    };
}
