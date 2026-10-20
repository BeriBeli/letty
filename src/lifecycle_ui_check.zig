//! M3 tests never touch the developer's clipboard, editor, config or visible windows.
const std = @import("std");
const nano = @import("nanoui");
const ui = nano.ui;
const vt_api = @import("vt.zig");
const c = @import("platform_ffi.zig");
const Request = @import("actions.zig").Request;
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn unlink([*:0]const u8) c_int;
extern "c" fn rmdir([*:0]const u8) c_int;
extern "c" fn kill(c_int, c_int) c_int;
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.LifecycleUiCheck;
}
fn action(s: anytype, t: *ui.Tester, request: Request) void {
    s.menu_actions[0] = request;
    s.menu_action_count = 1;
    t.frame();
}
fn rightClick(t: *ui.Tester, x: f32, y: f32, shift: bool) void {
    t.moveTo(x, y);
    t.ctx.input.mouse_button = 2;
    t.ctx.input.shift = shift;
    t.ctx.pointerDown();
    t.frame();
    t.ctx.pointerUp();
    t.frame();
    t.ctx.input.mouse_button = 1;
    t.ctx.input.shift = false;
}
fn clickText(t: *ui.Tester, title: []const u8) !void {
    const rect = t.findText(title) orelse return error.MissingControl;
    t.click(rect.x + rect.w / 2, rect.y + rect.h / 2);
    t.frame();
}
pub fn run(s: anytype, t: *ui.Tester, view: ui.View) !void {
    t.resize(800, 500);
    rightClick(t, 60, 150, false);
    try check(s.context_menu.open and t.findText("Select All") != null, "terminal right click opens nanoui actions");
    t.key(.escape);
    rightClick(t, 1, 150, false);
    try check(s.context_menu.open, "context menu opening at window edge does not treat its own press as outside dismissal");
    t.key(.escape);
    rightClick(t, 70, 14, false);
    try check(s.context_menu.open and s.context_menu.kind == .tab, "tab right click retains a stable tab target");
    try clickText(t, "Tab: Rename…");
    t.textOps(&.{ .{ .command = .select_all }, .{ .insert = "Context Tab" } });
    t.key(.enter);
    t.frame();
    try check(std.mem.eql(u8, s.layout.tabs[s.layout.active_tab].name(), "Context Tab"), "context menu rename shares typed dispatcher and prompt");
    const session = s.sessions[s.layout.active_pane].?;
    vt_api.lt_vt_feed(session.vt, "\x1b[?1000h\x1b[?1006h", 16);
    rightClick(t, 60, 150, false);
    try check(!s.context_menu.open, "TUI mouse tracking keeps ordinary right click");
    rightClick(t, 60, 150, true);
    try check(s.context_menu.open, "Shift right click opens terminal menu over TUI");
    t.key(.escape);
    vt_api.lt_vt_feed(session.vt, "\x1b[?1000l\x1b[?1006l", 16);
    _ = t.shortcut(.{ .key = 'u', .ctrl = true });
    try configFlow(s, t);
    // Make room for a dedicated task; existing test sessions remain independent.
    s.cfg.confirm_close = .never;
    action(s, t, .{ .action = .close_tab });
    action(s, t, .{ .action = .tab });
    const task = s.sessions[s.layout.active_pane].?;
    const pid = task.pid;
    const id = task.id;
    for (0..4) |_| {
        nano.runFor(0.05);
        t.frame();
    }
    t.typeText("sleep 30");
    t.key(.enter);
    for (0..4) |_| {
        nano.runFor(0.05);
        t.frame();
    }
    s.cfg.confirm_close = .always;
    action(s, t, .{ .action = .close });
    try check(s.confirmation.open and s.close_pending.contains(id) and kill(pid, 0) == 0, "close request snapshots task ID and leaves its process alive before approval");
    try t.screenshot(".cache/test-logs/close-confirmation-paper.png");
    t.key(.escape);
    try check(!s.confirmation.open and s.sessions[s.layout.active_pane].?.id == id and kill(pid, 0) == 0, "cancel close preserves layout, PTY and running task");
    action(s, t, .{ .action = .close });
    t.key(.enter);
    try check(!s.confirmation.open and kill(pid, 0) == 0, "confirmation defaults to Cancel on Enter");
    action(s, t, .{ .action = .close });
    try clickText(t, "Close Sessions");
    var found = false;
    for (s.sessions) |opt| if (opt) |p| if (p.id == id) {
        found = true;
    };
    try check(!found and !s.confirmation.open, "confirmed close resolves stable ID and destroys only requested session");
    // Test the same cancellable callback reached by OS close before destruction.
    const window = try s.app.newWindow(.{ .title = "Hidden close check", .visible = false, .width = 480, .height = 240, .content = .{ .view = view }, .on_close_request = .{ .ctx = s, .func = @TypeOf(s.*).windowCloseRequested } });
    const old_window = s.window;
    s.window = window;
    if (@import("builtin").os.tag == .macos) {
        const objc = nano.objc;
        const number = objc.msg(objc.NSInteger, window.nswindow, "windowNumber", .{});
        const surface = window.surface.?;
        const event = objc.msg(objc.Object, objc.class("NSEvent"), "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:", .{ @as(objc.NSUInteger, 3), objc.CGPoint{ .x = 60, .y = 90 }, @as(objc.NSUInteger, 0), @as(f64, 0), number, @as(?objc.Object, null), @as(objc.NSInteger, 1), @as(objc.NSInteger, 1), @as(f32, 1) });
        objc.msg(void, surface.nsview, "rightMouseDown:", .{event});

        try check(s.context_menu.open and surface.ctx.input.mouse_button == 2, "hidden native rightMouseDown reaches portable context menu");
        t.key(.escape);
        const allowed = objc.msg(objc.BOOL, window.delegate, "windowShouldClose:", .{window.nswindow});
        try check(allowed == objc.NO and !window.closed, "native NSWindowDelegate veto precedes window destruction");
        t.frame();
        t.key(.escape);
    }
    try check(!window.requestClose() and !window.closed, "window request-close callback vetoes destruction before on_close");
    t.frame();
    try check(s.confirmation.open and s.close_pending.scope == .window and !window.closed, "system-window close reaches cancellable all-session confirmation");
    t.key(.escape);
    try check(!s.confirmation.open and !window.closed, "cancelling window close keeps window and sessions alive");
    s.window = old_window;
    window.close();
    s.cfg.confirm_close = .never;
}
fn configFlow(s: anytype, t: *ui.Tester) !void {
    const template = try s.gpa.dupeSentinel(u8, ".cache/test-logs/lifecycle-XXXXXX", 0);
    defer s.gpa.free(template);
    const dir = mkdtemp(template) orelse return error.TempDirectory;
    defer _ = rmdir(dir);
    const file = try std.fmt.allocPrintSentinel(s.gpa, "{s}/config", .{std.mem.span(dir)}, 0);
    defer s.gpa.free(file);
    defer _ = unlink(file);
    const old_path = s.explicit_config;
    s.explicit_config = file;
    defer s.explicit_config = old_path;
    var called: usize = 0;
    s.opener_override = .{ .ctx = &called, .call = struct {
        fn fail(data: *anyopaque, _: []const u8) bool {
            const count: *usize = @ptrCast(@alignCast(data));
            count.* += 1;
            return false;
        }
    }.fail };
    defer s.opener_override = null;
    action(s, t, .{ .action = .open_config });
    try check(s.confirmation.open and !@import("config.zig").exists(file), "opening missing config asks for explicit starter-file creation");
    try clickText(t, "Create & Open");
    try check(@import("config.zig").exists(file) and called == 1 and s.confirmation.open, "starter creation and failed opener expose a copyable path");
    try clickText(t, "Copy Details");
    try check(std.mem.indexOf(u8, t.clipboard.items, std.mem.span(dir)) != null, "diagnostic Copy Details uses tester clipboard and includes actual path");
    t.key(.escape);
    // Create between request and acceptance: O_EXCL must preserve the new file.
    _ = unlink(file);
    action(s, t, .{ .action = .open_config });
    const preserved = "font-size = 17\n";
    try check(c.lt_write_atomic(file, preserved, preserved.len) == 0, "prepare concurrent configuration creation");
    try clickText(t, "Create & Open");
    t.key(.escape);
    var arena = std.heap.ArenaAllocator.init(s.gpa);
    defer arena.deinit();
    const loaded = try @import("config.zig").load(arena.allocator(), file);
    try check(loaded.font_size == 17, "starter creation never overwrites a concurrently created config");
    const invalid = "font-size = 18\ncursor-style = invalid\n";
    _ = c.lt_write_atomic(file, invalid, invalid.len);
    const pid = s.sessions[s.layout.active_pane].?.pid;
    action(s, t, .{ .action = .reload });
    try check(s.confirmation.open and s.config_diagnostic.line == 2 and std.mem.eql(u8, s.config_diagnostic.key[0..s.config_diagnostic.key_len], "cursor-style") and s.sessions[s.layout.active_pane].?.pid == pid, "reload diagnostics retain exact line/key and original running PTY");
    try t.screenshot(".cache/test-logs/config-diagnostics-paper.png");
    t.key(.escape);
}
