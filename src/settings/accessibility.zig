//! Bounded Settings semantics, published after layout to the existing native AX
//! bridge. Native callbacks queue IDs; only the UI turn resolves a live control.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("nanoui").ui;
const bridge = @import("../application_accessibility.zig");
const ax = bridge.ax;
pub const Note = struct { widget: u64, role: ax.Role, label: []const u8, value: []const u8 = "", enabled: bool = true, selected: bool = false };
pub const Collector = struct {
    notes: [512]Note = undefined,
    count: usize = 0,
    pressed: u64 = 0,
    pressed_stamp: u64 = 0,
    pub fn add(self: *Collector, note: Note) void {
        if (self.count == self.notes.len) return;
        self.notes[self.count] = note;
        self.count += 1;
    }
};
const Identity = struct { widget: u64 = 0, stamp: u64 = 0, id: u64 = 0, seen: u64 = 0 };
pub fn Runtime(comptime Owner: type) type {
    return struct {
        const Self = @This();
        owner: ?*Owner = null,
        adapter: ?bridge.Adapter = null,
        identities: [256]Identity = @splat(.{}),
        next_id: u64 = 2,
        generation: u64 = 1,
        stamp: u64 = 0,
        epoch: u64 = 0,
        routes: [ax.max_nodes]struct { id: u64, widget: u64 } = undefined,
        route_count: usize = 0,
        last_error: ?anyerror = null,
        pub fn detach(self: *Self) void {
            if (self.adapter) |*a| a.detach();
            self.adapter = null;
            self.route_count = 0;
            self.generation += 1;
        }
        fn currentStamp(self: *Self) u64 {
            const o = self.owner.?;
            var hash = std.hash.Wyhash.init(o.model_generation);
            hash.update(std.mem.asBytes(&o.form.category));
            const choice: u16 = if (o.form.choice_open) |field| @as(u16, @intCast(@backingInt(field))) + 1 else 0;
            hash.update(std.mem.asBytes(&choice));
            hash.update(o.form.query.text());
            hash.update(o.form.popup_query.text());
            hash.update(o.form.theme_query.text());
            hash.update(o.form.font_query.text());
            hash.update(o.form.shortcut_query.text());
            hash.update(o.form.editing_trigger.text());
            hash.update(&.{ @intFromBool(o.form.binding_editor), @intFromBool(o.form.binding_actions), @intFromBool(o.form.binding_advanced), @intFromBool(o.form.advanced_overrides), @intFromBool(o.form.advanced_applied) });
            hash.update(&.{ @intFromBool(o.form.confirm_discard), @intFromBool(o.form.show_fonts), @intFromBool(o.form.cell_options), @intFromBool(o.form.color_options), @intFromBool(o.form.workspace_options), @intFromBool(o.form.show_themes) });
            return hash.final();
        }
        pub fn begin(self: *Self, owner: *Owner, ctx: *ui.Context) void {
            self.owner = owner;
            if (self.adapter == null) self.adapter = bridge.Adapter.init(1) catch return;
            self.adapter.?.wake = .{ .context = self, .call = wake };
            if (self.adapter.?.native == null) if (owner.window) |window| if (!window.app.flags.hidden) if (window.surface) |surface| {
                if (builtin.os.tag == .macos) self.adapter.?.attach(@ptrCast(surface.nsview)) catch |err| {
                    self.last_error = err;
                } else if (builtin.os.tag == .linux) self.adapter.?.attach(@ptrCast(surface.area)) catch |err| {
                    self.last_error = err;
                };
            };
            const stamp = self.currentStamp();
            if (stamp != self.stamp) {
                self.generation += 1;
                self.stamp = stamp;
            }
            var dispatcher: Dispatcher = .{ .runtime = self, .ctx = ctx };
            _ = self.adapter.?.dispatch(&dispatcher) catch |err| {
                self.last_error = err;
            };
            owner.form.ax.count = 0;
            ctx.after_frame = .{ .context = self, .call = afterFrame };
        }
        fn wake(raw: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(raw));
            if (self.owner) |owner| if (owner.window) |window| window.redraw();
        }
        fn afterFrame(raw: *anyopaque, ctx: *ui.Context) void {
            const self: *Self = @ptrCast(@alignCast(raw));
            self.publish(ctx) catch |err| {
                self.last_error = err;
            };
        }
        fn publish(self: *Self, ctx: *ui.Context) !void {
            const owner = self.owner orelse return;
            if (!owner.alive or owner.window == null) return;
            const stamp = self.currentStamp();
            if (stamp != self.stamp) {
                self.generation += 1;
                self.stamp = stamp;
            }
            self.epoch += 1;
            const target: bridge.Target = .{ .window = 1, .document_generation = self.generation };
            var records: [ax.max_nodes]bridge.Record = undefined;
            records[0] = .{ .node = .{ .id = 1, .role = if (owner.form.confirm_discard) .dialog else .group, .label = if (owner.form.confirm_discard) "Unsaved Settings changes" else "Letty Settings", .state = ax.State.visible | ax.State.enabled | (if (owner.form.confirm_discard) ax.State.modal else @as(u32, 0)), .bounds = .{ .width = ctx.size.w, .height = ctx.size.h } }, .target = target };
            var n: usize = 1;
            self.route_count = 0;
            for (owner.form.ax.notes[0..owner.form.ax.count]) |note| {
                const bounds = @import("../application_ax_lifecycle.zig").geometry(ctx, note.widget) orelse continue;
                if (bounds.width <= 0 or bounds.height <= 0) continue;
                if (n == records.len) return error.AccessibilityNodeLimit;
                const identity_stamp = std.hash.Wyhash.hash(self.generation ^ @backingInt(note.role), note.label);
                var found: ?*Identity = null;
                var empty: ?*Identity = null;
                for (&self.identities) |*entry| {
                    if (entry.id != 0 and entry.widget == note.widget and entry.stamp == identity_stamp) {
                        found = entry;
                        break;
                    }
                    if (entry.id == 0 or entry.seen + 1 < self.epoch) empty = entry;
                }
                const entry = found orelse empty orelse return error.AccessibilityIdentityLimit;
                if (found == null) {
                    entry.* = .{ .id = self.next_id, .widget = note.widget, .stamp = identity_stamp };
                    self.next_id += 1;
                }
                entry.seen = self.epoch;
                var state: u32 = ax.State.visible;
                if (note.enabled) state |= ax.State.enabled;
                const interactive = note.role == .button or (note.role == .search or note.role == .text_field);
                if (interactive) state |= ax.State.focusable;
                if (note.enabled and interactive and ctx.focus == note.widget) state |= ax.State.focused;
                if (note.selected) state |= ax.State.selected;
                var label_end = @min(note.label.len, ax.max_label);
                while (label_end > 0 and label_end < note.label.len and note.label[label_end] & 0xc0 == 0x80) label_end -= 1;
                if (label_end < note.label.len) state |= ax.State.truncated;
                records[n] = .{ .target = target, .node = .{ .id = entry.id, .parent = 1, .role = note.role, .state = state, .label = note.label[0..label_end], .value = note.value, .bounds = bounds, .actions = if (note.role == .button) @backingInt(ax.Action.press) | @backingInt(ax.Action.focus) else if ((note.role == .search or note.role == .text_field)) @backingInt(ax.Action.focus) else 0 } };
                self.routes[self.route_count] = .{ .id = entry.id, .widget = note.widget };
                self.route_count += 1;
                n += 1;
            }
            _ = try self.adapter.?.publish(records[0..n]);
        }
        const Dispatcher = struct {
            runtime: *Self,
            ctx: *ui.Context,
            pub fn accessibilityAlive(d: *@This(), target: bridge.Target) bool {
                const o = d.runtime.owner orelse return false;
                return o.alive and o.window != null and target.document_generation == d.runtime.generation and d.runtime.stamp == d.runtime.currentStamp();
            }
            pub fn accessibilityDispatch(d: *@This(), request: bridge.Request) !void {
                if (!d.accessibilityAlive(request.target)) return error.AccessibilityStaleTarget;
                const form = &d.runtime.owner.?.form;
                if (form.composing or d.ctx.marked_text_id != 0) return error.AccessibilityCompositionActive;
                for (d.ctx.input.ops) |op| if (op == .set_marked or op == .unmark) return error.AccessibilityCompositionActive;
                for (d.runtime.routes[0..d.runtime.route_count]) |route| if (route.id == request.node) {
                    if (request.action == .press) {
                        if (form.ax.pressed != 0) return error.AccessibilityActionPending;
                        form.ax.pressed = route.widget;
                        const snapshot = &d.runtime.adapter.?.snapshot;
                        form.ax.pressed_stamp = std.hash.Wyhash.hash(0, snapshot.label(snapshot.find(request.node).?.*));
                    }
                    d.ctx.focus = route.widget;
                    d.ctx.changed = true;
                    return;
                };
            }
        };
    };
}
