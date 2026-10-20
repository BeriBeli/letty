const std = @import("std");
const damage = @import("damage_tracker.zig");
const a = std.testing.allocator;
const Instance = extern struct {
    rect: [4]f32,
    color: [4]f32 = .{ 0, 0, 0, 1 },
    border_color: [4]f32 = .{ 0, 0, 0, 0 },
    uv: [4]f32 = .{ 0, 0, 0, 0 },
    clip: [4]f32 = .{ -1e6, -1e6, 1e6, 1e6 },
    radius: f32 = 0,
    border_width: f32 = 0,
    kind: f32 = 0,
    clip_round: f32 = 0,
};
const Tracker = damage.GpuTracker(Instance);
const frame = damage.Frame{ .width = 32, .height = 24 };
fn item(x: f32, y: f32, w: f32, h: f32, alpha: f32) Instance {
    return .{ .rect = .{ x, y, w, h }, .color = .{ 0.8, 0.4, 0.2, alpha } };
}
fn rectangle(result: damage.Damage) !damage.Rect {
    return switch (result) {
        .rect => |r| r,
        else => error.ExpectedRectangle,
    };
}

test "first frame, idle, move and deletion invalidate old and new pixels" {
    var tracker = Tracker{};
    defer tracker.deinit(a);
    var list = [_]Instance{item(2, 3, 4, 5, 1)};
    try std.testing.expectEqual(damage.Damage.full, tracker.update(a, &list, frame));
    try std.testing.expectEqual(damage.Damage.none, tracker.update(a, &list, frame));
    list[0].rect[0] = 12;
    const moved = try rectangle(tracker.update(a, &list, frame));
    try std.testing.expectEqual(damage.Rect{ .x = 2, .y = 3, .width = 14, .height = 5 }, moved);
    const removed = try rectangle(tracker.update(a, &.{}, frame));
    try std.testing.expectEqual(damage.Rect{ .x = 12, .y = 3, .width = 4, .height = 5 }, removed);
    try std.testing.expectEqual(damage.Damage.none, tracker.update(a, &.{}, frame));
}
test "all pixel-affecting fields compare independently; no raw struct padding" {
    var tracker = Tracker{};
    defer tracker.deinit(a);
    const base = item(2, 3, 6, 7, 1);
    _ = tracker.update(a, &.{base}, frame);
    inline for (.{ "color", "border_color", "uv", "clip" }) |field| {
        var changed = base;
        @field(changed, field)[0] += 0.25;
        try std.testing.expect(tracker.update(a, &.{changed}, frame) != .none);
        _ = tracker.update(a, &.{base}, frame);
    }
    inline for (.{ "radius", "border_width", "kind", "clip_round" }) |field| {
        var changed = base;
        @field(changed, field) += 1;
        try std.testing.expect(tracker.update(a, &.{changed}, frame) != .none);
        _ = tracker.update(a, &.{base}, frame);
    }
    // Inactive clipping moves can be a conservative redraw; numeric -0 and +0
    // are pixel-equivalent and must not depend on their byte representation.
    var zero = base;
    zero.radius = -0.0;
    try std.testing.expectEqual(damage.Damage.none, tracker.update(a, &.{zero}, frame));
}
test "clipping, fractional DPI edges and shadow blur include old footprint" {
    var tracker = Tracker{};
    defer tracker.deinit(a);
    var shadow = item(10.25, 8.25, 4, 4, 0.5);
    shadow.kind = 2;
    shadow.border_width = 2;
    shadow.clip = .{ 5, 4, 30, 20 };
    const scaled = damage.Frame{ .width = 64, .height = 48, .scale = 1.5 };
    _ = tracker.update(a, &.{shadow}, scaled);
    shadow.clip[2] = 12;
    const clipped = try rectangle(tracker.update(a, &.{shadow}, scaled));
    try std.testing.expectEqual(damage.Rect{ .x = 7, .y = 6, .width = 24, .height = 22 }, clipped);
    const bounds = (try damage.GpuAdapter(Instance).bounds(shadow, scaled)).?;
    try std.testing.expect(bounds.right() >= 18);
    try std.testing.expect(bounds.x <= 7);
}
test "invisible modifications stay idle and becoming visible damages correct area" {
    var tracker = Tracker{};
    defer tracker.deinit(a);
    var hidden = item(100, 100, 4, 4, 1);
    _ = tracker.update(a, &.{hidden}, frame);
    hidden.color[0] = 0.3;
    try std.testing.expectEqual(damage.Damage.none, tracker.update(a, &.{hidden}, frame));
    hidden.rect[0] = 4;
    hidden.rect[1] = 5;
    try std.testing.expectEqual(damage.Rect{ .x = 4, .y = 5, .width = 4, .height = 4 }, try rectangle(tracker.update(a, &.{hidden}, frame)));
}
test "resize, scale, clear, atlas, images, theme, exposure and explicit loss force full" {
    var tracker = Tracker{};
    defer tracker.deinit(a);
    const list = [_]Instance{item(1, 1, 4, 4, 1)};
    _ = tracker.update(a, &list, frame);
    inline for (.{ "glyph_generation", "image_generation", "theme_generation", "backing_generation" }) |field| {
        var next = frame;
        @field(next, field) = 1;
        try std.testing.expectEqual(damage.Damage.full, tracker.update(a, &list, next));
        try std.testing.expectEqual(damage.Damage.none, tracker.update(a, &list, next));
        _ = tracker.update(a, &list, frame);
    }
    var next = frame;
    next.width = 33;
    try std.testing.expectEqual(damage.Damage.full, tracker.update(a, &list, next));
    next.height += 1;
    try std.testing.expectEqual(damage.Damage.full, tracker.update(a, &list, next));
    next.scale = 2;
    try std.testing.expectEqual(damage.Damage.full, tracker.update(a, &list, next));
    next.clear[2] = 0.5;
    try std.testing.expectEqual(damage.Damage.full, tracker.update(a, &list, next));
    tracker.invalidate();
    try std.testing.expectEqual(damage.Damage.full, tracker.update(a, &list, next));
}
test "instance and byte budgets plus OOM release stale cache and recover safely" {
    var tracker = Tracker{ .limits = .{ .instances = 2, .cache_bytes = @sizeOf(Instance) * 2 } };
    defer tracker.deinit(a);
    const list = [_]Instance{ item(1, 1, 2, 2, 1), item(4, 4, 2, 2, 1), item(8, 8, 2, 2, 1) };
    _ = tracker.update(a, list[0..1], frame);
    try std.testing.expectEqual(@as(usize, @sizeOf(Instance)), tracker.cachedBytes());
    try std.testing.expectEqual(damage.Damage.full, tracker.update(a, &list, frame));
    try std.testing.expectEqual(@as(usize, 0), tracker.cachedBytes());
    _ = tracker.update(a, list[0..2], frame);
    try std.testing.expect(tracker.cachedBytes() <= tracker.limits.cache_bytes);
    tracker.limits.cache_bytes = @sizeOf(Instance);
    _ = tracker.update(a, list[0..1], frame);
    try std.testing.expect(tracker.cachedBytes() <= tracker.limits.cache_bytes);
    try std.testing.expectEqual(damage.Damage.full, tracker.update(a, list[0..2], frame));
    try std.testing.expectEqual(@as(usize, 0), tracker.cachedBytes());
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectEqual(damage.Damage.full, tracker.update(failing.allocator(), list[0..1], frame));
    try std.testing.expectEqual(@as(usize, 0), tracker.cachedInstances());
    try std.testing.expectEqual(damage.Damage.full, tracker.update(a, list[0..1], frame));
    try std.testing.expectEqual(damage.Damage.none, tracker.update(a, list[0..1], frame));
}
test "NaN and infinity cannot poison a previously accepted frame cache" {
    var tracker = Tracker{};
    defer tracker.deinit(a);
    var good = item(1, 1, 2, 2, 1);
    _ = tracker.update(a, &.{good}, frame);
    good.color[1] = std.math.nan(f32);
    try std.testing.expectEqual(damage.Damage.full, tracker.update(a, &.{good}, frame));
    try std.testing.expectEqual(@as(usize, 0), tracker.cachedBytes());
    good = item(1, 1, 2, 2, 1);
    var bad_frame = frame;
    bad_frame.scale = std.math.inf(f32);
    try std.testing.expectEqual(damage.Damage.full, tracker.update(a, &.{good}, bad_frame));
    try std.testing.expectEqual(damage.Damage.full, tracker.update(a, &.{good}, frame));
}

