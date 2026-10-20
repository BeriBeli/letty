//! Stable Host-owned native services and deferred, owned action queue.
const std = @import("std");
const ui = @import("nanoui").ui;
const actions = @import("actions.zig");
const config = @import("config.zig");
const hotkey_api = @import("application_hotkeys.zig");
const quick_api = @import("quick_terminal.zig");
const timer = @import("one_shot.zig");
const workarea = @import("application_workarea.zig");
pub const Target = struct { window: u64 = 0, session: u64 = 0, tab: u64 = 0, domain: bool = false, focused: bool = false, document: u64 = 0, generation: u64 = 0 };
const Item = struct { request: actions.Request, target: Target };
pub const Prepared = struct {
    entries: []hotkey_api.Entry,
    geometry: ?quick_api.Geometry = null,
    enabled: bool,
    pub fn deinit(p: *Prepared, a: std.mem.Allocator) void {
        a.free(p.entries);
        p.* = undefined;
    }
};
pub fn Runtime(comptime Host: type) type {
    return struct {
        const Self = @This();
        owner: ?*Host = null,
        hotkeys: hotkey_api.Manager = .{},
        quick: quick_api.State = .{},
        items: [32]Item = undefined,
        count: usize = 0,
        wake: timer.Handle = .{},
        armed: bool = false,
        dropped: u64 = 0,
        screen_watch: @import("application_screen_watch.zig").Watch = .{},
        screen_pending: bool = false,
        last_screen_error: ?anyerror = null,
        reserved: bool = false,
        reserved_enabled: bool = false,
        reserved_opened: bool = false,
        pub fn init(self: *Self, host: *Host) void {
            self.owner = host;
        }
        pub fn prepare(self: *Self, next: config.Config) !Prepared {
            const h = self.owner orelse return error.ServicesStopped;
            try next.services.validate();
            const entries = try @import("application_global_bindings.zig").collect(h.gpa, next.keybinds);
            errdefer h.gpa.free(entries);
            var geometry: ?quick_api.Geometry = null;
            if (self.quick.window_id) |id| if (h.find(id)) |w| {
                geometry = next.services.geometry(try workarea.forWindow(w.window));
                _ = try quick_api.layout(geometry.?, .{ 0, 0 });
            };
            // No normal tests/snapshot entry opens or registers an OS backend.
            return .{ .entries = entries, .geometry = geometry, .enabled = next.services.global_hotkeys and entries.len > 0 and !h.demo and !h.app.flags.hidden };
        }
        /// Call after all config/profile validation and before publishing cfg.
        /// No fallible config work may follow this native commit.
        pub fn commit(self: *Self, prepared: *const Prepared) !@import("global_hotkey.zig").Commit {
            try self.reserve(prepared);
            return self.publish();
        }
        /// UI-thread transaction: reserve before checked config-file save.
        /// Keep the old map live until publish; no event-loop yield is allowed
        /// between reservation, save and publish/rollback.
        pub fn reserve(self: *Self, prepared: *const Prepared) !void {
            if (self.reserved) return error.PreparationPending;
            if (!prepared.enabled) {
                self.reserved = true;
                self.reserved_enabled = false;
                self.reserved_opened = false;
                return;
            }
            var opened = false;
            if (self.hotkeys.registry.adapter == null) {
                _ = try self.hotkeys.nativeInit(true, deliver, self);
                opened = true;
            }
            errdefer if (opened) self.hotkeys.deinit() catch {};
            try self.hotkeys.prepare(prepared.entries);
            self.reserved = true;
            self.reserved_enabled = true;
            self.reserved_opened = opened;
        }
        pub fn publish(self: *Self) @import("global_hotkey.zig").Commit {
            std.debug.assert(self.reserved);
            self.reserved = false;
            if (self.reserved_enabled) return self.hotkeys.commitPrepared();
            self.hotkeys.deinit() catch unreachable;
            return .{};
        }
        pub fn rollback(self: *Self) void {
            if (!self.reserved) return;
            self.reserved = false;
            if (self.reserved_enabled) self.hotkeys.rollbackPrepared();
            if (self.reserved_opened) self.hotkeys.deinit() catch unreachable;
        }
        pub fn adopted(self: *Self, geometry: ?quick_api.Geometry) !void {
            const h = self.owner orelse return error.ServicesStopped;
            if (geometry) |g| try self.quick.reconfigure(h, g);
        }
        pub fn stop(self: *Self) void {
            self.rollback();
            self.screen_watch.stop();
            self.screen_pending = false;
            if (self.armed) self.wake.cancel();
            self.armed = false;
            self.wake = .{};
            self.count = 0;
            self.hotkeys.deinit() catch unreachable;
            self.owner = null;
        }
        fn deliver(context: ?*anyopaque, request: *const actions.Request) void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            self.enqueue(request) catch {
                self.dropped +|= 1;
            };
        }
        /// Callback-safe: copy the complete Request and stable target only.
        /// Never use Host.queue here: it creates new_window synchronously.
        pub fn enqueue(self: *Self, request: *const actions.Request) !void {
            const h = self.owner orelse return error.ServicesStopped;
            if (settingsBlocked(h, request.action)) return error.SettingsInputActive;
            if (h.active()) |w| if (@import("application_preview.zig").blocksAction(w, request.action)) return error.DocumentInputActive;
            if (h.quitting or self.count == self.items.len) return error.ApplicationQueueFull;
            var target: Target = .{};
            if (request.action != .new_window and request.action != .toggle_quick_terminal and request.action != .open_settings) {
                const w = h.active() orelse blk: {
                    if (request.action == .quit) if (self.quick.window_id) |id| if (h.find(id)) |q| break :blk q;
                    return error.NoActiveWindow;
                };
                target.window = w.id;
                if (!windowOnly(request.action)) {
                    target.session = if (w.active()) |session| session.id else return error.NoActiveSession;
                    target.tab = if (w.layout.tab_count > 0) w.layout.tabs[w.layout.active_tab].id else return error.NoActiveTab;
                }
                captureDomain(w, request.action, &target);
                if (target.domain and explicitDocument(request.action) and target.document == 0) return error.NoActiveDocument;
            }
            self.items[self.count] = .{ .request = request.*, .target = target };
            self.count += 1;
            self.arm() catch |err| {
                self.count -= 1;
                return err;
            };
        }
        fn arm(self: *Self) !void {
            if (self.armed) return;
            self.wake = try timer.start(1, self, fired);
            self.armed = true;
        }
        fn fired(context: ?*anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            const handle = self.wake;
            self.wake = .{};
            self.armed = false;
            handle.fired();
            const h = self.owner orelse return;
            if (h.quitting) {
                self.count = 0;
                self.screen_pending = false;
                return;
            }
            if (self.screen_pending) {
                self.screen_pending = false;
                self.screenChanged();
            }
            var i: usize = 0;
            while (i < self.count) {
                const item = &self.items[i];
                if (settingsBlocked(h, item.request.action)) {
                    self.remove(i);
                    self.dropped +|= 1;
                    continue;
                }
                if (item.target.window == 0) {
                    if (h.active()) |active| if (@import("application_preview.zig").blocksAction(active, item.request.action)) {
                        self.remove(i);
                        self.dropped +|= 1;
                        continue;
                    };
                    const request = item.request;
                    self.remove(i);
                    switch (request.action) {
                        .new_window => {
                            _ = h.create(true) catch |err| {
                                report(h, @errorName(err));
                            };
                        },
                        .toggle_quick_terminal => self.toggleQuick() catch |err| report(h, @errorName(err)),
                        .open_settings => @import("application_settings.zig").open(h) catch |err| report(h, @errorName(err)),
                        else => self.dropped +|= 1,
                    }
                    continue;
                }
                const w = h.find(item.target.window) orelse {
                    self.remove(i);
                    self.dropped +|= 1;
                    continue;
                };
                if (!validDomain(w, item.target) or @import("application_preview.zig").blocksAction(w, item.request.action)) {
                    self.remove(i);
                    self.dropped +|= 1;
                    continue;
                }
                if (item.request.action == .quit and self.quick.owns(w.id) and !self.quick.visible) self.toggleQuick() catch |err| {
                    report(h, @errorName(err));
                    self.remove(i);
                    continue;
                };
                if (w.window) |window| window.redraw();
                i += 1;
            }
        }
        fn remove(self: *Self, index: usize) void {
            self.count -= 1;
            std.mem.copyForwards(Item, self.items[index..self.count], self.items[index + 1 ..][0 .. self.count - index]);
        }
        /// Window.view calls this outside native callbacks, before commands.
        /// Recheck exact tab/session at execution, without a yield before perform.
        pub fn drainWindow(self: *Self, w: anytype, ctx: *ui.Context) void {
            var i: usize = 0;
            while (i < self.count and !w.closing) {
                if (self.items[i].target.window != w.id) {
                    i += 1;
                    continue;
                }
                const item = self.items[i];
                self.remove(i);
                if (settingsBlocked(w.host, item.request.action) or !validDomain(w, item.target) or @import("application_preview.zig").blocksAction(w, item.request.action)) {
                    self.dropped +|= 1;
                    continue;
                }
                if (item.target.tab != 0 and (w.layout.tab_count == 0 or w.layout.tabs[w.layout.active_tab].id != item.target.tab)) {
                    self.dropped +|= 1;
                    continue;
                }
                if (item.target.session != 0 and (w.active() == null or w.active().?.id != item.target.session)) {
                    self.dropped +|= 1;
                    continue;
                }
                w.pending = item.request;
                w.perform(ctx);
            }
        }
        pub fn toggleQuick(self: *Self) !void {
            const h = self.owner orelse return error.ServicesStopped;
            if (h.demo or h.app.flags.hidden) return error.QuickTerminalDisabledForChecks;
            if (self.screen_watch.callback == null) try self.screen_watch.start(.{ .context = self, .changed = screenNotification });
            const current = if (h.active()) |w| w.window else null;
            const geometry = h.cfg.services.geometry(try workarea.forWindow(current));
            try self.quick.toggle(h, geometry);
        }
        fn screenNotification(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.screen_pending = true;
            self.arm() catch |err| {
                self.last_screen_error = err;
            };
        }
        /// Platform screen/workarea notification hook; no polling/timer loop.
        pub fn screenChanged(self: *Self) void {
            const h = self.owner orelse return;
            const id = self.quick.window_id orelse return;
            const w = h.find(id) orelse return;
            const screen = workarea.forWindow(w.window) catch |err| {
                self.last_screen_error = err;
                report(h, @errorName(err));
                return;
            };
            self.quick.reconfigure(h, h.cfg.services.geometry(screen)) catch |err| {
                self.last_screen_error = err;
                report(h, @errorName(err));
            };
        }
        fn report(h: *Host, message: []const u8) void {
            if (h.active()) |w| w.status = message;
        }
    };
}
fn settingsAllowed(action: actions.Action) bool {
    return switch (action) {
        .quit, .new_window, .toggle_quick_terminal, .open_settings => true,
        else => false,
    };
}
fn settingsBlocked(h: anytype, action: actions.Action) bool {
    return h.settings_focused and (h.settings.form.recording or !settingsAllowed(action));
}
fn windowOnly(action: actions.Action) bool {
    return switch (action) {
        .quit, .close_window, .reload, .open_config, .diagnostics, .palette, .save, .font_up, .font_down, .font_reset, .next_window, .previous_window => true,
        else => false,
    };
}
fn explicitDocument(action: actions.Action) bool {
    return action == .move_preview_to_workspace or action == .close_file_preview or action == .toggle_file_preview or action == .refresh_file_preview;
}
fn captureDomain(w: anytype, action: actions.Action, target: *Target) void {
    if (comptime @hasField(@typeInfo(@TypeOf(w)).pointer.child, "preview")) {
        if (windowOnly(action) and action != .font_up and action != .font_down and action != .font_reset) return;
        target.domain = true;
        target.focused = @import("application_preview.zig").focused(w);
        if (target.focused or explicitDocument(action)) if (w.preview.active(if (w.layout.tab_count > 0) w.layout.tabs[w.layout.active_tab].id else 0)) |d| {
            target.document = d.id;
            target.generation = d.panel.model.generation;
        };
    }
}
fn validDomain(w: anytype, target: Target) bool {
    if (!target.domain) return true;
    if (comptime @hasField(@typeInfo(@TypeOf(w)).pointer.child, "preview")) {
        if (@import("application_preview.zig").focused(w) != target.focused) return false;
        if (target.document != 0) {
            const d = w.preview.active(if (w.layout.tab_count > 0) w.layout.tabs[w.layout.active_tab].id else 0) orelse return false;
            if (d.id != target.document or d.panel.model.generation != target.generation) return false;
        }
    }
    return true;
}
