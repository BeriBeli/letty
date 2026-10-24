//! Presentation assets retained from the verified MyGo -> nanoui UI port.
//! This leaf has no application, PTY, configuration or legacy VT ownership.
const ui = @import("nanoui").ui;
pub const icons = @import("ui_icons/icons.zig");
pub fn wash(ctx: *ui.Context, name: []const u8) void {
    const std = @import("std");
    const dark = ctx.theme.dark;
    const asset: struct { key: []const u8, bytes: []const u8 } = if (std.mem.eql(u8, name, "mist"))
        (if (dark) .{ .key = "letty-mist-dark", .bytes = @embedFile("ui_assets/rex-mist-dark.png") } else .{ .key = "letty-mist-light", .bytes = @embedFile("ui_assets/rex-mist-light.png") })
    else if (std.mem.eql(u8, name, "meadow"))
        (if (dark) .{ .key = "letty-meadow-dark", .bytes = @embedFile("ui_assets/rex-meadow-dark.png") } else .{ .key = "letty-meadow-light", .bytes = @embedFile("ui_assets/rex-meadow-light.png") })
    else if (std.mem.eql(u8, name, "dusk"))
        (if (dark) .{ .key = "letty-dusk-dark", .bytes = @embedFile("ui_assets/rex-dusk-dark.png") } else .{ .key = "letty-dusk-light", .bytes = @embedFile("ui_assets/rex-dusk-light.png") })
    else if (std.mem.eql(u8, name, "plain"))
        (if (dark) .{ .key = "letty-plain-dark", .bytes = @embedFile("ui_assets/rex-plain-dark.png") } else .{ .key = "letty-plain-light", .bytes = @embedFile("ui_assets/rex-plain-light.png") })
    else
        (if (dark) .{ .key = "letty-rex-dark", .bytes = @embedFile("ui_assets/rex-dark.png") } else .{ .key = "letty-rex-light", .bytes = @embedFile("ui_assets/rex-light.png") });
    const node: u32 = @intCast(ctx.nodes.items.len);
    if (ui.image(ctx, .{ .key = asset.key, .bytes = asset.bytes, .radius = 0 })) ctx.node(node).style = .{ .absolute = true, .width = .{ .px = ctx.size.w }, .height = .{ .px = ctx.size.h } };
}
