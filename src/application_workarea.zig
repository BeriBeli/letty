//! Draft native workarea query. No hardcoded screen, user-setting change or poll.
const std = @import("std");
const builtin = @import("builtin");
const nano = @import("nanoui");
const Bounds = @import("quick_terminal.zig").Bounds;
extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;
const Rect = extern struct { x: c_int, y: c_int, width: c_int, height: c_int };
pub fn forWindow(window: ?*nano.Window) !Bounds {
    if (builtin.os.tag == .macos) {
        const o = nano.objc;
        const screens = o.msg(o.Object, o.class("NSScreen"), "screens", .{});
        if (o.msg(o.NSUInteger, screens, "count", .{}) == 0) return error.NoScreen;
        const primary = o.msg(o.Object, screens, "objectAtIndex:", .{@as(o.NSUInteger, 0)});
        const requested = if (window) |w| o.msg(?o.Object, w.nswindow, "screen", .{}) else null;
        const main = requested orelse o.msg(?o.Object, o.class("NSScreen"), "mainScreen", .{}) orelse primary;
        const r = o.msg(o.CGRect, main, "visibleFrame", .{});
        const primary_frame = o.msg(o.CGRect, primary, "frame", .{});
        return checked(.{ .x = r.origin.x, .y = primary_frame.size.height - r.origin.y - r.size.height, .width = r.size.width, .height = r.size.height });
    }
    if (builtin.os.tag == .linux) {
        if (getenv("WAYLAND_DISPLAY") != null) return error.QuickTerminalWaylandUnsupported;
        if (getenv("XDG_SESSION_TYPE")) |kind| if (std.mem.eql(u8, std.mem.span(kind), "wayland")) return error.QuickTerminalWaylandUnsupported;
        // CentOS GTK3 supports GdkScreen monitor_workarea; monitor APIs added
        // in GTK3.22 are deliberately not a hard requirement. Query GTK's
        // display rather than opening a second display or guessing DISPLAY.
        var lib = std.DynLib.open("libgdk-3.so.0") catch return error.WorkareaUnavailable;
        defer lib.close();
        const Get = *const fn () callconv(.c) ?*anyopaque;
        const At = *const fn (*anyopaque, *anyopaque) callconv(.c) c_int;
        const Primary = *const fn (*anyopaque) callconv(.c) c_int;
        const Area = *const fn (*anyopaque, c_int, *Rect) callconv(.c) void;
        const ScreenOf = *const fn (*anyopaque) callconv(.c) ?*anyopaque;
        const Native = *const fn (*anyopaque) callconv(.c) ?*anyopaque;
        const get = lib.lookup(Get, "gdk_screen_get_default") orelse return error.WorkareaUnavailable;
        const screen_of = lib.lookup(ScreenOf, "gdk_window_get_screen") orelse return error.WorkareaUnavailable;
        const primary = lib.lookup(Primary, "gdk_screen_get_primary_monitor") orelse return error.WorkareaUnavailable;
        const at = lib.lookup(At, "gdk_screen_get_monitor_at_window") orelse return error.WorkareaUnavailable;
        const area = lib.lookup(Area, "gdk_screen_get_monitor_workarea") orelse return error.WorkareaUnavailable;
        var gtk = std.DynLib.open("libgtk-3.so.0") catch return error.WorkareaUnavailable;
        defer gtk.close();
        const native = gtk.lookup(Native, "gtk_widget_get_window") orelse return error.WorkareaUnavailable;
        const widget = if (window) |w| w.gtkwindow else null;
        const gdk_window = if (widget) |w| native(w) else null;
        const screen = (if (gdk_window) |w| screen_of(w) else get()) orelse return error.NoScreen;
        const monitor = if (gdk_window) |w| at(screen, w) else primary(screen);
        if (monitor < 0) return error.NoScreen;
        var r: Rect = undefined;
        area(screen, monitor, &r);
        return checked(.{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y), .width = @floatFromInt(r.width), .height = @floatFromInt(r.height) });
    }
    return error.WorkareaUnsupported;
}
fn checked(r: Bounds) !Bounds {
    for ([_]f64{ r.x, r.y, r.width, r.height }) |v| if (!std.math.isFinite(v)) return error.InvalidWorkarea;
    if (r.width <= 0 or r.height <= 0) return error.InvalidWorkarea;
    return r;
}