const Pixels = [32 * 24][4]u8;
fn rounded(point: f32, scale: f32, limit: u32) u32 {
    return @intFromFloat(std.math.clamp(@round(point * scale), 0, @as(f32, @floatFromInt(limit))));
}
// Separate software compositor follows raster's rounded coverage convention;
// damage bounds deliberately use a different, outward rounding implementation.
fn paint(pixels: *Pixels, instances: []const Instance, region: damage.Rect) void {
    for (region.y..region.bottom()) |y| for (region.x..region.right()) |x| {
        pixels[y * 32 + x] = .{ 0, 0, 0, 255 };
    };
    for (instances) |i| {
        const grow: f32 = if (i.kind == 2) i.border_width * 3 else 0;
        const x0 = rounded(@max(i.rect[0] - grow, i.clip[0]), 1, 32);
        const y0 = rounded(@max(i.rect[1] - grow, i.clip[1]), 1, 24);
        const x1 = rounded(@min(i.rect[0] + i.rect[2] + grow, i.clip[2]), 1, 32);
        const y1 = rounded(@min(i.rect[1] + i.rect[3] + grow, i.clip[3]), 1, 24);
        const start_y = @max(y0, region.y);
        const end_y = @max(start_y, @min(y1, region.bottom()));
        const start_x = @max(x0, region.x);
        const end_x = @max(start_x, @min(x1, region.right()));
        for (start_y..end_y) |y| for (start_x..end_x) |x| {
            const out = &pixels[y * 32 + x];
            for (0..3) |k| out[k] = @intFromFloat(@min(255, i.color[k] * i.color[3] * 255 + @as(f32, @floatFromInt(out[k])) * (1 - i.color[3]) + 0.5));
        };
    }
}
const entire = damage.Rect{ .x = 0, .y = 0, .width = 32, .height = 24 };
fn verifyTransition(tracker: *Tracker, pixels: *Pixels, after: []const Instance) !void {
    const result = tracker.update(a, after, frame);
    var expected: Pixels = undefined;
    paint(&expected, after, entire);
    for (pixels, expected, 0..) |old, new, index| {
        if (!std.mem.eql(u8, &old, &new)) {
            switch (result) {
                .none => return error.ChangedPixelNotInvalidated,
                .full => {},
                .rect => |r| try std.testing.expect(r.contains(@intCast(index % 32), @intCast(index / 32))),
            }
        }
    }
    switch (result) {
        .none => {},
        .full => paint(pixels, after, entire),
        .rect => |r| paint(pixels, after, r),
    }
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expected), std.mem.asBytes(pixels));
}
test "partial rendering exactly matches full rendering across transparent stacking changes" {
    var tracker = Tracker{};
    defer tracker.deinit(a);
    var pixels: Pixels = @splat(.{ 0, 0, 0, 255 });
    var bottom = item(2, 2, 12, 10, 1);
    var overlay = item(5, 4, 15, 13, 0.35);
    overlay.color[1] = 0.9;
    try verifyTransition(&tracker, &pixels, &.{ bottom, overlay });
    // An unchanged alpha overlay intersects movement underneath it.
    bottom.rect[0] += 2;
    try verifyTransition(&tracker, &pixels, &.{ bottom, overlay });
    // Insertion shifts draw-stream indices without assuming stable nodes.
    const front = item(8, 7, 15, 12, 0.6);
    try verifyTransition(&tracker, &pixels, &.{ bottom, front, overlay });
    try verifyTransition(&tracker, &pixels, &.{ bottom, overlay, front });
    try verifyTransition(&tracker, &pixels, &.{ bottom, front });
    try verifyTransition(&tracker, &pixels, &.{front});
    try verifyTransition(&tracker, &pixels, &.{});
}
test "randomized clips, insertions, deletion and alpha replay never miss changed pixels" {
    var tracker = Tracker{};
    defer tracker.deinit(a);
    var pixels: Pixels = @splat(.{ 0, 0, 0, 255 });
    var list: [12]Instance = undefined;
    var seed: u32 = 0xbadcafe;
    for (0..200) |_| {
        const count = random(&seed) % (list.len + 1);
        for (list[0..count]) |*i| {
            i.* = item(@as(f32, @floatFromInt(random(&seed) % 40)) - 4.25, @as(f32, @floatFromInt(random(&seed) % 32)) - 3.5, @floatFromInt(random(&seed) % 15), @floatFromInt(random(&seed) % 12), @as(f32, @floatFromInt(random(&seed) % 10)) / 10);
            i.color[0] = @as(f32, @floatFromInt(random(&seed) % 10)) / 10;
            i.clip[0] = @floatFromInt(random(&seed) % 10);
            i.clip[1] = @floatFromInt(random(&seed) % 8);
            i.clip[2] = @floatFromInt(12 + random(&seed) % 20);
            i.clip[3] = @floatFromInt(10 + random(&seed) % 14);
        }
        try verifyTransition(&tracker, &pixels, list[0..count]);
    }
}
fn random(seed: *u32) u32 {
    seed.* = seed.* *% 1664525 +% 1013904223;
    return seed.*;
}

test "generic adapters ignore actual struct padding and reject unsafe bounds" {
    const Padded = extern struct { tag: u8, value: u64 };
    const Adapter = struct {
        pub fn equal(left: Padded, right: Padded) bool {
            return left.tag == right.tag and left.value == right.value;
        }
        pub fn bounds(value: Padded, _: damage.Frame) !?damage.Rect {
            return .{ .x = 0, .y = 0, .width = @intCast(value.value), .height = 2 };
        }
    };
    var tracker = damage.Tracker(Padded, Adapter){};
    defer tracker.deinit(a);
    var first: Padded = undefined;
    @memset(std.mem.asBytes(&first), 0xaa);
    first.tag = 7;
    first.value = 2;
    var second: Padded = undefined;
    @memset(std.mem.asBytes(&second), 0x55);
    second.tag = 7;
    second.value = 2;
    try std.testing.expectEqual(damage.Damage.full, tracker.update(a, &.{first}, frame));
    try std.testing.expectEqual(damage.Damage.none, tracker.update(a, &.{second}, frame));
    second.value = 100;
    try std.testing.expectEqual(damage.Damage.full, tracker.update(a, &.{second}, frame));
    try std.testing.expectEqual(@as(usize, 0), tracker.cachedBytes());
}
