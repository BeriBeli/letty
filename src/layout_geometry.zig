//! Geometry-only split navigation and resizing. No window or PTY ownership.
const std = @import("std");
const Direction = @import("actions.zig").Direction;
pub const Rect = struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };
const Frame = struct { index: usize, rect: Rect };
fn divided(n: anytype, rect: Rect, floor: bool) [2]Rect {
    var a = rect;
    var b = rect;
    if (n.kind == .horizontal) {
        a.w = if (floor) @floor(@max(0, rect.w - 1) * n.ratio) else rect.w * n.ratio;
        b.x += a.w + @as(f32, if (floor) 1 else 0);
        b.w = @max(0, rect.w - a.w - @as(f32, if (floor) 1 else 0));
    } else {
        a.h = if (floor) @floor(@max(0, rect.h - 1) * n.ratio) else rect.h * n.ratio;
        b.y += a.h + @as(f32, if (floor) 1 else 0);
        b.h = @max(0, rect.h - a.h - @as(f32, if (floor) 1 else 0));
    }
    return .{ a, b };
}
pub fn collect(layout: anytype, index: usize, rect: Rect, output: []Rect) void {
    if (index == @import("layout.zig").document_root) return;
    const pending = std.heap.page_allocator.alloc(Frame, layout.nodes.len) catch return;
    defer std.heap.page_allocator.free(pending);
    pending[0] = .{ .index = index, .rect = rect };
    var count: usize = 1;
    while (count > 0) {
        count -= 1;
        const item = pending[count];
        const n = layout.nodes[item.index];
        if (n.kind == .pane) {
            output[n.pane] = item.rect;
            continue;
        }
        if (n.kind != .horizontal and n.kind != .vertical) continue;
        const parts = divided(n, item.rect, true);
        pending[count] = .{ .index = n.second, .rect = parts[1] };
        pending[count + 1] = .{ .index = n.first, .rect = parts[0] };
        count += 2;
    }
}
pub fn neighbor(layout: anytype, direction: Direction, width: f32, height: f32) ?usize {
    if (layout.tab_count == 0 or layout.isDocument(layout.active_tab)) return null;
    const rects = std.heap.page_allocator.alloc(Rect, layout.nodes.len) catch return null;
    defer std.heap.page_allocator.free(rects);
    @memset(rects, .{});
    collect(layout, layout.roots[layout.active_tab], .{ .w = width, .h = height }, rects);
    const current = rects[layout.active_pane];
    var best: ?usize = null;
    var score = std.math.inf(f32);
    for (rects, 0..) |r, slot| {
        if (slot == layout.active_pane or r.w <= 0 or r.h <= 0) continue;
        const horizontal = direction == .left or direction == .right;
        const gap = switch (direction) {
            .left => current.x - r.x - r.w,
            .right => r.x - current.x - current.w,
            .up => current.y - r.y - r.h,
            .down => r.y - current.y - current.h,
        };
        if (gap < -0.5) continue;
        const overlap = if (horizontal) @min(current.y + current.h, r.y + r.h) - @max(current.y, r.y) else @min(current.x + current.w, r.x + r.w) - @max(current.x, r.x);
        const center = if (horizontal) @abs(r.y + r.h / 2 - current.y - current.h / 2) else @abs(r.x + r.w / 2 - current.x - current.w / 2);
        const candidate = (if (overlap > 0) @as(f32, 0) else 1e9) + @max(0, gap) * 10000 + center;
        if (candidate < score) {
            score = candidate;
            best = @intCast(slot);
        }
    }
    return best;
}
pub fn equalize(layout: anytype, index: usize, rect: Rect, min_w: f32, min_h: f32) void {
    if (index == @import("layout.zig").document_root) return;
    const a = std.heap.page_allocator;
    const pending = a.alloc(Frame, layout.nodes.len) catch return;
    defer a.free(pending);
    const order = a.alloc(usize, layout.nodes.len) catch return;
    defer a.free(order);
    const counts = a.alloc(usize, layout.nodes.len) catch return;
    defer a.free(counts);
    // Parent-before-child order, reversed for a linear subtree-size pass.
    order[0] = index;
    var end: usize = 1;
    var at: usize = 0;
    while (at < end) : (at += 1) {
        const n = layout.nodes[order[at]];
        if (n.kind != .horizontal and n.kind != .vertical) continue;
        order[end] = n.first;
        order[end + 1] = n.second;
        end += 2;
    }
    while (end > 0) {
        end -= 1;
        const slot = order[end];
        const n = layout.nodes[slot];
        counts[slot] = if (n.kind == .pane) 1 else counts[n.first] + counts[n.second];
    }
    pending[0] = .{ .index = index, .rect = rect };
    var count: usize = 1;
    while (count > 0) {
        count -= 1;
        const item = pending[count];
        var n = layout.nodes[item.index];
        if (n.kind != .horizontal and n.kind != .vertical) continue;
        const extent = @max(1, if (n.kind == .horizontal) item.rect.w - 1 else item.rect.h - 1);
        const limit = std.math.clamp((if (n.kind == .horizontal) min_w else min_h) / extent, 0.1, 0.45);
        n.ratio = std.math.clamp(@as(f32, @floatFromInt(counts[n.first])) / @as(f32, @floatFromInt(counts[item.index])), limit, 1 - limit);
        layout.nodes[item.index].ratio = n.ratio;
        const parts = divided(n, item.rect, false);
        pending[count] = .{ .index = n.second, .rect = parts[1] };
        pending[count + 1] = .{ .index = n.first, .rect = parts[0] };
        count += 2;
    }
}
pub fn resize(layout: anytype, index: usize, rect: Rect, direction: Direction, pixels: u16, min_w: f32, min_h: f32) bool {
    if (index == @import("layout.zig").document_root) return false;
    const horizontal = direction == .left or direction == .right;
    var item: Frame = .{ .index = index, .rect = rect };
    var nearest: ?Frame = null;
    while (true) {
        const n = layout.nodes[item.index];
        if (n.kind != .horizontal and n.kind != .vertical) break;
        if (horizontal == (n.kind == .horizontal)) nearest = item;
        const parts = divided(n, item.rect, false);
        const first = layout.contains(n.first, layout.active_pane);
        item = .{ .index = if (first) n.first else n.second, .rect = parts[if (first) 0 else 1] };
    }
    const target = nearest orelse return false;
    const extent = @max(1, if (horizontal) target.rect.w - 1 else target.rect.h - 1);
    const limit = std.math.clamp((if (horizontal) min_w else min_h) / extent, 0.1, 0.45);
    const amount = @as(f32, @floatFromInt(pixels)) / extent;
    const sign: f32 = if (direction == .right or direction == .down) 1 else -1;
    layout.nodes[target.index].ratio = std.math.clamp(layout.nodes[target.index].ratio + sign * amount, limit, 1 - limit);
    return true;
}
