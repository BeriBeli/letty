//! Application ownership; each registered WindowState has a stable heap address.
const std = @import("std");
const builtin = @import("builtin");
const nano = @import("nanoui");
const c = @import("platform_ffi.zig");
const config = @import("config.zig");
const persistence = @import("workspace_layout.zig");
const storage = @import("dynamic_storage.zig");
const actions = @import("actions.zig");
pub fn Host(comptime Window: type) type {
    return struct {
        const Self = @This();
        const Collection = struct { host: ?*Self };
        const CloseCall = struct { life: *Collection, id: u64 };
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        app: *nano.App,
        cfg: config.Config,
        system_dark: bool = false,
        appearance_watch: @import("system_appearance.zig").Watch = .{},
        config_arena: ?std.heap.ArenaAllocator = null,
        windows: []?*Window = &.{},
        retired: std.ArrayList(*Window) = .empty,
        active_id: u64 = 0,
        next_window_id: u64 = 1,
        next_session_id: u64 = 1,
        state_path: [:0]const u8,
        read_path: [:0]const u8,
        lock_fd: c_int = -1,
        explicit_config: ?[]const u8 = null,
        command_override: ?[]const u8 = null,
        cwd_override: ?[]const u8 = null,
        override_profile: []const u8 = "",
        chosen: u8 = 0,
        demo: bool = false,
        hold: bool = false,
        quitting: bool = false,
        collection: ?*Collection = null,
        collect_scheduled: bool = false,
        restoring: bool = false,
        creating_quick: bool = false,
        services: @import("application_services.zig").Runtime(Self) = .{},
        settings: @import("settings/window.zig").Settings = .{},
        settings_focused: bool = false,
        pub fn startAppearance(h: *Self) void {
            if (h.demo) return;
            _ = h.appearance_watch.start(.{ .context = h, .changed = struct {
                fn call(data: *anyopaque, dark: bool) void {
                    const host: *Self = @ptrCast(@alignCast(data));
                    host.setAppearance(dark);
                }
            }.call });
            h.setAppearance(h.appearance_watch.current());
        }
        pub fn setAppearance(h: *Self, dark: bool) void {
            if (h.system_dark == dark) return;
            h.system_dark = dark;
            h.settings.syncAppearance(dark);
            h.cfg = h.cfg.forAppearance(dark);
            for (h.windows) |opt| if (opt) |w| if (!w.closing) {
                const next = w.cfg.forAppearance(dark);
                if (std.meta.eql(w.cfg, next)) {
                    @import("application_theme_browser.zig").syncAppearance(w);
                    continue;
                }
                w.cfg = next;
                for (w.sessions) |entry| if (entry) |session| w.configureSession(session);
                if (w.window) |window| {
                    const theme = @import("appearance.zig").theme(next);
                    if (window.surface) |surface| {
                        surface.text.setFamilies(theme.font, theme.mono_font);
                        surface.theme_override = theme;
                    }
                    if (builtin.os.tag == .macos) @import("macos_chrome.zig").configure(window, next.background);
                    window.redraw();
                }
                @import("application_theme_browser.zig").syncAppearance(w);
            };
        }
        pub fn paneCount(h: *Self) usize {
            var total: usize = 0;
            for (h.windows) |opt| if (opt) |w| {
                for (w.sessions) |session| if (session != null) {
                    total += 1;
                };
            };
            return total;
        }
        pub fn count(h: *Self) usize {
            var n: usize = 0;
            for (h.windows) |opt| if (opt != null and !opt.?.closing) {
                n += 1;
            };
            return n;
        }
        pub fn find(h: *Self, id: u64) ?*Window {
            for (h.windows) |opt| if (opt) |w| if (w.id == id and !w.closing) return w;
            return null;
        }
        pub fn active(h: *Self) ?*Window {
            if (h.find(h.active_id)) |w| if (!w.transient_quick or h.services.quick.visible) return w;
            for (h.windows) |opt| if (opt) |w| if (!w.closing and (!w.transient_quick or h.services.quick.visible)) return w;
            return null;
        }
        pub fn create(h: *Self, native: bool) !*Window {
            if (h.services.owner == null) h.services.init(h);
            if (h.next_window_id == std.math.maxInt(u64)) return error.WindowIdExhausted;
            var index: ?usize = null;
            for (h.windows, 0..) |w, i| if (w == null) {
                index = i;
                break;
            };
            const at = index orelse h.windows.len;
            try storage.ensure(?*Window, &h.windows, at + 1, null);
            const w = try h.gpa.create(Window);
            errdefer h.gpa.destroy(w);
            w.* = .{ .transient_quick = h.creating_quick, .host = h, .id = h.next_window_id, .gpa = h.gpa, .arena = h.arena, .app = h.app, .cfg = h.cfg, .state_path = h.state_path, .explicit_config = h.explicit_config, .command_override = h.command_override, .cwd_override = h.cwd_override, .override_profile = h.override_profile, .profile = h.chosen, .base_font_size = h.cfg.font_size, .query = .{}, .demo = h.demo, .hold = h.hold };
            // Ghostty newSurfaceOptions carries the source surface's cwd to
            // new windows independently of tab/split inheritance settings.
            if (h.cfg.window_inherit_working_directory) if (h.active()) |source| {
                if (source.active()) |session| w.initial_directory.set(session.cwd.text());
            };
            h.next_window_id += 1;
            h.windows[at] = w;
            errdefer {
                h.windows[at] = null;
                w.deinit();
            }
            try w.reserve(1);
            if (!h.restoring) try w.add(.tab);
            if (native) try w.attach(null);
            if (!h.creating_quick) h.activate(w, native);
            return w;
        }
        pub fn createQuick(h: *Self) !*Window {
            if (h.creating_quick) return error.QuickTerminalReentrant;
            h.creating_quick = true;
            defer h.creating_quick = false;
            const w = try h.create(false);
            errdefer {
                if (w.window) |native| native.close() else h.retire(w);
            }
            try w.attachVisible(null, false);
            return w;
        }
        pub fn activate(h: *Self, w: *Window, native: bool) void {
            h.settings_focused = false;
            for (h.windows) |opt| if (opt) |other| if (other != w and other.window_focused) {
                @import("input_dispatch.zig").cancel(other, .focus_lost);
                other.window_focused = false;
                other.syncFocus();
            };
            h.active_id = w.id;
            if (native and !h.app.flags.hidden) if (w.window) |window| window.focus();
            if (builtin.os.tag == .macos) if (w.window != null) w.macMenu() catch {
                w.status = "Cannot update application menu";
            };
        }
        pub fn visibleCount(h: *Self) usize {
            var n: usize = 0;
            for (h.windows) |opt| if (opt) |w| if (!w.closing and (!w.transient_quick or h.services.quick.visible)) {
                n += 1;
            };
            return n;
        }
        pub fn cycle(h: *Self, delta: i8) void {
            const live = storage.allocator.alloc(*Window, h.windows.len) catch return;
            defer storage.allocator.free(live);
            var n: usize = 0;
            var current: usize = 0;
            for (h.windows) |opt| if (opt) |w| if (!w.closing and (!w.transient_quick or h.services.quick.visible)) {
                if (w.id == h.active_id) current = n;
                live[n] = w;
                n += 1;
            };
            if (n > 1) h.activate(live[if (delta > 0) (current + 1) % n else (current + n - 1) % n], true);
        }
        pub fn closeWindow(h: *Self, w: *Window) void {
            if (w.closing) return;
            @import("application_theme_browser.zig").cancel(w);
            w.closing = true;
            w.window_focused = false;
            w.syncFocus();
            h.save();
            const life = h.lifetime() catch {
                w.closing = false;
                w.status = "Cannot schedule window close";
                return;
            };
            const ticket = storage.allocator.create(CloseCall) catch {
                w.closing = false;
                w.status = "Cannot schedule window close";
                return;
            };
            ticket.* = .{ .life = life, .id = w.id };
            nano.App.after(0, ticket, struct {
                fn call(data: ?*anyopaque) callconv(.c) void {
                    const close_ticket: *CloseCall = @ptrCast(@alignCast(data.?));
                    defer storage.allocator.destroy(close_ticket);
                    const host = close_ticket.life.host orelse return;
                    for (host.windows) |entry| if (entry) |state| if (state.id == close_ticket.id) {
                        if (state.window) |window| window.close() else host.retire(state);
                        return;
                    };
                }
            }.call);
        }
        pub fn retire(h: *Self, w: *Window) void {
            if (w.retired) return;
            h.services.quick.closed(w.id);
            w.retired = true;
            w.closing = true;
            w.window = null;
            w.shutting_down = true;
            for (h.windows) |*entry| if (entry.* == w) {
                entry.* = null;
                break;
            };
            w.deinit();
            h.retired.append(h.gpa, w) catch return; // keep address alive if allocation fails
            h.collectLater();
            if (h.active()) |active_window| h.activate(active_window, false) else if (h.count() == 0 and !h.demo and h.settings.window == null) h.app.quit();
        }
        fn lifetime(h: *Self) !*Collection {
            if (h.collection) |token| return token;
            const token = try h.arena.create(Collection);
            token.* = .{ .host = h };
            h.collection = token;
            return token;
        }
        pub fn collectLater(h: *Self) void {
            if (h.collect_scheduled or h.quitting) return;
            const token = h.lifetime() catch return;
            h.collect_scheduled = true;
            nano.App.after(0, token, struct {
                fn call(data: ?*anyopaque) callconv(.c) void {
                    const ticket: *Collection = @ptrCast(@alignCast(data.?));
                    const host = ticket.host orelse return;
                    host.collect_scheduled = false;
                    var i: usize = 0;
                    while (i < host.retired.items.len) {
                        const state = host.retired.items[i];
                        if (state.refs == 0) {
                            _ = host.retired.swapRemove(i);
                            host.gpa.destroy(state);
                        } else i += 1;
                    }
                }
            }.call);
        }
        pub fn save(h: *Self) void {
            if (h.demo or h.restoring or h.quitting or h.creating_quick) return;
            var temporary = std.heap.ArenaAllocator.init(h.gpa);
            defer temporary.deinit();
            const a = temporary.allocator();
            const records = a.alloc(persistence.Record, h.windows.len) catch return;
            var n: usize = 0;
            for (h.windows) |opt| if (opt) |w| if (!w.closing and !w.transient_quick and w.layout.tab_count > 0) {
                records[n] = .{ .id = w.id, .title = w.title_override, .layout = w.layout, .navigation = .{ .width = w.sidebar.width, .collapsed = w.sidebar.collapsed } };
                const files = a.alloc(persistence.File, w.preview.count()) catch return;
                var file_count: usize = 0;
                for (w.preview.documents) |entry| if (entry) |d| {
                    const tab_index = w.layout.tabIndex(d.tab_id) orelse continue;
                    if (!w.layout.isDocument(tab_index)) continue;
                    files[file_count] = .{ .tab = d.tab_id, .path = d.panel.model.path.text() };
                    file_count += 1;
                };
                records[n].files = files[0..file_count];
                if (w.window) |window| {
                    const f = window.frame();
                    const content = window.contentSize();
                    records[n].frame = .{ .x = f.x, .y = f.y, .width = content[0], .height = content[1] };
                }
                n += 1;
            };
            if (n == 0) return; // retain last useful workspace for restart
            var saved_active = records[0].id;
            for (records[0..n]) |record| if (record.id == h.active_id) {
                saved_active = record.id;
                break;
            };
            const document: persistence.Document = .{ .active = saved_active, .next_window_id = h.next_window_id, .windows = records[0..n] };
            const bytes = std.json.Stringify.valueAlloc(h.gpa, document, .{ .whitespace = .indent_2 }) catch return;
            defer h.gpa.free(bytes);
            if (c.lt_write_atomic(h.state_path, bytes.ptr, bytes.len) != 0) if (h.active()) |w| {
                w.status = "Cannot save multi-window layout";
            };
        }
        pub fn restore(h: *Self) !bool {
            const bytes = (try config.read(h.arena, h.read_path, 64 * 1024 * 1024)) orelse return false;
            const document = try persistence.decode(h.arena, bytes, h.cfg.profiles.len);
            h.restoring = true;
            defer h.restoring = false;
            errdefer for (h.windows) |opt| if (opt) |w| {
                h.retire(w);
            };
            for (document.windows) |record| {
                const w = try h.create(false);
                w.id = record.id;
                w.layout.deinit();
                w.layout = try record.layout.clone();
                w.title_override = record.title;
                w.saved_frame = record.frame;
                w.sidebar.width = record.navigation.width;
                w.sidebar.collapsed = record.navigation.collapsed;
                for (w.layout.nodes) |node| if (node.kind == .pane) try w.start(node.pane, node.profile, false);
                for (record.files) |file| try @import("application_preview.zig").restoreWorkspace(w, file.tab, file.path);
            }
            h.next_window_id = document.next_window_id;
            h.active_id = document.active;
            return h.count() > 0;
        }
        pub fn queue(h: *Self, request: actions.Request) void {
            if (request.action == .quit and !h.settings.guardQuit()) return;
            if (request.action == .quit and h.count() == 0) {
                h.quitting = true;
                h.app.quit();
                return;
            }
            if (request.action == .open_settings) {
                @import("application_settings.zig").open(h) catch |err| {
                    if (h.active()) |w| w.status = @errorName(err);
                };
                return;
            }
            if (h.settings_focused and request.action != .new_window and request.action != .quit) return;
            if (h.settings_focused and request.action == .quit and !h.app.flags.hidden) if (h.active()) |window| {
                if (window.window) |native| native.focus();
            };
            if (request.action == .new_window) {
                _ = h.create(true) catch |err| {
                    if (h.active()) |w| {
                        w.status = @errorName(err);
                    }
                };
                return;
            }
            const w = h.active() orelse {
                if (request.action == .quit) h.services.enqueue(&request) catch {};
                return;
            };
            if (w.menu_action_count < w.menu_actions.len) {
                w.menu_actions[w.menu_action_count] = request;
                w.menu_action_count += 1;
            }
            if (w.window) |window| window.redraw();
        }
        pub fn quitRequested(data: *anyopaque) bool {
            const h: *Self = @ptrCast(@alignCast(data));
            h.queue(.{ .action = .quit });
            return false;
        }
        pub fn deinit(h: *Self) void {
            h.appearance_watch.stop();
            h.quitting = true;
            h.settings.deinit();
            // Cancel before closing views and before config_arena can be freed.
            for (h.windows) |opt| if (opt) |w| @import("application_theme_browser.zig").cancel(w);
            h.services.stop();
            if (h.collection) |token| token.host = null;
            for (h.windows) |opt| if (opt) |w| {
                if (w.window) |window| {
                    w.ax.detach(); // detach before surface destruction
                    window.on_close = null;
                    window.on_close_request = null;
                    window.on_focus_changed = null;
                    // Release managed image Views/Store while TextSystem lives.
                    w.deinit();
                    window.close();
                } else w.deinit();
                w.retired = true;
                w.host_deinitialized = true;
                if (w.refs == 0) h.gpa.destroy(w);
            };
            for (h.retired.items) |w| {
                w.host_deinitialized = true;
                if (w.refs == 0) h.gpa.destroy(w);
            }
            h.retired.deinit(h.gpa);
            storage.release(?*Window, &h.windows);
            if (h.config_arena) |*a| a.deinit();
            c.lt_close(h.lock_fd);
        }
    };
}
