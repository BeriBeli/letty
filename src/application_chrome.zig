//! Per-window native titlebar controls; callbacks only enqueue stable targets.
const builtin = @import("builtin");
const nano = @import("nanoui");
const ui = nano.ui;
const native = builtin.os.tag == .macos;
const objc = if (native) nano.objc else struct {};
const Object = if (native) objc.Object else *anyopaque;
pub fn Runtime(comptime Window: type) type {
    return struct {
        const Self = @This();
        pub const Action = enum { preview, commands };
        const Pending = struct { action: Action, tab: u64, document: u64, generation: u64 };
        owner: ?*Window = null,
        controller: ?Object = null,
        target: ?Object = null,
        pending: ?Pending = null,
        pub fn enqueue(self: *Self, s: *Window, action: Action) void {
            if (s.closing or s.deinitialized or s.layout.tab_count == 0) return;
            const tab = s.layout.tabs[s.layout.active_tab].id;
            const d = s.preview.active(tab);
            self.pending = .{ .action = action, .tab = tab, .document = if (d) |v| v.id else 0, .generation = if (d) |v| v.panel.model.generation else 0 };
            if (s.window) |w| w.redraw();
        }
        pub fn drain(self: *Self, s: *Window, ctx: *ui.Context) void {
            const p = self.pending orelse return;
            self.pending = null;
            if (s.closing or s.deinitialized or s.modalOpen() or s.layout.tab_count == 0) return;
            if (s.layout.tabs[s.layout.active_tab].id != p.tab) return;
            const d = s.preview.active(p.tab);
            if ((if (d) |v| v.id else @as(u64, 0)) != p.document) return;
            if (d) |v| if (v.panel.model.generation != p.generation) return;
            if (@import("application_preview.zig").composing(s, ctx)) return;
            s.pending = .{ .action = if (p.action == .preview) .toggle_file_preview else .palette };
            s.perform(ctx);
        }
        pub fn attach(self: *Self, s: *Window) void {
            if (!native) return;
            if (self.controller != null) return;
            const w = s.window orelse return;
            const pool = objc.Pool.push();
            defer pool.pop();
            const cls = objc.defineClass(.{ .name = "LettyTitlebarTarget", .methods = &.{.{ .name = "activate:", .imp = &activate, .types = "v@:@" }} });
            self.owner = s;
            self.target = objc.msg(Object, cls, "new", .{});
            objc.setZig(self.target.?, self);
            const view = objc.msg(Object, objc.msg(Object, objc.class("NSView"), "alloc", .{}), "initWithFrame:", .{objc.CGRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 72, .height = 28 } }});
            defer objc.release(view);
            inline for (.{ .{ "sidebar.right", "Toggle File Preview" }, .{ "ellipsis", "Commands" } }, 0..) |item, index| {
                const button = objc.msg(Object, objc.msg(Object, objc.class("NSButton"), "alloc", .{}), "initWithFrame:", .{objc.CGRect{ .origin = .{ .x = @as(f64, index * 32), .y = 0 }, .size = .{ .width = 30, .height = 28 } }});
                defer objc.release(button);
                const image = objc.msg(?Object, objc.class("NSImage"), "imageWithSystemSymbolName:accessibilityDescription:", .{ objc.nsString(item[0]), objc.nsString(item[1]) });
                objc.msg(void, button, "setImage:", .{image});
                objc.msg(void, button, "setTitle:", .{objc.nsString("")});
                objc.msg(void, button, "setBordered:", .{objc.NO});
                objc.msg(void, button, "setToolTip:", .{objc.nsString(item[1])});
                objc.msg(void, button, "setAccessibilityLabel:", .{objc.nsString(item[1])});
                objc.msg(void, button, "setTag:", .{@as(objc.NSInteger, index)});
                objc.msg(void, button, "setTarget:", .{self.target.?});
                objc.msg(void, button, "setAction:", .{objc.sel("activate:")});
                objc.msg(void, view, "addSubview:", .{button});
            }
            self.controller = objc.new("NSTitlebarAccessoryViewController");
            objc.msg(void, self.controller.?, "setView:", .{view});
            objc.msg(void, self.controller.?, "setLayoutAttribute:", .{@as(objc.NSInteger, 2)});
            objc.msg(void, w.nswindow, "addTitlebarAccessoryViewController:", .{self.controller.?});
        }
        pub fn detach(self: *Self) void {
            if (native) {
                if (self.target) |target| objc.setZig(target, null);
                if (self.controller) |controller| {
                    if (self.owner) |s| if (s.window) |w| {
                        const controllers = objc.msg(Object, w.nswindow, "titlebarAccessoryViewControllers", .{});
                        const count = objc.msg(objc.NSUInteger, controllers, "count", .{});
                        const index = objc.msg(objc.NSUInteger, controllers, "indexOfObjectIdenticalTo:", .{controller});
                        if (index < count) objc.msg(void, w.nswindow, "removeTitlebarAccessoryViewControllerAtIndex:", .{index});
                    };
                    objc.release(controller);
                }
                if (self.target) |target| objc.autorelease(target);
            }
            self.* = .{};
        }
        fn activate(target: Object, _: if (native) objc.SEL else void, sender: Object) callconv(.c) void {
            if (!native) return;
            const self = objc.getZig(Self, target) orelse return;
            const s = self.owner orelse return;
            self.enqueue(s, if (objc.msg(objc.NSInteger, sender, "tag", .{}) == 0) .preview else .commands);
        }
    };
}
