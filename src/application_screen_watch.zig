//! Event-driven native monitor/workarea observation. UI-thread only, stable
//! address until stop. Callback schedules work; it must not resize synchronously.
const std = @import("std");
const builtin = @import("builtin");
const nano = @import("nanoui");
const objc = if (builtin.os.tag == .macos) nano.objc else struct {};
extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;
pub const Callback = struct { context: *anyopaque, changed: *const fn (*anyopaque) void };
const Disconnect = *const fn (*anyopaque, c_ulong) callconv(.c) void;
const Filter = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) c_int;
const RemoveFilter = *const fn (*anyopaque, Filter, ?*anyopaque) callconv(.c) void;
const Gtk = struct {
    gdk: std.DynLib,
    xlib: std.DynLib,
    screen: *anyopaque,
    root: *anyopaque,
    disconnect: Disconnect,
    remove_filter: RemoveFilter,
    signals: [3]c_ulong,
    workarea: c_ulong,
};
const PropertyEvent = extern struct {
    kind: c_int,
    serial: c_ulong,
    send: c_int,
    display: ?*anyopaque,
    window: c_ulong,
    atom: c_ulong,
    time: c_ulong,
    state: c_int,
};
pub const Watch = struct {
    callback: ?Callback = null,
    object: ?*anyopaque = null,
    gtk: ?Gtk = null,
    pub fn start(self: *Watch, callback: Callback) !void {
        if (self.callback != null) return error.ScreenWatchAlreadyStarted;
        if (builtin.os.tag == .macos) {
            const cls = objc.defineClass(.{ .name = "LettyWorkareaObserver", .methods = &.{.{ .name = "screenChanged:", .imp = &macChanged, .types = "v@:@" }} });
            const object = objc.msg(objc.Object, objc.msg(objc.Object, cls, "alloc", .{}), "init", .{});
            objc.setZig(object, self);
            self.object = @ptrCast(object);
            self.callback = callback;
            const center = objc.msg(objc.Object, objc.class("NSNotificationCenter"), "defaultCenter", .{});
            for ([_][]const u8{ "NSApplicationDidChangeScreenParametersNotification", "NSWindowDidChangeScreenNotification" }) |name|
                objc.msg(void, center, "addObserver:selector:name:object:", .{ object, objc.sel("screenChanged:"), objc.nsString(name), @as(?objc.Object, null) });
        } else if (builtin.os.tag == .linux) {
            if (getenv("WAYLAND_DISPLAY") != null) return error.ScreenWatchWaylandUnsupported;
            if (getenv("XDG_SESSION_TYPE")) |kind| if (std.mem.eql(u8, std.mem.span(kind), "wayland")) return error.ScreenWatchWaylandUnsupported;
            try self.startGtk();
            self.callback = callback;
        } else return error.ScreenWatchUnsupported;
    }
    pub fn stop(self: *Watch) void {
        self.callback = null; // invalidate before unregister/release
        if (builtin.os.tag == .macos) if (self.object) |raw| {
            const object: objc.Object = @ptrCast(raw);
            const center = objc.msg(objc.Object, objc.class("NSNotificationCenter"), "defaultCenter", .{});
            objc.msg(void, center, "removeObserver:", .{object});
            objc.setZig(object, null);
            objc.release(object);
            self.object = null;
        };
        if (self.gtk) |*api| {
            api.remove_filter(api.root, filtered, self);
            for (api.signals) |id| if (id != 0) api.disconnect(api.screen, id);
            api.xlib.close();
            api.gdk.close();
            self.gtk = null;
        }
    }
    fn changed(self: *Watch) void {
        if (self.callback) |callback| callback.changed(callback.context);
    }
    fn macChanged(object: if (builtin.os.tag == .macos) objc.Object else *anyopaque, _: if (builtin.os.tag == .macos) objc.SEL else *anyopaque, _: ?*anyopaque) callconv(.c) void {
        if (builtin.os.tag == .macos) if (objc.getZig(Watch, object)) |self| self.changed();
    }
    fn gtkChanged(_: *anyopaque, data: ?*anyopaque) callconv(.c) void {
        const self: *Watch = @ptrCast(@alignCast(data.?));
        self.changed();
    }
    fn filtered(raw: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Watch = @ptrCast(@alignCast(data orelse return 0));
        const event: *align(1) const PropertyEvent = @ptrCast(raw orelse return 0);
        if (event.kind == 28) if (self.gtk) |api| if (event.atom == api.workarea) self.changed();
        return 0; // GDK_FILTER_CONTINUE; never consume another client's event
    }
    fn startGtk(self: *Watch) !void {
        var lib = std.DynLib.open("libgdk-3.so.0") catch return error.ScreenWatchUnavailable;
        errdefer lib.close();
        var xlib = std.DynLib.open("libX11.so.6") catch return error.ScreenWatchUnavailable;
        errdefer xlib.close();
        const Get = *const fn () callconv(.c) ?*anyopaque;
        const ScreenPtr = *const fn (*anyopaque) callconv(.c) ?*anyopaque;
        const Type = *const fn () callconv(.c) usize;
        const IsA = *const fn (*anyopaque, usize) callconv(.c) c_int;
        const Connect = *const fn (*anyopaque, [*:0]const u8, *const anyopaque, ?*anyopaque, ?*anyopaque, c_uint) callconv(.c) c_ulong;
        const AddFilter = *const fn (*anyopaque, Filter, ?*anyopaque) callconv(.c) void;
        const GetEvents = *const fn (*anyopaque) callconv(.c) c_int;
        const SetEvents = *const fn (*anyopaque, c_int) callconv(.c) void;
        const Atom = *const fn (*anyopaque, [*:0]const u8, c_int) callconv(.c) c_ulong;
        const screen_default = lib.lookup(Get, "gdk_screen_get_default") orelse return error.ScreenWatchUnavailable;
        const root_window = lib.lookup(ScreenPtr, "gdk_screen_get_root_window") orelse return error.ScreenWatchUnavailable;
        const screen_display = lib.lookup(ScreenPtr, "gdk_screen_get_display") orelse return error.ScreenWatchUnavailable;
        const xdisplay = lib.lookup(ScreenPtr, "gdk_x11_display_get_xdisplay") orelse return error.ScreenWatchX11Unsupported;
        const xtype = lib.lookup(Type, "gdk_x11_display_get_type") orelse return error.ScreenWatchX11Unsupported;
        const is_a = lib.lookup(IsA, "g_type_check_instance_is_a") orelse return error.ScreenWatchUnavailable;
        const connect = lib.lookup(Connect, "g_signal_connect_data") orelse return error.ScreenWatchUnavailable;
        const disconnect = lib.lookup(Disconnect, "g_signal_handler_disconnect") orelse return error.ScreenWatchUnavailable;
        const add_filter = lib.lookup(AddFilter, "gdk_window_add_filter") orelse return error.ScreenWatchUnavailable;
        const remove_filter = lib.lookup(RemoveFilter, "gdk_window_remove_filter") orelse return error.ScreenWatchUnavailable;
        const get_events = lib.lookup(GetEvents, "gdk_window_get_events") orelse return error.ScreenWatchUnavailable;
        const set_events = lib.lookup(SetEvents, "gdk_window_set_events") orelse return error.ScreenWatchUnavailable;
        const atom = xlib.lookup(Atom, "XInternAtom") orelse return error.ScreenWatchUnavailable;
        const screen = screen_default() orelse return error.NoScreen;
        const display = screen_display(screen) orelse return error.NoScreen;
        if (is_a(display, xtype()) == 0) return error.ScreenWatchX11Unsupported;
        const native = xdisplay(display) orelse return error.NoScreen;
        const root = root_window(screen) orelse return error.NoScreen;
        const workarea = atom(native, "_NET_WORKAREA", 0);
        if (workarea == 0) return error.ScreenWatchUnavailable;
        var signals: [3]c_ulong = @splat(0);
        errdefer for (signals) |id| if (id != 0) disconnect(screen, id);
        for ([_][*:0]const u8{ "monitors-changed", "size-changed", "window-manager-changed" }, 0..) |name, at| {
            signals[at] = connect(screen, name, @ptrCast(&gtkChanged), self, null, 0);
            if (signals[at] == 0) return error.ScreenWatchUnavailable;
        }
        // Select only this process's X11 client mask; no root property is
        // written. Preserve existing subscriptions. The mask lives until this
        // shared GTK connection closes; stop removes our filter and signals.
        set_events(root, get_events(root) | (1 << 16)); // GDK_PROPERTY_CHANGE_MASK
        self.gtk = .{ .gdk = lib, .xlib = xlib, .screen = screen, .root = root, .disconnect = disconnect, .remove_filter = remove_filter, .signals = signals, .workarea = workarea };
        add_filter(root, filtered, self);
    }
};
