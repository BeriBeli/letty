//! Native box typesetting: metrics and paint share the same recursive geometry.
const std = @import("std");
const ui = @import("nanoui").ui;
const Node = @import("math.zig").Node;
pub const Box = struct { width: f32, ascent: f32, descent: f32 };
fn scaled(size: f32) f32 {
    return @max(6, size * 0.72);
}
pub fn measure(ctx: *ui.Context, node: *const Node, size: f32) Box {
    return switch (node.*) {
        .text => |value| .{ .width = ctx.text.layout(value, .{ .size = size }).width, .ascent = size * 1.05, .descent = size * 0.35 },
        .sequence => |items| blk: {
            var box: Box = .{ .width = 0, .ascent = size * 1.05, .descent = size * 0.35 };
            for (items) |item| {
                const b = measure(ctx, item, size);
                box.width += b.width;
                box.ascent = @max(box.ascent, b.ascent);
                box.descent = @max(box.descent, b.descent);
            }
            break :blk box;
        },
        .fraction => |pair| blk: {
            const top = measure(ctx, pair.top, scaled(size));
            const bottom = measure(ctx, pair.bottom, scaled(size));
            break :blk .{ .width = @max(top.width, bottom.width) + size * 0.5, .ascent = top.ascent + top.descent + size * 0.35, .descent = bottom.ascent + bottom.descent + size * 0.15 };
        },
        .root => |inner| blk: {
            const b = measure(ctx, inner, size);
            break :blk .{ .width = b.width + size * 0.85, .ascent = b.ascent + size * 0.2, .descent = b.descent };
        },
        .scripts => |scripts| blk: {
            var b = measure(ctx, scripts.base, size);
            var w: f32 = 0;
            if (scripts.sup) |sup| {
                const v = measure(ctx, sup, scaled(size));
                w = @max(w, v.width);
                b.ascent = @max(b.ascent, size * 0.65 + v.ascent);
            }
            if (scripts.sub) |sub| {
                const v = measure(ctx, sub, scaled(size));
                w = @max(w, v.width);
                b.descent = @max(b.descent, size * 0.4 + v.descent);
            }
            b.width += w;
            break :blk b;
        },
    };
}
pub fn draw(ctx: *ui.Context, node: *const Node, size: f32, x: f32, baseline: f32) void {
    switch (node.*) {
        .text => |value| {
            ui.column(ctx, .{ .absolute = true, .offset = .{ .x = x, .y = baseline - size * 1.05 } });
            ui.text(ctx, value, .{ .size = size });
            ui.end(ctx);
        },
        .sequence => |items| {
            var at = x;
            for (items) |item| {
                draw(ctx, item, size, at, baseline);
                at += measure(ctx, item, size).width;
            }
        },
        .fraction => |pair| {
            const b = measure(ctx, node, size);
            const top = measure(ctx, pair.top, scaled(size));
            const bottom = measure(ctx, pair.bottom, scaled(size));
            const axis = baseline - size * 0.15;
            draw(ctx, pair.top, scaled(size), x + (b.width - top.width) / 2, axis - size * 0.2 - top.descent);
            draw(ctx, pair.bottom, scaled(size), x + (b.width - bottom.width) / 2, axis + size * 0.2 + bottom.ascent);
            rule(ctx, x + 1, axis, b.width - 2);
        },
        .root => |inner| {
            const b = measure(ctx, inner, size);
            const top = baseline - b.ascent - size * 0.08;
            segment(ctx, x, baseline - size * 0.3, x + size * 0.2, baseline - size * 0.45);
            segment(ctx, x + size * 0.2, baseline - size * 0.45, x + size * 0.4, baseline + b.descent * 0.2);
            segment(ctx, x + size * 0.4, baseline + b.descent * 0.2, x + size * 0.65, top);
            draw(ctx, inner, size, x + size * 0.75, baseline);
            rule(ctx, x + size * 0.65, baseline - b.ascent - size * 0.08, b.width + size * 0.2);
        },
        .scripts => |scripts| {
            draw(ctx, scripts.base, size, x, baseline);
            const at = x + measure(ctx, scripts.base, size).width;
            if (scripts.sup) |sup| draw(ctx, sup, scaled(size), at, baseline - size * 0.65);
            if (scripts.sub) |sub| draw(ctx, sub, scaled(size), at, baseline + size * 0.4);
        },
    }
}
fn rule(ctx: *ui.Context, x: f32, y: f32, w: f32) void {
    _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = .{ .px = w }, .height = .{ .px = 1 }, .background = ctx.theme.text }, .none, null);
}

fn segment(ctx: *ui.Context, ax: f32, ay: f32, bx: f32, by: f32) void {
    const count: usize = @intFromFloat(@max(1, @ceil(@max(@abs(bx - ax), @abs(by - ay)) / 0.8)));
    for (0..count + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count));
        rule(ctx, ax + (bx - ax) * t, ay + (by - ay) * t, 1);
    }
}
