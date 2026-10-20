//! Opt-in real AppKit/Metal measurements, in a separate developer test app.
const std = @import("std");
const nano = @import("nanoui");
const objc = nano.objc;
const ui = nano.ui;
const metrics = ui.window_metrics;
const clock = ui.clock;
const vt = @import("vt.zig");
extern "c" fn sel_getName(objc.SEL) [*:0]const u8;
extern "c" const NSWindowDidMiniaturizeNotification: objc.Object;
extern "c" const NSWindowDidDeminiaturizeNotification: objc.Object;
const Events = struct { mini: f64 = 0, restore: f64 = 0 };
const Target = struct { menu: objc.Object, index: objc.NSInteger };
var left: ?Target = null;
var right: ?Target = null;
var fill: ?Target = null;
fn menuTargets(menu: objc.Object, moving: bool, depth: usize) void {
    if (depth > 6) return;
    const count = objc.msg(objc.NSInteger, menu, "numberOfItems", .{});
    var i: objc.NSInteger = 0;
    while (i < count) : (i += 1) {
        const item = objc.msg(objc.Object, menu, "itemAtIndex:", .{i});
        const title = objc.fromNSString(objc.msg(objc.Object, item, "title", .{}));
        const move = moving or std.mem.indexOf(u8, title, "Move & Resize") != null;
        if (moving and std.mem.eql(u8, title, "Left")) left = .{ .menu = menu, .index = i };
        if (moving and std.mem.eql(u8, title, "Right")) right = .{ .menu = menu, .index = i };
        if (std.mem.eql(u8, title, "Fill")) fill = .{ .menu = menu, .index = i };
        if (objc.msg(?objc.Object, item, "submenu", .{})) |sub| menuTargets(sub, move, depth + 1);
        if (move) if (objc.msg(?objc.SEL, item, "action", .{})) |sel|
            std.debug.print("WINDOW_MENU {s}: {s}\n", .{ title, std.mem.span(sel_getName(sel)) });
    }
}
fn mini(obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    if (objc.getZig(Events, obj)) |e| e.mini = clock.now();
}
fn restored(obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    if (objc.getZig(Events, obj)) |e| e.restore = clock.now();
}
fn invoke(target: ?Target) bool {
    const t = target orelse return false;
    objc.msg(void, t.menu, "performActionForItemAtIndex:", .{t.index});
    return true;
}
fn setFrame(window: *nano.Window, rect: objc.CGRect) void {
    objc.msg(void, window.nswindow, "setFrame:display:animate:", .{ rect, objc.YES, objc.NO });
}
pub fn run(s: anytype, history: usize) !void {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag != .macos) return error.MacOSOnly;
    if (s.app.flags.hidden) return error.RealWindowRequired;
    s.cfg.confirm_close = .never;
    s.cfg.cursor_blink = false;
    try s.attach(null);
    s.window.?.setTitle("Letty Window Timing (isolated test)");
    const Task = struct {
        state: @TypeOf(s),
        lines: usize,
        events: Events = .{},
        bounds: objc.CGRect = .{},
        ordinary: objc.CGRect = .{},
        repeat: usize = 0,
        op: usize = 0,
        start_time: f64 = 0,
        call_us: f64 = 0,
        previous_size: [2]f64 = .{ 0, 0 },
        failure: ?anyerror = null,
        const operations = [_][]const u8{ "left", "right", "fill", "zoom", "unzoom", "resize_burst", "live_resize_burst", "minimize", "restore" };
        fn from(ptr: ?*anyopaque) *@This() {
            return @ptrCast(@alignCast(ptr.?));
        }
        fn start(ptr: ?*anyopaque) callconv(.c) void {
            const t = from(ptr);
            const window = t.state.window.?;
            const screen = objc.msg(objc.Object, window.nswindow, "screen", .{});
            t.bounds = objc.msg(objc.CGRect, screen, "visibleFrame", .{});
            const b = t.bounds;
            t.ordinary = .{ .origin = .{ .x = b.origin.x + 40, .y = b.origin.y + 40 }, .size = .{ .width = @min(950, b.size.width - 80), .height = @min(600, b.size.height - 80) } };
            setFrame(window, t.ordinary);
            if (objc.msg(?objc.Object, t.state.app.nsapp, "mainMenu", .{})) |menu| menuTargets(menu, false, 0);
            std.debug.print("WINDOW_ROUTES left={s} right={s} fill={s}\n", .{ if (left != null) "system-menu" else "geometry", if (right != null) "system-menu" else "geometry", if (fill != null) "system-menu" else "geometry" });
            for (0..t.lines) |_| {
                const line = "window resize payload 中文 e\xcc\x81 abcdefghijklmnopqrstuvwxyz 0123456789 abcdefghijklmnopqrstuvwxyz\r\n";
                vt.lt_vt_feed(t.state.active().?.vt, line.ptr, line.len);
            }
            window.redraw();
            // Every action and observation runs in a separate AppKit event-loop
            // turn. Nested CFRunLoop pumping inside one GCD callback prevents
            // normal transaction commits and is not a valid presentation test.
            nano.App.after(350, t, step);
        }
        fn step(ptr: ?*anyopaque) callconv(.c) void {
            const t = from(ptr);
            const window = t.state.window.?;
            const operation = operations[t.op];
            const b = t.bounds;
            t.events = .{};
            t.previous_size = window.contentSize();
            metrics.reset();
            t.start_time = clock.now();
            if (std.mem.eql(u8, operation, "left")) {
                if (!invoke(left)) setFrame(window, .{ .origin = b.origin, .size = .{ .width = b.size.width / 2, .height = b.size.height } });
            } else if (std.mem.eql(u8, operation, "right")) {
                if (!invoke(right)) setFrame(window, .{ .origin = .{ .x = b.origin.x + b.size.width / 2, .y = b.origin.y }, .size = .{ .width = b.size.width / 2, .height = b.size.height } });
            } else if (std.mem.eql(u8, operation, "fill")) {
                if (!invoke(fill)) setFrame(window, b);
            } else if (std.mem.eql(u8, operation, "zoom") or std.mem.eql(u8, operation, "unzoom")) {
                window.zoom();
            } else if (std.mem.eql(u8, operation, "minimize")) {
                window.minimize();
            } else if (std.mem.eql(u8, operation, "restore")) {
                objc.msg(void, window.nswindow, "deminiaturize:", .{@as(?objc.Object, null)});
            } else {
                const live = std.mem.eql(u8, operation, "live_resize_burst");
                const surface = window.surface.?;
                if (live) objc.msg(void, surface.nsview, "viewWillStartLiveResize", .{});
                for (0..16) |i| window.setSize(600 + @as(f64, @floatFromInt(i)) * 20, 420 + @as(f64, @floatFromInt(i)) * 6);
                if (live) objc.msg(void, surface.nsview, "viewDidEndLiveResize", .{});
            }
            t.call_us = (clock.now() - t.start_time) * 1e6;
            nano.App.after(700, t, finish);
        }
        fn finish(ptr: ?*anyopaque) callconv(.c) void {
            const t = from(ptr);
            t.check() catch |err| {
                t.failure = err;
                std.debug.print("WINDOW_CHECK_FAILED {s} repeat={d}: {s}\n", .{ operations[t.op], t.repeat, @errorName(err) });
            };
            const window = t.state.window.?;
            // Exercise a real background update while minimized. Restoring
            // must present fresh content even though its geometry is unchanged.
            if (std.mem.eql(u8, operations[t.op], "minimize")) {
                const marker = "\r\nWINDOW_RESTORE_UPDATE\r\n";
                vt.lt_vt_feed(t.state.active().?.vt, marker.ptr, marker.len);
                window.redraw();
            }
            t.op += 1;
            if (t.op == operations.len) {
                t.op = 0;
                t.repeat += 1;
                if (t.repeat == 3) {
                    std.debug.print("WINDOW_DONE history={d}\n", .{t.lines});
                    t.state.app.quit();
                    return;
                }
                setFrame(window, t.ordinary);
                nano.App.after(250, t, step);
            } else nano.App.after(80, t, step);
        }
        fn check(t: *@This()) !void {
            const window = t.state.window.?;
            const operation = operations[t.op];
            const notice = if (std.mem.eql(u8, operation, "minimize")) t.events.mini else if (std.mem.eql(u8, operation, "restore")) t.events.restore else 0;
            const callbacks = metrics.presentation.?.callbacks.load(.monotonic);
            const rendered_width = metrics.presentation.?.width.load(.monotonic);
            const rendered_height = metrics.presentation.?.height.load(.monotonic);
            metrics.dump(operation, t.repeat, t.lines, t.start_time, t.call_us, if (notice > 0) (notice - t.start_time) * 1e6 else -1);
            if (std.mem.eql(u8, operation, "minimize")) {
                if (t.events.mini == 0) return error.MinimizeNotificationMissing;
                return;
            }
            if (std.mem.eql(u8, operation, "restore") and t.events.restore == 0) return error.RestoreNotificationMissing;
            const size = window.contentSize();
            const rendered = window.surface.?.ctx.size;
            if (@abs(size[0] - rendered.w) > 0.5 or @abs(size[1] - rendered.h) > 0.5) return error.FinalGeometryNotRendered;
            const changed = @abs(size[0] - t.previous_size[0]) > 0.5 or @abs(size[1] - t.previous_size[1]) > 0.5;
            if ((changed or std.mem.eql(u8, operation, "restore")) and callbacks == 0) return error.NoDrawableCallback;
            if (callbacks > 0) {
                const scale = window.surface.?.scale;
                if (@abs(@as(f64, @floatFromInt(rendered_width)) - @round(size[0] * scale)) > 0.5 or
                    @abs(@as(f64, @floatFromInt(rendered_height)) - @round(size[1] * scale)) > 0.5) return error.WrongDrawableDimensions;
            }
            if (t.state.active().?.fatal) return error.TerminalResizeFailed;
        }
    };
    var task: Task = .{ .state = s, .lines = history };
    const cls = objc.defineClass(.{ .name = "LettyWindowTimingObserver", .methods = &.{
        .{ .name = "didMini:", .imp = &mini, .types = "v@:@" },
        .{ .name = "didRestore:", .imp = &restored, .types = "v@:@" },
    } });
    const observer = objc.msg(objc.Object, cls, "new", .{});
    objc.setZig(observer, &task.events);
    const center = objc.msg(objc.Object, objc.class("NSNotificationCenter"), "defaultCenter", .{});
    objc.msg(void, center, "addObserver:selector:name:object:", .{ observer, objc.sel("didMini:"), NSWindowDidMiniaturizeNotification, s.window.?.nswindow });
    objc.msg(void, center, "addObserver:selector:name:object:", .{ observer, objc.sel("didRestore:"), NSWindowDidDeminiaturizeNotification, s.window.?.nswindow });
    defer {
        objc.msg(void, center, "removeObserver:", .{observer});
        objc.setZig(observer, null);
        objc.release(observer);
        metrics.enabled = false;
    }
    nano.App.after(250, &task, Task.start);
    try s.app.run();
    if (task.failure) |err| return err;
}
