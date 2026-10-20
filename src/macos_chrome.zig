//! Ghostty's transparent window style uses the terminal background for the titlebar.
//! Keep AppKit's traffic lights, dragging, window shadow and fullscreen behavior.
const nano = @import("nanoui");
const objc = nano.objc;
pub fn configure(window: *nano.Window, rgb: u24) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const color = objc.msg(objc.Object, objc.class("NSColor"), "colorWithSRGBRed:green:blue:alpha:", .{
        @as(f64, @floatFromInt((rgb >> 16) & 255)) / 255,
        @as(f64, @floatFromInt((rgb >> 8) & 255)) / 255,
        @as(f64, @floatFromInt(rgb & 255)) / 255,
        @as(f64, 1),
    });
    objc.msg(void, window.nswindow, "setBackgroundColor:", .{color});
    objc.msg(void, window.nswindow, "setTitlebarAppearsTransparent:", .{objc.YES});
    // Our portable layout owns tabs; don't let the default Window menu create
    // a second, unrelated AppKit tab group.
    objc.msg(void, window.nswindow, "setTabbingMode:", .{@as(objc.NSInteger, 2)});
    const light = (rgb >> 16) * @as(u32, 299) + ((rgb >> 8) & 255) * @as(u32, 587) + (rgb & 255) * @as(u32, 114) > 128000;
    const appearance = objc.msg(objc.Object, objc.class("NSAppearance"), "appearanceNamed:", .{objc.nsString(if (light) "NSAppearanceNameAqua" else "NSAppearanceNameDarkAqua")});
    objc.msg(void, window.nswindow, "setAppearance:", .{appearance});
}
