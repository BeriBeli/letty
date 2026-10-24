//! Product-owned native close guard; independent of nanoui option revisions.
const std = @import("std");
const nano = @import("nanoui");
const mac = @import("builtin").os.tag == .macos;
pub const Guard = struct {
    a: std.mem.Allocator,
    native: *nano.Window,
    ctx: *anyopaque,
    allow: *const fn (*anyopaque) bool,
    signal: c_ulong = 0,
    focus_signal: c_ulong = 0,
    focused: *const fn (*anyopaque, bool) void,
    pub fn install(a: std.mem.Allocator, native: *nano.Window, ctx: *anyopaque, allow: *const fn (*anyopaque) bool, focused: *const fn (*anyopaque, bool) void) !*Guard {
        const self = try a.create(Guard);
        errdefer a.destroy(self);
        self.* = .{ .a = a, .native = native, .ctx = ctx, .allow = allow, .focused = focused };
        if (mac) {
            try guards.append(std.heap.c_allocator, self);
            errdefer _ = guards.pop();
            const objc = nano.objc;
            const class = objc.defineClass(.{ .name = "LettyWindowCloseGuard", .superclass = "NanoUIWindowDelegate", .methods = &.{ .{ .name = "windowShouldClose:", .imp = &shouldClose, .types = "B@:@" }, .{ .name = "windowDidBecomeKey:", .imp = &becameKey, .types = "v@:@" }, .{ .name = "windowDidResignKey:", .imp = &resignedKey, .types = "v@:@" } } });
            const delegate = objc.msg(objc.Object, class, "new", .{});
            objc.setZig(delegate, native);
            const old = native.delegate;
            native.delegate = delegate;
            objc.msg(void, native.nswindow, "setDelegate:", .{delegate});
            objc.release(old);
        } else {
            const widget = native.gtkwindow orelse return self;
            try load();
            self.signal = api.?.connect(widget, "delete-event", @ptrCast(&deleteEvent), self, null, 0);
            if (self.signal == 0) return error.CloseGuard;
            self.focus_signal = api.?.connect(widget, "notify::is-active", @ptrCast(&focusChanged), self, null, 0);
        }
        return self;
    }
    pub fn deinit(self: *Guard) void {
        if (mac) {
            for (guards.items, 0..) |guard, i| if (guard == self) {
                _ = guards.orderedRemove(i);
                break;
            };
            if (guards.items.len == 0) {
                guards.deinit(std.heap.c_allocator);
                guards = .empty;
            }
        } else if (self.signal != 0) {
            if (self.native.gtkwindow) |widget| {
                api.?.disconnect(widget, self.signal);
                if (self.focus_signal != 0) api.?.disconnect(widget, self.focus_signal);
            }
        }
        self.a.destroy(self);
    }
};
var guards: std.ArrayList(*Guard) = .empty;
fn shouldClose(delegate: if (mac) nano.objc.Object else *anyopaque, _: if (mac) nano.objc.SEL else *anyopaque, _: if (mac) nano.objc.Object else *anyopaque) callconv(.c) bool {
    if (!mac) return true;
    const native = nano.objc.getZig(nano.Window, delegate) orelse return true;
    for (guards.items) |guard| if (guard.native == native) return guard.allow(guard.ctx);
    return true;
}
fn becameKey(delegate: if (mac) nano.objc.Object else *anyopaque, _: if (mac) nano.objc.SEL else *anyopaque, _: if (mac) nano.objc.Object else *anyopaque) callconv(.c) void {
    if (!mac) return;
    const native = nano.objc.getZig(nano.Window, delegate) orelse return;
    for (guards.items) |guard| if (guard.native == native) {
        guard.focused(guard.ctx, true);
        return;
    };
}
fn resignedKey(delegate: if (mac) nano.objc.Object else *anyopaque, _: if (mac) nano.objc.SEL else *anyopaque, notification: if (mac) nano.objc.Object else *anyopaque) callconv(.c) void {
    if (!mac) return;
    nano.objc.msgSuper(void, delegate, nano.objc.class("NanoUIWindowDelegate"), "windowDidResignKey:", .{notification});
    const native = nano.objc.getZig(nano.Window, delegate) orelse return;
    for (guards.items) |guard| if (guard.native == native) {
        guard.focused(guard.ctx, false);
        return;
    };
}
fn focusChanged(_: *anyopaque, _: *anyopaque, raw: ?*anyopaque) callconv(.c) void {
    const guard: *Guard = @ptrCast(@alignCast(raw.?));
    guard.focused(guard.ctx, guard.native.isFocused());
}
fn deleteEvent(_: ?*anyopaque, _: ?*anyopaque, raw: ?*anyopaque) callconv(.c) c_int {
    const guard: *Guard = @ptrCast(@alignCast(raw.?));
    return if (guard.allow(guard.ctx)) 0 else 1;
}
const Api = struct { lib: std.DynLib, connect: *const fn (*anyopaque, [*:0]const u8, *const anyopaque, ?*anyopaque, ?*anyopaque, c_uint) callconv(.c) c_ulong, disconnect: *const fn (*anyopaque, c_ulong) callconv(.c) void };
var api: ?Api = null;
fn load() !void {
    if (api != null) return;
    var lib = try std.DynLib.open("libgobject-2.0.so.0");
    errdefer lib.close();
    api = .{ .lib = lib, .connect = lib.lookup(@FieldType(Api, "connect"), "g_signal_connect_data") orelse return error.CloseGuardSymbol, .disconnect = lib.lookup(@FieldType(Api, "disconnect"), "g_signal_handler_disconnect") orelse return error.CloseGuardSymbol };
}
