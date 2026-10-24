//! Kero's wash table expressed through the shared nanoui rectangle interface.
const std = @import("std");
const ui = @import("nanoui").ui;
pub fn draw(ctx: *ui.Context, name: []const u8, translucent: bool) void {
    if (!std.mem.eql(u8, name, "petal")) {
        ctx.node(0).style.background = .transparent;
        const first = ctx.nodes.items.len;
        @import("interface-assets").wash(ctx, name);
        if (translucent and ctx.nodes.items.len > first) ctx.node(@intCast(first)).style.opacity = if (std.mem.eql(u8, name, "plain")) 0.82 else 0.95;
        return;
    }
    const dark = ctx.theme.dark;
    const stops: [4]u24 = if (std.mem.eql(u8, name, "mist")) (if (dark) .{ 0x12151b, 0x14171d, 0x17181b, 0x17181b } else .{ 0xe3e9f4, 0xebeff6, 0xf1f2f3, 0xf2f1ec }) else if (std.mem.eql(u8, name, "meadow")) (if (dark) .{ 0x111814, 0x141a16, 0x181a14, 0x181a14 } else .{ 0xe2eee5, 0xebf2e7, 0xf3f2e2, 0xf5f0d6 }) else if (std.mem.eql(u8, name, "dusk")) (if (dark) .{ 0x191321, 0x1e161e, 0x221a17, 0x221a17 } else .{ 0xe4dbf3, 0xefdeee, 0xf6e3dc, 0xf7e6cf }) else if (std.mem.eql(u8, name, "plain")) (if (dark) @splat(0x141418) else @splat(0xeceef4)) else if (std.mem.eql(u8, name, "petal")) (if (dark) .{ 0x21161c, 0x231b20, 0x261f21, 0x261f21 } else .{ 0xf5dfe8, 0xf6e4ee, 0xf8ebf0, 0xf7efe6 }) else (if (dark) .{ 0x17141f, 0x191620, 0x1b1916, 0x1b1916 } else .{ 0xebe0f3, 0xf3e7f1, 0xf7eee4, 0xf6efcf });
    const alpha: f32 = if (translucent) (if (std.mem.eql(u8, name, "plain")) @as(f32, 0.82) else 0.95) else 1;
    ctx.node(0).style.background = ui.Color.transparent;
    ctx.theme.background = ui.Color.hex(stops[0]).alpha(if (translucent) 0 else 1);
    const bands = 64;
    for (0..bands) |i| {
        const position = @as(f32, @floatFromInt(i)) / @as(f32, bands - 1) * 3;
        const index = @min(@as(usize, @intFromFloat(position)), 2);
        const color = ui.Color.hex(stops[index]).mix(ui.Color.hex(stops[index + 1]), position - @as(f32, @floatFromInt(index))).alpha(alpha);
        const y = @as(f32, @floatFromInt(i)) * ctx.size.h / bands;
        _ = ctx.leaf(.{ .absolute = true, .offset = .{ .y = y }, .width = .fill, .height = .{ .px = ctx.size.h / bands + 1 }, .background = color }, .none, null);
    }
}
