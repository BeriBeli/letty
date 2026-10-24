//! Retained Kero frameless-window geometry, adapted to the current nanoui API.
const std = @import("std");
const nano = @import("nanoui");
const ui = nano.ui;
const mac = @import("builtin").os.tag == .macos;
const c = @import("libc.zig");
pub fn configure(window: *nano.Window) void {
    if (mac) {
        const objc = nano.objc;
        const view = objc.msg(objc.Object, objc.alloc("NSView"), "initWithFrame:", .{objc.CGRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1, .height = 32 } }});
        defer objc.release(view);
        const accessory = objc.new("NSTitlebarAccessoryViewController");
        defer objc.release(accessory);
        objc.msg(void, accessory, "setView:", .{view});
        objc.msg(void, accessory, "setLayoutAttribute:", .{@as(objc.NSInteger, 4)});
        objc.msg(void, window.nswindow, "addTitlebarAccessoryViewController:", .{accessory});
        layout(window);
    } else if (window.gtkwindow) |widget| {
        const lib = c.dlopen("libgtk-3.so.0", c.RTLD_LAZY) orelse return;
        defer _ = c.dlclose(lib);
        const set: *const fn (*anyopaque, c_int) callconv(.c) void = @ptrCast(c.dlsym(lib, "gtk_window_set_decorated") orelse return);
        set(@ptrCast(widget), 0);
    }
}
pub fn layout(window: *nano.Window) void {
    if (!mac) return;
    const objc = nano.objc;
    for (0..3) |i| {
        const button = objc.msg(?objc.Object, window.nswindow, "standardWindowButton:", .{@as(objc.NSUInteger, @intCast(i))}) orelse continue;
        const parent = objc.msg(objc.Object, button, "superview", .{});
        const bounds = objc.msg(objc.CGRect, parent, "bounds", .{});
        objc.msg(void, button, "setFrameOrigin:", .{objc.CGPoint{ .x = 18 + @as(f64, @floatFromInt(i)) * 20, .y = bounds.size.height - 38 }});
    }
}
pub fn drag(window: *nano.Window, ctx: *ui.Context, rect: ui.Rect) bool {
    if (window.app.flags.hidden or !ctx.input.pressed or ctx.input.mouse_button != 1 or !rect.contains(ctx.input.mouse)) return false;
    if (ctx.input.click_count == 2) window.zoom() else if (mac) {
        const objc = nano.objc;
        const app = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
        if (objc.msg(?objc.Object, app, "currentEvent", .{})) |event| objc.msg(void, window.nswindow, "performWindowDragWithEvent:", .{event});
    } else if (window.gtkwindow) |widget| {
        const lib = c.dlopen("libgtk-3.so.0", c.RTLD_LAZY) orelse return false;
        defer _ = c.dlclose(lib);
        const event = c.dlsym(lib, "gtk_get_current_event") orelse return false;
        const get: *const fn () callconv(.c) ?*anyopaque = @ptrCast(event);
        const raw = get() orelse return false;
        const free: *const fn (*anyopaque) callconv(.c) void = @ptrCast(c.dlsym(lib, "gdk_event_free") orelse return false);
        defer free(raw);
        var x: f64 = 0;
        var y: f64 = 0;
        const coordinates: *const fn (*anyopaque, *f64, *f64) callconv(.c) c_int = @ptrCast(c.dlsym(lib, "gdk_event_get_root_coords") orelse return false);
        if (coordinates(raw, &x, &y) == 0) return false;
        const time: *const fn (*anyopaque) callconv(.c) u32 = @ptrCast(c.dlsym(lib, "gdk_event_get_time") orelse return false);
        const begin: *const fn (*anyopaque, c_int, c_int, c_int, u32) callconv(.c) void = @ptrCast(c.dlsym(lib, "gtk_window_begin_move_drag") orelse return false);
        begin(@ptrCast(widget), 1, @intFromFloat(x), @intFromFloat(y), time(raw));
    }
    ctx.input.clearEdges();
    return true;
}
