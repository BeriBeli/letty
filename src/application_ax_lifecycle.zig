//! M11 window accessibility. Geometry is resolved only after final arrange/paint.
//! Notes borrow frame-local labels; Adapter.publish owns all OS-visible data.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("nanoui").ui;
const bridge = @import("application_accessibility.zig");
const ax = bridge.ax;
const vt = @import("vt.zig");
const surfaces = @import("application_ax_surfaces.zig");
const semantic = @import("ui_semantics.zig");
pub const Intent = enum { none, tab, pane, copy, new_tab, palette, previous_tab, next_tab, search_previous, search_next, search_close, query, scrollbar, sidebar_toggle, preview_toggle, tab_pin, tab_close, open_settings, document_tab, document_body, document_query, document_path, document_copy, document_refresh, document_close, document_open, document_browse, document_rendered, document_source, document_toggle_source, document_more, document_copy_code, document_fit, document_actual, document_zoom_out, document_zoom_in, document_previous, document_next, document_done, document_find, document_copy_path, document_external, document_workspace };
pub const Note = struct {
    widget: u64,
    role: ax.Role,
    target: bridge.Target,
    intent: Intent = .none,
    label: []const u8,
    selected: bool = false,
    value: []const u8 = "",
    enabled: bool = true,
    focused: bool = false,
    caret: u32 = 0,
    selection_start: u32 = 0,
    selection_end: u32 = 0,
    truncated: bool = false,
    modal: surfaces.Ref = .{},
    inset: [4]f32 = @splat(0), // left, top, right, bottom in logical points
};
const Identity = struct { id: u64 = 0, role: ax.Role = .group, intent: Intent = .none, target: bridge.Target = .{ .window = 0 }, seen: u64 = 0, surface: surfaces.Surface = .none, generation: u64 = 0, control: semantic.Control = .panel, ordinal: u32 = 0, stamp: u64 = 0 };
const Route = struct { id: u64, intent: Intent, modal: surfaces.Ref = .{}, widget: u64 = 0 };
pub fn Runtime(comptime Window: type) type {
    return struct {
        const Self = @This();
        owner: ?*Window = null,
        adapter: ?bridge.Adapter = null,
        notes: [ax.max_nodes - 1]Note = undefined,
        count: usize = 0,
        identities: [ax.max_nodes * 2]Identity = @splat(.{}),
        next_id: u64 = 2, // 1 is the permanent window root.
        epoch: u64 = 0,
        routes: [ax.max_nodes]Route = undefined,
        route_count: usize = 0,
        visible: [60 * 1024]u8 = undefined,
        used: usize = 0,
        last_error: ?anyerror = null,
        external_geometry: semantic.Geometry = .{},
        pub fn attach(self: *Self, w: *Window) !void {
            if (!w.cfg.services.accessibility or w.demo or w.app.flags.hidden) return;
            if (self.adapter != null and self.adapter.?.native != null) return error.AccessibilityAlreadyAttached;
            const window = w.window orelse return error.NoNativeWindow;
            const surface = window.surface orelse return error.NoNativeSurface;
            self.owner = w;
            errdefer self.owner = null;
            if (self.adapter == null) self.adapter = try bridge.Adapter.init(w.id);
            errdefer self.adapter = null;
            self.adapter.?.wake = .{ .context = self, .call = wake };
            if (builtin.os.tag == .macos) try self.adapter.?.attach(@ptrCast(surface.nsview)) else if (builtin.os.tag == .linux) try self.adapter.?.attach(@ptrCast(surface.area)) else return error.AccessibilityUnsupported;
        }
        pub fn sync(self: *Self, w: *Window) void {
            if (!w.cfg.services.accessibility) {
                self.detach();
                return;
            }
            if (self.adapter == null or self.adapter.?.native == null) self.attach(w) catch |err| {
                self.last_error = err;
            };
        }
        pub fn detach(self: *Self) void {
            if (self.adapter) |*a| a.detach();
            self.adapter = null;
            self.owner = null;
            self.count = 0;
            self.route_count = 0;
        }
        fn wake(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            const w = self.owner orelse return;
            if (!w.closing) if (w.window) |window| window.redraw();
        }
        /// Window.view: dispatch outside native callback, then collect the new
        /// tree. Called again on rebuild; only the final pass is published.
        pub fn begin(self: *Self, w: *Window, ctx: *ui.Context) void {
            if (self.adapter == null) self.adapter = bridge.Adapter.init(w.id) catch return;
            self.owner = w;
            self.adapter.?.wake = .{ .context = self, .call = wake };
            self.keyboard(w, ctx);
            self.count = 0;
            var dispatcher: Dispatcher = .{ .runtime = self, .ctx = ctx };
            _ = self.adapter.?.dispatch(&dispatcher) catch |err| {
                self.last_error = err;
            };
            ctx.after_frame = .{ .context = self, .call = afterFrame };
        }
        pub fn note(self: *Self, value: Note) void {
            if (self.adapter == null) return;
            if (self.count == self.notes.len) {
                self.last_error = error.AccessibilityNodeLimit;
                return;
            }
            self.notes[self.count] = value;
            self.count += 1;
        }
        fn afterFrame(context: *anyopaque, ctx: *ui.Context) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.publish(ctx) catch |err| {
                self.last_error = err;
            };
        }
        fn identity(self: *Self, note_: Note) !u64 {
            var empty: ?*Identity = null;
            for (&self.identities) |*entry| {
                if (entry.id != 0 and entry.role == note_.role and entry.intent == note_.intent and entry.target.eql(note_.target) and entry.surface == note_.modal.surface and entry.generation == note_.modal.generation and entry.control == note_.modal.control and entry.ordinal == note_.modal.ordinal and entry.stamp == note_.modal.stamp) {
                    entry.seen = self.epoch;
                    return entry.id;
                }
                if (entry.id == 0 or entry.seen +| 1 < self.epoch) empty = entry;
            }
            const entry = empty orelse return error.AccessibilityIdentityLimit;
            if (self.next_id == std.math.maxInt(u64)) return error.AccessibilityIdExhausted;
            const id = self.next_id;
            self.next_id += 1;
            entry.* = .{ .id = id, .role = note_.role, .intent = note_.intent, .target = note_.target, .seen = self.epoch, .surface = note_.modal.surface, .generation = note_.modal.generation, .control = note_.modal.control, .ordinal = note_.modal.ordinal, .stamp = note_.modal.stamp };
            return id;
        }
        fn publish(self: *Self, ctx: *ui.Context) !void {
            const w = self.owner orelse return;
            if (w.closing or w.deinitialized or w.host.find(w.id) != w) return;
            if (comptime @hasField(Window, "inspector")) {
                if (w.inspector.open and !w.inspector.frozen) w.inspector.snapshot.services = @import("application_service_diagnostics.zig").capture(&w.host.services, self);
            }
            self.collectSurface(w, ctx);
            self.epoch +|= 1;
            self.used = 0;
            var records: [ax.max_nodes]bridge.Record = undefined;
            var next_routes: [ax.max_nodes]Route = undefined;
            records[0] = .{ .node = .{ .id = 1, .role = .group, .label = "Letty", .bounds = .{ .width = ctx.size.w, .height = ctx.size.h } }, .target = .{ .window = w.id } };
            var n: usize = 1;
            for (self.notes[0..self.count]) |note_| {
                var bounds = geometry(ctx, note_.widget) orelse continue;
                bounds.x += note_.inset[0];
                bounds.y += note_.inset[1];
                bounds.width = @max(0, bounds.width - note_.inset[0] - note_.inset[2]);
                bounds.height = @max(0, bounds.height - note_.inset[1] - note_.inset[3]);
                if (bounds.width <= 0 or bounds.height <= 0) continue;
                const id = try self.identity(note_);
                var state: u32 = ax.State.visible | ax.State.enabled;
                var actions_: u32 = 0;
                var value: []const u8 = note_.value;
                var visible_text: ?bridge.VisibleText = null;
                if (!note_.enabled or (w.modalOpen() and note_.modal.surface == .none)) state &= ~ax.State.enabled;
                if (note_.focused and note_.enabled) state |= ax.State.focused;
                if (note_.selected) state |= ax.State.selected;
                if (note_.truncated) state |= ax.State.truncated;
                if (note_.modal.surface != .none and note_.modal.control == .panel) state |= ax.State.modal;
                switch (note_.intent) {
                    .tab, .pane, .query, .document_tab, .document_body, .document_query, .document_path => {
                        state |= ax.State.focusable;
                        actions_ = @backingInt(ax.Action.focus) | @backingInt(ax.Action.press);
                    },
                    .scrollbar => actions_ = @backingInt(ax.Action.increment) | @backingInt(ax.Action.decrement),
                    .none => {},
                    else => actions_ = @backingInt(ax.Action.press),
                }
                if (note_.modal.surface != .none) {
                    const control = note_.modal.control;
                    actions_ = switch (control) {
                        .panel => @backingInt(ax.Action.dismiss),
                        .body => 0,
                        .query => @backingInt(ax.Action.focus),
                        else => @backingInt(ax.Action.focus) | @backingInt(ax.Action.press),
                    };
                    if (control != .panel and control != .body) state |= ax.State.focusable;
                }
                if (actions_ & @backingInt(ax.Action.press) != 0) state |= ax.State.focusable;
                if (note_.role == .terminal) {
                    const viewport_text = (try self.viewport(w, note_.target)) orelse continue;
                    visible_text = viewport_text.text;
                    if (viewport_text.truncated) state |= ax.State.truncated;
                    state |= ax.State.read_only | ax.State.focusable;
                    actions_ = @backingInt(ax.Action.focus) | @backingInt(ax.Action.copy);
                    if (w.active()) |session| {
                        if (session.id == note_.target.session and w.window_focused and !w.search_open and !w.modalOpen() and !w.sidebar.focused and !@import("application_preview.zig").focused(w)) state |= ax.State.focused;
                    }
                }
                if (note_.intent == .document_body) {
                    state |= ax.State.read_only | ax.State.focusable;
                    actions_ = @backingInt(ax.Action.focus) | @backingInt(ax.Action.copy);
                }
                if (note_.intent == .query and note_.modal.surface == .none) {
                    value = w.query.text();
                    if (ctx.focus == note_.widget and w.window_focused and !w.modalOpen()) state |= ax.State.focused;
                }
                var parent: u64 = 1;
                for (records[1..n]) |record| {
                    if (note_.role == .tab and record.node.role == .tab_group) parent = record.node.id;
                    if ((note_.intent == .tab_pin or note_.intent == .tab_close) and record.node.role == .tab and record.target.tab == note_.target.tab) parent = record.node.id;
                    if (note_.role == .terminal and record.node.role == .pane and record.target.eql(note_.target)) parent = record.node.id;
                    if (note_.modal.surface != .none and note_.modal.control != .panel and record.node.state & ax.State.modal != 0) parent = record.node.id;
                }
                records[n] = .{ .node = .{ .id = id, .parent = parent, .role = note_.role, .state = state, .actions = actions_, .label = note_.label, .value = value, .bounds = bounds, .caret = note_.caret, .selection_start = note_.selection_start, .selection_end = note_.selection_end }, .target = note_.target, .visible_text = visible_text };
                next_routes[n - 1] = .{ .id = id, .intent = note_.intent, .modal = note_.modal, .widget = note_.widget };
                n += 1;
            }
            // Publish only controls constructed in this final layout pass.
            // Modal routes own generation/stamp; background actions are disabled.
            _ = try self.adapter.?.publish(records[0..n]);
            @memcpy(self.routes[0 .. n - 1], next_routes[0 .. n - 1]);
            self.route_count = n - 1;
        }
        /// A fresh, synchronous visible frame only. Never call text/history APIs.
        const Viewport = struct { text: bridge.VisibleText, truncated: bool };
        fn viewport(self: *Self, w: *Window, target: bridge.Target) !?Viewport {
            const slot = liveSlot(w, target) orelse return null;
            const session = w.sessions[slot].?;
            var cursor: vt.Cursor = .{};
            if (vt.lt_vt_frame(session.vt, &cursor) != 0) return error.AccessibilityTerminalFrame;
            defer vt.lt_vt_frame_end(session.vt);
            const start = self.used;
            const limit = @min(self.visible.len, start + 4096);
            var cell: vt.Cell = undefined;
            var row: ?u32 = null;
            var caret: u32 = 0;
            var sel_start: ?u32 = null;
            var sel_end: u32 = 0;
            var truncated = false;
            while (vt.lt_vt_next(session.vt, &cell)) {
                if (cell.width == 0) continue;
                const text = if (cell.flags & 256 != 0 or cell.len == 0) " " else (cell.text orelse return error.AccessibilityTerminalText)[0..cell.len];
                if (std.mem.indexOfScalar(u8, text, 0) != null or !std.unicode.utf8ValidateSlice(text)) return error.AccessibilityTerminalText;
                const newline: usize = if (row != null and row.? != cell.y) 1 else 0;
                if (text.len + newline > limit - self.used) {
                    truncated = true;
                    break;
                }
                if (newline != 0) {
                    self.visible[self.used] = '\n';
                    self.used += 1;
                }
                row = cell.y;
                const at: u32 = @intCast(self.used - start);
                if (cursor.visible and cursor.x >= cell.x and cursor.x < cell.x + cell.width and cursor.y == cell.y) caret = at;
                @memcpy(self.visible[self.used..][0..text.len], text);
                self.used += text.len;
                if (cell.flags & 16 != 0) {
                    if (sel_start == null) sel_start = at;
                    sel_end = @intCast(self.used - start);
                }
            }
            return .{ .text = .{ .text = self.visible[start..self.used], .caret = caret, .selection_start = sel_start orelse 0, .selection_end = sel_end }, .truncated = truncated };
        }
        fn collectSurface(self: *Self, w: *Window, ctx: *ui.Context) void {
            const current = surfaces.current(w) orelse return;
            const g = current.geometry orelse blk: {
                if (!@import("application_ax_theme.zig").collect(w, ctx, &self.external_geometry)) return;
                break :blk &self.external_geometry;
            };
            if (g.frame != ctx.frame or g.generation != current.generation) return;
            for (g.entries[0..g.count]) |*entry| {
                const role: ax.Role = switch (entry.control) {
                    .panel => if (current.surface == .context or current.surface == .palette) .menu else .dialog,
                    .body => .label,
                    .query => .search,
                    .command => .menu_item,
                    else => .button,
                };
                self.note(.{ .widget = entry.widget, .role = role, .target = current.target, .intent = .none, .label = entry.label.text(), .value = entry.value.text(), .enabled = entry.enabled, .selected = entry.selected, .truncated = entry.truncated, .focused = entry.control != .panel and entry.control != .body and ctx.focus == entry.widget and w.window_focused, .modal = .{ .surface = current.surface, .generation = current.generation, .stamp = current.stamp, .control = entry.control, .ordinal = entry.ordinal, .widget = entry.widget, .command = entry.command } });
            }
        }
        /// Consume only unmodified Tab/Shift-Tab in a real modal/search tree.
        /// Terminal-focused Tab remains untouched; no synthetic key/PTY event.
        fn keyboard(self: *Self, w: *Window, ctx: *ui.Context) void {
            const current = surfaces.current(w);
            // The theme browser owns its four-stop query/footer keyboard
            // traversal; native AX actions still use the deferred routes.
            if (current) |surface| if (surface.surface == .theme) return;
            if (current == null and !w.search_open and !@import("application_preview.zig").focused(w)) return;
            if (ctx.marked_text_id != 0 and ctx.focus == ctx.marked_text_id) return;
            if (ctx.focused_text) |field| if (field.marked != null) return;
            for (ctx.input.ops) |op| if (op == .set_marked or op == .unmark) return;
            const sc = ctx.input.shortcut;
            if (ctx.input.ctrl or ctx.input.alt or (sc != null and (sc.?.ctrl or sc.?.cmd or sc.?.alt))) return;
            var tab = ctx.input.key == .tab or (sc != null and sc.?.key == ui.Shortcut.tab);
            var enter = ctx.input.key == .enter or (sc != null and sc.?.key == ui.Shortcut.enter);
            for (ctx.input.ops) |op| if (op == .command) {
                tab = tab or op.command == .insert_tab;
                enter = enter or op.command == .insert_newline;
            };
            if (!tab and !enter) return;
            const a = if (self.adapter) |*value| value else return;
            var focused: u64 = 0;
            for (self.routes[0..self.route_count]) |route| if (route.widget == ctx.focus) {
                focused = route.id;
                break;
            };
            if (tab) {
                var next = focused;
                var selected: ?Route = null;
                for (0..ax.max_nodes) |_| {
                    next = a.snapshot.nextFocusable(next, ctx.input.shift or (sc != null and sc.?.shift)) orelse return;
                    for (self.routes[0..self.route_count]) |route| if (route.id == next) {
                        const search_control = route.intent == .query or route.intent == .search_next or route.intent == .search_previous or route.intent == .search_close;
                        const document_control = route.intent == .document_body or route.intent == .document_query or route.intent == .document_path or route.intent == .document_copy or route.intent == .document_refresh or route.intent == .document_close or route.intent == .document_tab or (@backingInt(route.intent) >= @backingInt(Intent.document_open));
                        if (route.modal.surface != .none or (w.search_open and search_control) or (@import("application_preview.zig").focused(w) and document_control)) selected = route;
                        break;
                    };
                    if (selected != null) break;
                }
                const chosen = selected orelse return;
                for (self.routes[0..self.route_count]) |route| if (route.id == chosen.id) {
                    if (route.modal.surface != .none) {
                        if (!surfaces.focus(w, route.modal, ctx)) return;
                    } else {
                        // Search controls: focus is real UI focus, never VT input.
                        ctx.focus = route.widget;
                        if (route.intent == .query) w.search_focus = true;
                        if (w.preview.active(w.layout.tabs[w.layout.active_tab].id)) |doc| {
                            if (route.intent == .document_query) {
                                doc.panel.focus_query = true;
                                doc.panel.field = .query;
                            }
                            if (route.intent == .document_path) {
                                doc.panel.focus_path = true;
                                doc.panel.field = .path;
                            }
                            if (route.intent == .document_body) doc.panel.field = .body;
                        }
                    }
                    break;
                };
            } else {
                // Text fields retain Enter/IME semantics. Only a focused,
                // advertised button/menu item is activated here.
                const node = a.snapshot.find(focused) orelse return;
                if (!a.snapshot.canInvoke(focused, .press) or node.role == .search or node.role == .text_field) return;
                var dispatcher: Dispatcher = .{ .runtime = self, .ctx = ctx };
                for (a.routes[0..a.route_count]) |route| if (route.node == focused) {
                    dispatcher.accessibilityDispatch(.{ .node = focused, .target = route.target, .action = .press }) catch return;
                    break;
                };
            }
            if (sc) |shortcut| _ = ctx.shortcut(shortcut);
            ctx.input.key = null;
            ctx.input.chars = "";
            ctx.input.ops = &.{};
            ctx.changed = true;
        }
        const Dispatcher = struct {
            runtime: *Self,
            ctx: *ui.Context,
            pub fn accessibilityAlive(d: *@This(), target: bridge.Target) bool {
                const w = d.runtime.owner orelse return false;
                if (w.closing or w.retired or w.deinitialized or w.id != target.window or w.host.find(w.id) != w) return false;
                if (target.tab == 0) return target.session == 0;
                _ = w.layout.tabIndex(target.tab) orelse return false;
                if (target.document != 0) {
                    const doc = w.preview.find(target.document) orelse return false;
                    return doc.tab_id == target.tab and doc.panel.model.generation == target.document_generation;
                }
                if (target.session != 0) return liveSlot(w, target) != null;
                return true;
            }
            pub fn accessibilityDispatch(d: *@This(), request: bridge.Request) !void {
                if (!d.accessibilityAlive(request.target)) return error.AccessibilityStaleTarget;
                const w = d.runtime.owner.?;
                // AX callbacks may have queued an action before AppKit delivers
                // this frame's marked text. Do not move focus, accept a dialog
                // or clear terminal preedit while the IME owns that input.
                // The consumed action can be requested again after composition.
                if (compositionActive(w, d.ctx)) return error.AccessibilityCompositionActive;
                var modal: surfaces.Ref = .{};
                var intent: ?Intent = null;
                for (d.runtime.routes[0..d.runtime.route_count]) |route| if (route.id == request.node) {
                    intent = route.intent;
                    modal = route.modal;
                    break;
                };
                const command = intent orelse return error.AccessibilityStaleTarget;
                if (modal.surface != .none) {
                    try surfaces.dispatch(w, modal, request.action, d.ctx);
                    return;
                }
                if (w.modalOpen()) return error.AccessibilityModalBlocked;
                if (command == .preview_toggle) {
                    if (w.layout.tab_count == 0 or request.target.tab != w.layout.tabs[w.layout.active_tab].id) return error.AccessibilityStaleTarget;
                    if (request.target.document != 0) {
                        const active = w.preview.active(request.target.tab) orelse return error.AccessibilityStaleTarget;
                        if (active.id != request.target.document) return error.AccessibilityStaleTarget;
                    } else if (w.preview.active(request.target.tab) != null) return error.AccessibilityStaleTarget;
                    w.pending = .{ .action = .toggle_file_preview };
                    w.perform(d.ctx);
                    d.ctx.changed = true;
                    return;
                }
                if (request.target.session != 0 and request.target.tab != w.layout.tabs[w.layout.active_tab].id) return error.AccessibilityStaleTarget;
                if (request.target.document != 0) {
                    const doc = w.preview.find(request.target.document) orelse return error.AccessibilityStaleTarget;
                    if (request.target.tab != w.layout.tabs[w.layout.active_tab].id or doc.tab_id != request.target.tab) return error.AccessibilityStaleTarget;
                    const dock = w.preview.dockFor(doc.tab_id);
                    if (command != .document_tab and (dock.active != doc.id or dock.collapsed)) return error.AccessibilityStaleTarget;
                    dock.active = doc.id;
                    dock.collapsed = false;
                    doc.panel.focused = true;
                    w.sidebar.focused = false;
                    switch (command) {
                        .document_tab, .document_body => if (request.action == .copy) doc.panel.copy(d.ctx) else {
                            doc.panel.field = .body;
                            d.ctx.focus = 0;
                        },
                        .document_path => {
                            doc.panel.focus_path = true;
                            doc.panel.field = .path;
                        },
                        .document_query => {
                            doc.panel.show_find = true;
                            doc.panel.focus_query = true;
                            doc.panel.field = .query;
                        },
                        .document_open => @import("application_preview.zig").openDraft(w, doc),
                        .document_browse => w.preview.pending_picker = true,
                        .document_rendered => @import("preview/view.zig").setMode(&doc.panel, d.ctx, .rendered),
                        .document_toggle_source => @import("preview/view.zig").setMode(&doc.panel, d.ctx, if (doc.panel.mode == .source) .rendered else .source),
                        .document_more => @import("preview/view.zig").toggleActions(&doc.panel, d.ctx),
                        .document_source => @import("preview/view.zig").setMode(&doc.panel, d.ctx, .source),
                        .document_find => {
                            doc.panel.show_find = true;
                            doc.panel.focus_query = true;
                            doc.panel.field = .query;
                        },
                        .document_copy_path => d.ctx.clipboard.write(d.ctx.clipboard.ctx, doc.panel.model.path.text()),
                        .document_external => @import("application_commands.zig").openPath(w, d.ctx, doc.panel.model.path.text()),
                        .document_previous => doc.panel.find(true),
                        .document_next => doc.panel.find(false),
                        .document_done => {
                            doc.panel.show_find = false;
                            doc.panel.field = .body;
                            d.ctx.focus = 0;
                        },
                        .document_fit => {
                            doc.panel.fit_image = true;
                            doc.panel.layout_width = -1;
                        },
                        .document_actual => {
                            doc.panel.fit_image = false;
                            doc.panel.image_zoom = 1;
                            doc.panel.layout_width = -1;
                        },
                        .document_zoom_out => @import("preview/view.zig").zoom(&doc.panel, d.ctx, false),
                        .document_zoom_in => @import("preview/view.zig").zoom(&doc.panel, d.ctx, true),
                        .document_copy_code => {
                            if (modal.generation != doc.panel.model.revision) return error.AccessibilityStaleTarget;
                            @import("preview/view.zig").copyCode(&doc.panel, d.ctx, modal.ordinal);
                        },
                        .document_copy => doc.panel.copy(d.ctx),
                        .document_refresh => try doc.panel.model.refresh(),
                        .document_workspace => w.pending = .{ .action = .move_preview_to_workspace },
                        .document_close => w.preview.pending_close = doc.id,
                        else => return error.AccessibilityStaleTarget,
                    }
                    w.syncFocus();
                    d.ctx.changed = true;
                    return;
                }
                if (command == .tab or command == .tab_pin or command == .tab_close) {
                    const tab = w.layout.tabIndex(request.target.tab) orelse return error.AccessibilityStaleTarget;
                    if (tab != w.layout.active_tab) w.activateTab(tab);
                    if (w.cfg.workspace_navigation == .sidebar) {
                        w.sidebar.focused = w.navigation_rects.compact == null;
                        if (!w.sidebar.focused) {
                            if (w.preview.active(request.target.tab)) |doc| doc.panel.focused = false;
                            d.ctx.focus = 0;
                        }
                        w.sidebar.selected = request.target.tab;
                    }
                } else if (request.target.session != 0) {
                    w.focusPane(liveSlot(w, request.target) orelse return error.AccessibilityStaleTarget);
                    if (request.action == .focus) {
                        w.sidebar.focused = false;
                        if (w.preview.active(w.layout.tabs[w.layout.active_tab].id)) |doc| doc.panel.focused = false;
                        d.ctx.focus = 0;
                        if (w.search_open) {
                            w.pending = .{ .action = .end_search };
                            w.perform(d.ctx);
                        }
                    }
                }
                if (command == .scrollbar) {
                    const slot = liveSlot(w, request.target) orelse return error.AccessibilityStaleTarget;
                    const session = w.sessions[slot].?;
                    var info: vt.Scroll = .{};
                    vt.lt_vt_scroll_info(session.vt, &info);
                    if (info.alternate) return error.AccessibilityScrollUnavailable;
                    const rows: c_int = @intCast(@min(256, @max(1, info.len -| 1)));
                    vt.lt_vt_scroll(session.vt, if (request.action == .decrement) -rows else rows);
                } else if (request.action == .copy) {
                    // The advertised action is limited to current visible
                    // content. Ordinary Copy may include offscreen history and
                    // fails without a selection, so do not route through it.
                    d.runtime.used = 0;
                    const view = (try d.runtime.viewport(w, request.target)) orelse return error.AccessibilityStaleTarget;
                    const text = view.text;
                    const copied = if (text.selection_start < text.selection_end)
                        text.text[text.selection_start..text.selection_end]
                    else
                        text.text;
                    d.ctx.clipboard.write(d.ctx.clipboard.ctx, copied);
                } else if (command == .query) {
                    // draw() resolves this rebuild's actual field ID.
                    w.search_focus = true;
                } else {
                    const action: @import("actions.zig").Action = switch (command) {
                        .new_tab => .tab,
                        .palette => .palette,
                        .previous_tab => .previous_tab,
                        .next_tab => .next_tab,
                        .search_previous => .search_previous,
                        .search_next => .search_next,
                        .search_close => .end_search,
                        .sidebar_toggle => .toggle_sidebar,
                        .preview_toggle => .toggle_file_preview,
                        .tab_pin => .toggle_tab_pin,
                        .tab_close => .close_tab,
                        .open_settings => .open_settings,
                        else => .none,
                    };
                    if (action != .none) {
                        w.pending = .{ .action = action };
                        w.perform(d.ctx);
                    }
                }
                d.ctx.changed = true;
            }
        };
    };
}
fn compositionActive(w: anytype, ctx: *ui.Context) bool {
    if (ctx.marked_text_id != 0 and ctx.focus == ctx.marked_text_id) return true;
    if (ctx.focused_text) |field| if (field.marked != null) return true;
    if (w.views[w.layout.active_pane].preedit.items.len != 0) return true;
    for (ctx.input.ops) |op| if (op == .set_marked or op == .unmark) return true;
    return false;
}
fn liveSlot(w: anytype, target: bridge.Target) ?usize {
    const tab = w.layout.tabIndex(target.tab) orelse return null;
    for (w.sessions, 0..) |opt, slot| if (opt) |session| if (session.id == target.session and w.layout.contains(w.layout.roots[tab], @intCast(slot))) return @intCast(slot);
    return null;
}
pub fn geometry(ctx: *ui.Context, id: u64) ?ax.Bounds {
    for (ctx.nodes.items, 0..) |node, index| if (node.id == id) {
        var r = intersect(node.rect, .{ .w = ctx.size.w, .h = ctx.size.h });
        var next: usize = index;
        var depth: usize = 0;
        while (next != 0) {
            next = ctx.nodes.items[next].parent;
            if (next >= ctx.nodes.items.len or depth >= ctx.nodes.items.len) return null;
            const parent = ctx.nodes.items[next];
            if (parent.style.clip) r = intersect(r, parent.rect);
            depth += 1;
        }
        return .{ .x = r.x, .y = r.y, .width = r.w, .height = r.h };
    };
    return null;
}
fn intersect(a: ui.Rect, b: ui.Rect) ui.Rect {
    const x = @max(a.x, b.x);
    const y = @max(a.y, b.y);
    return .{ .x = x, .y = y, .w = @max(0, @min(a.x + a.w, b.x + b.w) - x), .h = @max(0, @min(a.y + a.h, b.y + b.h) - y) };
}
