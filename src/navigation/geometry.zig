//! One surface-space geometry result for navigation, content and all hit tests.
const std = @import("std");
pub const Mode = enum { top, sidebar };
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    pub fn contains(r: Rect, p: anytype) bool {
        return r.w > 0 and r.h > 0 and p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h;
    }
};
pub const Rects = struct {
    navigation: Rect = .{},
    content: Rect = .{},
    /// The accessible expand control. null means the full sidebar is visible.
    compact: ?Rect = null,
    /// Entirely inside navigation: terminal column zero wins outside this band.
    resize: Rect = .{},
};
pub const top_height: f32 = 36;
pub const default_width: f32 = 268;
pub const minimum_width: f32 = 200;
pub const maximum_width: f32 = 440;
pub const compact_width: f32 = 0;
pub const minimum_content: f32 = 240;
pub fn sanitizedWidth(value: f32) f32 {
    return if (std.math.isFinite(value)) std.math.clamp(value, minimum_width, maximum_width) else default_width;
}
pub fn compute(width: f32, height: f32, _: Mode, _: bool, preferred_width: f32, collapsed: bool) Rects {
    const w = if (std.math.isFinite(width)) @max(0, width) else 0;
    const h = if (std.math.isFinite(height)) @max(0, height) else 0;
    const compact = collapsed or w < minimum_content + minimum_width;
    const nav = if (compact) @min(compact_width, @max(0, w - 1)) else @min(sanitizedWidth(preferred_width), w - minimum_content);
    return .{
        .navigation = .{ .w = nav, .h = h },
        .content = .{ .x = nav, .w = w - nav, .h = h },
        .compact = if (compact) .{ .x = if (@import("builtin").os.tag == .macos) 84 else 16, .y = 17, .w = 28, .h = @min(26, h) } else null,
        .resize = if (!compact) .{ .x = nav - 6, .w = 6, .h = h } else .{},
    };
}

test "navigation geometry preserves preferred width and isolates terminal hits" {
    const normal = compute(900, 600, .sidebar, false, 240, false);
    try std.testing.expectEqual(@as(f32, 240), normal.content.x);
    try std.testing.expect(!normal.resize.contains(.{ .x = normal.content.x, .y = 10 }));
    const narrow = compute(399, 100, .sidebar, true, 300, false);
    try std.testing.expect(narrow.compact != null and narrow.content.w > 300);
    try std.testing.expectEqual(@as(f32, 300), compute(900, 600, .sidebar, false, 300, false).navigation.w);
    const top = compute(900, 10, .top, true, 240, false);
    try std.testing.expectEqual(@as(f32, 10), top.content.h);
    try std.testing.expectEqual(@as(f32, 268), sanitizedWidth(std.math.nan(f32)));
}
