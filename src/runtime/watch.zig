//! Toolkit-loop fd readiness, including writable PTYs. Cancellation owns context lifetime.
const std = @import("std");
const mac = @import("builtin").os.tag == .macos;
pub const Handler = *const fn (?*anyopaque) callconv(.c) void;
const dispatch_source_t = *opaque {};
const dispatch_queue_t = *opaque {};
extern "c" var _dispatch_source_type_read: opaque {};
extern "c" var _dispatch_source_type_write: opaque {};
extern "c" var _dispatch_source_type_timer: opaque {};
extern "c" var _dispatch_main_q: opaque {};
extern "c" fn dispatch_source_create(*anyopaque, usize, usize, dispatch_queue_t) ?dispatch_source_t;
extern "c" fn dispatch_set_context(*anyopaque, ?*anyopaque) void;
extern "c" fn dispatch_source_set_event_handler_f(dispatch_source_t, Handler) void;
extern "c" fn dispatch_source_set_cancel_handler_f(dispatch_source_t, Handler) void;
extern "c" fn dispatch_resume(*anyopaque) void;
extern "c" fn dispatch_source_cancel(dispatch_source_t) void;
extern "c" fn dispatch_release(*anyopaque) void;
extern "c" fn dispatch_time(u64, i64) u64;
extern "c" fn dispatch_source_set_timer(dispatch_source_t, u64, u64, u64) void;
const Glib = struct {
    lib: std.DynLib,
    add: *const fn (c_int, c_int, c_uint, *const fn (c_int, c_uint, ?*anyopaque) callconv(.c) c_int, ?*anyopaque, Handler) callconv(.c) c_uint,
    remove: *const fn (c_uint) callconv(.c) c_int,
    timeout: *const fn (c_int, c_uint, *const fn (?*anyopaque) callconv(.c) c_int, ?*anyopaque, Handler) callconv(.c) c_uint,
};
var glib: ?Glib = null;
fn loadGlib() !void {
    if (glib != null) return;
    var lib = try std.DynLib.open("libglib-2.0.so.0");
    errdefer lib.close();
    glib = .{ .lib = lib, .add = lib.lookup(@FieldType(Glib, "add"), "g_unix_fd_add_full") orelse return error.GlibSymbol, .remove = lib.lookup(@FieldType(Glib, "remove"), "g_source_remove") orelse return error.GlibSymbol, .timeout = lib.lookup(@FieldType(Glib, "timeout"), "g_timeout_add_full") orelse return error.GlibSymbol };
}
pub const Watch = struct {
    source: if (mac) dispatch_source_t else c_uint,
    ctx: ?*anyopaque,
    handler: Handler,
    alive: bool = true,
    pub fn create(fd: c_int, writing: bool, ctx: ?*anyopaque, handler: Handler) !*Watch {
        const self = try std.heap.c_allocator.create(Watch);
        errdefer std.heap.c_allocator.destroy(self);
        if (mac) {
            const source = dispatch_source_create(if (writing) @ptrCast(&_dispatch_source_type_write) else @ptrCast(&_dispatch_source_type_read), @intCast(fd), 0, @ptrCast(&_dispatch_main_q)) orelse return error.FdWatch;
            self.* = .{ .source = source, .ctx = ctx, .handler = handler };
            dispatch_set_context(source, self);
            dispatch_source_set_event_handler_f(source, ready);
            dispatch_source_set_cancel_handler_f(source, released);
            dispatch_resume(source);
        } else {
            try loadGlib();
            self.* = .{ .source = 0, .ctx = ctx, .handler = handler };
            self.source = glib.?.add(0, fd, (if (writing) @as(c_uint, 4) else 1) | 8 | 16, linuxReady, self, released);
            if (self.source == 0) return error.FdWatch;
        }
        return self;
    }
    /// A one-shot owned deadline. The handler must cancel or replace its watch.
    pub fn timer(ms: u32, ctx: ?*anyopaque, handler: Handler) !*Watch {
        const self = try std.heap.c_allocator.create(Watch);
        errdefer std.heap.c_allocator.destroy(self);
        if (mac) {
            const source = dispatch_source_create(@ptrCast(&_dispatch_source_type_timer), 0, 0, @ptrCast(&_dispatch_main_q)) orelse return error.Timer;
            self.* = .{ .source = source, .ctx = ctx, .handler = handler };
            dispatch_set_context(source, self);
            dispatch_source_set_event_handler_f(source, ready);
            dispatch_source_set_cancel_handler_f(source, released);
            dispatch_source_set_timer(source, dispatch_time(0, @as(i64, ms) * std.time.ns_per_ms), std.math.maxInt(u64), 10 * std.time.ns_per_ms);
            dispatch_resume(source);
        } else {
            try loadGlib();
            self.* = .{ .source = 0, .ctx = ctx, .handler = handler };
            self.source = glib.?.timeout(0, @max(ms, 1), timed, self, released);
            if (self.source == 0) return error.Timer;
        }
        return self;
    }
    fn timed(raw: ?*anyopaque) callconv(.c) c_int {
        ready(raw);
        return 0;
    }
    pub fn cancel(self: *Watch) void {
        if (!self.alive) return;
        self.alive = false;
        if (mac) {
            dispatch_source_cancel(self.source);
            dispatch_release(self.source);
        } else _ = glib.?.remove(self.source);
    }
    fn ready(raw: ?*anyopaque) callconv(.c) void {
        const self: *Watch = @ptrCast(@alignCast(raw.?));
        if (self.alive) self.handler(self.ctx);
    }
    fn linuxReady(_: c_int, _: c_uint, raw: ?*anyopaque) callconv(.c) c_int {
        ready(raw);
        return 1;
    }
    fn released(raw: ?*anyopaque) callconv(.c) void {
        const self: *Watch = @ptrCast(@alignCast(raw.?));
        std.heap.c_allocator.destroy(self);
    }
};
