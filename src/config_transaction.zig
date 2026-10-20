//! Shared reload/save transaction. prepare/reserve/save/commit run in one main
//! loop turn, without callbacks yielding or native nested event loops.
const std = @import("std");
const builtin = @import("builtin");
const Config = @import("config.zig").Config;
const appearance = @import("appearance.zig");
const ui = @import("nanoui").ui;
const Layout = @import("layout.zig").Layout;
const Services = @import("application_services.zig");

pub fn Transaction(comptime Pointer: type) type {
    return struct {
        const Self = @This();
        source: Pointer,
        arena: ?std.heap.ArenaAllocator,
        next: Config,
        layouts: []Layout = &.{},
        selected: []u8 = &.{},
        host_profile: u8 = 0,
        services: Services.Prepared,
        live: bool = true,
        navigation_only: bool = false,

        /// Candidate borrows arena until success, then this transaction owns it.
        /// Failure leaves both the caller's arena and the active config intact.
        pub fn prepare(s: Pointer, arena: *std.heap.ArenaAllocator, candidate: Config) !Self {
            var result = try prepareBorrowed(s, candidate);
            result.arena = arena.*;
            arena.* = std.heap.ArenaAllocator.init(s.gpa);
            return result;
        }
        /// Save UIs keep their Candidate alive through checked file save; attach
        /// its arena only after save succeeds. No borrowed slice outlives it.
        pub fn prepareBorrowed(s: Pointer, candidate: Config) !Self {
            const h = s.host;
            const next = candidate.forAppearance(h.system_dark);
            try next.validate();
            var result: Self = .{ .source = s, .arena = null, .next = next, .services = undefined };
            const a = @import("dynamic_storage.zig").allocator;
            result.layouts = try a.alloc(Layout, h.windows.len);
            @memset(result.layouts, .{});
            errdefer {
                for (result.layouts) |*layout| layout.deinit();
                a.free(result.layouts);
            }
            result.selected = try a.alloc(u8, h.windows.len);
            @memset(result.selected, 0);
            errdefer a.free(result.selected);
            result.navigation_only = @import("config_equal.zig").navigationOnly(h.cfg, next);
            for (h.windows, 0..) |opt, index| if (opt) |w| {
                result.layouts[index] = try w.layout.clone();
                for (result.layouts[index].nodes) |*node| if (node.kind == .pane) {
                    const name = w.cfg.profiles[node.profile].name;
                    var found = false;
                    for (next.profiles, 0..) |profile, at| if (std.mem.eql(u8, profile.name, name)) {
                        node.profile = @intCast(at);
                        found = true;
                        break;
                    };
                    if (!found) return error.OpenProfileRemoved;
                };
                const name = w.cfg.profiles[w.profile].name;
                for (next.profiles, 0..) |profile, at| if (std.mem.eql(u8, profile.name, name)) {
                    result.selected[index] = @intCast(at);
                    break;
                };
            };
            const host_name = h.cfg.profiles[h.chosen].name;
            for (next.profiles, 0..) |profile, at| if (std.mem.eql(u8, profile.name, host_name)) {
                result.host_profile = @intCast(at);
                break;
            };
            result.services = try h.services.prepare(next);
            errdefer result.services.deinit(s.gpa);
            try h.services.reserve(&result.services);
            return result;
        }
        fn freeLayouts(self: *Self) void {
            for (self.layouts) |*layout| layout.deinit();
            @import("dynamic_storage.zig").release(Layout, &self.layouts);
            @import("dynamic_storage.zig").release(u8, &self.selected);
        }
        pub fn adoptArena(self: *Self, arena: std.heap.ArenaAllocator) void {
            std.debug.assert(self.live and self.arena == null);
            self.arena = arena;
        }
        /// Also rolls back reserved native registrations after a failed save.
        pub fn deinit(self: *Self) void {
            if (!self.live) return;
            self.live = false;
            self.freeLayouts();
            self.source.host.services.rollback();
            self.services.deinit(self.source.gpa);
            if (self.arena) |*arena| arena.deinit();
            self.arena = null;
        }
        /// No registration or config validation can fail after checked save.
        /// Renderer/menu best-effort refresh failures remain explicit notices.
        pub fn commit(self: *Self, ctx: *ui.Context) void {
            std.debug.assert(self.live and self.arena != null);
            const s = self.source;
            const h = s.host;
            const next = self.next;
            const registration = h.services.publish();
            if (self.navigation_only) {
                h.cfg.workspace_navigation = next.workspace_navigation;
                h.cfg.tab_bar = next.tab_bar;
                h.cfg.sidebar_show_git = next.sidebar_show_git;
                h.cfg.sidebar_show_ports = next.sidebar_show_ports;
                for (h.windows) |opt| if (opt) |w| {
                    w.cfg.workspace_navigation = next.workspace_navigation;
                    w.cfg.tab_bar = next.tab_bar;
                    w.cfg.sidebar_show_git = next.sidebar_show_git;
                    w.cfg.sidebar_show_ports = next.sidebar_show_ports;
                    // A live theme lease restores this pinned base on Cancel,
                    // preview changes and Apply. Keep newly committed navigation
                    // values in that base while retaining its visual ownership.
                    if (w.theme_original) |*original| {
                        original.workspace_navigation = next.workspace_navigation;
                        original.tab_bar = next.tab_bar;
                        original.sidebar_show_git = next.sidebar_show_git;
                        original.sidebar_show_ports = next.sidebar_show_ports;
                    }
                    w.drag_split = null;
                    w.drag_tab = null;
                    w.sidebar.cancel();
                    for (w.sessions) |opt_session| if (opt_session) |session| session.metadata.configure(session, next.workspace_navigation == .sidebar and next.sidebar_show_git, next.workspace_navigation == .sidebar and next.sidebar_show_ports);
                    // Navigation-only publication does not retire old config
                    // owners or clear terminal search, selection or preedit.
                    if (w.window) |window| window.redraw();
                };
                self.services.deinit(s.gpa);
                self.arena.?.deinit();
                self.arena = null;
                self.live = false;
                self.freeLayouts();
                ctx.changed = true;
                s.status = if (registration.cleanup_pending > 0) "Navigation applied; muted old shortcuts await cleanup" else "Workspace navigation applied";
                return;
            }
            for (h.windows) |opt| if (opt) |w| @import("application_theme_browser.zig").cancel(w);
            ctx.focus = 0;
            ctx.active = 0;
            ctx.input.clearEdges();
            var previous = h.config_arena;
            h.cfg = next;
            h.chosen = self.host_profile;
            h.config_arena = self.arena;
            self.arena = null;
            var refresh_warning: ?[]const u8 = null;
            h.services.adopted(self.services.geometry) catch |err| {
                refresh_warning = @errorName(err);
            };
            for (h.windows, 0..) |opt, index| if (opt) |w| {
                @import("input_dispatch.zig").cancel(w, .reload);
                w.cfg = next;
                @import("application_theme_browser.zig").releaseApplied(w);
                w.ax.sync(w);
                w.layout.deinit();
                w.layout = self.layouts[index];
                self.layouts[index] = .{};
                w.profile = self.selected[index];
                w.base_font_size = next.font_size;
                w.clearSearch();
                // Old notices may borrow profile names from the retiring
                // arena. Preserve only newly owned refresh diagnostics.
                w.status = "";
                for (w.sessions) |session| if (session) |p| w.configureSession(p);
                if (w.status.len > 0) refresh_warning = w.status;
                if (w.window) |window| {
                    const theme = appearance.theme(next);
                    if (window.surface) |surface| {
                        surface.text.setFamilies(theme.font, theme.mono_font);
                        surface.theme_override = theme;
                    }
                    if (builtin.os.tag == .macos) @import("macos_chrome.zig").configure(window, next.background);
                    window.redraw();
                }
            };
            ctx.theme = appearance.theme(next);
            ctx.text.setFamilies(ctx.theme.font, ctx.theme.mono_font);
            if (previous) |*arena| arena.deinit();
            s.status = if (registration.cleanup_pending > 0) "Reloaded; muted old shortcuts await cleanup" else "Configuration applied to all terminal windows";
            if (refresh_warning) |warning| s.status = std.fmt.bufPrint(&s.notice_buffer, "Configuration applied; refresh failed: {s}", .{warning}) catch "Configuration applied; terminal refresh failed";
            if (builtin.os.tag == .macos) s.macMenu() catch {
                s.status = "Configuration applied; menu refresh failed";
            };
            ctx.changed = true;
            self.services.deinit(s.gpa);
            self.live = false;
            self.freeLayouts();
        }
    };
}
