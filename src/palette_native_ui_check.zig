//! Exercise AppKit routing in an owned hidden window, without desktop input.
const std = @import("std");
const nano = @import("nanoui");
const keys = @import("keybindings.zig");
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.NativePaletteCheck;
}
pub fn run(s: anytype, view: nano.ui.View) !void {
    if (@import("builtin").os.tag != .macos) return;
    const objc = nano.objc;
    const window = try s.app.newWindow(.{ .title = "Hidden palette check", .visible = false, .width = 800, .height = 500, .content = .{ .view = view } });
    defer window.close();
    const old_window = s.window;
    s.window = window;
    defer s.window = old_window;
    const surface = window.surface.?;
    var controls: @import("application_chrome.zig").Runtime(@TypeOf(s.*)) = .{};
    @import("window_chrome.zig").configure(window);
    const controllers = objc.msg(objc.Object, window.nswindow, "titlebarAccessoryViewControllers", .{});
    try check(objc.msg(objc.NSUInteger, controllers, "count", .{}) == 1, "Letty titlebar reserves traffic-light space in an owned hidden window");
    const accessory = objc.msg(objc.Object, controllers, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
    const accessory_view = objc.msg(objc.Object, accessory, "view", .{});
    const buttons = objc.msg(objc.Object, accessory_view, "subviews", .{});
    try check(objc.msg(objc.NSUInteger, buttons, "count", .{}) == 0, "Letty titlebar has no legacy accessory buttons");
    controls.enqueue(s, .commands);
    try check(controls.pending != null and !s.palette.open, "window request queues until ownership is validated");
    controls.drain(s, &surface.ctx);
    try check(s.palette.open, "validated window request opens the session palette");
    s.palette.dismiss(&surface.ctx);
    controls.detach();
    try check(controls.pending == null, "detach clears deferred window work");
    const number = objc.msg(objc.NSInteger, window.nswindow, "windowNumber", .{});
    const event = objc.msg(objc.Object, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
        @as(objc.NSUInteger, 10), objc.CGPoint{}, @as(objc.NSUInteger, (1 << 20) | (1 << 17)), @as(f64, 0), number, @as(?objc.Object, null), objc.nsString("P"), objc.nsString("P"), objc.NO, @as(u16, 35),
    });
    const session = s.active().?;
    const pid = session.pid;
    objc.msg(void, surface.nsview, "keyDown:", .{event});
    try check(s.palette.open and s.palette.query.len == 0 and session.pid == pid, "native Cmd+Shift+P opens palette without inserting P or replacing PTY");
    objc.msg(void, surface.nsview, "keyDown:", .{event});
    try check(!s.palette.open, "native Cmd+Shift+P toggles palette closed");
    try s.macMenu();
    const menu = s.app.main_menu.?;
    const taken = objc.msg(objc.BOOL, menu.ns, "performKeyEquivalent:", .{event});
    surface.frame();
    try check(taken == objc.YES and s.palette.open, "AppKit menu Cmd+Shift+P opens the same command palette");
    s.palette.dismiss(&surface.ctx);
    const previous = s.cfg.keybinds;
    const overrides = [_]keys.Binding{try keys.parse("super+shift+p=ignore")};
    s.cfg.keybinds = &overrides;
    defer s.cfg.keybinds = previous;
    try s.macMenu();
    const ignored = objc.msg(objc.BOOL, s.app.main_menu.?.ns, "performKeyEquivalent:", .{event});
    objc.msg(void, surface.nsview, "keyDown:", .{event});
    try check(ignored == objc.NO and !s.palette.open, "custom override removes native palette accelerator and consumes the original key");
    s.cfg.keybinds = previous;
    try s.macMenu();
}
