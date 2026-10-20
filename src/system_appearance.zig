//! Event-driven system appearance observation; no configuration reads or timer.
const std = @import("std");
const builtin = @import("builtin");
const nano = @import("nanoui");
const objc = if (builtin.os.tag == .macos) nano.objc else struct {};
pub const Callback = struct { context: *anyopaque, changed: *const fn (*anyopaque, bool) void };
const Get = *const fn (*anyopaque, [*:0]const u8, ...) callconv(.c) void;
const Disconnect = *const fn (*anyopaque, c_ulong) callconv(.c) void;
const Free = *const fn (?*anyopaque) callconv(.c) void;
const Gtk = struct {
    library: *anyopaque,
    settings: *anyopaque,
    get: Get,
    disconnect: Disconnect,
    free: Free,
    ids: [2]c_ulong,
};
pub const Watch = struct {
    callback: ?Callback = null,
    object: ?*anyopaque = null,
    gtk: ?Gtk = null,
    last_dark: ?bool = null,
    pub fn start(self: *Watch, callback: Callback) bool {
        self.callback = callback;
        if (builtin.os.tag == .macos) {
            const class = objc.defineClass(.{ .name = "LettyAppearanceObserver", .methods = &.{.{ .name = "appearanceChanged:", .imp = &macChanged, .types = "v@:@" }} });
            const object = objc.msg(objc.Object, objc.msg(objc.Object, class, "alloc", .{}), "init", .{});
            objc.setZig(object, self);
            self.object = @ptrCast(object);
            const center = objc.msg(objc.Object, objc.class("NSDistributedNotificationCenter"), "defaultCenter", .{});
            objc.msg(void, center, "addObserver:selector:name:object:", .{ object, objc.sel("appearanceChanged:"), objc.nsString("AppleInterfaceThemeChangedNotification"), @as(?objc.Object, null) });
        } else if (builtin.os.tag == .linux) {
            if (!self.startGtk()) return false;
        } else return false;
        self.last_dark = self.current();
        return true;
    }
    pub fn current(self: *const Watch) bool {
        if (builtin.os.tag == .linux) if (self.gtk) |api| {
            var prefer: c_int = 0;
            api.get(api.settings, "gtk-application-prefer-dark-theme", &prefer, @as(?*anyopaque, null));
            if (prefer != 0) return true;
            var name: ?[*:0]u8 = null;
            api.get(api.settings, "gtk-theme-name", &name, @as(?*anyopaque, null));
            defer if (name) |p| api.free(p);
            if (name) |p| {
                const text = std.mem.span(p);
                if (text.len >= 4) for (0..text.len - 3) |i| if (std.ascii.eqlIgnoreCase(text[i..][0..4], "dark")) return true;
            }
            return false;
        };
        return nano.isDark();
    }
    pub fn stop(self: *Watch) void {
        self.callback = null;
        if (builtin.os.tag == .macos) if (self.object) |raw| {
            const object: objc.Object = @ptrCast(raw);
            const center = objc.msg(objc.Object, objc.class("NSDistributedNotificationCenter"), "defaultCenter", .{});
            objc.msg(void, center, "removeObserver:", .{object});
            objc.setZig(object, null);
            objc.release(object);
            self.object = null;
        };
        if (self.gtk) |api| {
            for (api.ids) |id| if (id != 0) api.disconnect(api.settings, id);
            _ = std.c.dlclose(api.library);
            self.gtk = null;
        }
    }
    fn emit(self: *Watch) void {
        const value = self.current();
        if (self.last_dark != null and self.last_dark.? == value) return;
        self.last_dark = value;
        if (self.callback) |callback| callback.changed(callback.context, value);
    }
    fn macChanged(object: if (builtin.os.tag == .macos) objc.Object else *anyopaque, _: if (builtin.os.tag == .macos) objc.SEL else *anyopaque, _: ?*anyopaque) callconv(.c) void {
        if (builtin.os.tag == .macos) if (objc.getZig(Watch, object)) |self| self.emit();
    }
    fn gtkChanged(_: *anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
        const self: *Watch = @ptrCast(@alignCast(data.?));
        self.emit();
    }
    fn startGtk(self: *Watch) bool {
        // RTLD_LOCAL is the default when GLOBAL is false on Linux.
        const library = std.c.dlopen("libgtk-3.so.0", .{ .NOW = true }) orelse return false;
        var adopted = false;
        defer if (!adopted) {
            _ = std.c.dlclose(library);
        };
        const get_default: *const fn () callconv(.c) ?*anyopaque = @ptrCast(std.c.dlsym(library, "gtk_settings_get_default") orelse return false);
        const settings = get_default() orelse return false;
        const get: Get = @ptrCast(std.c.dlsym(library, "g_object_get") orelse return false);
        const disconnect: Disconnect = @ptrCast(std.c.dlsym(library, "g_signal_handler_disconnect") orelse return false);
        const free: Free = @ptrCast(std.c.dlsym(library, "g_free") orelse return false);
        const connect: *const fn (*anyopaque, [*:0]const u8, *const anyopaque, ?*anyopaque, ?*anyopaque, c_uint) callconv(.c) c_ulong = @ptrCast(std.c.dlsym(library, "g_signal_connect_data") orelse return false);
        const first = connect(settings, "notify::gtk-application-prefer-dark-theme", @ptrCast(&gtkChanged), self, null, 0);
        if (first == 0) return false;
        const second = connect(settings, "notify::gtk-theme-name", @ptrCast(&gtkChanged), self, null, 0);
        if (second == 0) {
            disconnect(settings, first);
            return false;
        }
        self.gtk = .{ .library = library, .settings = settings, .get = get, .disconnect = disconnect, .free = free, .ids = .{ first, second } };
        adopted = true;
        return true;
    }
};
