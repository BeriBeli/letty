//! Native notifications and activation. No callback owns a terminal pointer.
const std = @import("std");
const nano = @import("nanoui");
const targets = @import("notification_targets.zig");
const mac = @import("builtin").os.tag == .macos;
pub const Target = targets.Target;
const G = if (mac) nano.objc.Object else *anyopaque;
var current: ?*Service = null;
var next_epoch: u64 = 0;
pub const Service = struct {
    registry: targets.Registry = .{},
    epoch: u64 = 0,
    ctx: *anyopaque,
    activate: *const fn (*anyopaque, Target) void,
    delegate: ?G = null,
    connection: ?G = null,
    subscription: c_uint = 0,
    badge_count: usize = 0,
    pub fn install(self: *Service) void {
        next_epoch +%= 1;
        self.epoch = next_epoch;
        current = self;
    }
    pub fn deinit(self: *Service) void {
        if (current == self) current = null;
        if (mac) {
            if (self.delegate) |delegate| {
                const objc = nano.objc;
                const center = objc.msg(G, objc.class("NSUserNotificationCenter"), "defaultUserNotificationCenter", .{});
                objc.msg(void, center, "setDelegate:", .{@as(?G, null)});
                objc.release(delegate);
            }
            self.badge(0, false);
        } else if (self.connection) |connection| {
            if (self.subscription != 0) gio.?.unsubscribe(connection, self.subscription);
            gio.?.unref(connection);
        }
    }
    pub fn click(self: *Service, token: u64) void {
        const target = self.registry.take(token) orelse return;
        self.activate(self.ctx, target);
    }
    pub fn show(self: *Service, target: Target, program: []const u8, message: []const u8, sound: bool) !void {
        const token = self.registry.add(target) orelse return error.NotificationBusy;
        errdefer _ = self.registry.take(token);
        if (mac) {
            const objc = nano.objc;
            const pool = objc.Pool.push();
            defer pool.pop();
            const center = objc.msg(G, objc.class("NSUserNotificationCenter"), "defaultUserNotificationCenter", .{});
            if (self.delegate == null) {
                const cls = objc.defineClass(.{ .name = "LettyNotificationDelegate", .methods = &.{.{ .name = "userNotificationCenter:didActivateNotification:", .imp = &clicked, .types = "v@:@@" }} });
                self.delegate = objc.msg(G, cls, "new", .{});
                objc.msg(void, center, "setDelegate:", .{self.delegate.?});
            }
            const notification = objc.new("NSUserNotification");
            defer objc.release(notification);
            var buffer: [64]u8 = undefined;
            const id = try std.fmt.bufPrint(&buffer, "letty-{d}", .{token});
            objc.msg(void, notification, "setIdentifier:", .{objc.nsString(id)});
            objc.msg(void, notification, "setTitle:", .{objc.nsString(if (program.len > 0) program else "Letty")});
            objc.msg(void, notification, "setInformativeText:", .{objc.nsString(message)});
            if (sound) objc.msg(void, notification, "setSoundName:", .{objc.nsString("NSUserNotificationDefaultSoundName")});
            objc.msg(void, center, "deliverNotification:", .{notification});
        } else {
            try load();
            const api = &gio.?;
            if (self.connection == null) {
                self.connection = api.bus(2, null, null) orelse return error.NoSessionBus;
                self.subscription = api.subscribe(self.connection.?, "org.freedesktop.Notifications", "org.freedesktop.Notifications", "ActionInvoked", "/org/freedesktop/Notifications", null, 0, invoked, null, null);
            }
            const a = std.heap.c_allocator;
            const title = try a.dupeSentinel(u8, if (program.len > 0) program else "Letty", 0);
            defer a.free(title);
            const body = try a.dupeSentinel(u8, message, 0);
            defer a.free(body);
            const pending = try a.create(Pending);
            pending.* = .{ .epoch = self.epoch, .token = token };
            const actions = [_][*:0]const u8{ "default", "Open terminal" };
            const hint = api.variant("{sv}", @as([*:0]const u8, "suppress-sound"), api.boolean(@intFromBool(!sound)));
            const hints = [_]G{hint};
            const parameters = api.variant("(susss@as@a{sv}i)", @as([*:0]const u8, "Letty"), @as(u32, 0), @as([*:0]const u8, "utilities-terminal"), title.ptr, body.ptr, api.strings(&actions, 2), api.array("{sv}", &hints, 1), @as(c_int, -1));
            self.registry.find(token).?.pending = true;
            api.call(self.connection.?, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "Notify", parameters, null, 0, 1500, null, finished, pending);
        }
    }
    pub fn badge(self: *Service, count: usize, enabled: bool) void {
        const wanted = if (enabled) count else 0;
        if (wanted == self.badge_count) return;
        self.badge_count = wanted;
        if (mac) {
            const objc = nano.objc;
            const pool = objc.Pool.push();
            defer pool.pop();
            const app = objc.msg(G, objc.class("NSApplication"), "sharedApplication", .{});
            const tile = objc.msg(G, app, "dockTile", .{});
            var bytes: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&bytes, "{d}", .{wanted}) catch return;
            objc.msg(void, tile, "setBadgeLabel:", .{if (wanted > 0) @as(?G, objc.nsString(text)) else null});
        }
    }
    pub fn bounce(_: *Service) void {
        if (mac) {
            const objc = nano.objc;
            const app = objc.msg(G, objc.class("NSApplication"), "sharedApplication", .{});
            _ = objc.msg(objc.NSInteger, app, "requestUserAttention:", .{@as(objc.NSUInteger, 10)});
        }
    }
};
fn clicked(_: G, _: nano.objc.SEL, center: G, notification: G) callconv(.c) void {
    const objc = nano.objc;
    const value = objc.msg(?G, notification, "identifier", .{}) orelse return;
    const id = objc.fromNSString(value);
    if (!std.mem.startsWith(u8, id, "letty-")) return;
    const token = std.fmt.parseInt(u64, id[6..], 10) catch return;
    if (current) |self| self.click(token);
    objc.msg(void, center, "removeDeliveredNotification:", .{notification});
}
const Pending = struct { epoch: u64, token: u64 };
fn finished(source: G, result: G, raw: ?G) callconv(.c) void {
    const pending: *Pending = @ptrCast(@alignCast(raw.?));
    defer std.heap.c_allocator.destroy(pending);
    const response = gio.?.finish(source, result, null);
    defer if (response) |value| gio.?.variant_unref(value);
    const self = current orelse return;
    if (self.epoch != pending.epoch) return;
    const entry = self.registry.find(pending.token) orelse return;
    entry.pending = false;
    if (response) |value| {
        var id: u32 = 0;
        gio.?.get(value, "(u)", &id);
        entry.server = id;
    } else _ = self.registry.take(pending.token);
}
fn invoked(_: G, _: [*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, parameters: G, _: ?G) callconv(.c) void {
    var id: u32 = 0;
    var action: ?[*:0]const u8 = null;
    gio.?.get(parameters, "(u&s)", &id, &action);
    if (action == null or !std.mem.eql(u8, std.mem.span(action.?), "default")) return;
    if (current) |self| for (self.registry.entries) |entry| if (entry.server == id and id != 0) {
        self.click(entry.token);
        break;
    };
}
const Api = struct {
    lib: std.DynLib,
    bus: *const fn (c_int, ?G, ?G) callconv(.c) ?G,
    unref: *const fn (G) callconv(.c) void,
    variant: *const fn ([*:0]const u8, ...) callconv(.c) G,
    get: *const fn (G, [*:0]const u8, ...) callconv(.c) void,
    variant_unref: *const fn (G) callconv(.c) void,
    boolean: *const fn (c_int) callconv(.c) G,
    strings: *const fn (?[*]const [*:0]const u8, isize) callconv(.c) G,
    array: *const fn ([*:0]const u8, ?[*]const G, usize) callconv(.c) G,
    call: *const fn (G, [*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, G, ?G, c_uint, c_int, ?G, *const fn (G, G, ?G) callconv(.c) void, ?G) callconv(.c) void,
    finish: *const fn (G, G, ?G) callconv(.c) ?G,
    subscribe: *const fn (G, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, c_uint, *const fn (G, [*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, G, ?G) callconv(.c) void, ?G, ?G) callconv(.c) c_uint,
    unsubscribe: *const fn (G, c_uint) callconv(.c) void,
};
var gio: ?Api = null;
fn load() !void {
    if (gio != null) return;
    var lib = try std.DynLib.open("libgio-2.0.so.0");
    errdefer lib.close();
    var api: Api = undefined;
    api.lib = lib;
    inline for (.{ .{ "bus", "g_bus_get_sync" }, .{ "unref", "g_object_unref" }, .{ "variant", "g_variant_new" }, .{ "get", "g_variant_get" }, .{ "variant_unref", "g_variant_unref" }, .{ "boolean", "g_variant_new_boolean" }, .{ "strings", "g_variant_new_strv" }, .{ "array", "g_variant_new_array" }, .{ "call", "g_dbus_connection_call" }, .{ "finish", "g_dbus_connection_call_finish" }, .{ "subscribe", "g_dbus_connection_signal_subscribe" }, .{ "unsubscribe", "g_dbus_connection_signal_unsubscribe" } }) |entry| @field(api, entry[0]) = lib.lookup(@FieldType(Api, entry[0]), entry[1]) orelse return error.NotificationSymbol;
    gio = api;
}
