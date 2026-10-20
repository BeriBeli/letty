//! Native service settings; global: declarations are the registration opt-in.
const std = @import("std");
const quick = @import("quick_terminal.zig");
pub const Settings = struct {
    global_hotkeys: bool = true,
    accessibility: bool = true,
    quick_position: quick.Position = .top,
    quick_width: f64 = 1,
    quick_height: f64 = 0.4,
    quick_auto_hide: bool = true,
    quick_always_on_top: bool = true,
    pub fn geometry(s: Settings, screen: quick.Bounds) quick.Geometry {
        return .{ .screen = screen, .position = s.quick_position, .width = s.quick_width, .height = s.quick_height, .auto_hide = s.quick_auto_hide, .always_on_top = s.quick_always_on_top };
    }
    pub fn validate(s: Settings) !void {
        if (!std.math.isFinite(s.quick_width) or s.quick_width <= 0 or s.quick_width > 1 or
            !std.math.isFinite(s.quick_height) or s.quick_height <= 0 or s.quick_height > 1) return error.InvalidQuickTerminalGeometry;
    }
};
fn boolean(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidBoolean;
}
pub fn apply(s: *Settings, key: []const u8, value: []const u8) !bool {
    if (std.mem.eql(u8, key, "global-hotkeys")) s.global_hotkeys = try boolean(value) else if (std.mem.eql(u8, key, "accessibility")) s.accessibility = try boolean(value) else if (std.mem.eql(u8, key, "quick-terminal-position")) s.quick_position = std.meta.stringToEnum(quick.Position, value) orelse return error.InvalidQuickTerminalPosition else if (std.mem.eql(u8, key, "quick-terminal-width")) s.quick_width = try std.fmt.parseFloat(f64, value) else if (std.mem.eql(u8, key, "quick-terminal-height")) s.quick_height = try std.fmt.parseFloat(f64, value) else if (std.mem.eql(u8, key, "quick-terminal-autohide")) s.quick_auto_hide = try boolean(value) else if (std.mem.eql(u8, key, "quick-terminal-always-on-top")) s.quick_always_on_top = try boolean(value) else return false;
    try s.validate();
    return true;
}
