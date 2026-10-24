//! Route OS Quit through product confirmation while preserving nanoui lifecycle.
const std = @import("std");
const nano = @import("nanoui");
const mac = @import("builtin").os.tag == .macos;
pub const Guard = struct {
    app: *nano.App,
    ctx: *anyopaque,
    allow: *const fn (*anyopaque) bool,
    pub fn install(app: *nano.App, ctx: *anyopaque, allow: *const fn (*anyopaque) bool) !?*Guard {
        if (!mac) return null;
        const self = try std.heap.c_allocator.create(Guard);
        errdefer std.heap.c_allocator.destroy(self);
        self.* = .{ .app = app, .ctx = ctx, .allow = allow };
        try guards.append(std.heap.c_allocator, self);
        const objc = nano.objc;
        const class = objc.defineClass(.{ .name = "LettyAppDelegate", .superclass = "NanoUIAppDelegate", .methods = &.{.{ .name = "applicationShouldTerminate:", .imp = &terminate, .types = "Q@:@" }} });
        const delegate = objc.msg(objc.Object, class, "new", .{});
        objc.setZig(delegate, app);
        const old = app.delegate;
        app.delegate = delegate;
        objc.msg(void, app.nsapp, "setDelegate:", .{delegate});
        objc.release(old);
        return self;
    }
    pub fn deinit(self: *Guard) void {
        for (guards.items, 0..) |guard, i| if (guard == self) {
            _ = guards.orderedRemove(i);
            break;
        };
        if (guards.items.len == 0) {
            guards.deinit(std.heap.c_allocator);
            guards = .empty;
        }
        std.heap.c_allocator.destroy(self);
    }
};
var guards: std.ArrayList(*Guard) = .empty;
fn terminate(delegate: if (mac) nano.objc.Object else *anyopaque, _: if (mac) nano.objc.SEL else *anyopaque, _: if (mac) nano.objc.Object else *anyopaque) callconv(.c) usize {
    if (!mac) return 0;
    const app = nano.objc.getZig(nano.App, delegate) orelse return 0;
    for (guards.items) |guard| if (guard.app == app) {
        if (guard.allow(guard.ctx)) app.quit();
        return 0;
    };
    return 0;
}
