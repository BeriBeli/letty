//! Main-event-loop one-shot; cancellation prevents any later callback.
const std = @import("std");
const builtin = @import("builtin");
const nano = @import("nanoui");
const c = @import("platform_ffi.zig");
extern "c" var _dispatch_source_type_timer: opaque {};
extern "c" fn dispatch_source_create(*anyopaque, usize, usize, *anyopaque) ?*anyopaque;
extern "c" fn dispatch_set_context(*anyopaque, ?*anyopaque) void;
extern "c" fn dispatch_source_set_event_handler_f(*anyopaque, *const fn (?*anyopaque) callconv(.c) void) void;
extern "c" fn dispatch_source_set_timer(*anyopaque, u64, u64, u64) void;
extern "c" fn dispatch_time(u64, i64) u64;
extern "c" fn dispatch_resume(*anyopaque) void;
extern "c" fn dispatch_source_cancel(*anyopaque) void;
extern "c" fn dispatch_release(*anyopaque) void;
pub const Handle = struct {
    source: ?*anyopaque = null,
    id: c_uint = 0,
    pub fn cancel(self: Handle) void {
        if (builtin.os.tag == .macos) {
            if (self.source) |source| {
                // Both cancellation and callbacks run on the main queue. The
                // SDK contract prevents further event-handler invocations;
                // no descriptor is owned by this timer.
                dispatch_source_cancel(source);
                dispatch_release(source);
            }
        } else if (self.id != 0) c.lt_unwatch(self.id);
    }
    /// The GLib callback removes itself; libdispatch needs explicit cancel.
    pub fn fired(self: Handle) void {
        if (builtin.os.tag == .macos) self.cancel();
    }
};
pub fn start(ms: u64, context: ?*anyopaque, comptime callback: *const fn (?*anyopaque) callconv(.c) void) !Handle {
    if (builtin.os.tag == .macos) {
        const source = dispatch_source_create(@ptrCast(&_dispatch_source_type_timer), 0, 0, @ptrCast(nano.objc.mainQueue())) orelse return error.TimerUnavailable;
        dispatch_set_context(source, context);
        dispatch_source_set_event_handler_f(source, callback);
        dispatch_source_set_timer(source, dispatch_time(0, @intCast(@max(1, ms) * std.time.ns_per_ms)), std.math.maxInt(u64), 0);
        dispatch_resume(source);
        return .{ .source = source };
    } else {
        const id = c.lt_timeout(@intCast(@max(1, ms)), struct {
            fn call(data: ?*anyopaque) callconv(.c) c_int {
                callback(data);
                return 0;
            }
        }.call, context);
        if (id == 0) return error.TimerUnavailable;
        return .{ .id = id };
    }
}
