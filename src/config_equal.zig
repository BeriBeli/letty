//! Semantic config comparison across separately owned parse arenas.
const std = @import("std");
const Config = @import("config.zig").Config;
fn equal(comptime T: type, a: T, b: T) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => blk: {
                if (a.len != b.len) break :blk false;
                for (a, b) |left, right| if (!equal(p.child, left, right)) break :blk false;
                break :blk true;
            },
            .one => equal(p.child, a.*, b.*),
            else => a == b,
        },
        .optional => |o| if (a) |left| (if (b) |right| equal(o.child, left, right) else false) else b == null,
        .array => |array| blk: {
            for (a, b) |left, right| if (!equal(array.child, left, right)) break :blk false;
            break :blk true;
        },
        .@"struct" => |s| blk: {
            inline for (s.field_names) |name| if (!equal(@FieldType(T, name), @field(a, name), @field(b, name))) break :blk false;
            break :blk true;
        },
        .@"union" => |u| blk: {
            if (u.tag_type == null) @compileError("Config comparison requires tagged unions");
            const tag = std.meta.activeTag(a);
            if (tag != std.meta.activeTag(b)) break :blk false;
            inline for (u.field_names) |name| if (tag == @field(u.tag_type.?, name)) break :blk equal(@FieldType(T, name), @field(a, name), @field(b, name));
            unreachable;
        },
        .void => true,
        else => a == b,
    };
}
pub fn navigationOnly(before: Config, after: Config) bool {
    inline for (@typeInfo(Config).@"struct".field_names) |name| {
        if (comptime !std.mem.eql(u8, name, "workspace_navigation") and !std.mem.eql(u8, name, "sidebar_show_git") and !std.mem.eql(u8, name, "sidebar_show_ports") and !std.mem.eql(u8, name, "tab_bar")) {
            if (!equal(@FieldType(Config, name), @field(before, name), @field(after, name))) return false;
        }
    }
    return before.workspace_navigation != after.workspace_navigation or before.tab_bar != after.tab_bar or
        before.sidebar_show_git != after.sidebar_show_git or before.sidebar_show_ports != after.sidebar_show_ports;
}
test "navigation comparison uses owned values and preserves non-navigation changes" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var b = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer b.deinit();
    const config = @import("config.zig");
    const left = try config.parseText(a.allocator(), "font-family = Maple Mono\nworkspace-navigation = top\nkeybind = ctrl+k=text:abc");
    var right = try config.parseText(b.allocator(), "font-family = Maple Mono\nworkspace-navigation = sidebar\nkeybind = ctrl+k=text:abc");
    try std.testing.expect(navigationOnly(left, right));
    right.font_size += 1;
    try std.testing.expect(!navigationOnly(left, right));
}
