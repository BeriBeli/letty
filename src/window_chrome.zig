//! Kero's frameless window geometry and native window actions.
const builtin = @import("builtin");
const nano = @import("nanoui");
const ui = nano.ui;
const objc = if (builtin.os.tag == .macos) nano.objc else struct {};
const c = @import("platform_ffi.zig");

pub fn configure(window: *nano.Window) void {
    if (builtin.os.tag == .macos) {
        const view = objc.msg(objc.Object, objc.msg(objc.Object, objc.class("NSView"), "alloc", .{}), "initWithFrame:", .{objc.CGRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1, .height = 32 } }});
        defer objc.release(view);
        const accessory = objc.new("NSTitlebarAccessoryViewController");
        defer objc.release(accessory);
        objc.msg(void, accessory, "setView:", .{view});
        objc.msg(void, accessory, "setLayoutAttribute:", .{@as(objc.NSInteger, 4)});
        objc.msg(void, window.nswindow, "addTitlebarAccessoryViewController:", .{accessory});
    } else if (builtin.os.tag == .linux) if (window.gtkwindow) |win| c.lt_window_configure(@ptrCast(win));
}
pub fn layout(window: ?*nano.Window, _: f32) void {
    if (builtin.os.tag != .macos) return;
    const w = window orelse return;
    for (0..3) |i| {
        const button = objc.msg(?objc.Object, w.nswindow, "standardWindowButton:", .{@as(objc.NSUInteger, @intCast(i))}) orelse continue;
        const parent = objc.msg(objc.Object, button, "superview", .{});
        const bounds = objc.msg(objc.CGRect, parent, "bounds", .{});
        objc.msg(void, button, "setFrameOrigin:", .{objc.CGPoint{ .x = 18 + @as(f64, @floatFromInt(i)) * 20, .y = bounds.size.height - 38 }});
    }
}
pub fn drag(window: ?*nano.Window, ctx: *ui.Context, rect: ui.Rect) void {
    const w = window orelse return;
    if (w.app.flags.hidden or !ctx.input.pressed or ctx.input.mouse_button != 1 or !rect.contains(ctx.input.mouse)) return;
    if (ctx.input.click_count == 2) {
        w.zoom();
    } else if (builtin.os.tag == .macos) {
        const app = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
        if (objc.msg(?objc.Object, app, "currentEvent", .{})) |event| objc.msg(void, w.nswindow, "performWindowDragWithEvent:", .{event});
    } else if (builtin.os.tag == .linux) if (w.gtkwindow) |win| c.lt_window_drag(@ptrCast(win));
    ctx.input.clearEdges();
}
pub fn controls(ctx: *ui.Context, window: ?*nano.Window) bool {
    if (builtin.os.tag == .macos) return false;
    const chrome = @import("chrome.zig");
    const w = window orelse return false;
    ui.key(ctx, "window-minimize");
    if (chrome.iconButton(ctx, .minimize, 28)) w.minimize();
    ui.key(ctx, "window-maximize");
    if (chrome.iconButton(ctx, .maximize, 28)) w.zoom();
    ui.key(ctx, "window-close");
    return chrome.iconButton(ctx, .close, 28);
}
