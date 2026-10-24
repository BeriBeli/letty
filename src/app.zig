const std = @import("std");
const builtin = @import("builtin");
const nano = @import("nanoui");
const ui = nano.ui;
const vt_api = @import("vt.zig");
const c = @import("platform_ffi.zig");
const config = @import("config.zig");
const Config = config.Config;
const appearance = @import("appearance.zig");
const bindings = @import("keybindings.zig");
const chrome = @import("chrome.zig");
const Session = @import("session.zig").Session;
const TerminalView = @import("terminal_view.zig").View;
const layout_mod = @import("layout.zig");
const Layout = layout_mod.Layout;
const storage = @import("dynamic_storage.zig");
const actions = @import("actions.zig");
const Action = actions.Action;
const Request = actions.Request;
pub const AppState = @import("app_state.zig").Host(WindowState);
pub const WindowState = struct {
    host: *AppState,
    id: u64,
    refs: usize = 0,
    host_deinitialized: bool = false,
    closing: bool = false,
    retired: bool = false,
    deinitialized: bool = false,
    title_override: []const u8 = "",
    transient_quick: bool = false,
    ax: @import("application_ax_lifecycle.zig").Runtime(WindowState) = .{},
    saved_frame: ?@import("workspace_layout.zig").Frame = null,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    app: *nano.App,
    window: ?*nano.Window = null,
    drop_bridge: ?@import("application_drop.zig").Bridge = null,
    drop_panes: []@import("application_drop.zig").Pane = &.{},
    drop_pane_count: usize = 0,
    drop_geometry_fault: bool = false,
    cfg: Config,
    config_diagnostic: config.Diagnostic = .{},
    confirmation: @import("message_dialog.zig").Dialog = .{},
    close_pending: @import("close_request.zig").Pending = .{},
    config_create_path: ?[:0]u8 = null,
    opener_watch: c_uint = 0,
    opener_target: @import("fixed_text.zig").Text(4096) = .{},
    opener_failed: bool = false,
    opener_override: ?struct { ctx: *anyopaque, call: *const fn (*anyopaque, []const u8) bool } = null,
    context_menu: @import("context_menu.zig").Menu = .{},
    link_target: @import("fixed_text.zig").Text(2048) = .{},
    /// Session that displayed link_target; file targets revalidate against it.
    link_session: u64 = 0,
    opener_is_url: bool = false,
    explicit_config: ?[]const u8 = null,
    command_override: ?[]const u8 = null,
    cwd_override: ?[]const u8 = null,
    initial_directory: @import("fixed_text.zig").Text(4096) = .{},
    override_profile: []const u8 = "",
    notice_buffer: [512]u8 = undefined,
    layout: Layout = .{},
    sidebar: @import("navigation/state.zig").State = .{},
    navigation_rects: @import("navigation/geometry.zig").Rects = .{},
    titlebar: @import("application_chrome.zig").Runtime(WindowState) = .{},
    preview: @import("application_preview.zig").Runtime(WindowState) = .{},
    sessions: []?*Session = &.{},
    views: []TerminalView = &.{},
    graphics_store: ?@import("nanoui_graphics_resources.zig").Store = null,
    profile: u8 = 0,
    base_font_size: f32 = 13,
    search_open: bool = false,
    search_focus: bool = false,
    palette: @import("command_palette.zig").Palette = .{},
    chrome_action: ?@import("rex_chrome.zig").Pending = null,
    theme_browser: @import("application_theme_browser.zig").Browser = .{},
    theme_pending: @import("application_theme_browser.zig").Intent = .none,
    theme_original: ?Config = null,
    theme_applied: ?@import("application_theme_browser.zig").Candidate = null,
    theme_lease_generation: u64 = 0,
    inspector: @import("terminal_inspector.zig").Inspector = .{},
    drag_split: ?usize = null,
    zoom: ?u64 = null,
    rename_dialog: @import("text_dialog.zig").Dialog = .{},
    rename_id: ?u64 = null,
    tab_first: usize = 0,
    drag_tab: ?u64 = null,
    drag_origin: f32 = 0,
    window_title: std.ArrayList(u8) = .empty,
    query: ui.TextBuffer,
    last_query: std.ArrayList(u8) = .empty,
    total: usize = 0,
    search_info: vt_api.SearchInfo = .{},
    search_failed: bool = false,
    state_path: [:0]const u8,
    status: []const u8 = "",
    status_feedback: @import("status_feedback.zig").Feedback = .{},
    shape_notice_seen: ?[]const u8 = null,
    binding_state: @import("binding_dispatch.zig").State = .{},
    binding_timer_pending: bool = false,
    binding_timer: @import("one_shot.zig").Handle = .{},
    binding_capabilities: actions.Capabilities = .{},
    pending: Request = .{},
    menu_actions: [32]Request = @splat(.{}),
    menu_action_count: usize = 0,
    hold: bool = false,
    smoke_ms: u64 = 0,
    osc52_pending: ?@import("application_osc52.zig").Pending = null,
    paste_session: ?u64 = null,
    paste_delivery: ?@import("clipboard_model.zig").Pending = null,
    paste_transaction: ?@import("clipboard_model.zig").Pending = null,
    clipboard_read_override: ?struct { ctx: *anyopaque, call: *const fn (*anyopaque, u64, bool) bool } = null,
    primary_write_override: ?struct { ctx: *anyopaque, call: *const fn (*anyopaque, []const u8) void } = null,
    shutting_down: bool = false,
    demo: bool = false,
    window_focused: bool = false,

    pub fn reserve(s: *WindowState, count: usize) !void {
        try storage.ensure(?*Session, &s.sessions, count, null);
        try storage.ensure(TerminalView, &s.views, s.sessions.len, .{});
        try storage.ensure(@import("application_drop.zig").Pane, &s.drop_panes, s.sessions.len + 1, .{});
    }
    pub fn start(s: *WindowState, slot: usize, profile: u8, inherit: bool) !void {
        try s.reserve(slot + 1);
        const p = s.cfg.profiles[profile];
        const shell = if (s.cfg.shell.len > 0) s.cfg.shell else std.mem.span(c.lt_default_shell());
        const shell_z = try s.gpa.dupeSentinel(u8, shell, 0);
        defer s.gpa.free(shell_z);
        const overridden = std.mem.eql(u8, p.name, s.override_profile);
        const command = if (overridden and s.command_override != null) s.command_override.? else if (p.command.len > 0) p.command else s.cfg.command;
        // Ghostty embedded.Surface.init revalidates inherited directories at
        // creation: a directory may have been removed after its OSC 7 report.
        const inherited = if (inherit and s.active() != null) s.active().?.cwd.text() else if (s.active() == null) s.initial_directory.text() else "";
        const inherited_z = try s.gpa.dupeSentinel(u8, inherited, 0);
        defer s.gpa.free(inherited_z);
        const cwd = if (p.cwd.len > 0) p.cwd else if (inherited.len > 0 and c.lt_local_directory("", inherited_z)) inherited else if (overridden and s.cwd_override != null) s.cwd_override.? else s.cfg.working_directory;
        const command_z = try s.gpa.dupeSentinel(u8, command, 0);
        defer s.gpa.free(command_z);
        const cwd_z = try s.gpa.dupeSentinel(u8, cwd, 0);
        defer s.gpa.free(cwd_z);
        if (s.host.next_session_id == std.math.maxInt(u64)) return error.SessionIdExhausted;
        const id = s.host.next_session_id;
        s.host.next_session_id += 1;
        const session = try Session.create(s.gpa, s.app.io, id, shell_z, command_z, cwd_z, s.cfg.shell_integration == .detect, s.cfg.scrollback_lines, s.cfg.scrollback_bytes, s, changed);
        s.sessions[slot] = session;
        s.configureSession(session);
    }
    pub fn configureSession(s: *WindowState, session: *Session) void {
        session.metadata.configure(session, s.cfg.sidebar_show_git, s.cfg.sidebar_show_ports);
        if (s.drop_bridge) |*drop| drop.invalidateGeometry();
        vt_api.lt_vt_colors(session.vt, s.cfg.foreground, s.cfg.background);
        var palette: [16]u32 = undefined;
        for (s.cfg.palette, 0..) |rgb, i| palette[i] = rgb;
        vt_api.lt_vt_palette(session.vt, &palette, s.cfg.cursor);
        if (vt_api.lt_vt_settings(session.vt, @intCast(@backingInt(s.cfg.cursor_style)), s.cfg.cursor_blink, s.cfg.scrollback_lines, s.cfg.scrollback_bytes) != 0) s.status = "Could not apply terminal settings";
        vt_api.configureGraphics(session.vt, s.cfg.kitty_graphics) catch |err| {
            s.status = @errorName(err);
        };
        if (!s.cfg.kitty_graphics) for (s.views) |*view_state| view_state.graphics.deactivate();
        vt_api.configureClipboardWrite(session.vt, s.cfg.clipboard_write) catch |err| {
            s.status = @errorName(err);
        };
    }
    fn reloadConfig(s: *WindowState, ctx: *ui.Context) void {
        @import("config_reload.zig").reload(s, ctx);
    }

    fn changed(ctx: ?*anyopaque, id: u64) void {
        const s: *WindowState = @ptrCast(@alignCast(ctx.?));
        for (s.sessions, 0..) |opt, i| if (opt) |session| {
            if (session.id != id) continue;
            if (session.fatal) s.status = "PTY/queue error; close this pane and collect stderr";
            if ((if (s.zoom != null) i == s.layout.active_pane else s.layout.visible(@intCast(i))) or session.feedback_changed or session.eof and session.status != null) if (s.window) |w| w.redraw();
            break;
        };
    }
    pub fn add(s: *WindowState, kind: Action) !void {
        var slot: ?usize = null;
        for (s.sessions, 0..) |p, i| if (p == null) {
            slot = @intCast(i);
            break;
        };
        const at = slot orelse s.sessions.len;
        try s.reserve(at + 1);
        var next = try s.layout.clone();
        errdefer next.deinit();
        if (kind == .tab) try next.newTab(at, s.profile) else if (kind == .split_left or kind == .split_up)
            try next.splitBefore(at, s.profile, if (kind == .split_left) .horizontal else .vertical)
        else
            try next.split(at, s.profile, if (kind == .horizontal) .horizontal else .vertical);
        try s.start(at, s.profile, if (kind == .tab) s.cfg.tab_inherit_working_directory else s.cfg.split_inherit_working_directory);
        s.layout.deinit();
        s.layout = next;
        s.sidebar.focused = false;
        s.zoom = null;
        s.clearSearch();
        s.save();
    }
    pub fn clearSearch(s: *WindowState) void {
        if (s.drop_bridge) |*drop| drop.invalidateGeometry();
        for (s.sessions) |p| if (p) |session| vt_api.lt_vt_search_close(session.vt);
        s.last_query.clearRetainingCapacity();
        s.total = 0;
        s.search_info = .{};
        s.search_failed = false;
    }
    pub fn close(s: *WindowState, slot: usize) void {
        if (!s.shutting_down and !s.closing and !s.deinitialized) for (s.layout.roots[0..s.layout.tab_count], 0..) |root, index| {
            if (s.layout.contains(root, @intCast(slot)) and @import("application_preview_edit.zig").blocked(s, s.layout.tabs[index].id)) return;
        };
        s.zoom = null;
        if (s.sessions[slot]) |p| {
            if (s.inspector.target == p.id) s.inspector.invalidate();
            p.destroy();
        }
        s.sessions[slot] = null;
        s.views[slot].deinit(s.gpa);
        s.views[slot] = .{};
        s.layout.close(slot);
        s.preview.prune(s);
        s.clearSearch();
        if (s.layout.tab_count == 0) s.host.closeWindow(s) else s.save();
    }
    pub fn save(s: *WindowState) void {
        s.host.save();
    }
    pub fn active(s: *WindowState) ?*Session {
        if (s.layout.tab_count == 0 or s.layout.isDocument(s.layout.active_tab)) return null;
        return s.sessions[s.layout.active_pane];
    }
    pub fn perform(s: *WindowState, ctx: *ui.Context) void {
        s.navigation_rects = s.navigationGeometry(ctx.size.w, ctx.size.h);
        const request = s.pending;
        s.pending = .{};
        const action = request.action;
        const amount = request.amount();
        if (!s.modalOpen() and @import("application_preview.zig").handle(s, ctx, request)) return;
        if (@import("application_preview.zig").blocksAction(s, action)) return;
        if (s.capabilities(ctx).disabled(request)) |reason| {
            s.status = reason;
            s.status_feedback.condition = request;
            s.status_feedback.condition_text = reason;
            return;
        }
        if (s.theme_browser.open and action != .none and action != .open_theme_browser) {
            switch (action) {
                .reload, .close, .close_tab, .close_other_tabs, .close_window, .quit => @import("application_theme_browser.zig").cancel(s),
                else => {
                    s.status = "Finish or cancel the theme browser first";
                    return;
                },
            }
        }
        if (action != .none and (s.rename_dialog.open or s.confirmation.open or (s.inspector.open and action != .inspector))) {
            s.status = "Finish or cancel the current prompt first";
            return;
        }
        if (action != .none and action != .palette and s.palette.open) s.palette.dismiss(ctx);
        if (@import("application_commands.zig").handle(s, ctx, request)) return;
        switch (action) {
            .open_file_workspace, .move_preview_to_workspace, .open_file_preview, .preview_selected_path, .close_file_preview, .toggle_file_preview, .refresh_file_preview => {},
            .open_settings => @import("application_settings.zig").open(s.host) catch |err| {
                s.status = @errorName(err);
            },
            .toggle_sidebar => {
                s.sidebar.toggle();
                s.save();
            },
            .toggle_tab_pin => if (s.layout.tab_count > 0) {
                s.layout.togglePin(s.layout.tabs[s.layout.active_tab].id);
                s.save();
            },
            .open_theme_browser => @import("application_theme_browser.zig").open(s, ctx, .{}),
            .send_bytes => {
                if (request.args != .bytes) {
                    s.status = "Missing byte payload";
                    return;
                }
                if (s.active()) |session| if (!session.send(request.args.bytes.bytes())) {
                    s.status = "Input queue busy; byte action not sent";
                };
            },
            .toggle_quick_terminal => s.host.services.toggleQuick() catch |err| {
                s.status = @errorName(err);
            },
            .new_window => {
                _ = s.host.create(!s.demo) catch |err| {
                    s.status = @errorName(err);
                };
            },
            .next_window => s.host.cycle(1),
            .previous_window => s.host.cycle(-1),
            .prompt_previous, .prompt_next => if (s.active()) |session| {
                vt_api.lt_vt_prompt_jump(session.vt, if (action == .prompt_previous) -1 else 1);
                ctx.changed = true;
            },
            .close_other_tabs, .open_config, .diagnostics, .inspector, .search_selection, .open_link, .copy_link => unreachable,
            .scroll_top, .scroll_bottom, .page_up, .page_down, .select_all, .clear_screen, .reset => if (s.active()) |session| {
                switch (action) {
                    .scroll_top => vt_api.lt_vt_scroll_to(session.vt, 0),
                    .scroll_bottom => vt_api.lt_vt_bottom(session.vt),
                    .page_up, .page_down => vt_api.lt_vt_scroll(session.vt, (if (action == .page_up) @as(c_int, -1) else 1) * @as(c_int, @max(1, session.rows - 1))),
                    .select_all => {
                        if (vt_api.lt_vt_select_all(session.vt) != 0) s.status = "No selectable terminal text";
                    },
                    .clear_screen => {
                        session.clearScreen() catch |err| {
                            s.status = if (err == error.InputQueueBusy) "Input queue busy; clear screen was not applied" else "Clear screen is unavailable for this terminal";
                        };
                    },
                    .reset => {
                        s.clearSearch();
                        s.search_open = false;
                        vt_api.lt_vt_reset(session.vt);
                        s.configureSession(session);
                    },
                    else => unreachable,
                }
                ctx.changed = true;
            },
            .search_next, .search_previous => if (s.active()) |session| {
                vt_api.lt_vt_search_next(session.vt, action == .search_previous);
                s.search_focus = true;
                ctx.changed = true;
            },
            .end_search => {
                s.search_open = false;
                s.clearSearch();
                ctx.focus = 0;
            },
            .none, .unbind, .ignore => {},
            .palette => {
                s.link_target.set("");
                s.palette.toggle(ctx);
                s.drag_split = null;
                if (s.palette.open) {
                    s.search_open = false;
                    s.clearSearch();
                }
            },
            .reload => s.reloadConfig(ctx),
            .goto_tab => if (s.layout.tab_count > 0) {
                s.activateTab(@intCast(request.index() - 1));
            },
            .next_profile => {
                s.profile = @intCast((s.profile + 1) % s.cfg.profiles.len);
                s.status = s.cfg.profiles[s.profile].name;
            },
            .tab, .horizontal, .vertical, .split_left, .split_up => s.add(action) catch |err| {
                std.debug.print("Session action failed: {s}\n", .{@errorName(err)});
                s.status = "Could not start a terminal session; system resources may be exhausted. See the application log.";
            },
            .close => s.close(s.layout.active_pane),
            .close_window, .quit => unreachable,
            .close_tab => {
                const root = s.layout.roots[s.layout.active_tab];
                const slots = storage.allocator.alloc(usize, s.sessions.len) catch {
                    s.status = "Cannot allocate close request";
                    return;
                };
                defer storage.allocator.free(slots);
                var count: usize = 0;
                for (s.sessions, 0..) |p, slot| if (p != null and s.layout.contains(root, @intCast(slot))) {
                    slots[count] = @intCast(slot);
                    count += 1;
                };
                for (slots[0..count]) |slot| s.close(slot);
            },
            .font_up => s.cfg.font_size = @min(96, s.cfg.font_size + amount),
            .font_down => s.cfg.font_size = @max(8, s.cfg.font_size - amount),
            .font_reset => s.cfg.font_size = s.base_font_size,
            .copy => if (s.active()) |p| {
                if (!TerminalView.copy(p, ctx)) s.status = "No selection, or selection exceeds 1 MiB";
            },
            .paste, .paste_primary => @import("clipboard.zig").request(s, ctx, action == .paste_primary),
            .search => {
                s.search_open = !s.search_open;
                s.search_focus = s.search_open;
                if (!s.search_open) {
                    s.clearSearch();
                    ctx.focus = 0;
                }
            },
            .save => {
                s.save();
                s.status = "Layout saved; restore creates fresh sessions";
            },
            .next_tab, .previous_tab => if (s.layout.tab_count > 0) {
                s.activateTab(@intCast((@as(usize, s.layout.active_tab) + s.layout.tab_count + (if (action == .next_tab) @as(usize, 1) else s.layout.tab_count - 1)) % s.layout.tab_count));
            },
            .next_pane, .previous_pane => {
                const old = s.layout.active_pane;
                s.layout.cyclePane(action == .previous_pane);
                const next = s.layout.active_pane;
                s.layout.active_pane = old;
                s.focusPane(next);
            },
            .focus_pane => if (s.layout.neighbor(request.normalized().args.direction, s.navigation_rects.content.w, s.navigation_rects.content.h)) |slot| s.focusPane(slot),
            .toggle_zoom => {
                s.zoom = if (s.zoom == null) s.active().?.id else null;
            },
            .equalize => {
                s.layout.equalize(s.navigation_rects.content.w, s.navigation_rects.content.h, s.cfg.font_size * 4, s.cfg.font_size * 2);
                s.save();
            },
            .resize_pane => {
                const arg = request.normalized().args.resize;
                _ = s.layout.resize(arg.direction, arg.pixels, s.navigation_rects.content.w, s.navigation_rects.content.h, s.cfg.font_size * 4, s.cfg.font_size * 2);
                s.save();
            },
            .move_tab => {
                const count_tabs: isize = @intCast(s.layout.tab_count);
                const target: usize = @intCast(@mod(@as(isize, @intCast(s.layout.active_tab)) + @mod(request.normalized().args.offset, count_tabs), count_tabs));
                s.layout.move(s.layout.active_tab, target);
                s.save();
            },
            .rename_tab => {
                const tab = &s.layout.tabs[s.layout.active_tab];
                s.rename_id = tab.id;
                s.sidebar.collapsed = false;
                s.rename_dialog.show(ctx, tab.name());
            },
        }
    }
    pub fn capabilities(s: *WindowState, ctx: *ui.Context) actions.Capabilities {
        const content = s.navigationGeometry(ctx.size.w, ctx.size.h).content;
        var result: actions.Capabilities = .{ .tabs = s.layout.tab_count, .profiles = s.cfg.profiles.len, .searching = s.search_open };
        for (s.sessions, 0..) |p, slot| if (p != null) {
            result.total_panes += 1;
            if (s.layout.visible(@intCast(slot))) result.panes += 1;
        };
        for ([_]actions.Direction{ .left, .right, .up, .down }) |direction| {
            result.neighbors[@backingInt(direction)] = s.layout.neighbor(direction, content.w, content.h) != null;
        }
        result.total_panes = s.host.paneCount();
        result.windows = s.host.count();
        result.visible_windows = s.host.visibleCount();
        result.document_workspace = s.layout.isDocument(s.layout.active_tab);
        result.sidebar = true;
        result.preview = s.preview.active(if (s.layout.tab_count > 0) s.layout.tabs[s.layout.active_tab].id else 0) != null;
        if (@import("application_preview.zig").focused(s)) {
            result.selection = true;
            if (s.preview.active(s.layout.tabs[s.layout.active_tab].id)) |d| result.searching = d.panel.show_find;
        }
        result.primary = builtin.os.tag == .linux or s.clipboard_read_override != null;
        result.link = @import("terminal_paths.zig").classify(s.link_target.text(), true) != .none or @import("terminal_paths.zig").isPath(s.link_target.text());
        if (s.active()) |session| {
            result.selection = result.selection or vt_api.lt_vt_has_selection(session.vt);
            result.prompts = session.events.prompts > 0;
            var scroll: vt_api.Scroll = .{};
            vt_api.lt_vt_scroll_info(session.vt, &scroll);
            result.alternate = scroll.alternate;
        }
        return result;
    }
    pub fn navigationGeometry(s: *WindowState, width: f32, height: f32) @import("navigation/geometry.zig").Rects {
        // Auto keeps workspace controls discoverable even with one tab. An
        // explicit never setting still opts out of the top navigation strip.
        const top = s.cfg.tab_bar != .never;
        var rects = @import("navigation/geometry.zig").compute(width, height, .sidebar, top, s.sidebar.width, s.sidebar.collapsed);
        const content = s.preview.geometry(if (s.layout.tab_count > 0) s.layout.tabs[s.layout.active_tab].id else 0, .{ .x = rects.content.x, .y = rects.content.y, .w = rects.content.w, .h = rects.content.h });
        rects.content = .{ .x = content.x, .y = content.y, .w = content.w, .h = content.h };
        return rects;
    }
    pub fn macMenu(s: *WindowState) !void {
        try @import("app_menu.zig").install(s);
    }
    fn shortcuts(s: *WindowState, ctx: *ui.Context) void {
        @import("input_dispatch.zig").shortcuts(s, ctx);
    }
    pub fn view(s: *WindowState, ctx: *ui.Context) void {
        if (s.closing) return;
        @import("bundled_fonts.zig").install(ctx.text);
        s.titlebar.drain(s, ctx);
        @import("rex_chrome.zig").drain(s, ctx);
        if (s.palette.chosen_tab != 0) {
            const chosen = s.palette.chosen_tab;
            s.palette.chosen_tab = 0;
            if (s.layout.tabIndex(chosen)) |at| s.activateTab(at);
        }
        @import("window_chrome.zig").layout(s.window, ctx.size.h);
        @import("application_preview.zig").process(s, ctx);
        if (s.preview.pending_picker) {
            s.preview.pending_picker = false;
            @import("application_preview.zig").picker(s, ctx);
        }
        s.status_feedback.update(s, ctx);
        s.ax.begin(s, ctx);
        if (s.closing) return;
        s.host.services.drainWindow(s, ctx);
        if (s.closing) return;
        const count = s.menu_action_count;
        s.menu_action_count = 0;
        for (s.menu_actions[0..count]) |action| {
            s.pending = action;
            s.perform(ctx);
        }
        if (s.opener_failed) {
            s.opener_failed = false;
            @import("application_commands.zig").showOpenerFailure(s, ctx, s.opener_target.text(), "xdg-open exited with an error");
        }
        s.navigation_rects = s.navigationGeometry(ctx.size.w, ctx.size.h);
        const document_input = @import("application_preview.zig").prepareInput(s, ctx);
        const navigation_consumed = @import("navigation/sidebar.zig").input(s, ctx);
        if (!navigation_consumed) s.shortcuts(ctx);
        s.perform(ctx);
        s.status_feedback.update(s, ctx);
        @import("application_theme_browser.zig").process(s, ctx);
        @import("clipboard.zig").process(s, ctx);
        @import("application_osc52.zig").process(s, ctx);
        // EOF is drained before removing the session; hidden tabs obey the same lifecycle.
        if (!s.hold and !s.demo) for (s.sessions, 0..) |p, slot| if (p) |session| {
            if (session.eof and session.status != null) {
                s.close(@intCast(slot));
                ctx.changed = true;
                break;
            }
        };
        _ = @import("application_drop.zig").drain(s, ctx);
        s.drop_pane_count = 0;
        s.drop_geometry_fault = false;
        ctx.theme = appearance.theme(s.cfg);
        ctx.text.setFamilies(ctx.theme.font, ctx.theme.mono_font);
        ctx.node(0).style.background = ctx.theme.background;
        ui.column(ctx, .{ .width = .fill, .height = .fill, .background = ui.Color.hex(s.cfg.background) });
        @import("rex_chrome.zig").backdrop(ctx, s.cfg.ui_background);
        defer ui.end(ctx);
        s.navigation_rects = s.navigationGeometry(ctx.size.w, ctx.size.h);
        const content = s.navigation_rects.content;
        const top = content.y;
        if (s.search_open) @import("search_overlay.zig").update(s, ctx);
        const context_was_open = s.context_menu.open;
        const modal_input = ctx.input;
        @import("application_preview.zig").draw(s, ctx);
        // A terminal drag that started in a pane must also receive its release,
        // even over the dock; otherwise selection or a mouse report stays open.
        const terminal_drag = for (s.views) |v| {
            if (v.selecting) break true;
        } else false;
        const over_preview = s.preview.rect.contains(ctx.input.mouse);
        const preview_consumed = !terminal_drag and (document_input or @import("application_preview.zig").focused(s) or s.preview.resizing or (over_preview and (ctx.input.pressed or ctx.input.released or ctx.input.scroll.x != 0 or ctx.input.scroll.y != 0)));
        // Document keyboard focus still lets panes under the pointer hover links
        // and scroll; keys, text, IME and button edges never reach a PTY.
        const pointer_only = preview_consumed and !over_preview and !s.preview.resizing and !ctx.input.pressed and !ctx.input.released;
        if (s.modalOpen()) ctx.input = .{};
        s.updateTitle();
        const terminal_input = ctx.input;
        if (preview_consumed) ctx.input = if (pointer_only) .{ .mouse = terminal_input.mouse, .scroll = terminal_input.scroll, .scroll_lines = terminal_input.scroll_lines, .scroll_started = terminal_input.scroll_started, .shift = terminal_input.shift, .cmd = terminal_input.cmd, .ctrl = terminal_input.ctrl, .alt = terminal_input.alt } else .{};
        if (s.layout.tab_count > 0 and content.w > 1 and content.h > 1) s.pane(ctx, if (s.zoom != null) s.layout.findPane(s.layout.active_pane).? else s.layout.roots[s.layout.active_tab], .{ .x = content.x, .y = content.y, .w = @max(1, content.w), .h = @max(1, content.h) });
        if (preview_consumed) ctx.input = terminal_input;
        @import("navigation/sidebar.zig").draw(s, ctx);
        for (s.views, 0..) |*view_state, slot| {
            const visible = s.layout.visible(@intCast(slot)) and (s.zoom == null or s.layout.active_pane == slot);
            if (!visible or !s.cfg.kitty_graphics) view_state.graphics.deactivate();
        }
        if (s.search_open and content.w > 1) {
            const search_input = ctx.input;
            const preview_find_focused = @import("application_preview.zig").focused(s);
            if (preview_find_focused) {
                ctx.input = .{};
                s.search_focus = false;
            }
            s.searchBar(ctx, top);
            if (preview_find_focused) ctx.input = search_input;
        }
        if (s.status.len > 0) {
            ui.key(ctx, "notice");
            // A full-width document leaves no terminal area; span the workspace
            // instead of collapsing the notice into a sliver.
            const area: ui.Rect = if (content.w >= 240) .{ .x = content.x, .y = content.y, .w = content.w, .h = content.h } else s.preview.base;
            const notice_w = @max(1, @min(ctx.text.layout(s.status, .{ .size = 13 }).width + 64, area.w - 32));
            ui.row(ctx, .{ .absolute = true, .offset = .{ .x = area.x + (area.w - notice_w) / 2, .y = @max(area.y, ctx.size.h - 56) }, .width = .{ .px = notice_w }, .height = .{ .px = 36 }, .padding = .xy(10, 4), .gap = 8, .radius = 12, .border = ctx.theme.border, .background = ctx.theme.surface, .shadow = .{ .color = ui.Color.black.alpha(0.12), .blur = 12, .y = 4 }, .align_items = .center, .clip = true });
            ui.text(ctx, chrome.ellipsize(ctx, s.status, @max(1, notice_w - 60), 12), .{ .size = 12 });
            ui.spacer(ctx);
            if (chrome.iconButton(ctx, .close, 24)) s.status = "";
            ui.end(ctx);
        }
        if (s.palette.open) {
            ctx.input = modal_input;
            if (s.palette.drawWorkspaces(ctx, s.cfg.keybinds, s.cfg.clear_default_keybinds, s.capabilities(ctx), s.sidebar.snapshot.rows[0..s.sidebar.snapshot.count])) |action| s.pending = action;
        }
        if (s.theme_browser.open) {
            ctx.input = modal_input;
            @import("application_theme_browser.zig").draw(s, ctx);
        }
        if (s.rename_dialog.open) {
            ctx.input = modal_input;
            s.rename_dialog.inline_rect = null;
            if (s.rename_id) |id| if (s.layout.tabIndex(id)) |index| if (s.navigation_rects.compact == null) {
                s.sidebar.reveal(index, s.navigation_rects.navigation);
                const row = s.sidebar.rowRect(index, s.navigation_rects.navigation);
                s.rename_dialog.inline_rect = .{ .x = row.x + 5, .y = row.y + 3, .w = @max(1, row.w - 10), .h = 28 };
            };
            if (s.rename_id == null or s.layout.tabIndex(s.rename_id.?) == null) {
                s.rename_dialog.dismiss(ctx);
                s.rename_id = null;
            } else switch (s.rename_dialog.draw(ctx, "Rename Tab", "Rename")) {
                .none => {},
                .cancel => s.rename_id = null,
                .submit => {
                    s.layout.rename(s.rename_id.?, s.rename_dialog.text.text()) catch {
                        s.status = "Tab title must be valid text, at most 128 bytes";
                        return;
                    };
                    s.rename_dialog.dismiss(ctx);
                    s.rename_id = null;
                    s.save();
                },
            }
        }
        if (s.context_menu.open) {
            if (context_was_open) ctx.input = modal_input;
            const target = s.context_menu.target;
            const kind = s.context_menu.kind;
            if (s.context_menu.draw(ctx, s.cfg.keybinds, s.cfg.clear_default_keybinds, s.capabilities(ctx))) |request| {
                s.link_target.set(s.context_menu.link.text());
                if (s.resolveContext(kind, target)) s.pending = request else s.status = "The target terminal or tab has closed";
            }
        }
        if (s.confirmation.open) {
            ctx.input = modal_input;
            @import("application_commands.zig").resolveDialog(s, ctx);
        }
        if (s.inspector.open) {
            ctx.input = modal_input;
            s.inspector.draw(ctx);
        }
        if (s.preview.active(if (s.layout.tab_count > 0) s.layout.tabs[s.layout.active_tab].id else 0)) |d| if (!s.preview.dockFor(d.tab_id).collapsed and s.preview.rect.w > 0 and s.preview.rect.h > 0 and s.drop_pane_count < s.drop_panes.len) {
            const r = s.preview.rect;
            s.drop_panes[s.drop_pane_count] = .{ .document = d.id, .rect = .{ .x = r.x, .y = r.y, .width = r.w, .height = r.h } };
            s.drop_pane_count += 1;
        };
        if (s.drop_bridge) |*drop| {
            if (s.drop_geometry_fault) drop.invalidateGeometry() else {
                drop.publish(s.drop_panes[0..s.drop_pane_count], s.modalOpen()) catch drop.invalidateGeometry();
            }
            drop.setViewSize(ctx.size.w, ctx.size.h);
        }
        s.syncFocus();
        if (s.pending.action != .none) ctx.frameIn(0.001);
        // Native preview only: Linux uses readiness sources, never an idle polling timer.
        if (builtin.os.tag == .macos) for (s.sessions) |p| if (p) |session| {
            if (session.tx.len > 0) {
                session.flush();
                ctx.frameIn(0.016);
            }
        };
    }
    pub fn syncFocus(s: *WindowState) void {
        const focused = !s.layout.isDocument(s.layout.active_tab) and s.window_focused and !s.modalOpen() and !s.search_open and !s.sidebar.focused and !@import("application_preview.zig").focused(s);
        if (!focused) @import("input_dispatch.zig").cancel(s, if (!s.window_focused) .focus_lost else .modal);
        // Retire the old recipient before granting the new one focus.
        for (s.sessions, 0..) |opt, slot| if (opt) |session| {
            session.metadata.setFocus(focused and slot == s.layout.active_pane);
            if (!focused or slot != s.layout.active_pane) session.reportFocus(false);
        };
        if (focused) if (s.active()) |session| {
            session.reportFocus(true);
            session.attention = .none;
        };
    }
    pub fn windowFocusChanged(data: *anyopaque, window: *nano.Window, focused: bool) void {
        const s: *WindowState = @ptrCast(@alignCast(data));
        s.window_focused = focused;
        if (focused and !s.closing) s.host.activate(s, false);
        if (!focused) {
            s.drag_split = null;
            s.drag_tab = null;
            for (s.views) |*v| {
                v.selecting = false;
                v.preedit.clearRetainingCapacity();
            }
        }
        s.syncFocus();
        s.host.services.quick.focusChanged(s.host, s.id, focused);
        window.redraw();
    }
    pub fn modalOpen(s: *WindowState) bool {
        return s.palette.open or s.inspector.open or s.rename_dialog.open or s.confirmation.open or s.context_menu.open or s.theme_browser.open;
    }
    pub fn openContext(s: *WindowState, ctx: *ui.Context, kind: @import("context_menu.zig").Kind, target: u64) void {
        s.views[s.layout.active_pane].selecting = false;
        s.views[s.layout.active_pane].preedit.clearRetainingCapacity();
        s.context_menu.show(ctx, kind, target);
        if (kind == .terminal) s.context_menu.link.set(s.link_target.text());
        s.search_open = false;
        s.clearSearch();
        s.drag_split = null;
        s.drag_tab = null;
    }
    fn resolveContext(s: *WindowState, kind: @import("context_menu.zig").Kind, target: u64) bool {
        if (kind == .tab) {
            if (s.layout.tabIndex(target)) |tab| {
                s.activateTab(tab);
                return true;
            }
        } else for (s.sessions, 0..) |opt, slot| if (opt) |session| if (session.id == target) {
            for (s.layout.roots[0..s.layout.tab_count], 0..) |root, tab| if (s.layout.contains(root, @intCast(slot))) {
                s.activateTab(@intCast(tab));
                s.focusPane(@intCast(slot));
                return true;
            };
        };
        return false;
    }
    pub fn windowCloseRequested(data: *anyopaque, window: *nano.Window) bool {
        const s: *WindowState = @ptrCast(@alignCast(data));
        if (s.menu_action_count < s.menu_actions.len) {
            s.menu_actions[s.menu_action_count] = .{ .action = .close_window };
            s.menu_action_count += 1;
        }
        window.redraw();
        return false;
    }
    fn windowClosed(data: *anyopaque, _: *nano.Window) void {
        const s: *WindowState = @ptrCast(@alignCast(data));
        @import("application_drop.zig").detach(s);
        s.ax.detach(); // native view/surface still alive in on_close
        s.titlebar.detach();
        s.window = null;
        s.host.retire(s);
    }
    pub fn label(s: *WindowState, slot: usize) []const u8 {
        if (s.sessions[slot]) |session| return @import("terminal_title.zig").automatic(
            session.title[0..session.title_len],
            session.cwd.text(),
            std.mem.span(c.lt_env("HOME")),
            session.initial_title.text(),
        );
        return "Terminal";
    }
    fn updateTitle(s: *WindowState) void {
        if (s.layout.tab_count == 0 or s.window == null) return;
        const title = if (s.title_override.len > 0) s.title_override else s.tabLabel(s.layout.active_tab);
        if (std.mem.eql(u8, title, s.window_title.items)) return;
        s.window_title.clearRetainingCapacity();
        s.window_title.appendSlice(s.gpa, title) catch return;
        if (s.window) |w| w.setTitle(title);
    }
    pub fn tabLabel(s: *WindowState, tab: usize) []const u8 {
        const name = s.layout.tabs[tab].name();
        if (name.len > 0) return name;
        if (s.layout.isDocument(tab)) {
            if (s.preview.active(s.layout.tabs[tab].id)) |d| return std.fs.path.basename(d.panel.model.path.text());
            return "File";
        }
        return s.label(s.layout.tabs[tab].focused);
    }
    pub fn focusPane(s: *WindowState, slot: usize) void {
        if (s.drop_bridge) |*drop| drop.invalidateGeometry();
        if (slot == s.layout.active_pane) return;
        s.views[s.layout.active_pane].selecting = false;
        s.views[s.layout.active_pane].preedit.clearRetainingCapacity();
        s.layout.focus(slot);
        if (s.zoom != null) s.zoom = s.sessions[slot].?.id;
        s.clearSearch();
        s.save();
    }
    pub fn activateTab(s: *WindowState, tab: usize) void {
        if (tab >= s.layout.tab_count) return;
        if (tab == s.layout.active_tab) return;
        if (s.drop_bridge) |*drop| drop.invalidateGeometry();
        s.views[s.layout.active_pane].selecting = false;
        s.views[s.layout.active_pane].preedit.clearRetainingCapacity();
        s.layout.activate(tab);
        if (s.layout.isDocument(tab)) if (s.preview.active(s.layout.tabs[tab].id)) |d| {
            d.panel.focused = true;
            s.preview.pending_focus = d.id;
        };
        s.zoom = null;
        s.drag_split = null;
        s.clearSearch();
        s.save();
    }
    fn searchBar(s: *WindowState, ctx: *ui.Context, top: f32) void {
        @import("search_overlay.zig").draw(s, ctx, top);
    }
    fn pane(s: *WindowState, ctx: *ui.Context, index: usize, rect: ui.Rect) void {
        @import("workspace_view.zig").draw(s, ctx, index, rect);
    }
    pub fn retain(s: *WindowState) void {
        s.refs += 1;
    }
    pub fn release(s: *WindowState) void {
        s.refs -= 1;
        if (s.host_deinitialized) {
            if (s.refs == 0) s.gpa.destroy(s);
            return;
        }
        if (s.retired) s.host.collectLater();
    }
    pub fn attach(s: *WindowState, saved: ?@import("workspace_layout.zig").Frame) !void {
        return s.attachVisible(saved, true);
    }
    pub fn attachVisible(s: *WindowState, saved: ?@import("workspace_layout.zig").Frame, visible: bool) !void {
        const f: @import("workspace_layout.zig").Frame = saved orelse .{};
        s.window = try s.app.newWindow(.{ .visible = visible, .title_bar = .hidden, .title = "Letty", .width = f.width, .height = f.height, .min_width = 480, .min_height = 240, .on_focus_changed = .{ .ctx = s, .func = windowFocusChanged }, .on_close_request = .{ .ctx = s, .func = windowCloseRequested }, .on_close = .{ .ctx = s, .func = windowClosed }, .theme = appearance.theme(s.cfg), .content = .{ .view = .init(s, view) } });
        @import("window_chrome.zig").configure(s.window.?);
        if (builtin.os.tag == .macos or builtin.os.tag == .linux) if (s.window.?.surface) |surface| {
            const host: *anyopaque = if (builtin.os.tag == .macos) @ptrCast(surface.nsview) else @ptrCast(surface.area);
            @import("application_drop.zig").attach(host, s) catch {
                s.status = "Native file drop unavailable";
            };
            s.window.?.redraw(); // First complete geometry publication after attach.
        };
        errdefer @import("application_drop.zig").detach(s);
        s.ax.sync(s);
        if (saved != null) s.window.?.setPosition(f.x, f.y);
        if (builtin.os.tag == .macos) {
            @import("macos_chrome.zig").configure(s.window.?, s.cfg.background);
            try s.macMenu();
        }
    }
    pub fn deinit(s: *WindowState) void {
        s.titlebar.detach();
        s.ax.detach();
        if (s.deinitialized) return;
        // Suppress native/VT refresh while cancelling before any owners die.
        s.shutting_down = true;
        s.status_feedback.deinit();
        @import("application_theme_browser.zig").deinit(s);
        @import("application_drop.zig").detach(s);
        s.deinitialized = true;
        @import("input_dispatch.zig").cancel(s, .reload);
        @import("application_osc52.zig").deinit(s);
        if (s.paste_delivery) |pending| s.gpa.free(pending.bytes);
        if (s.paste_transaction) |pending| s.gpa.free(pending.bytes);
        if (s.opener_watch != 0) c.lt_unwatch(s.opener_watch);
        if (s.config_create_path) |path| s.gpa.free(path);
        s.preview.deinit(s);
        for (s.sessions) |p| if (p) |session| session.destroy();
        for (s.views) |*v| v.deinit(s.gpa);
        if (s.graphics_store) |*store| store.deinit();
        s.graphics_store = null;
        s.layout.deinit();
        s.sidebar.deinit();
        s.close_pending.deinit();
        storage.release(?*Session, &s.sessions);
        storage.release(TerminalView, &s.views);
        storage.release(@import("application_drop.zig").Pane, &s.drop_panes);
        s.last_query.deinit(s.gpa);
        s.window_title.deinit(s.gpa);
    }
};
extern "c" fn lt_mkdirs([*:0]const u8) c_int;
pub fn main(init: std.process.Init) !void {
    const startup_start = c.lt_millis();
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    c.lt_launch_context(args.len);
    var cfg_path: ?[]const u8 = null;
    var profile: ?[]const u8 = null;
    var command: ?[]const u8 = null;
    var cwd: ?[]const u8 = null;
    var no_restore = false;
    var ui_checks = false;
    var feature_checks: ?@import("feature_checks.zig").Batch = null;
    var font_checks = false;
    var window_perf: ?usize = null;
    var cpu_damage_panes: u8 = 0;
    var perf_panes: u8 = 0;
    var memory_checks = false;
    var stability_cycles: u16 = 0;
    var check_config = false;
    var hold = false;
    var smoke_ms: u64 = 0;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("Letty 0.2.3\n--config=FILE --check-config --profile=NAME --command=COMMAND --cwd=DIR --no-restore --hold --smoke-ms=N\nCtrl+Shift: T tab, D split columns, E split rows, W close, N new window, ]/[ cycle panes, F find, P command palette, C/V copy/paste, S save. Ctrl+Tab next tab. On macOS: Cmd+T tab, Cmd+D / Cmd+Shift+D split, Cmd+W close, Cmd+F find, Cmd+Shift+P command palette, Cmd+C/V copy/paste, Cmd+1..8 select tab.\n", .{});
            return;
        }
        if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("Letty 0.2.3; Zig 0.17.0; libghostty-vt df246d0105e1; vt-backend={s}\n", .{vt_api.backend_name});
            return;
        }
        if (std.mem.eql(u8, arg, "--check-config")) {
            check_config = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--config=")) cfg_path = arg[9..] else if (std.mem.startsWith(u8, arg, "--profile=")) {
            profile = arg[10..];
            no_restore = true;
        } else if (std.mem.startsWith(u8, arg, "--command=")) {
            command = arg[10..];
            no_restore = true;
        } else if (std.mem.startsWith(u8, arg, "--cwd=")) cwd = arg[6..] else if (std.mem.eql(u8, arg, "--no-restore")) no_restore = true else if (std.mem.startsWith(u8, arg, "--perf-checks=")) {
            perf_panes = try std.fmt.parseInt(u8, arg[14..], 10);
            no_restore = true;
        } else if (std.mem.startsWith(u8, arg, "--cpu-damage-perf=")) {
            cpu_damage_panes = try std.fmt.parseInt(u8, arg[18..], 10);
            if (cpu_damage_panes != 1 and cpu_damage_panes != 4 and cpu_damage_panes != 16) return error.InvalidOption;
            no_restore = true;
        } else if (std.mem.startsWith(u8, arg, "--window-perf=")) {
            window_perf = try std.fmt.parseInt(usize, arg[14..], 10);
            if (window_perf.? > 100000) return error.InvalidOption;
            no_restore = true;
        } else if (std.mem.eql(u8, arg, "--memory-checks")) {
            memory_checks = true;
            no_restore = true;
        } else if (std.mem.eql(u8, arg, "--font-checks")) {
            font_checks = true;
            no_restore = true;
        } else if (std.mem.eql(u8, arg, "--ui-checks")) {
            ui_checks = true;
            no_restore = true;
        } else if (std.mem.startsWith(u8, arg, "--feature-checks=")) {
            feature_checks = std.meta.stringToEnum(@import("feature_checks.zig").Batch, arg[17..]) orelse return error.InvalidOption;
            no_restore = true;
        } else if (std.mem.startsWith(u8, arg, "--stability-checks=")) {
            stability_cycles = try std.fmt.parseInt(u16, arg[19..], 10);
            no_restore = true;
        } else if (std.mem.eql(u8, arg, "--hold")) hold = true else if (std.mem.startsWith(u8, arg, "--smoke-ms=")) smoke_ms = try std.fmt.parseInt(u64, arg[11..], 10) else if (!std.mem.startsWith(u8, arg, "--nanoui-")) {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return error.InvalidOption;
        }
    }
    if (cwd) |value| cwd = try config.expandHome(a, value);
    const dir = try config.configDir(a);
    const dirz = try a.dupeSentinel(u8, dir, 0);
    if (lt_mkdirs(dirz) != 0) return error.ConfigDirectory;
    const preferred = try config.selectPath(a, cfg_path);
    const has_config = config.exists(preferred);
    var diagnostic: config.Diagnostic = .{};
    const cfg = if (cfg_path != null or has_config) config.loadDetailed(a, preferred, &diagnostic) catch |err| {
        std.debug.print("Configuration rejected: {s}:{d}: {s} ({s})\n", .{
            if (diagnostic.path_len > 0) diagnostic.path[0..diagnostic.path_len] else preferred,
            diagnostic.line,
            @errorName(err),
            diagnostic.key[0..diagnostic.key_len],
        });
        if (diagnostic.chain_len > 0) std.debug.print("Included from:\n{s}{s}", .{
            diagnostic.chain[0..diagnostic.chain_len], if (diagnostic.chain_truncated) "[include chain truncated]\n" else "",
        });
        return err;
    } else Config{};
    if (check_config) {
        std.debug.print("{s}{s}\n", .{ if (has_config) "Configuration valid: " else "Using defaults; create configuration at: ", preferred });
        for (cfg.config_sources) |source| std.debug.print("  source: {s}\n", .{source});
        std.debug.print("Capabilities: native Zig VT, chord sequences, text/csi/esc, performable/unconsumed/all:text, config-file includes, cached light/dark themes, font-feature, font-ligatures, font-family-fallback\n", .{});
        return;
    }
    var chosen: u8 = 0;
    if (profile) |name| {
        var found = false;
        for (cfg.profiles, 0..) |p, i| if (std.mem.eql(u8, p.name, name)) {
            chosen = @intCast(i);
            found = true;
            break;
        };
        if (!found) return error.UnknownProfile;
    }
    // CLI overrides stay in Host/Window startup fields. Mutating the parsed
    // profile here would make a navigation-only save look like a config edit.
    try @import("bundled_fonts.zig").initialize(a, init.io);
    const app = try nano.App.create(init, .{ .name = "Letty" });
    defer app.destroy();
    if (builtin.os.tag == .linux) if (app.gui) {
        @import("application_icon.zig").initialize() catch |err| std.log.warn("Linux application icon: {s}", .{@errorName(err)});
    };
    const shared_path = try std.fmt.allocPrintSentinel(a, "{s}/layout.json", .{dir}, 0);
    const lock_path = try std.fmt.allocPrintSentinel(a, "{s}.lock", .{shared_path}, 0);
    const checking = memory_checks or window_perf != null or ui_checks or feature_checks != null or font_checks or cpu_damage_panes > 0 or perf_panes > 0 or stability_cycles > 0;
    const lock_fd = if (checking) -1 else c.lt_state_lock(lock_path);
    const state_path = if (lock_fd >= 0 or checking) shared_path else try std.fmt.allocPrintSentinel(a, "{s}/layout-instance-{d}.json", .{ dir, c.lt_process_id() }, 0);
    var host: AppState = .{ .gpa = init.gpa, .arena = a, .app = app, .cfg = cfg, .state_path = state_path, .read_path = shared_path, .lock_fd = lock_fd, .explicit_config = cfg_path, .command_override = command, .cwd_override = cwd, .override_profile = cfg.profiles[chosen].name, .chosen = chosen, .demo = checking, .hold = hold };
    defer host.deinit();
    host.services.init(&host);
    host.startAppearance();
    const restored = if (!no_restore and cfg.restore_layout) host.restore() catch |err| blk: {
        std.debug.print("Ignoring workspace: {s}\n", .{@errorName(err)});
        break :blk false;
    } else false;
    if (!restored) _ = try host.create(false);
    const state = host.active() orelse return error.NoWorkspace;
    if (feature_checks) |batch| {
        try @import("feature_checks.zig").run(state, batch);
        return;
    }
    const theme = appearance.theme(cfg);
    if (memory_checks) {
        if (comptime @hasField(@TypeOf(@as(ui.Tester, undefined).text), "db")) {
            try @import("memory_check.zig").run(state, .init(state, WindowState.view), theme);
        } else return error.PortableBuildRequired;
        return;
    }
    if (window_perf) |lines| {
        if (comptime builtin.os.tag == .macos) try @import("window_performance.zig").run(state, lines) else return error.MacOSOnly;
        return;
    }
    if (cpu_damage_panes > 0) {
        try @import("cpu_damage_ui_check.zig").benchmark(state, cpu_damage_panes);
        return;
    }
    if (font_checks) {
        try @import("font_render_ui_check.zig").run(state);
        std.debug.print("All font checks passed.\n", .{});
        return;
    }
    if (stability_cycles > 0) {
        try @import("stability_check.zig").run(state, .init(state, WindowState.view), theme, stability_cycles);
        return;
    }
    if (perf_panes > 0) {
        try @import("performance_check.zig").run(state, .init(state, WindowState.view), theme, perf_panes, c.lt_millis() - startup_start);
        return;
    }
    if (ui_checks) {
        try @import("ui_check.zig").run(state, .init(state, WindowState.view), theme);
        return;
    }
    var services_plan = try host.services.prepare(host.cfg);
    defer services_plan.deinit(host.gpa);
    const services_commit = try host.services.commit(&services_plan);
    if (services_commit.cleanup_pending > 0) std.debug.print("Global shortcuts committed; {d} muted grabs await cleanup\n", .{services_commit.cleanup_pending});
    for (host.windows) |opt| if (opt) |w| try w.attach(w.saved_frame);
    app.on_quit_request = .{ .ctx = &host, .func = AppState.quitRequested };
    if (smoke_ms > 0) nano.App.after(smoke_ms, state, struct {
        fn quit(ctx: ?*anyopaque) callconv(.c) void {
            const s: *WindowState = @ptrCast(@alignCast(ctx.?));
            s.app.quit();
        }
    }.quit);
    try app.run();
    host.save();
}
