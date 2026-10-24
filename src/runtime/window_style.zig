//! Product-owned AppKit material adapter. Linux keeps an opaque X11 surface.
const std = @import("std");
const nano = @import("nanoui");
const mac = @import("builtin").os.tag == .macos;
const Object = if (mac) nano.objc.Object else *anyopaque;
pub const State = struct {
    root: ?Object = null,
    effect: ?Object = null,
    drop_ctx: ?*anyopaque = null,
    drop_handler: ?@import("file_drop.zig").Handler = null,
    pub fn apply(self: *State, window: *nano.Window, enabled: bool) void {
        if (!mac) return;
        const objc = nano.objc;
        const surface = window.surface orelse return;
        if (self.root == null) {
            const bounds = objc.msg(objc.CGRect, surface.nsview, "bounds", .{});
            const class = objc.defineClass(.{ .name = "LettyTerminalContent", .superclass = "NSView", .methods = &.{ .{ .name = "draggingEntered:", .imp = &entered, .types = "Q@:@" }, .{ .name = "performDragOperation:", .imp = &dropped, .types = "B@:@" } } });
            const root = objc.msg(objc.Object, objc.msg(objc.Object, class, "alloc", .{}), "initWithFrame:", .{bounds});
            objc.setZig(root, self);
            const effect = objc.msg(objc.Object, objc.alloc("NSVisualEffectView"), "initWithFrame:", .{bounds});
            objc.msg(void, effect, "setAutoresizingMask:", .{@as(objc.NSUInteger, 18)});
            objc.msg(void, effect, "setMaterial:", .{@as(objc.NSInteger, 7)});
            objc.msg(void, effect, "setBlendingMode:", .{@as(objc.NSInteger, 0)});
            objc.msg(void, effect, "setState:", .{@as(objc.NSInteger, 0)});
            objc.msg(void, root, "addSubview:", .{effect});
            // Surface retains its native view independently of the content view.
            objc.msg(void, window.nswindow, "setContentView:", .{root});
            objc.msg(void, surface.nsview, "setFrame:", .{bounds});
            objc.msg(void, surface.nsview, "setAutoresizingMask:", .{@as(objc.NSUInteger, 18)});
            objc.msg(void, root, "addSubview:", .{surface.nsview});
            self.root = root;
            self.effect = effect;
        }
        objc.msg(void, self.effect.?, "setHidden:", .{if (enabled) objc.NO else objc.YES});
        objc.msg(void, window.nswindow, "setOpaque:", .{if (enabled) objc.NO else objc.YES});
        objc.msg(void, window.nswindow, "setBackgroundColor:", .{objc.msg(objc.Object, objc.class("NSColor"), if (enabled) "clearColor" else "windowBackgroundColor", .{})});
        objc.msg(void, surface.renderer.layer, "setOpaque:", .{if (enabled) objc.NO else objc.YES});
    }
    pub fn enableDrop(self: *State) void {
        if (!mac or self.root == null) return;
        const objc = nano.objc;
        const types = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{objc.nsString("public.file-url")});
        objc.msg(void, self.root.?, "registerForDraggedTypes:", .{types});
    }
    pub fn deinit(self: *State) void {
        if (!mac) return;
        if (self.effect) |effect| nano.objc.release(effect);
        if (self.root) |root| {
            nano.objc.setZig(root, null);
            nano.objc.msg(void, root, "unregisterDraggedTypes", .{});
            nano.objc.release(root);
        }
        self.* = .{};
    }
};

fn entered(root: Object, _: if (mac) nano.objc.SEL else *anyopaque, _: Object) callconv(.c) usize {
    if (!mac) return 0;
    const self = nano.objc.getZig(State, root) orelse return 0;
    return if (self.drop_handler != null) 1 else 0;
}
fn dropped(root: Object, _: if (mac) nano.objc.SEL else *anyopaque, sender: Object) callconv(.c) bool {
    if (!mac) return false;
    const objc = nano.objc;
    const self = objc.getZig(State, root) orelse return false;
    const callback = self.drop_handler orelse return false;
    const pool = objc.Pool.push();
    defer pool.pop();
    const board = objc.msg(Object, sender, "draggingPasteboard", .{});
    const classes = objc.msg(Object, objc.class("NSArray"), "arrayWithObject:", .{objc.class("NSURL")});
    const urls = objc.msg(?Object, board, "readObjectsForClasses:options:", .{ classes, @as(?Object, null) }) orelse return false;
    const count = objc.msg(usize, urls, "count", .{});
    if (count == 0 or count > 1024) return false;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(std.heap.c_allocator);
    var total: usize = 0;
    for (0..count) |i| {
        const url = objc.msg(Object, urls, "objectAtIndex:", .{i});
        if (!objc.msg(bool, url, "isFileURL", .{})) continue;
        const path = objc.fromNSString(objc.msg(?Object, url, "path", .{}));
        total += path.len;
        if (total > 1024 * 1024) return false;
        files.append(std.heap.c_allocator, path) catch return false;
    }
    const point = objc.msg(objc.CGPoint, sender, "draggingLocation", .{});
    const at = objc.msg(objc.CGPoint, root, "convertPoint:fromView:", .{ point, @as(?Object, null) });
    const bounds = objc.msg(objc.CGRect, root, "bounds", .{});
    return callback(self.drop_ctx.?, files.items, .{ .x = @floatCast(at.x), .y = @floatCast(bounds.size.height - at.y) });
}
