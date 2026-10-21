//! Native wheel deltas are positive toward the top/left of content.
//! Keep precise fractions until a complete row is available; never invent
//! momentum or apply acceleration to already accelerated OS input.
const std = @import("std");
pub const Rows = struct {
    remainder: f32 = 0,
    discrete: bool = false,
    pub fn take(self: *Rows, pixels: f32, lines: ?f32, height: f32, started: bool) i32 {
        if (started or self.discrete != (lines != null)) self.remainder = 0;
        self.discrete = lines != null;
        const delta = lines orelse (pixels / @max(1, height));
        if (!std.math.isFinite(delta)) return 0;
        // Reversal responds immediately instead of paying off old fractions.
        if (delta * self.remainder < 0) self.remainder = 0;
        const total = std.math.clamp(self.remainder + delta, -128, 128);
        const whole: i32 = @intFromFloat(total);
        self.remainder = total - @as(f32, @floatFromInt(whole));
        return whole;
    }
    pub fn select(self: *Rows, input: anytype, height: f32, selected: usize, count: usize) usize {
        const rows = self.take(input.scroll.y, input.scroll_lines, height, input.scroll_started);
        if (count == 0) return 0;
        return if (rows >= 0) selected -| @as(usize, @intCast(rows)) else @min(count - 1, selected +| @as(usize, @intCast(-rows)));
    }
};

test "precise wheel accumulates sub-row input and uses actual row height" {
    var rows: Rows = .{};
    for (0..7) |_| try std.testing.expectEqual(@as(i32, 0), rows.take(2, null, 16, false));
    try std.testing.expectEqual(@as(i32, 1), rows.take(2, null, 16, false));
    try std.testing.expectEqual(@as(i32, 0), rows.take(16, null, 32, false));
    try std.testing.expectEqual(@as(i32, 1), rows.take(16, null, 32, false));
    try std.testing.expectEqual(@as(i32, -1), rows.take(-32, null, 32, false));
}
test "wheel device changes gesture starts reversal and large bursts" {
    var rows: Rows = .{};
    _ = rows.take(15, null, 16, false);
    try std.testing.expectEqual(@as(i32, 1), rows.take(12, 1, 32, false));
    try std.testing.expectEqual(@as(i32, 0), rows.take(1, null, 16, false));
    _ = rows.take(14, null, 16, false);
    try std.testing.expectEqual(@as(i32, 0), rows.take(1, null, 16, true));
    try std.testing.expectEqual(@as(i32, -1), rows.take(-16, null, 16, false));
    try std.testing.expectEqual(@as(i32, 128), rows.take(1e20, null, 16, false));
    try std.testing.expectEqual(@as(i32, 0), rows.take(std.math.nan(f32), null, 16, false));
}
