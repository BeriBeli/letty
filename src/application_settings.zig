//! Application-owned settings adapter. No terminal slot or PTY is allocated.
const std = @import("std");
const nano = @import("nanoui");
const ui = nano.ui;
const config = @import("config.zig");
const settings = @import("settings/window.zig");

pub fn Callbacks(comptime Host: type) type {
    return struct {
        const Anchor = struct {
            host: *Host,
            gpa: std.mem.Allocator,
            status: []const u8 = "",
            notice_buffer: [512]u8 = undefined,
            pub fn macMenu(a: *@This()) !void {
                if (a.host.active()) |window| try window.macMenu();
            }
        };
        const Transaction = @import("config_transaction.zig").Transaction(*Anchor);
        const Ticket = struct { anchor: Anchor, transaction: Transaction = undefined };
        pub fn adapter(h: *Host) settings.Host {
            return .{ .context = h, .prepare = prepare, .abort = abort, .commit = commit, .open_config = openConfig, .closed = closed };
        }
        fn owner(raw: *anyopaque) *Host {
            return @ptrCast(@alignCast(raw));
        }
        fn prepare(raw: *anyopaque, candidate: *const @import("settings/document.zig").Candidate) !*anyopaque {
            const h = owner(raw);
            if (h.quitting) return error.ApplicationClosing;
            const ticket = try h.gpa.create(Ticket);
            errdefer h.gpa.destroy(ticket);
            ticket.* = .{ .anchor = .{ .host = h, .gpa = h.gpa } };
            ticket.transaction = try Transaction.prepareBorrowed(&ticket.anchor, candidate.cfg);
            return ticket;
        }
        fn abort(raw: *anyopaque, token: *anyopaque) void {
            const h = owner(raw);
            const ticket: *Ticket = @ptrCast(@alignCast(token));
            ticket.transaction.deinit();
            h.gpa.destroy(ticket);
        }
        fn commit(raw: *anyopaque, token: *anyopaque, candidate: @import("settings/document.zig").Candidate) void {
            const h = owner(raw);
            const ticket: *Ticket = @ptrCast(@alignCast(token));
            defer h.gpa.destroy(ticket);
            // The settings callback runs synchronously outside draw, after its
            // file save. Native close/teardown cannot interleave this turn.
            const surface = h.settings.window.?.surface.?;
            ticket.transaction.adoptArena(candidate.arena);
            ticket.transaction.commit(&surface.ctx);
            if (h.active()) |window| {
                window.status = if (std.mem.startsWith(u8, ticket.anchor.status, "Configuration applied;")) "Settings saved; a terminal/menu refresh failed" else "Settings saved and applied";
            }
        }
        fn openConfig(raw: *anyopaque) !void {
            const h = owner(raw);
            if (h.app.flags.hidden or h.demo) return error.ExternalEditorDisabledForChecks;
            const window = h.active() orelse return error.NoTerminalWindow;
            const native = window.window orelse return error.NoNativeWindow;
            const surface = native.surface orelse return error.NoNativeSurface;
            @import("application_commands.zig").openConfig(window, &surface.ctx);
            if (window.confirmation.open and !h.app.flags.hidden) native.focus();
            native.redraw();
        }
        fn focusChanged(raw: *anyopaque, _: *nano.Window, focused: bool) void {
            const h = owner(raw);
            h.settings_focused = focused;
            if (focused) {
                for (h.windows) |opt| if (opt) |w| {
                    w.window_focused = false;
                    w.syncFocus();
                };
                @import("app_menu.zig").installSettings(h) catch {};
            }
        }
        fn closed(raw: *anyopaque) void {
            const h = owner(raw);
            h.settings_focused = false;
            if (h.active()) |w| w.macMenu() catch {};
            // A settings-only window close never dispatches Quit or changes
            // the persisted terminal layout. Application Quit stays explicit.
        }
    };
}

pub fn open(h: anytype) !void {
    const Host = @typeInfo(@TypeOf(h)).pointer.child;
    var arena = std.heap.ArenaAllocator.init(h.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try config.selectPath(a, h.explicit_config);
    const directory = std.fs.path.dirname(path) orelse ".";
    const executable = try std.process.executablePathAlloc(h.app.io, a);
    const bundle = try std.fs.path.join(a, &.{ std.fs.path.dirname(executable) orelse ".", if (@import("builtin").os.tag == .macos) "../Resources/config/themes" else "../config/themes" });
    const roots = [_]@import("theme_browser.zig").Root{
        .{ .directory = try std.fs.path.join(a, &.{ directory, "themes" }), .origin = .user },
        .{ .directory = bundle, .origin = .bundled },
    };
    try h.settings.open(h.gpa, h.app, Callbacks(Host).adapter(h), .{
        .path = path,
        .home = config.env("HOME"),
        .dark = h.system_dark,
        .effective = h.cfg,
        .command_override = h.command_override orelse "",
        .cwd_override = h.cwd_override orelse "",
        .profile_override = h.override_profile,
        .theme_roots = &roots,
        .diagnostic = if (h.active()) |window| window.config_diagnostic else .{},
    });
    if (h.settings.window) |window| window.on_focus_changed = .{ .ctx = h, .func = Callbacks(Host).focusChanged };
    if (!h.app.flags.hidden) {
        h.settings_focused = true;
        try @import("app_menu.zig").installSettings(h);
    }
}
