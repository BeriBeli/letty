//! Letty's native desktop, with process-local PTY/VT ownership.
const std = @import("std");
const nano = @import("nanoui");
const ui = nano.ui;
const L = @import("localized.zig");
const ghostty = @import("ghostty-vt");
const os = @import("platform.zig");
const c = os.c;
const Pty = @import("pty.zig").Pty;
const Layout = @import("model.zig").Layout;
const Watch = @import("watch.zig").Watch;
const render = @import("render.zig");
const Settings = @import("settings.zig").Settings;
const commands = @import("actions.zig");
const Vcs = @import("vcs.zig");
const Jobs = @import("jobs.zig");
const A = std.mem.Allocator;
const C = @import("presentation.zig");
const Documents = @import("document-native");
const DocumentDesktop = @import("document_desktop.zig");
const DocumentRestore = @import("document_restore.zig");
const Action = struct {
    window: u64,
    workspace: u64 = 0,
    pane: u64 = 0,
    document: u64 = 0,
    document_generation: u64 = 0,
    document_edit_epoch: u64 = 0,
    document_intent: Documents.panel.Intent = .none,
    kind: enum { persist_documents, document_open, document_event, document_resize, paste_paths, revert_hunk, editor_open, editor_save, editor_reload, editor_close, notification_activate, update_attention, image_hover, image_hide, persist_ui, toggle_group, rename_project, session_meta, document_meta, assign_project, move_workspace, move_project, close_project, sidebar_visibility, chrome_resize, split_resize, pane_move, open_link, copy_link, focus_report, window_focus, git_show, git_refresh, git_base, git_context, git_select, git_open, restart, command, set_setting, set_binding, set_environment, edit_configuration, reload_settings, search_tick, new_window, close_window, new_workspace, split_right, split_down, close_workspace, close_pane, focus, input, resize, paste, copy, scroll, quit },
    text: []const u8 = "",
    other: u64 = 0,
    value: f64 = 0,
    review_epoch: u64 = 0,
    settings_epoch: u64 = 0,
    cols: u16 = 0,
    rows: u16 = 0,
    cell_w: u16 = 0,
    cell_h: u16 = 0,
    delta: isize = 0,
};
var child_signal_fd: c_int = -1;
fn childSignal(_: c_int) callconv(.c) void {
    if (child_signal_fd >= 0) {
        const byte = [_]u8{1};
        _ = c.write(child_signal_fd, &byte, 1);
    }
}
const Owner = struct {
    host: *Runtime,
    window: u64,
    workspace: u64,
    key: []const u8,
    pty: *Pty,
    paste_store: @import("paste.zig").Store = .{},
    reading: ?*Watch = null,
    writing: ?*Watch = null,
    last_cols: u16 = 80,
    last_rows: u16 = 24,
    metadata_stamp: u64 = 0,
    search_queued: bool = false,
    scroll_fraction: f32 = 0,
    mouse_cell: ?ghostty.Coordinate = null,
    mouse_button: ?ghostty.input.MouseButton = null,
    rect: ui.Rect = .{},
    screen_rect: ui.Rect = .{},
    agent: []const u8 = "",
    status: []const u8 = "idle",
    unread: bool = false,
    idle_deadline: ?*Watch = null,
    vcs_deadline: ?*Watch = null,
    idle_from: i64 = 0,
    changes: Vcs.State = .{},
    git_queued: bool = false,
    focus_queued: bool = false,
    focus_reported: bool = false,
    focus_mode: bool = false,
    fn create(host: *Runtime, window: u64, workspace: u64, directory: []const u8) !*Owner {
        const a = host.a;
        const self = try a.create(Owner);
        errdefer a.destroy(self);
        const id = host.allocateId();
        const key = try std.fmt.allocPrint(a, "pane-{d}", .{id});
        errdefer a.free(key);
        const selected_shell = if (host.shell_path.len > 0) host.shell_path else if (host.settings.command.len > 0) host.settings.command else os.shell();
        const resolved_shell = try Jobs.resolve(a, selected_shell);
        defer a.free(resolved_shell);
        const terminal = try Pty.createWithEnv(a, host.io, id, directory, resolved_shell, if (!host.startup_used) host.startup_args else &.{}, @as(usize, host.settings.@"scrollback-limit") * 1024 * 1024, host.configuration.?.env.items, !host.hidden);
        errdefer terminal.destroy();
        self.* = .{ .host = host, .window = window, .workspace = workspace, .key = key, .pty = terminal };
        terminal.terminal.hooks = .{ .ctx = self, .read = clipboardRead, .write = clipboardWrite };
        self.reading = try Watch.create(terminal.fd, false, self, readable);
        host.startup_used = true;
        return self;
    }
    fn destroy(self: *Owner) void {
        if (self.host.notifications) |*service| service.registry.invalidate(self.pty.id);
        if (self.host.jobs) |*pool| pool.cancelPane(self.pty.id);
        self.changes.deinit(self.host.a);
        if (self.idle_deadline) |watch| watch.cancel();
        if (self.vcs_deadline) |watch| watch.cancel();
        if (self.reading) |watch| watch.cancel();
        if (self.writing) |watch| watch.cancel();
        const a = self.host.a;
        self.pty.destroy();
        self.paste_store.deinit(a);
        a.free(self.key);
        a.destroy(self);
    }
    fn readable(raw: ?*anyopaque) callconv(.c) void {
        const self: *Owner = @ptrCast(@alignCast(raw.?));
        _ = self.pty.read() catch |err| {
            self.host.problem(err);
            self.pty.eof = true;
        };
        self.scheduleWrites() catch |err| self.host.problem(err);
        self.pumpSearch();
        self.classify() catch |err| self.host.problem(err);
        if (!self.host.hidden and self.host.settings.@"git-status" and !self.pty.eof) {
            if (self.vcs_deadline) |watch| watch.cancel();
            self.vcs_deadline = Watch.timer(250, self, vcsIdle) catch null;
        }
        const vt = self.pty.terminal;
        for (vt.notices.items) |notice| if (self.agent.len == 0 and !self.host.hidden and !self.viewed()) self.host.notifications.?.show(.{ .window = self.window, .workspace = self.workspace, .pane = self.pty.id }, notice.title, notice.body, self.host.settings.@"notify-sound") catch {};
        vt.clearNotices();
        if (self.pty.eof) {
            if (self.reading) |watch| watch.cancel();
            self.reading = null;
        }
        var hash = std.hash.Wyhash.init(0);
        hash.update(self.pty.terminal.terminal.getTitle() orelse "");
        hash.update(std.mem.asBytes(&self.pty.terminal.at_prompt));
        hash.update(self.status);
        hash.update(self.agent);
        hash.update(std.mem.asBytes(&self.unread));
        for (self.pty.terminal.records.list.items) |record| {
            hash.update(record.state);
            hash.update(record.msg);
            hash.update(std.mem.asBytes(&record.progress));
        }
        const stamp = hash.final();
        if (self.host.findWindow(self.window)) |win| if (win.active == self.workspace or stamp != self.metadata_stamp) win.redraw();
        self.metadata_stamp = stamp;
    }
    fn writable(raw: ?*anyopaque) callconv(.c) void {
        const self: *Owner = @ptrCast(@alignCast(raw.?));
        const pending = self.pty.flush() catch |err| {
            self.host.problem(err);
            if (self.writing) |watch| watch.cancel();
            self.writing = null;
            return;
        };
        if (!pending) {
            if (self.writing) |watch| watch.cancel();
            self.writing = null;
        }
    }
    fn scheduleWrites(self: *Owner) !void {
        if (try self.pty.flush()) if (self.writing == null) {
            self.writing = try Watch.create(self.pty.fd, true, self, writable);
        };
    }
    fn pumpSearch(self: *Owner) void {
        const vt = self.pty.terminal;
        if (!vt.interaction.step(&vt.terminal, vt.revision) or self.search_queued) return;
        self.host.enqueue(.{ .window = self.window, .workspace = self.workspace, .pane = self.pty.id, .kind = .search_tick }) catch |err| {
            self.host.problem(err);
            return;
        };
        self.search_queued = true;
    }
    fn viewed(self: *Owner) bool {
        const win = self.host.findWindow(self.window) orelse return false;
        return win.active == self.workspace and !win.blocksInput() and (if (win.native) |native| native.isFocused() else false);
    }
    fn transition(self: *Owner, state: []const u8) void {
        if (std.mem.eql(u8, self.status, state)) return;
        const begins_turn = std.mem.eql(u8, state, "working") and (std.mem.eql(u8, self.status, "idle") or std.mem.eql(u8, self.status, "done"));
        self.status = state;
        if (begins_turn and self.agent.len > 0 and self.host.settings.@"git-status" and !self.host.hidden) {
            self.changes.capture_requested = true;
            self.refreshGit();
        }
        const attention = std.mem.eql(u8, state, "blocked") or std.mem.eql(u8, state, "done") or std.mem.eql(u8, state, "error");
        if (attention and !self.viewed()) {
            self.unread = true;
            const settings = self.host.settings;
            const enabled = if (std.mem.eql(u8, state, "blocked")) settings.@"notify-on-waiting" else if (std.mem.eql(u8, state, "error")) settings.@"notify-on-error" else settings.@"notify-on-done";
            if (!self.host.hidden and settings.@"dock-bounce") self.host.notifications.?.bounce();
            self.host.queueAttention();
            if (enabled and !self.host.hidden) self.host.notifications.?.show(.{ .window = self.window, .workspace = self.workspace, .pane = self.pty.id }, self.agent, if (std.mem.eql(u8, state, "blocked")) "Waiting for your input" else if (std.mem.eql(u8, state, "error")) "A program reported an error" else "Agent finished", settings.@"notify-sound") catch {};
        }
        if (!self.host.hidden and self.host.settings.@"git-status" and (std.mem.eql(u8, state, "done") or std.mem.eql(u8, state, "idle"))) self.refreshGit();
        self.host.redraw(self.window);
    }
    fn refreshGit(self: *Owner) void {
        if (self.git_queued) return;
        self.host.enqueue(.{ .window = self.window, .workspace = self.workspace, .pane = self.pty.id, .kind = .git_refresh }) catch return;
        self.git_queued = true;
    }
    fn currentDirectory(self: *Owner, a: A) ![]const u8 {
        const origin = Documents.terminal_paths.origin(self.pty.fd, self.pty.pid, self.pty.explicit_command, "");
        if (origin.refusal == null and origin.cwd.len > 0) return a.dupe(u8, origin.cwd.text());
        return @import("paths.zig").directory(a, self.pty.terminal.terminal.getPwd(), self.pty.directory);
    }
    fn vcsIdle(raw: ?*anyopaque) callconv(.c) void {
        const self: *Owner = @ptrCast(@alignCast(raw.?));
        if (self.vcs_deadline) |watch| watch.cancel();
        self.vcs_deadline = null;
        if (!self.pty.eof and !self.pty.busy() and self.host.settings.@"git-status") self.refreshGit();
    }
    fn idle(raw: ?*anyopaque) callconv(.c) void {
        const self: *Owner = @ptrCast(@alignCast(raw.?));
        if (self.idle_deadline) |watch| watch.cancel();
        self.idle_deadline = null;
        self.classify() catch |err| self.host.problem(err);
    }
    fn classify(self: *Owner) !void {
        const vt = self.pty.terminal;
        if (vt.records.leading()) |record| {
            self.transition(record.state);
            if (vt.records.declared()) return;
        }
        const agent = try @import("process_info.zig").foreground(self.host.a, self.pty.fd, self.pty.pid);
        const was_agent = self.agent.len > 0;
        self.agent = agent;
        if (agent.len == 0) {
            if (!self.pty.busy()) {
                vt.at_prompt = true;
                if (std.mem.eql(u8, self.status, "working") and vt.records.leading() == null) self.transition(if (was_agent) "done" else "idle");
            } else {
                vt.at_prompt = false;
                if (vt.records.leading() == null) self.transition("working");
            }
            return;
        }
        var buffer: [65536]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        const screen = vt.terminal.screens.active;
        screen.dumpString(&writer, .{ .tl = screen.pages.getTopLeft(.active), .br = screen.pages.getBottomRight(.active), .unwrap = false }) catch {};
        var text = writer.buffered();
        while (text.len > 0 and !std.unicode.utf8ValidateSlice(text)) text = text[0 .. text.len - 1];
        var progress: [32]u8 = undefined;
        const result = try self.host.detector.?.detect(agent, .{ .screen = text, .title = vt.terminal.getTitle() orelse "", .progress = try std.fmt.bufPrint(&progress, "4;{d}", .{vt.progress_state}) });
        if (result.skip or result.state == .unknown) return;
        if (result.state == .idle and !result.visible and std.mem.eql(u8, self.status, "working")) {
            if (self.idle_from == 0) self.idle_from = os.millis();
            if (os.millis() - self.idle_from < 1200) {
                if (self.idle_deadline == null) self.idle_deadline = try Watch.timer(1200, self, idle);
                return;
            }
        } else self.idle_from = 0;
        if (result.state == .idle) {
            if (std.mem.eql(u8, self.status, "working") or std.mem.eql(u8, self.status, "blocked")) self.transition("done");
        } else self.transition(@tagName(result.state));
    }
    fn clipboardRead(raw: *anyopaque, request: ghostty.clipboard.Read) void {
        const self: *Owner = @ptrCast(@alignCast(raw));
        const host = self.host;
        if (request.location != .standard) {
            request.reply(.unsupported);
            return;
        }
        const policy = host.settings.@"clipboard-read";
        if (std.mem.eql(u8, policy, "deny")) {
            request.reply(.denied);
            return;
        }
        if (request.mimes.len == 0) {
            request.reply(.{ .success = .{ .available = &.{"text/plain"} } });
            return;
        }
        if (!request.granted and std.mem.eql(u8, policy, "ask")) {
            if (host.hidden or host.modal_window != 0) {
                request.reply(.denied);
                return;
            }
            host.modal_window = self.window;
            defer host.modal_window = 0;
            const answer = nano.dialog.message(.{ .title = "Allow this terminal to read your clipboard?", .detail = "The program running in this terminal requested clipboard text.", .buttons = &.{ "Deny", "Allow once" } });
            if (answer.button != 1) {
                request.reply(.denied);
                return;
            }
        }
        const text = host.readClipboard() catch {
            request.reply(.io_error);
            return;
        };
        defer if (text) |value| host.a.free(value);
        if (text) |value| {
            if (value.len > 1024 * 1024) {
                request.reply(.busy);
                return;
            }
            const contents = [_]ghostty.clipboard.Content{.{ .mime = "text/plain", .data = value }};
            request.reply(.{ .success = .{ .contents = &contents, .available = &.{"text/plain"} } });
        } else request.reply(.{ .success = .{} });
    }
    fn clipboardWrite(raw: *anyopaque, request: ghostty.clipboard.Write) void {
        const self: *Owner = @ptrCast(@alignCast(raw));
        if (request.location != .standard) {
            request.reply(.unsupported);
            return;
        }
        if (request.contents.len == 0) {
            self.host.writeClipboard("") catch {
                request.reply(.io_error);
                return;
            };
            request.reply(.{ .success = .{} });
            return;
        }
        for (request.contents) |content| if (ghostty.clipboard.isTextMime(content.mime)) {
            if (content.data.len > 1024 * 1024 or !std.unicode.utf8ValidateSlice(content.data) or std.mem.indexOfScalar(u8, content.data, 0) != null) {
                request.reply(.invalid_data);
                return;
            }
            self.host.writeClipboard(content.data) catch {
                request.reply(.io_error);
                return;
            };
            request.reply(.{ .success = .{} });
            return;
        };
        request.reply(.unsupported);
    }
};
const Workspace = struct {
    id: u64,
    directory: []const u8,
    sidebar_rect: ui.Rect = .{},
    project_rect: ui.Rect = .{},
    name: []const u8 = "",
    panes: std.ArrayList(*Owner) = .empty,
    is_file: bool = false,
    documents: Documents.Collection = .{},
    document_width: f32 = 440,
    layout: *Layout,
    focus: u64,
    fn destroy(self: *Workspace, a: A) void {
        self.documents.deinit(a);
        for (self.panes.items) |owner| owner.destroy();
        self.panes.deinit(a);
        self.layout.deinit(a);
        a.free(self.directory);
        if (self.name.len > 0) a.free(self.name);
        a.destroy(self);
    }
    fn pane(self: *Workspace, id: u64) ?*Owner {
        for (self.panes.items) |owner| if (owner.pty.id == id) return owner;
        return null;
    }
    fn title(self: *Workspace) []const u8 {
        if (self.name.len > 0) return self.name;
        if (self.is_file) if (self.documents.selected()) |document| return std.fs.path.basename(document.absolute());
        if (self.panes.items.len == 0) return "Document";
        const mode = self.panes.items[0].host.settings.@"session-name";
        if (std.mem.eql(u8, mode, "folder")) return std.fs.path.basename(self.directory);
        const chosen = if (std.mem.eql(u8, mode, "lead")) self.panes.items[0] else self.pane(self.focus);
        if (chosen) |owner| if (owner.pty.terminal.terminal.getTitle()) |title_| if (title_.len > 0) return title_;
        return std.fs.path.basename(self.directory);
    }
};
const Window = struct {
    host: *Runtime,
    id: u64,
    native: ?*nano.Window = null,
    close_guard: ?*@import("window_guard.zig").Guard = null,
    drop_guard: ?*@import("file_drop.zig").Guard = null,
    closed: bool = false,
    workspaces: std.ArrayList(*Workspace) = .empty,
    active: u64 = 0,
    sidebar: bool = true,
    sidebar_forced: bool = false,
    session_menu: u64 = 0,
    session_menu_point: ui.Point = .{},
    session_menu_frame: u64 = 0,
    session_menu_project: bool = false,
    session_menu_state: @import("menu.zig").State = .{},
    project_menu_state: @import("menu.zig").State = .{},
    project_menu_open: bool = false,
    project_rename: u64 = 0,
    project_drag: u64 = 0,
    project_drag_start: ui.Point = .{},
    project_dragging: bool = false,
    sidebar_drag: u64 = 0,
    sidebar_drag_start: ui.Point = .{},
    sidebar_dragging: bool = false,
    drag_pane: u64 = 0,
    drag_workspace: u64 = 0,
    drag_start: ui.Point = .{},
    dragging_pane: bool = false,
    drag_frame: u64 = 0,
    settings_open: bool = false,
    settings_native: ?*nano.Window = null,
    settings_guard: ?*@import("window_guard.zig").Guard = null,
    settings_discard: bool = false,
    settings_close_intent: enum { settings, window, application } = .settings,
    marked: std.ArrayList(u8) = .empty,
    marked_pane: u64 = 0,
    find_pane: u64 = 0,
    find_query: ui.TextBuffer = .{},
    field_focus: bool = false,
    palette_open: bool = false,
    palette_query: ui.TextBuffer = .{},
    palette_index: usize = 0,
    rename_open: bool = false,
    rename_query: ui.TextBuffer = .{},
    zoom: u64 = 0,
    preferences: @import("preferences.zig").State = .{},
    input_settings_open: bool = false,
    input_settings: @import("input_settings.zig").State = .{},
    native_focus: bool = false,
    changes_open: bool = false,
    review_focus: bool = false,
    review_pane: u64 = 0,
    git_view: @import("git_view.zig").View = .{},
    editor: @import("review_editor.zig").State = .{},
    window_style: @import("window_style.zig").State = .{},
    terminal_menu: @import("terminal_menu.zig").State = .{},
    preview: @import("image_preview.zig").State = .{},
    preview_edge: u64 = 0,
    document_context: ?*ui.Context = null,
    edit_tester: ?*ui.Tester = null,
    document_close_choice: ?u8 = null, // Private hidden-fixture response only.
    pending_document_close: ?struct { action: Action, workspace: u64, document: u64, generation: u64, text: []u8 } = null,
    path_hover: []const u8 = "",
    path_hover_pane: u64 = 0,
    path_origin: Documents.terminal_paths.Origin = .{},
    theme_picker_open: bool = false,
    theme_picker: @import("theme_picker.zig").State = .{},
    fn workspace(self: *Window, id: u64) ?*Workspace {
        for (self.workspaces.items) |ws| if (ws.id == id) return ws;
        return null;
    }
    fn setChanges(self: *Window, value: bool) void {
        self.changes_open = value;
        self.host.presentation.changes_open = value;
        self.host.markPresentation();
    }
    fn redraw(self: *Window) void {
        if (self.native) |win| if (win.surface) |surface| surface.requestFrame();
    }
    fn queue(self: *Window, kind: @FieldType(Action, "kind"), ws: ?*Workspace, owner: ?*Owner) void {
        self.host.enqueue(.{ .window = self.id, .settings_epoch = self.preferences.draft.id, .workspace = if (ws) |w| w.id else 0, .pane = if (owner) |o| o.pty.id else 0, .kind = kind }) catch |err| self.host.problem(err);
    }
    fn dispatchCommand(self: *Window, id: []const u8) void {
        const ws = self.workspace(self.active);
        self.host.enqueue(.{ .window = self.id, .settings_epoch = self.preferences.draft.id, .workspace = self.active, .pane = if (ws) |w| w.focus else 0, .kind = .command, .text = id }) catch |err| self.host.problem(err);
    }
    fn blocksInput(self: *Window) bool {
        const document = if (self.workspace(self.active)) |ws| ws.documents.selected() else null;
        const document_focus = if (document) |d| (self.workspace(self.active).?.documents.visible and (self.workspace(self.active).?.is_file or d.panel.focused or d.preview.focused)) else false;
        return document_focus or self.session_menu != 0 or self.terminal_menu.open or self.settings_open or self.find_pane != 0 or self.palette_open or self.rename_open or self.project_rename != 0 or (self.changes_open and self.review_focus);
    }
    fn blocksPointer(self: *Window) bool {
        return self.session_menu != 0 or self.terminal_menu.open or self.settings_open or self.find_pane != 0 or self.palette_open or self.rename_open or self.project_rename != 0 or (self.changes_open and self.review_focus);
    }
    fn trustedPath(self: *Window, owner: *Owner, target: []const u8) bool {
        if (self.path_hover_pane != owner.pty.id or !std.mem.eql(u8, self.path_hover, target)) {
            const owned = self.host.a.dupe(u8, target) catch return false;
            self.host.a.free(self.path_hover);
            self.path_hover = owned;
            self.path_hover_pane = owner.pty.id;
            self.path_origin = Documents.terminal_paths.origin(owner.pty.fd, owner.pty.pid, owner.pty.explicit_command, owner.pty.directory);
        }
        const host = Documents.terminal_paths.hostname();
        return Documents.terminal_paths.resolve(target, self.path_origin, os.env("HOME") orelse "", host.text()) == .path;
    }
    fn documentPlacement(self: *Window, ctx: *ui.Context, ws: *Workspace) DocumentDesktop.Placement {
        const sidebar_shown = self.sidebar and (ctx.size.w >= 680 or self.sidebar_forced);
        const width = @min(self.host.presentation.sidebar_width, @max(200, ctx.size.w * 0.4));
        const x: f32 = if (sidebar_shown) width else 8;
        return DocumentDesktop.place(.{ .x = x, .y = 8, .w = @max(1, ctx.size.w - x - 8), .h = @max(1, ctx.size.h - 16) }, ws.documents.visible, ws.is_file, ws.document_width);
    }
    fn documentView(self: *Window, ctx: *ui.Context, ws: *Workspace) void {
        if (!ws.documents.visible) return;
        const saved_input = ctx.input;
        const enabled = !self.blocksPointer();
        if (!enabled) ctx.input = .{};
        defer ctx.input = saved_input;
        if (ws.documents.selected()) |document| {
            document.presentation_enabled = enabled;
            if (!enabled) document.stopPresentation();
        }
        const placement = self.documentPlacement(ctx, ws);
        const padding: f32 = if (@import("builtin").os.tag == .linux) 94 else 0;
        if (DocumentDesktop.draw(&ws.documents, ctx, placement, padding)) |event| self.host.enqueue(.{ .window = self.id, .workspace = ws.id, .kind = .document_event, .document = event.id, .document_generation = event.generation, .document_intent = event.intent, .other = event.select, .text = event.text }) catch |err| self.host.problem(err);
        if (!ws.is_file and placement.divider.w > 0) {
            const bar = placement.divider;
            const node = ctx.open(.{ .fixed = true, .absolute = true, .offset = .{ .x = bar.x, .y = bar.y }, .width = .{ .px = bar.w }, .height = .{ .px = bar.h }, .control = true }, "document-divider");
            const hit = ctx.interact(node, .{});
            if (hit.hovered or hit.pressed) ctx.cursor = .resize_left_right;
            if (hit.pressed and ctx.input.down) self.host.enqueue(.{ .window = self.id, .workspace = ws.id, .kind = .document_resize, .value = ctx.size.w - ctx.input.mouse.x - 8 }) catch |err| self.host.problem(err);
            ui.end(ctx);
        }
    }
    fn sidebarMenu(self: *Window, ctx: *ui.Context) void {
        if (self.session_menu == 0) return;
        const ws = self.workspace(self.session_menu) orelse {
            self.session_menu = 0;
            return;
        };
        if (self.session_menu_project) return self.projectMenu(ctx, ws);
        const Menu = @import("menu.zig");
        const Command = enum { rename, project, read, id, directory, reveal, path, reveal_file, close, separator };
        const Entry = struct { item: Menu.Item, command: Command };
        var entries: std.ArrayList(Entry) = .empty;
        const a = ctx.alloc();
        entries.append(a, .{ .item = .{ .label = if (ws.is_file) "Rename Workspace" else "Rename", .hint = self.shortcutHint(ctx, "session.rename") }, .command = .rename }) catch return;
        var unread = false;
        for (ws.panes.items) |pane| unread = unread or pane.unread;
        if (!ws.is_file and unread) entries.append(a, .{ .item = .{ .label = "Mark as read" }, .command = .read }) catch return;
        entries.appendSlice(a, &.{
            .{ .item = .{ .label = "Move to project", .submenu = true }, .command = .project },
            .{ .item = .{ .separator = true }, .command = .separator },
        }) catch return;
        if (ws.is_file) {
            entries.appendSlice(a, &.{
                .{ .item = .{ .label = "Copy Path", .disabled = ws.documents.selected() == null }, .command = .path },
                .{ .item = .{ .label = "Show in Folder", .disabled = ws.documents.selected() == null }, .command = .reveal_file },
            }) catch return;
        } else entries.appendSlice(a, &.{
            .{ .item = .{ .label = "Copy session ID" }, .command = .id },
            .{ .item = .{ .label = "Copy directory" }, .command = .directory },
            .{ .item = .{ .label = "Reveal directory" }, .command = .reveal },
        }) catch return;
        entries.appendSlice(a, &.{
            .{ .item = .{ .separator = true }, .command = .separator },
            .{ .item = .{ .label = if (ws.is_file) "Close Workspace" else "Close Session", .hint = self.shortcutHint(ctx, "session.close") }, .command = .close },
        }) catch return;
        const items = a.alloc(Menu.Item, entries.items.len) catch return;
        for (entries.items, items) |entry, *item| item.* = entry.item;
        const bounds = Menu.place(ctx.size, self.session_menu_point, Menu.contentWidth(ctx, items, 192), Menu.contentHeight(items));
        var projects: std.ArrayList(Menu.Item) = .empty;
        var targets: std.ArrayList(u64) = .empty;
        for (self.workspaces.items, 0..) |target, i| {
            var seen = false;
            for (self.workspaces.items[0..i]) |previous| if (std.mem.eql(u8, target.directory, previous.directory)) {
                seen = true;
                break;
            };
            if (seen) continue;
            const current = std.mem.eql(u8, target.directory, ws.directory);
            projects.append(a, .{ .label = self.host.presentation.label(target.directory), .disabled = current, .checked = current }) catch return;
            targets.append(a, target.id) catch return;
        }
        var project_y = bounds.y + Menu.padding;
        for (entries.items) |entry| {
            if (entry.command == .project) break;
            project_y += if (entry.item.separator) Menu.separator_height else Menu.row_height;
        }
        const project_width = Menu.contentWidth(ctx, projects.items, 140);
        const project_point: ui.Point = .{ .x = if (bounds.x + bounds.w + project_width <= ctx.size.w) bounds.x + bounds.w - 2 else @max(8, bounds.x - project_width + 2), .y = project_y };
        const project_bounds = Menu.place(ctx.size, project_point, project_width, Menu.contentHeight(projects.items));
        if (ctx.input.key == .escape or (ctx.input.pressed and ctx.frame != self.session_menu_frame and !bounds.contains(ctx.input.mouse) and !(self.project_menu_open and project_bounds.contains(ctx.input.mouse)))) {
            self.session_menu = 0;
            self.project_menu_open = false;
            ctx.focus = 0;
            ctx.input.clearEdges();
            return;
        }
        if (self.project_menu_open and ctx.input.key == .left) {
            self.project_menu_open = false;
            ctx.input.key = null;
        }
        ui.key(ctx, "sidebar-context-menu");
        if (Menu.draw(&self.session_menu_state, ctx, bounds, items, !self.project_menu_open)) |index| {
            switch (entries.items[index].command) {
                .project => {
                    self.project_menu_open = !self.project_menu_open;
                    self.project_menu_state = .{};
                    ctx.input.key = null;
                },
                .rename => {
                    self.activate(ws);
                    if (self.active == ws.id) {
                        self.rename_query.set(ws.title());
                        self.rename_open = true;
                        self.field_focus = true;
                    }
                    self.session_menu = 0;
                },
                .read, .id, .directory, .reveal => |command| {
                    self.host.enqueue(.{ .window = self.id, .workspace = ws.id, .kind = .session_meta, .text = @tagName(command) }) catch |err| self.host.problem(err);
                    self.session_menu = 0;
                },
                .path, .reveal_file => |command| {
                    if (ws.documents.selected()) |document| self.host.enqueue(.{ .window = self.id, .workspace = ws.id, .document = document.id, .document_generation = document.panel.model.generation, .kind = .document_meta, .text = @tagName(command) }) catch |err| self.host.problem(err);
                    self.session_menu = 0;
                },
                .close => {
                    self.queue(.close_workspace, ws, ws.pane(ws.focus));
                    self.session_menu = 0;
                },
                .separator => {},
            }
        }
        if (self.project_menu_open and self.session_menu != 0) {
            ui.key(ctx, "sidebar-project-menu");
            if (Menu.draw(&self.project_menu_state, ctx, project_bounds, projects.items, true)) |index| {
                self.host.enqueue(.{ .window = self.id, .workspace = ws.id, .other = targets.items[index], .kind = .assign_project }) catch |err| self.host.problem(err);
                self.session_menu = 0;
                self.project_menu_open = false;
            }
        }
    }
    fn projectMenu(self: *Window, ctx: *ui.Context, ws: *Workspace) void {
        const Menu = @import("menu.zig");
        const items = [_]Menu.Item{
            .{ .label = "New Session" },
            .{ .label = if (self.host.presentation.folded(ws.directory)) "Expand" else "Collapse" },
            .{ .label = "Rename Project" },
            .{ .separator = true },
            .{ .label = "Close Project" },
        };
        const bounds = Menu.place(ctx.size, self.session_menu_point, Menu.contentWidth(ctx, &items, 192), Menu.contentHeight(&items));
        if (ctx.input.key == .escape or (ctx.input.pressed and ctx.frame != self.session_menu_frame and !bounds.contains(ctx.input.mouse))) {
            self.session_menu = 0;
            ctx.focus = 0;
            ctx.input.clearEdges();
            return;
        }
        ui.key(ctx, "project-context-menu");
        if (Menu.draw(&self.session_menu_state, ctx, bounds, &items, true)) |index| {
            self.session_menu = 0;
            switch (index) {
                0 => self.queue(.new_workspace, ws, null),
                1 => self.host.enqueue(.{ .window = self.id, .workspace = ws.id, .kind = .toggle_group, .text = ws.directory }) catch |err| self.host.problem(err),
                2 => {
                    self.project_rename = ws.id;
                    self.rename_query.set(self.host.presentation.label(ws.directory));
                    self.rename_open = false;
                    self.field_focus = true;
                },
                4 => self.queue(.close_project, ws, null),
                else => {},
            }
        }
    }
    fn shortcutHint(self: *Window, ctx: *ui.Context, id: []const u8) []const u8 {
        for (commands.all, 0..) |command, i| if (std.mem.eql(u8, command.id, id)) return C.shortcutLabel(ctx, commands.keys(i, self.host.bindings, @import("builtin").os.tag == .macos));
        return "";
    }
    fn settingsView(self: *Window, ctx: *ui.Context) void {
        defer self.nativeControls(ctx, true);
        const appearance = self.host.settings.@"window-theme";
        if (std.mem.eql(u8, appearance, "light")) ctx.theme = .light else if (std.mem.eql(u8, appearance, "dark")) ctx.theme = .dark_theme;
        C.theme(ctx);
        @import("fonts.zig").install(ctx.text, self.host.settings.@"font-family");
        @import("backdrop.zig").draw(ctx, self.host.settings.background, false);
        if (self.settings_native) |native| @import("window_chrome.zig").layout(native);
        if (self.input_settings.recording != null) if (@import("input_settings.zig").capture(&self.input_settings, ctx)) |event| self.inputSettingsEvent(ctx, event);
        self.settings(ctx);
        self.host.recordingMenus(self.id, self.input_settings_open and self.input_settings.recording != null);
    }
    fn nativeControls(self: *Window, ctx: *ui.Context, settings_window: bool) void {
        if (@import("builtin").os.tag == .macos) return;
        const native = (if (settings_window) self.settings_native else self.native) orelse return;
        ui.row(ctx, .{ .fixed = true, .absolute = true, .layer = 10, .offset = .{ .x = @max(0, ctx.size.w - 102), .y = 16 }, .height = .{ .px = 28 }, .gap = 0 });
        defer ui.end(ctx);
        if (C.button(ctx, .minimize, "Minimize window", 28)) native.minimize();
        if (C.button(ctx, .maximize, "Zoom window", 28)) native.zoom();
        if (C.button(ctx, .close, "Close window", 28)) {
            if (settings_window) self.dispatchCommand("settings.cancel") else self.host.enqueue(.{ .window = self.id, .kind = .close_window }) catch |err| self.host.problem(err);
        }
    }
    fn settingsCloseRequest(raw: *anyopaque) bool {
        const self: *Window = @ptrCast(@alignCast(raw));
        self.settings_close_intent = .settings;
        return self.host.discardSettings(self);
    }
    fn settingsFocus(_: *anyopaque, _: bool) void {}
    fn settingsClosed(raw: *anyopaque, _: *nano.Window) void {
        const self: *Window = @ptrCast(@alignCast(raw));
        if (self.settings_guard) |guard| guard.deinit();
        self.settings_guard = null;
        self.settings_native = null;
        self.host.resetSettings(self) catch |err| self.host.problem(err);
    }
    fn closeFind(self: *Window) void {
        for (self.workspaces.items) |ws| if (ws.pane(self.find_pane)) |owner| owner.pty.terminal.interaction.endFind(&owner.pty.terminal.terminal);
        self.find_pane = 0;
        self.marked.clearRetainingCapacity();
    }
    fn activate(self: *Window, ws: *Workspace) void {
        if (!self.canLeaveDocument(ws.id)) return;
        if (self.active != ws.id) {
            self.closeFind();
            if (self.workspace(self.active)) |previous| for (previous.documents.documents.items) |d| d.stopPresentation();
        }
        self.active = ws.id;
        self.marked.clearRetainingCapacity();
        self.marked_pane = 0;
        self.zoom = 0;
        self.review_focus = false;
        if (!self.host.hidden) if (ws.pane(ws.focus)) |owner| owner.refreshGit();
        self.redraw();
    }
    fn canLeaveDocument(self: *Window, target: u64) bool {
        if (target == self.active) return true;
        if (self.workspace(self.active)) |ws| if (ws.documents.selected()) |document| if (document.panel.editor) |editor| if (editor.composition.range != null) {
            document.panel.notice.set("Finish or cancel the current input before switching documents.");
            editor.focus = true;
            self.redraw();
            return false;
        };
        return true;
    }
    fn close(raw: *anyopaque, _: *nano.Window) void {
        const self: *Window = @ptrCast(@alignCast(raw));
        if (self.pending_document_close) |pending| self.host.a.free(pending.text);
        self.pending_document_close = null;
        self.host.closeSettings(self);
        self.closed = true;
        self.host.markDocuments();
        self.host.recordingMenus(self.id, false);
        self.terminal_menu.close(self.host.a);
        self.preview.deinit(self.host.a);
        self.host.a.free(self.path_hover);
        self.path_hover = "";
        self.editor.deinit(self.host.a);
        if (self.drop_guard) |guard| guard.deinit();
        self.drop_guard = null;
        self.window_style.deinit();
        if (self.close_guard) |guard| guard.deinit();
        self.close_guard = null;
        self.native = null;
        for (self.workspaces.items) |ws| ws.destroy(self.host.a);
        self.workspaces.clearRetainingCapacity();
    }
    fn filesDropped(raw: *anyopaque, files: []const []const u8, point: ui.Point) bool {
        const self: *Window = @ptrCast(@alignCast(raw));
        if (self.closed or self.blocksPointer() or self.host.modal_window != 0 or files.len == 0) return false;
        const ws = self.workspace(self.active) orelse return false;
        if (ws.is_file or (ws.documents.visible and if (ws.documents.selected()) |document| document.panel.rect.contains(point) else false)) {
            self.host.enqueue(.{ .window = self.id, .workspace = ws.id, .kind = .document_open, .delta = if (ws.is_file) 0 else 1, .text = files[0] }) catch return false;
            return true;
        }
        var target = ws.pane(ws.focus) orelse return false;
        for (ws.panes.items) |pane| if (pane.screen_rect.contains(point)) {
            target = pane;
            break;
        };
        const quoted = @import("paste.zig").paths(self.host.a, files, target.pty.shell_path) catch return false;
        defer self.host.a.free(quoted);
        self.host.enqueue(.{ .window = self.id, .workspace = ws.id, .pane = target.pty.id, .kind = .paste_paths, .text = quoted }) catch return false;
        return true;
    }
    fn closeRequest(raw: *anyopaque) bool {
        const self: *Window = @ptrCast(@alignCast(raw));
        if (self.host.modal_window != 0) return false;
        self.settings_close_intent = .window;
        if (!self.host.discardSettings(self)) return false;
        if (!self.host.discardEditor(self)) return false;
        if (!self.host.documentsCanClose(self, null, .{ .window = self.id, .kind = .close_window })) return false;
        for (self.workspaces.items) |ws| for (ws.panes.items) |owner| if (!self.host.confirmClose(owner)) return false;
        return true;
    }
    fn focusChanged(raw: *anyopaque, focused: bool) void {
        const self: *Window = @ptrCast(@alignCast(raw));
        self.host.enqueue(.{ .window = self.id, .kind = .window_focus, .delta = if (focused) 1 else 0 }) catch |err| self.host.problem(err);
    }
    fn syncFocus(self: *Window) void {
        for (self.workspaces.items) |ws| for (ws.panes.items) |owner| {
            const mode = owner.pty.terminal.terminal.modes.get(.focus_event);
            const desired = self.native_focus and self.host.modal_window == 0 and self.active == ws.id and ws.focus == owner.pty.id and !self.blocksInput();
            if (!owner.focus_queued and (owner.focus_reported != desired or owner.focus_mode != mode)) {
                self.host.enqueue(.{ .window = self.id, .workspace = ws.id, .pane = owner.pty.id, .kind = .focus_report }) catch continue;
                owner.focus_queued = true;
            }
        };
    }
    fn view(self: *Window, ctx: *ui.Context) void {
        if (self.closed) return;
        // Hidden UI checks render through their owned Tester context. The
        // dormant native surface must not overwrite its pane geometry or PTY
        // dimensions when asynchronous work wakes the application loop.
        if (self.host.hidden) if (self.native) |native| if (native.surface) |surface| {
            if (ctx == &surface.ctx) return;
        };
        self.document_context = ctx;
        defer self.nativeControls(ctx, false);
        if (self.native) |native| @import("window_chrome.zig").layout(native);
        defer self.syncFocus();
        defer self.contextMenu(ctx);
        defer self.sidebarMenu(ctx);
        defer if (self.palette_open) self.palette(ctx);
        defer self.finishPaneDrag(ctx);
        self.preview.shown = false;
        defer self.finishPreview(ctx);
        // The menu owns this event. Restore it for the deferred menu draw,
        // keeping outside dismissal from activating an underlying control.
        const menu_input = ctx.input;
        const input_blocked_at_start = self.blocksInput();
        if (self.session_menu != 0 or self.terminal_menu.open or self.palette_open) ctx.input = .{};
        defer ctx.input = menu_input;
        const appearance = self.host.settings.@"window-theme";
        if (std.mem.eql(u8, appearance, "light")) ctx.theme = .light else if (std.mem.eql(u8, appearance, "dark")) ctx.theme = .dark_theme;
        C.theme(ctx);
        @import("fonts.zig").install(ctx.text, self.host.settings.@"font-family");
        const translucent = @import("builtin").os.tag == .macos and self.host.settings.@"window-translucent" and !self.host.hidden;
        @import("backdrop.zig").draw(ctx, self.host.settings.background, translucent);
        const wash = ui.Color.transparent;
        const active = self.workspace(self.active);
        defer if (self.find_pane != 0) if (active) |ws| self.findBar(ctx, ws);
        if (ctx.size.w >= 680) self.sidebar_forced = false;
        const sidebar_shown = self.sidebar and (ctx.size.w >= 680 or self.sidebar_forced);
        const sidebar_width = @min(self.host.presentation.sidebar_width, @max(200, ctx.size.w * 0.4));
        var document_input_owned = false;
        if (active) |ws| if (ws.documents.visible and !self.blocksPointer()) {
            document_input_owned = DocumentDesktop.prepare(&ws.documents, ctx, self.documentPlacement(ctx, ws));
        };
        // A native surface and an offscreen tester can share this Window.
        // Input edge ownership belongs to each Context, across rebuild passes.
        const edges = ctx.state(struct { input: u64 = std.math.maxInt(u64), consumed: bool = false }, "terminal-input-edges");
        if (edges.input != ctx.frame) {
            edges.input = ctx.frame;
            edges.consumed = false;
            if (self.settings_open and self.input_settings_open and self.input_settings.recording != null) {
                edges.consumed = true;
                if (@import("input_settings.zig").capture(&self.input_settings, ctx)) |event| self.inputSettingsEvent(ctx, event);
            } else if (ctx.input.shortcut) |event| if (commands.match(.{ .key = event.key, .cmd = event.cmd, .ctrl = event.ctrl, .alt = event.alt, .shift = event.shift }, self.host.bindings, @import("builtin").os.tag == .macos)) |id| {
                const editable = self.rename_open or self.project_rename != 0 or self.find_pane != 0 or (if (ctx.focused_text) |focused| focused.editable else false);
                const save_without_document = std.mem.eql(u8, id, "document.save") and (active == null or !active.?.documents.visible);
                if (!save_without_document and (!editable or !std.mem.startsWith(u8, id, "edit."))) {
                    self.dispatchCommand(id);
                    edges.consumed = true;
                    ctx.shortcut_taken = true;
                }
            };
        }
        const shortcut_used = edges.consumed;
        self.host.recordingMenus(self.id, self.settings_open and self.input_settings_open and self.input_settings.recording != null);
        if (self.settings_open and self.settings_native == null) {
            self.settings(ctx);
            return;
        }
        ui.row(ctx, .{ .width = .fill, .height = .fill, .background = wash, .padding = .{ .top = 8, .right = 8, .bottom = 8, .left = if (sidebar_shown) 0 else 8 }, .gap = 0 });
        defer ui.end(ctx);
        if (sidebar_shown) {
            const side_node = ctx.open(.{ .width = .{ .px = sidebar_width }, .height = .fill }, "sidebar-area");
            self.chromeDivider(ctx, side_node, true, sidebar_width);
            self.sidebarView(ctx, active);
            ui.end(ctx);
        }
        ui.column(ctx, .{ .width = .fill, .height = .fill, .grow = 1, .gap = 8 });
        defer ui.end(ctx);
        if (active) |ws| {
            var available = ui.Rect{ .x = 0, .y = 0, .w = @max(100, ctx.size.w - if (sidebar_shown) sidebar_width + 8 else 16), .h = @max(100, ctx.size.h - 16) };
            if (ws.documents.visible) available.w = self.documentPlacement(ctx, ws).terminal.w;
            const total_width = available.w;
            const show_changes = self.changes_open and !ws.is_file and !ws.documents.visible;
            const review_width: f32 = if (show_changes) @max(300, @min(self.host.presentation.changes_width, total_width - 360)) else 0;
            if (show_changes) available.w -= review_width + 8;
            _ = ctx.open(.{ .width = .fill, .height = .fill, .grow = 1 }, "terminals");
            if (available.w > 0 and !ws.is_file) {
                if (ws.pane(self.zoom)) |owner| {
                    var leaf: Layout = .{ .pane = owner.key };
                    self.layout(ctx, ws, &leaf, available);
                } else self.layout(ctx, ws, ws.layout, available);
            }
            if (show_changes) if (ws.pane(ws.focus)) |owner| {
                if (self.review_pane != owner.pty.id) {
                    self.git_view.deinit(self.host.a);
                    self.git_view = .{};
                    self.review_pane = owner.pty.id;
                }
                const panel = ui.Rect{ .x = available.w + 8, .y = 0, .w = review_width, .h = available.h };
                self.chromeDivider(ctx, ctx.stack.items[ctx.stack.items.len - 1], false, review_width);
                if (ctx.input.pressed) if (ctx.rects.get(ctx.node(ctx.stack.items[ctx.stack.items.len - 1]).id)) |bounds| {
                    self.review_focus = ctx.input.mouse.x >= bounds.x + panel.x;
                };
                if (self.editor.open()) {
                    var enabled = self.active == self.editor.workspace and ws.focus == self.editor.pane;
                    for (ws.panes.items) |pane| if (std.mem.eql(u8, pane.status, "working")) {
                        enabled = false;
                        break;
                    };
                    const event = @import("review_editor.zig").view(&self.editor, ctx, self.host.a, panel, enabled) catch |err| blk: {
                        self.host.problem(err);
                        break :blk null;
                    };
                    if (event) |value| self.host.enqueue(.{ .window = self.id, .workspace = self.editor.workspace, .pane = self.editor.pane, .kind = switch (value) {
                        .save => .editor_save,
                        .reload => .editor_reload,
                        .close => .editor_close,
                    } }) catch |err| self.host.problem(err);
                } else {
                    var hunk_actions = true;
                    for (ws.panes.items) |pane| if (std.mem.eql(u8, pane.status, "working")) {
                        hunk_actions = false;
                        break;
                    };
                    const event = self.git_view.draw(ctx, self.host.a, &owner.changes, panel, self.host.settings.@"diff-layout", hunk_actions) catch |err| blk: {
                        self.host.problem(err);
                        break :blk null;
                    };
                    if (event) |value| switch (value) {
                        .close => {
                            self.setChanges(false);
                            self.review_focus = false;
                        },
                        .refresh => self.queue(.git_refresh, ws, owner),
                        .base => |base| self.host.enqueue(.{ .window = self.id, .workspace = ws.id, .pane = owner.pty.id, .kind = .git_base, .review_epoch = owner.changes.epoch, .text = @tagName(base) }) catch |err| self.host.problem(err),
                        .context => |lines| self.host.enqueue(.{ .window = self.id, .workspace = ws.id, .pane = owner.pty.id, .kind = .git_context, .review_epoch = owner.changes.epoch, .other = owner.changes.patchVersion(), .cols = 0, .value = @floatFromInt(lines) }) catch |err| self.host.problem(err),
                        .select => |path| self.host.enqueue(.{ .window = self.id, .workspace = ws.id, .pane = owner.pty.id, .kind = .git_select, .review_epoch = owner.changes.epoch, .text = path }) catch |err| self.host.problem(err),
                        .revert_hunk => |offset| self.host.enqueue(.{ .window = self.id, .workspace = ws.id, .pane = owner.pty.id, .kind = .revert_hunk, .review_epoch = owner.changes.epoch, .other = owner.changes.patchVersion(), .value = @floatFromInt(offset), .text = owner.changes.selected() }) catch |err| self.host.problem(err),
                        .edit => |path| self.host.enqueue(.{ .window = self.id, .workspace = ws.id, .pane = owner.pty.id, .kind = .editor_open, .review_epoch = owner.changes.epoch, .text = path }) catch |err| self.host.problem(err),
                        .open => |path| self.host.enqueue(.{ .window = self.id, .workspace = ws.id, .pane = owner.pty.id, .kind = .git_open, .review_epoch = owner.changes.epoch, .text = path }) catch |err| self.host.problem(err),
                    };
                }
            };
            ui.end(ctx);
            const terminal_edge = ctx.state(struct { frame: u64 = std.math.maxInt(u64) }, "terminal-key-edge");
            self.documentView(ctx, ws);
            if (!shortcut_used and !document_input_owned and !input_blocked_at_start and !self.blocksInput() and terminal_edge.frame != ctx.frame) {
                terminal_edge.frame = ctx.frame;
                self.handleInput(ctx, ws);
            }
        } else L.text(ctx, "Open a terminal to begin", .{ .color = ctx.theme.muted });
        if (self.host.problem_text.len > 0) ui.text(ctx, self.host.problem_text, .{ .size = 11, .color = ui.Color.hex(0xd93a35), .wrap = true });
    }
    fn sidebarView(self: *Window, ctx: *ui.Context, active: ?*Workspace) void {
        ui.column(ctx, .{ .width = .fill, .height = .fill, .padding = .{ .left = 10, .right = 10, .bottom = 4 }, .gap = 2 });
        defer ui.end(ctx);
        ui.row(ctx, .{ .width = .fill, .height = .{ .px = 44 }, .gap = 4, .align_items = .center, .justify = .end });
        ui.spacer(ctx);
        if (C.button(ctx, .panel, "Toggle Sidebar", 28)) self.host.enqueue(.{ .window = self.id, .kind = .sidebar_visibility }) catch |err| self.host.problem(err);
        if (C.button(ctx, .plus, "New Session", 28)) self.queue(.new_workspace, active, null);
        ui.end(ctx);
        _ = ctx.leaf(.{ .height = .{ .px = 10 } }, .none, null);
        ui.scroll(ctx, .{ .width = .fill, .height = .fill, .grow = 1 });
        for (self.workspaces.items) |ws| {
            ws.sidebar_rect = .{};
            ws.project_rect = .{};
        }
        if (self.project_rename != 0 and self.workspace(self.project_rename) == null) self.project_rename = 0;
        for (self.workspaces.items, 0..) |group, group_index| {
            var seen = false;
            var count: usize = 0;
            for (self.workspaces.items) |member| if (std.mem.eql(u8, member.directory, group.directory)) {
                count += 1;
            };
            for (self.workspaces.items[0..group_index]) |prior| if (std.mem.eql(u8, prior.directory, group.directory)) {
                seen = true;
                break;
            };
            if (seen) continue;
            ui.key(ctx, group.directory);
            const header = ctx.open(.{ .direction = .row, .width = .fill, .height = .{ .px = 28 }, .padding = .xy(10, 0), .gap = 4, .align_items = .center, .radius = 6 }, null);
            const hit = ctx.interact(header, .{});
            group.project_rect = ctx.rects.get(ctx.node(header).id) orelse .{};
            const renaming = if (self.workspace(self.project_rename)) |source| std.mem.eql(u8, source.directory, group.directory) else false;
            if (hit.clicked and !self.project_dragging and !renaming) self.host.enqueue(.{ .window = self.id, .kind = .toggle_group, .text = group.directory }) catch |err| self.host.problem(err);
            if (ctx.input.pressed and ctx.input.mouse_button == 1 and hit.pressed and !renaming) {
                self.project_drag = group.id;
                self.project_drag_start = ctx.input.mouse;
                self.project_dragging = false;
            }
            if (ctx.input.pressed and ctx.input.mouse_button == 2 and group.project_rect.contains(ctx.input.mouse)) {
                self.session_menu = group.id;
                self.session_menu_project = true;
                self.session_menu_point = ctx.input.mouse;
                self.session_menu_frame = ctx.frame;
                self.session_menu_state = .{};
                self.sidebar_drag = 0;
                self.project_drag = 0;
            }
            if (hit.hovered and !renaming) C.icon(ctx, if (self.host.presentation.folded(group.directory)) .right else .down, 10);
            if (renaming) {
                ui.key(ctx, "project-name");
                if (self.field_focus) {
                    ctx.focus = ctx.peekId(null);
                    self.field_focus = false;
                }
                const field = L.field(ctx, &self.rename_query, .{ .placeholder = "Project name", .width = .fill, .bare = true, .size = 12.5 });
                if (field.submitted) {
                    self.host.enqueue(.{ .window = self.id, .workspace = self.project_rename, .kind = .rename_project, .text = self.rename_query.text() }) catch |err| self.host.problem(err);
                    self.project_rename = 0;
                    ctx.focus = 0;
                } else if (ctx.input.key == .escape) {
                    self.project_rename = 0;
                    ctx.focus = 0;
                    ctx.changed = true;
                }
            } else ui.text(ctx, C.ellipsize(ctx, self.host.presentation.label(group.directory), self.host.presentation.sidebar_width - 90, 12.5), .{ .size = 12.5, .color = ctx.theme.muted });
            ui.spacer(ctx);
            if (hit.hovered) {
                if (C.button(ctx, .plus, "New Session in Project", 20)) self.queue(.new_workspace, group, null);
            } else ui.text(ctx, ctx.print("{d}", .{count}), .{ .size = 12, .color = ctx.theme.muted });
            ui.end(ctx);
            for (self.workspaces.items) |ws| {
                if (!std.mem.eql(u8, ws.directory, group.directory) or (self.host.presentation.folded(group.directory) and ws.id != self.active)) continue;
                ui.key(ctx, ctx.print("workspace-{d}", .{ws.id}));
                const selected = ws.id == self.active;
                const node = ctx.open(.{ .direction = .row, .width = .fill, .height = .{ .px = 34 }, .padding = .xy(12, 0), .align_items = .center, .gap = 6, .radius = 8, .background = if (selected) C.selected(ctx) else null, .border = if (selected) C.edge(ctx) else null, .shadow = if (selected) .{ .color = C.shadow(ctx), .blur = 4, .y = 1 } else null }, null);
                ws.sidebar_rect = ctx.rects.get(ctx.node(node).id) orelse .{};
                const interaction = ctx.interact(node, .{ .focusable = true });
                if (interaction.hovered and !selected) ctx.node(node).style.background = ctx.theme.surface_hover;
                if (ctx.input.pressed and interaction.pressed and ctx.input.mouse_button == 1 and !(self.rename_open and selected)) {
                    self.sidebar_drag = ws.id;
                    self.sidebar_drag_start = ctx.input.mouse;
                    self.sidebar_dragging = false;
                }
                if (interaction.clicked and !self.sidebar_dragging) {
                    self.activate(ws);
                    ctx.focus = 0;
                    if (ctx.input.click_count >= 2 and self.active == ws.id) {
                        self.rename_query.set(ws.title());
                        self.rename_open = true;
                        self.field_focus = true;
                    }
                }
                if (ctx.input.pressed and ctx.input.mouse_button == 2 and ws.sidebar_rect.contains(ctx.input.mouse)) {
                    self.session_menu = ws.id;
                    self.session_menu_project = false;
                    self.session_menu_point = ctx.input.mouse;
                    self.session_menu_frame = ctx.frame;
                    self.session_menu_state = .{};
                    self.project_menu_state = .{};
                    self.project_menu_open = false;
                    self.sidebar_drag = 0;
                }
                if (self.rename_open and selected) {
                    ui.key(ctx, "session-name");
                    if (self.field_focus) {
                        ctx.focus = ctx.peekId(null);
                        self.field_focus = false;
                    }
                    const field = L.field(ctx, &self.rename_query, .{ .placeholder = if (ws.is_file) "Workspace name" else "Session name", .width = .fill, .bare = true, .size = 13.5 });
                    if (field.submitted) {
                        const value = self.host.a.dupe(u8, self.rename_query.text()) catch return;
                        if (ws.name.len > 0) self.host.a.free(ws.name);
                        ws.name = value;
                        if (ws.is_file) self.host.markDocuments();
                        self.rename_open = false;
                        ctx.focus = 0;
                    }
                    if (ctx.input.key == .escape) {
                        self.rename_open = false;
                        ctx.focus = 0;
                    }
                } else {
                    const title = ctx.alloc().dupe(u8, ws.title()) catch "Terminal";
                    ui.text(ctx, C.ellipsize(ctx, title, self.host.presentation.sidebar_width - 72, 13.5), .{ .size = 13.5 });
                    ui.spacer(ctx);
                }
                if (ws.is_file) {
                    C.icon(ctx, if (ws.documents.selected()) |d| Documents.fileIcon(d.absolute()) else .document, 15);
                } else if (ws.pane(ws.focus)) |owner| C.status(ctx, owner.status, owner.unread, owner.pty.exit_code != null);
                ui.end(ctx);
                if (self.host.settings.@"git-status" and !ws.is_file) if (ws.pane(ws.focus)) |owner| if (@import("vcs_badge.zig").visible(&owner.changes)) {
                    nano.kit.tooltip(ctx, interaction, ctx.print("{s}\n{s}", .{ owner.changes.directory, @import("vcs_badge.zig").description(ctx, &owner.changes) }), .{});
                };
            }
        }
        if (self.project_drag != 0) {
            ctx.wants_moves = true;
            if (@abs(ctx.input.mouse.y - self.project_drag_start.y) + @abs(ctx.input.mouse.x - self.project_drag_start.x) > 5) self.project_dragging = true;
            if (!ctx.input.down) {
                if (self.project_dragging) if (self.workspace(self.project_drag)) |source| {
                    for (self.workspaces.items) |target| if (!std.mem.eql(u8, source.directory, target.directory) and target.project_rect.contains(ctx.input.mouse)) {
                        self.host.enqueue(.{ .window = self.id, .workspace = source.id, .other = target.id, .kind = .move_project, .delta = if (ctx.input.mouse.y >= target.project_rect.y + target.project_rect.h / 2) 1 else 0 }) catch |err| self.host.problem(err);
                        break;
                    };
                };
                self.project_drag = 0;
                self.project_dragging = false;
            }
        }
        if (self.sidebar_drag != 0) {
            ctx.wants_moves = true;
            if (@abs(ctx.input.mouse.y - self.sidebar_drag_start.y) + @abs(ctx.input.mouse.x - self.sidebar_drag_start.x) > 5) self.sidebar_dragging = true;
            if (!ctx.input.down) {
                if (self.sidebar_dragging) if (self.workspace(self.sidebar_drag)) |source| {
                    for (self.workspaces.items) |target| if (target.id != source.id and target.sidebar_rect.contains(ctx.input.mouse)) {
                        self.host.enqueue(.{ .window = self.id, .workspace = source.id, .other = target.id, .kind = if (std.mem.eql(u8, source.directory, target.directory)) .move_workspace else .assign_project, .delta = if (ctx.input.mouse.y >= target.sidebar_rect.y + target.sidebar_rect.h / 2) 1 else 0 }) catch |err| self.host.problem(err);
                        break;
                    };
                };
                self.sidebar_drag = 0;
                self.sidebar_dragging = false;
            }
        }
        ui.end(ctx);
        ui.row(ctx, .{ .width = .fill, .height = .{ .px = 34 }, .gap = 4, .align_items = .center });
        if (C.button(ctx, .folder, "Open Project…", 28)) self.dispatchCommand("project.open");
        if (C.button(ctx, .document, "Open File in Workspace…", 28)) self.dispatchCommand("document.open");
        if (C.button(ctx, .code, "Toggle Side Preview", 28)) self.dispatchCommand("document.toggle");
        if (C.button(ctx, .search, "Go to Session…", 28)) self.dispatchCommand("palette.open");
        if (C.button(ctx, .settings, "Settings", 28)) self.dispatchCommand("settings.open");
        ui.spacer(ctx);
        ui.end(ctx);
    }
    fn findBar(self: *Window, ctx: *ui.Context, ws: *Workspace) void {
        const owner = ws.pane(self.find_pane) orelse {
            self.closeFind();
            return;
        };
        const vt = owner.pty.terminal;
        const bounds = owner.screen_rect;
        const width = @min(374, @max(160, bounds.w - 24));
        ui.row(ctx, .{ .fixed = true, .absolute = true, .layer = 30, .offset = .{ .x = bounds.x + bounds.w - width - 12, .y = bounds.y + C.header_height + 8 }, .width = .{ .px = width }, .height = .{ .px = 36 }, .padding = .xy(8, 0), .align_items = .center, .gap = 4, .background = if (ctx.theme.dark) ui.Color.hex(0x232328) else .white, .border = C.edge(ctx), .shadow = .{ .color = C.shadow(ctx), .blur = 8, .y = 3 }, .radius = 10 });
        defer ui.end(ctx);
        C.icon(ctx, .search, 16);
        ui.key(ctx, "find-query");
        if (self.field_focus) {
            ctx.focus = ctx.peekId(null);
            self.field_focus = false;
        }
        const field = L.field(ctx, &self.find_query, .{ .placeholder = "Search", .width = .fill, .size = 13, .bare = true });
        if (field.changed) {
            vt.interaction.find(self.host.a, &vt.terminal, self.find_query.text()) catch |err| self.host.problem(err);
            owner.pumpSearch();
        }
        ui.text(ctx, if (self.find_query.len > 0) ctx.print("{d} / {d}", .{ vt.interaction.selected(), vt.interaction.count() }) else "", .{ .size = 12, .color = C.faint(ctx) });
        if (C.button(ctx, .up, "Previous match", 24) or (field.submitted and ctx.input.shift)) vt.interaction.next(&vt.terminal, false) catch |err| self.host.problem(err);
        if (C.button(ctx, .down, "Next match", 24) or (field.submitted and !ctx.input.shift)) vt.interaction.next(&vt.terminal, true) catch |err| self.host.problem(err);
        if (C.button(ctx, .close, "Close find", 24) or ctx.input.key == .escape) {
            self.closeFind();
            ctx.focus = 0;
        }
    }
    fn rename(self: *Window, ctx: *ui.Context) void {
        ui.column(ctx, .{ .width = .fill, .padding = .all(24), .gap = 12 });
        defer ui.end(ctx);
        L.text(ctx, "Rename session", .{ .size = 20, .weight = .bold });
        ui.key(ctx, "session-name");
        if (self.field_focus) {
            ctx.focus = ctx.peekId(null);
            self.field_focus = false;
        }
        const field = L.field(ctx, &self.rename_query, .{ .placeholder = "Session name", .width = .fill });
        if (field.submitted or L.button(ctx, "Rename", .{ .variant = .primary }).clicked) {
            if (self.workspace(self.active)) |ws| {
                const value = self.host.a.dupe(u8, self.rename_query.text()) catch return;
                if (ws.name.len > 0) self.host.a.free(ws.name);
                ws.name = value;
            }
            self.rename_open = false;
            ctx.focus = 0;
        }
        if (L.button(ctx, "Cancel", .{}).clicked or ctx.input.key == .escape) {
            self.rename_open = false;
            ctx.focus = 0;
        }
    }
    fn palette(self: *Window, ctx: *ui.Context) void {
        const overlay = ctx.leaf(.{ .fixed = true, .absolute = true, .layer = 35, .width = .fill, .height = .fill, .background = ui.Color.black.alpha(if (ctx.theme.dark) 0.35 else 0.12), .control = true }, .none, "palette-overlay");
        _ = ctx.interact(overlay, .{});
        const panel = ctx.open(.{ .fixed = true, .absolute = true, .layer = 40, .offset = .{ .x = @max(16, (ctx.size.w - 600) / 2), .y = @min(84, @max(16, ctx.size.h - 140)) }, .width = .{ .px = @min(600, ctx.size.w - 32) }, .height = .{ .px = @min(460, ctx.size.h - 100) }, .background = C.card(ctx), .radius = 14, .border = C.edge(ctx), .shadow = .{ .color = C.shadow(ctx), .blur = 20, .y = 6 } }, "command-palette");
        defer ui.end(ctx);
        const opening = self.field_focus;
        ui.row(ctx, .{ .width = .fill, .height = .{ .px = 50 }, .padding = .xy(16, 0), .gap = 10, .align_items = .center });
        C.icon(ctx, .search, 16);
        ui.key(ctx, "palette-query");
        if (self.field_focus) {
            ctx.focus = ctx.peekId(null);
            self.field_focus = false;
        }
        const field = L.field(ctx, &self.palette_query, .{ .placeholder = "Go to a session or run a command…", .width = .fill, .size = 15, .bare = true });
        ui.end(ctx);
        if (field.changed) self.palette_index = 0;
        const Item = struct { score: i32, title: []const u8, detail: []const u8 = "", keys: []const u8 = "", order: usize, command: []const u8 = "", workspace: u64 = 0 };
        var items: std.ArrayList(Item) = .empty;
        for (self.workspaces.items) |ws| {
            const title = ctx.print("{s} · {s}", .{ ws.title(), ws.directory });
            const score = commands.fuzzy(self.palette_query.text(), title);
            if (score >= 0) items.append(ctx.alloc(), .{ .score = score + 50, .title = ws.title(), .detail = ws.directory, .order = items.items.len, .workspace = ws.id }) catch return;
        }
        const file_target = if (self.workspace(self.active)) |ws| ws.is_file else false;
        for (commands.all, 0..) |cmd, index| {
            if (!cmd.implemented) continue;
            if (file_target and ((std.mem.startsWith(u8, cmd.id, "pane.") and !std.mem.eql(u8, cmd.id, "pane.close")) or std.mem.eql(u8, cmd.id, "changes.toggle") or std.mem.eql(u8, cmd.id, "document.selected"))) continue;
            const title = if (file_target and std.mem.eql(u8, cmd.id, "session.rename")) "Rename Workspace" else if (file_target and std.mem.eql(u8, cmd.id, "session.close")) "Close Workspace" else cmd.title;
            const score = commands.fuzzy(self.palette_query.text(), title);
            if (score >= 0) items.append(ctx.alloc(), .{ .score = score, .title = title, .keys = commands.keys(index, self.host.bindings, @import("builtin").os.tag == .macos), .order = items.items.len, .command = cmd.id }) catch return;
        }
        std.mem.sort(Item, items.items, {}, struct {
            fn less(_: void, a: Item, b: Item) bool {
                return a.score > b.score or (a.score == b.score and a.order < b.order);
            }
        }.less);
        var section_height: f32 = 0;
        var section_index: usize = items.items.len;
        if (self.palette_query.len == 0) for (items.items, 0..) |item, i| {
            if (i > 0 and item.workspace == 0 and items.items[i - 1].workspace != 0) {
                section_height = 28;
                section_index = i;
                break;
            }
        };
        const height = @min(@min(460, ctx.size.h - ctx.node(panel).style.offset.y - 16), if (items.items.len == 0) 102 else 62 + @as(f32, @floatFromInt(items.items.len)) * 38 + section_height);
        ctx.node(panel).style.height = .{ .px = height };
        const bounds: ui.Rect = .{ .x = ctx.node(panel).style.offset.x, .y = ctx.node(panel).style.offset.y, .w = ctx.node(panel).style.width.px, .h = height };
        if (ctx.input.pressed and !opening and !bounds.contains(ctx.input.mouse)) {
            self.palette_open = false;
            ctx.focus = 0;
            ctx.input.clearEdges();
            ctx.changed = true;
            return;
        }
        if (ctx.input.key == .down and items.items.len > 0) self.palette_index = (self.palette_index + 1) % items.items.len;
        if (ctx.input.key == .up and items.items.len > 0) self.palette_index = (self.palette_index + items.items.len - 1) % items.items.len;
        if (ctx.input.key == .home) self.palette_index = 0;
        if (ctx.input.key == .end) self.palette_index = items.items.len -| 1;
        self.palette_index = @min(self.palette_index, items.items.len -| 1);
        const list = ctx.open(.{ .scroll = true, .width = .fill, .height = .fill, .grow = 1, .padding = .all(6) }, "palette-results");
        const list_id = ctx.node(list).id;
        if (field.changed or opening) ctx.scroll.put(ctx.gpa, list_id, 0) catch {} else if (ctx.input.key != null) {
            const top = @as(f32, @floatFromInt(self.palette_index)) * 38 + (if (self.palette_index >= section_index) section_height else 0);
            const offset = ctx.scroll.get(list_id) orelse 0;
            ctx.scroll.put(ctx.gpa, list_id, std.math.clamp(offset, @max(0, top + 38 - height + 62), top)) catch {};
        }
        if (items.items.len == 0) {
            ui.column(ctx, .{ .width = .fill, .padding = .all(12) });
            L.text(ctx, "No matches", .{ .size = 13, .color = C.faint(ctx) });
            ui.end(ctx);
        }
        for (items.items, 0..) |item, i| {
            if (i > 0 and item.workspace == 0 and items.items[i - 1].workspace != 0 and self.palette_query.len == 0) {
                ui.column(ctx, .{ .padding = .{ .top = 10, .left = 10, .bottom = 4 } });
                L.text(ctx, "Commands", .{ .size = 11.5, .weight = .semibold, .color = C.faint(ctx) });
                ui.end(ctx);
            }
            ui.key(ctx, ctx.print("result-{d}", .{i}));
            const row = ctx.open(.{ .direction = .row, .width = .fill, .height = .{ .px = 38 }, .padding = .xy(12, 0), .gap = 10, .align_items = .center, .radius = 8, .control = true, .background = if (i == self.palette_index) ctx.theme.accent.alpha(0.12) else null }, null);
            const hit = ctx.interact(row, .{});
            if (item.workspace != 0) {
                if (self.workspace(item.workspace)) |ws| {
                    if (ws.is_file) C.icon(ctx, if (ws.documents.selected()) |document| Documents.fileIcon(document.absolute()) else .document, 15) else if (ws.pane(ws.focus)) |owner| C.status(ctx, owner.status, owner.unread, owner.pty.exit_code != null);
                }
            } else C.icon(ctx, .return_key, 14);
            ui.text(ctx, C.ellipsize(ctx, @import("locale.zig").t(item.title), @min(300, ctx.size.w - 140), 13.5), .{ .size = 13.5 });
            if (item.detail.len > 0) ui.text(ctx, C.ellipsize(ctx, item.detail, @max(20, @min(220, ctx.size.w - 400)), 12.5), .{ .size = 12.5, .color = C.faint(ctx) });
            ui.spacer(ctx);
            if (item.keys.len > 0) {
                ui.column(ctx, .{ .padding = .xy(5, 1), .radius = 4, .background = ctx.theme.text.alpha(0.045) });
                ui.text(ctx, C.shortcutLabel(ctx, item.keys), .{ .size = 11, .color = ctx.theme.muted });
                ui.end(ctx);
            }
            ui.end(ctx);
            if (hit.clicked or (field.submitted and i == self.palette_index)) {
                self.palette_open = false;
                ctx.focus = 0;
                if (item.workspace != 0) {
                    if (self.workspace(item.workspace)) |ws| self.activate(ws);
                } else self.dispatchCommand(item.command);
            }
        }
        ui.end(ctx);
        if (ctx.input.key == .escape) {
            self.palette_open = false;
            ctx.focus = 0;
        }
    }
    fn settings(self: *Window, ctx: *ui.Context) void {
        if (self.settings_discard) {
            self.settingsDiscard(ctx);
            return;
        }
        const Prefs = @import("preferences.zig");
        // Popovers are siblings of the page, outside its scroll/clip/input domain.
        defer if (self.preferences.menu != null) {
            if (Prefs.popup(&self.preferences, ctx, self.host.settings, &self.host.themes.?)) |edit| self.host.enqueue(.{ .window = self.id, .settings_epoch = self.preferences.draft.id, .kind = .set_setting, .text = ctx.print("{s}={s}", .{ edit.key, edit.value }) }) catch |err| self.host.problem(err);
        };
        ui.row(ctx, .{ .width = .fill, .height = .fill, .padding = .{ .top = 8, .right = 8, .bottom = 8 } });
        defer ui.end(ctx);
        ui.column(ctx, .{ .width = .{ .px = if (ctx.size.w < 700) 170 else 212 }, .height = .fill, .padding = .{ .left = 10, .right = 10, .top = 52, .bottom = 12 }, .gap = 2 });
        ui.row(ctx, .{ .width = .fill, .height = .{ .px = 28 }, .padding = .xy(10, 0), .gap = 8, .radius = 8, .background = C.card(ctx), .border = C.edge(ctx), .align_items = .center });
        C.icon(ctx, .search, 16);
        ui.key(ctx, "settings-search");
        _ = L.field(ctx, &self.preferences.query, .{ .placeholder = "Search", .width = .fill, .size = 13, .bare = true });
        ui.end(ctx);
        _ = ctx.leaf(.{ .height = .{ .px = 6 } }, .none, null);
        const icons = [_]C.Icon{ .settings, .paintbrush, .terminal, .code, .bell, .keyboard, .sliders };
        for (Prefs.names, 0..) |name, index| {
            ui.key(ctx, name);
            const selected = @backingInt(self.preferences.page) == index;
            const node = ctx.open(.{ .direction = .row, .width = .fill, .height = .{ .px = 32 }, .padding = .xy(10, 0), .gap = 10, .align_items = .center, .radius = 8, .control = true, .background = if (selected) C.selected(ctx) else null }, null);
            const hit = ctx.interact(node, .{ .focusable = true });
            if (hit.hovered and !selected) ctx.node(node).style.background = ctx.theme.surface_hover;
            C.tintedIcon(ctx, icons[index], 15, if (selected) ctx.theme.accent else ctx.theme.muted);
            L.text(ctx, name, .{ .size = 13.5 });
            ui.end(ctx);
            if (hit.clicked) {
                ctx.changed = true;
                self.preferences.page = @fromBackingInt(@intCast(index));
                self.preferences.query.clear();
                self.preferences.key = null;
                self.preferences.menu = null;
                self.theme_picker_open = false;
                self.input_settings_open = self.preferences.page == .keyboard;
                if (self.preferences.page == .keyboard) self.input_settings.tab = .shortcuts;
            }
        }
        ui.spacer(ctx);
        const config_link = ctx.open(.{ .direction = .row, .width = .fill, .height = .{ .px = 28 }, .padding = .xy(10, 0), .gap = 8, .align_items = .center, .radius = 6, .control = true }, "open-config");
        const config_hit = ctx.interact(config_link, .{ .focusable = true });
        C.icon(ctx, .code, 14);
        L.text(ctx, "Open configuration", .{ .size = 12, .color = ctx.theme.muted });
        ui.end(ctx);
        if (config_hit.clicked) self.queue(.edit_configuration, null, null);
        ui.end(ctx);
        ui.column(ctx, .{ .width = .fill, .grow = 1, .height = .fill, .radius = 14, .background = C.card(ctx), .border = C.edge(ctx), .shadow = .{ .color = C.shadow(ctx), .blur = 6, .y = 2 }, .clip = true });
        defer ui.end(ctx);
        ui.row(ctx, .{ .width = .fill, .height = .{ .px = 44 }, .padding = .xy(24, 0), .gap = 8, .align_items = .center });
        L.text(ctx, if (self.preferences.query.len > 0) "Search results" else Prefs.names[@backingInt(self.preferences.page)], .{ .size = 15, .weight = .semibold });
        ui.spacer(ctx);
        const drag_space = ctx.open(.{ .width = .fill, .grow = 1, .height = .fill }, "settings-window-drag");
        _ = ctx.interact(drag_space, .{});
        ui.end(ctx);
        if (self.settings_native) |native| if (ctx.rects.get(ctx.node(drag_space).id)) |gap| {
            _ = @import("window_chrome.zig").drag(native, ctx, gap);
        };
        ui.end(ctx);
        ui.column(ctx, .{ .width = .fill, .max_width = 668, .height = .fill, .grow = 1, .padding = .{ .left = 24, .right = 24, .top = 16, .bottom = 28 }, .gap = 22, .scroll = true, .clip = true });
        defer ui.end(ctx);
        if (self.theme_picker_open) {
            if (@import("theme_picker.zig").view(ctx, &self.theme_picker, &self.host.themes.?)) |event| switch (event) {
                .close => self.theme_picker_open = false,
                .use => |choice| {
                    const existing = self.host.settings.theme;
                    const light = @import("themes.zig").name(existing, false) catch "letty";
                    const night = @import("themes.zig").name(existing, true) catch "letty";
                    const spec = if (choice.scope == .both) choice.value else ctx.print("light:{s},dark:{s}", .{ if (choice.scope == .light) choice.value else light, if (choice.scope == .dark) choice.value else night });
                    self.host.enqueue(.{ .window = self.id, .settings_epoch = self.preferences.draft.id, .kind = .set_setting, .text = ctx.print("theme={s}", .{spec}) }) catch |err| self.host.problem(err);
                    self.theme_picker_open = false;
                },
            };
            return;
        }
        if (self.input_settings_open) {
            if (!self.input_settings.loaded) self.input_settings.load(if (self.preferences.draft.config) |draft| draft.env.items else self.host.configuration.?.env.items);
            if (@import("input_settings.zig").view(&self.input_settings, ctx, self.host.bindings)) |event| self.inputSettingsEvent(ctx, event);
            return;
        }
        if (@import("preferences.zig").view(&self.preferences, ctx, self.host.settings, &self.host.themes.?, self.host.theme_set)) |edit| self.host.enqueue(.{ .window = self.id, .settings_epoch = self.preferences.draft.id, .kind = .set_setting, .text = ctx.print("{s}={s}", .{ edit.key, edit.value }) }) catch |err| self.host.problem(err);
        if (self.preferences.page == .shell) {
            ui.column(ctx, .{ .width = .fill, .gap = 8 });
            L.text(ctx, "Environment", .{ .size = 12, .weight = .semibold, .color = ctx.theme.muted });
            const node = ctx.open(.{ .direction = .row, .width = .fill, .min_height = 50, .padding = .xy(16, 12), .radius = 12, .background = ctx.theme.text.alpha(if (ctx.theme.dark) 0.07 else 0.045), .align_items = .center, .gap = 12, .control = true }, "environment-settings");
            const hit = ctx.interact(node, .{ .focusable = true });
            L.text(ctx, "Edit environment", .{ .size = 13.5 });
            ui.spacer(ctx);
            C.icon(ctx, .right, 12);
            ui.end(ctx);
            L.text(ctx, "One NAME=value per line. Applied to new terminals.", .{ .size = 12, .color = ctx.theme.muted, .wrap = true });
            ui.end(ctx);
            if (hit.clicked) {
                self.input_settings_open = true;
                self.input_settings.tab = .environment;
                self.input_settings.loaded = false;
                ctx.changed = true;
            }
        }
        if (self.preferences.page == .advanced) self.advancedSettings(ctx);
        if (self.host.problem_text.len > 0) ui.text(ctx, self.host.problem_text, .{ .size = 12, .wrap = true, .color = ctx.theme.danger });
    }
    fn advancedSettings(self: *Window, ctx: *ui.Context) void {
        ui.column(ctx, .{ .width = .fill, .gap = 8 });
        defer ui.end(ctx);
        L.text(ctx, "Configuration", .{ .size = 12, .weight = .semibold, .color = ctx.theme.muted });
        ui.column(ctx, .{ .width = .fill, .radius = 12, .background = ctx.theme.text.alpha(if (ctx.theme.dark) 0.07 else 0.045), .padding = .xy(16, 4) });
        ui.row(ctx, .{ .width = .fill, .min_height = 58, .padding = .xy(0, 11), .gap = 12, .align_items = .center });
        ui.column(ctx, .{ .width = .fill, .grow = 1, .gap = 3 });
        L.text(ctx, "Config file", .{ .size = 13.5 });
        ui.text(ctx, C.ellipsize(ctx, self.host.config_path, @max(100, ctx.size.w - 370), 12), .{ .size = 12, .color = ctx.theme.muted });
        ui.end(ctx);
        if (L.button(ctx, "Open", .{ .size = 13 }).clicked) self.queue(.edit_configuration, null, null);
        ui.end(ctx);
        ui.divider(ctx);
        ui.row(ctx, .{ .width = .fill, .min_height = 58, .padding = .xy(0, 11), .gap = 12, .align_items = .center });
        ui.column(ctx, .{ .width = .fill, .grow = 1, .gap = 3 });
        L.text(ctx, "Reload configuration", .{ .size = 13.5 });
        L.text(ctx, "Read the saved configuration from disk.", .{ .size = 12, .color = ctx.theme.muted, .wrap = true });
        ui.end(ctx);
        if (L.button(ctx, "Reload", .{ .size = 13 }).clicked) self.queue(.reload_settings, null, null);
        ui.end(ctx);
        ui.end(ctx);
    }
    fn settingsDiscard(self: *Window, ctx: *ui.Context) void {
        const overlay = ctx.leaf(.{ .fixed = true, .absolute = true, .layer = 45, .width = .fill, .height = .fill, .background = ui.Color.black.alpha(if (ctx.theme.dark) 0.35 else 0.12), .control = true }, .none, "discard-overlay");
        _ = ctx.interact(overlay, .{});
        const width = @min(380, ctx.size.w - 32);
        ui.column(ctx, .{ .fixed = true, .absolute = true, .layer = 50, .offset = .{ .x = (ctx.size.w - width) / 2, .y = @max(16, (ctx.size.h - 140) / 2) }, .width = .{ .px = width }, .padding = .all(22), .gap = 8, .radius = 14, .background = C.card(ctx), .border = C.edge(ctx), .shadow = .{ .color = C.shadow(ctx), .blur = 16, .y = 6 } });
        defer ui.end(ctx);
        L.text(ctx, "Unsaved changes", .{ .size = 15, .weight = .semibold });
        L.text(ctx, "Discard the draft and close Settings?", .{ .size = 13, .color = ctx.theme.muted, .wrap = true });
        ui.row(ctx, .{ .width = .fill, .gap = 8, .justify = .end, .padding = .{ .top = 8 } });
        defer ui.end(ctx);
        if (L.button(ctx, "Keep editing", .{ .variant = .primary, .size = 13 }).clicked or ctx.input.key == .escape) self.dispatchCommand("settings.keepEditing");
        if (L.button(ctx, "Discard and close", .{ .size = 13 }).clicked) self.dispatchCommand("settings.discard");
    }
    fn contextMenu(self: *Window, ctx: *ui.Context) void {
        if (!self.terminal_menu.open) return;
        const event = @import("terminal_menu.zig").view(&self.terminal_menu, ctx) orelse return;
        const target = self.terminal_menu;
        defer self.terminal_menu.close(self.host.a);
        switch (event) {
            .close => {},
            .command => |id| self.host.enqueue(.{ .window = self.id, .workspace = target.workspace, .pane = target.pane, .kind = .command, .text = id }) catch |err| self.host.problem(err),
            .open_link, .copy_link => self.host.enqueue(.{ .window = self.id, .workspace = target.workspace, .pane = target.pane, .kind = if (event == .open_link) .open_link else .copy_link, .text = target.link }) catch |err| self.host.problem(err),
        }
        ctx.focus = 0;
    }
    fn inputSettingsEvent(self: *Window, ctx: *ui.Context, event: @import("input_settings.zig").Event) void {
        switch (event) {
            .close => self.input_settings_open = false,
            .edit_config => self.queue(.edit_configuration, null, null),
            .environment => |text| self.host.enqueue(.{ .window = self.id, .settings_epoch = self.preferences.draft.id, .kind = .set_environment, .text = text }) catch |err| self.host.problem(err),
            .binding => |binding| self.host.enqueue(.{ .window = self.id, .settings_epoch = self.preferences.draft.id, .kind = .set_binding, .text = ctx.print("{s}={s}", .{ binding.id, binding.chord }) }) catch |err| self.host.problem(err),
        }
        self.host.recordingMenus(self.id, self.settings_open and self.input_settings_open and self.input_settings.recording != null);
    }
    fn finishPreview(self: *Window, ctx: *ui.Context) void {
        if (self.preview.shown) self.preview.view(ctx) else if (self.preview.was_shown) self.host.enqueue(.{ .window = self.id, .kind = .image_hide }) catch {};
        self.preview.was_shown = self.preview.shown;
    }
    fn finishPaneDrag(self: *Window, ctx: *ui.Context) void {
        if (self.drag_pane == 0) return;
        const edge = ctx.state(struct { frame: u64 = 0 }, "pane-drag-edge");
        if (edge.frame == ctx.frame) return;
        edge.frame = ctx.frame;
        if (self.blocksInput() or ctx.input.key == .escape) {
            self.drag_pane = 0;
            self.dragging_pane = false;
            return;
        }
        const dx = ctx.input.mouse.x - self.drag_start.x;
        const dy = ctx.input.mouse.y - self.drag_start.y;
        if (ctx.input.down and dx * dx + dy * dy > 36) self.dragging_pane = true;
        if (ctx.input.released) {
            defer {
                self.drag_pane = 0;
                self.dragging_pane = false;
            }
            if (!self.dragging_pane or self.active != self.drag_workspace) return;
            const ws = self.workspace(self.drag_workspace) orelse return;
            if (ws.pane(self.drag_pane) == null) return;
            for (ws.panes.items) |owner| if (owner.pty.id != self.drag_pane and owner.screen_rect.contains(ctx.input.mouse)) {
                const rect = owner.screen_rect;
                const zone = @import("layout_actions.zig").zone((ctx.input.mouse.x - rect.x) / rect.w, (ctx.input.mouse.y - rect.y) / rect.h);
                self.host.enqueue(.{ .window = self.id, .workspace = ws.id, .pane = self.drag_pane, .other = owner.pty.id, .kind = .pane_move, .text = @tagName(zone) }) catch |err| self.host.problem(err);
                break;
            };
        } else if (!ctx.input.down) {
            self.drag_pane = 0;
            self.dragging_pane = false;
        }
    }
    fn splitDivider(self: *Window, ctx: *ui.Context, ws: *Workspace, tree: *Layout, rect: ui.Rect, position: f32) void {
        const model = @import("layout_actions.zig");
        const left = ws.panes.items;
        var one: u64 = 0;
        var two: u64 = 0;
        for (left) |pane| {
            if (std.mem.eql(u8, pane.key, model.first(tree.a.?))) one = pane.pty.id;
            if (std.mem.eql(u8, pane.key, model.first(tree.b.?))) two = pane.pty.id;
        }
        const node = ctx.leaf(.{ .absolute = true, .layer = 2, .offset = .{ .x = rect.x + if (tree.row) position else 0, .y = rect.y + if (tree.row) 0 else position }, .width = .{ .px = if (tree.row) 8 else rect.w }, .height = .{ .px = if (tree.row) rect.h else 8 } }, .none, ctx.print("divider-{d}-{d}", .{ one, two }));
        const hit = ctx.interact(node, .{});
        if (hit.hovered or ctx.active == hit.id) ctx.cursor = if (tree.row) .resize_left_right else .resize_up_down;
        if (ctx.active == hit.id and ctx.input.down) if (ctx.rects.get(ctx.node(node).id)) |bounds| {
            const start = if (tree.row) bounds.x - position else bounds.y - position;
            const mouse = if (tree.row) ctx.input.mouse.x else ctx.input.mouse.y;
            const size = @max(1, if (tree.row) rect.w - 8 else rect.h - 8);
            const frame = ctx.state(struct { frame: u64 = 0 }, "divider-edge");
            if (frame.frame != ctx.frame) {
                frame.frame = ctx.frame;
                self.host.enqueue(.{ .window = self.id, .workspace = ws.id, .pane = one, .other = two, .kind = .split_resize, .value = (mouse - start - 4) / size }) catch |err| self.host.problem(err);
            }
        };
    }
    fn chromeDivider(self: *Window, ctx: *ui.Context, parent: u32, sidebar_: bool, width: f32) void {
        const parent_rect = ctx.rects.get(ctx.node(parent).id) orelse return;
        const node = ctx.leaf(.{ .absolute = true, .layer = 3, .offset = .{ .x = if (sidebar_) width - 2 else parent_rect.w - width - 8 }, .width = .{ .px = 8 }, .height = .fill }, .none, if (sidebar_) "sidebar-divider" else "changes-divider");
        const hit = ctx.interact(node, .{});
        if (hit.hovered or ctx.active == hit.id) ctx.cursor = .resize_left_right;
        if (ctx.active == hit.id and ctx.input.down) {
            const value = if (sidebar_) ctx.input.mouse.x - parent_rect.x else parent_rect.x + parent_rect.w - ctx.input.mouse.x;
            self.host.enqueue(.{ .window = self.id, .kind = .chrome_resize, .text = if (sidebar_) "sidebar" else "changes", .value = value }) catch |err| self.host.problem(err);
        }
    }
    fn layout(self: *Window, ctx: *ui.Context, ws: *Workspace, tree: *Layout, rect: ui.Rect) void {
        if (!tree.leaf()) {
            const gap: f32 = 8;
            const ratio: f32 = @floatCast(tree.ratio);
            var first = rect;
            var second = rect;
            if (tree.row) {
                first.w = (rect.w - gap) * ratio;
                second.x += first.w + gap;
                second.w = rect.w - first.w - gap;
            } else {
                first.h = (rect.h - gap) * ratio;
                second.y += first.h + gap;
                second.h = rect.h - first.h - gap;
            }
            if (tree.a) |a| self.layout(ctx, ws, a, first);
            if (tree.b) |b| self.layout(ctx, ws, b, second);
            if (!self.blocksInput()) self.splitDivider(ctx, ws, tree, rect, if (tree.row) first.w else first.h);
            return;
        }
        var found: ?*Owner = null;
        for (ws.panes.items) |owner| if (std.mem.eql(u8, owner.key, tree.pane)) {
            found = owner;
            break;
        };
        const owner = found orelse return;
        owner.rect = rect;
        if (!self.host.hidden and self.host.settings.@"git-status" and !owner.changes.initialized) owner.refreshGit();
        const active = owner.pty.id == ws.focus;
        const vt = owner.pty.terminal;
        const cursor_style = self.host.settings.@"cursor-style";
        vt.terminal.setDefaultCursorStyle(if (std.mem.eql(u8, cursor_style, "bar")) .bar else if (std.mem.eql(u8, cursor_style, "underline")) .underline else .block);
        vt.terminal.setDefaultCursorBlink(self.host.settings.@"cursor-style-blink");
        if (active and owner.viewed() and owner.unread) {
            owner.unread = false;
            self.host.queueAttention();
        }
        vt.applyColors(if (ctx.theme.dark) self.host.theme_set.dark else self.host.theme_set.light, ctx.theme.dark) catch |err| self.host.problem(err);
        const m = render.metrics(ctx, self.host.settings);
        const cols: u16 = @intFromFloat(std.math.clamp(@floor((rect.w - 2 * C.terminal_inset) / m.width), 2, 1000));
        const rows: u16 = @intFromFloat(std.math.clamp(@floor((rect.h - C.header_height - 2 * C.terminal_inset) / m.height), 2, 1000));
        if (cols != owner.last_cols or rows != owner.last_rows) {
            self.host.enqueue(.{ .window = self.id, .workspace = ws.id, .pane = owner.pty.id, .kind = .resize, .cols = cols, .rows = rows, .cell_w = @intFromFloat(@max(1, @round(m.width * ctx.scale))), .cell_h = @intFromFloat(@max(1, @round(m.height * ctx.scale))) }) catch |err| self.host.problem(err);
        }
        const card = ctx.open(.{ .absolute = true, .offset = .{ .x = rect.x, .y = rect.y }, .width = .{ .px = @max(20, rect.w) }, .height = .{ .px = @max(60, rect.h) }, .background = C.card(ctx), .radius = 14, .border = C.edge(ctx), .shadow = .{ .color = C.shadow(ctx), .blur = 6, .y = 2 }, .clip = true }, owner.key);
        const hit = ctx.interact(card, .{});
        if (ctx.rects.get(ctx.node(card).id)) |bounds| owner.screen_rect = bounds;
        if (hit.clicked) self.queue(.focus, ws, owner);
        const single = ws.panes.items.len == 1;
        const first_card = rect.x < 8 and rect.y < 8;
        const native_padding: f32 = if (@import("builtin").os.tag != .macos and !self.changes_open and rect.y < 8 and rect.x + rect.w >= ctx.size.w - (if (self.sidebar) self.host.presentation.sidebar_width else 0) - 20) 94 else 0;
        const hidden_sidebar = !(self.sidebar and (ctx.size.w >= 680 or self.sidebar_forced));
        ui.row(ctx, .{ .width = .fill, .height = .{ .px = 44 }, .padding = .{ .left = if (first_card and hidden_sidebar and @import("builtin").os.tag == .macos) 86 else 16, .right = 10 + native_padding }, .align_items = .center, .gap = 8 });
        if (first_card and hidden_sidebar) {
            if (C.button(ctx, .panel, "Toggle Sidebar", 28)) self.host.enqueue(.{ .window = self.id, .kind = .sidebar_visibility, .delta = 1 }) catch |err| self.host.problem(err);
            if (C.button(ctx, .plus, "New Session", 28)) self.queue(.new_workspace, ws, null);
        }
        if (!single) C.icon(ctx, .terminal, 14);
        const Badge = @import("vcs_badge.zig");
        const badge_width: f32 = if (self.host.settings.@"git-status" and Badge.visible(&owner.changes) and rect.w >= 280) @min(260, @max(60, rect.w * 0.4)) else 0;
        const grip_width = @max(20, rect.w - (if (single) @as(f32, 100) else 170) - native_padding - badge_width);
        const grip = ctx.open(.{ .direction = .row, .max_width = grip_width, .height = .fill, .gap = 8, .align_items = .center, .clip = true }, "pane-grip");
        const grip_hit = ctx.interact(grip, .{});
        if (ctx.input.pressed and grip_hit.pressed and ctx.input.mouse_button == 1 and !self.blocksInput()) {
            self.drag_pane = owner.pty.id;
            self.drag_workspace = ws.id;
            self.drag_start = ctx.input.mouse;
            self.dragging_pane = false;
        }
        const title = ctx.alloc().dupe(u8, if (single) ws.title() else owner.pty.terminal.terminal.getTitle() orelse std.fs.path.basename(owner.pty.directory)) catch "Terminal";
        const title_width = @min(@max(20, rect.w - 200), if (grip_width > 160) grip_width * 0.45 else grip_width);
        ui.text(ctx, C.ellipsize(ctx, title, title_width, if (single) 14 else 13.5), .{ .size = if (single) 14 else 13.5, .weight = .semibold, .color = if (active) ctx.theme.text else ctx.theme.muted });
        if (grip_width > 160) {
            const directory = if (owner.changes.directory.len > 0) owner.changes.directory else @import("paths.zig").directory(ctx.alloc(), vt.terminal.getPwd(), owner.pty.directory) catch owner.pty.directory;
            const title_used = ctx.text.layout(title, .{ .size = if (single) 14 else 13.5, .weight = .semibold }).width;
            ui.text(ctx, C.ellipsize(ctx, directory, @max(0, grip_width - @min(title_width, title_used) - 8), 13), .{ .size = 13, .color = C.faint(ctx) });
        }
        ui.end(ctx);
        if (badge_width > 0) if (Badge.draw(ctx, &owner.changes, badge_width)) |badge| if (badge.clicked) self.queue(.git_show, ws, owner);
        const window_gap = ctx.open(.{ .width = .fill, .grow = 1, .height = .fill }, "window-drag");
        _ = ctx.interact(window_gap, .{});
        ui.end(ctx);
        if (rect.y < 8) if (self.native) |native| if (ctx.rects.get(ctx.node(window_gap).id)) |gap| {
            _ = @import("window_chrome.zig").drag(native, ctx, gap);
        };
        if ((!single and active) or hit.hovered) {
            ui.row(ctx, .{ .height = .{ .px = 28 }, .gap = 0 });
            if (C.button(ctx, .split_right, "Split Right", 28)) self.queue(.split_right, ws, owner);
            if (C.button(ctx, .split_down, "Split Down", 28)) self.queue(.split_down, ws, owner);
            if (!single) {
                if (C.button(ctx, if (self.zoom == owner.pty.id) .unzoom else .zoom, if (self.zoom == owner.pty.id) "Show all panes" else "Zoom pane", 28)) self.zoom = if (self.zoom == owner.pty.id) 0 else owner.pty.id;
                if (C.button(ctx, .close, "Close pane", 28)) self.queue(.close_pane, ws, owner);
            }
            ui.end(ctx);
        }
        ui.end(ctx);
        const bg = vt.terminal.colors.background.get() orelse ghostty.color.RGB{ .r = 0, .g = 0, .b = 0 };
        const body = ctx.open(.{ .width = .fill, .height = .fill, .grow = 1, .padding = .all(C.terminal_inset), .background = ui.Color.hex((@as(u24, bg.r) << 16) | (@as(u24, bg.g) << 8) | bg.b), .clip = true, .opacity = if (!active and self.host.settings.@"dim-unfocused-terminals") 0.7 else 1 }, "body");
        const pointer_edge = ctx.state(struct { frame: u64 = std.math.maxInt(u64) }, "terminal-pointer-edge");
        if (!self.blocksPointer() and pointer_edge.frame != ctx.frame) if (ctx.rects.get(ctx.node(body).id)) |bounds| {
            pointer_edge.frame = ctx.frame;
            self.pointer(ctx, ws, owner, bounds, m) catch |err| self.host.problem(err);
        };
        render.paint(vt, ctx, m, active) catch |err| self.host.problem(err);
        if (!self.blocksPointer() and (if (@import("builtin").os.tag == .macos) ctx.input.cmd else ctx.input.ctrl)) if (ctx.rects.get(ctx.node(body).id)) |bounds| if (bounds.contains(ctx.input.mouse)) {
            const x: u16 = @intFromFloat(std.math.clamp(@floor((ctx.input.mouse.x - bounds.x - C.terminal_inset) / m.width), 0, @as(f32, @floatFromInt(vt.terminal.cols - 1))));
            const y: u16 = @intFromFloat(std.math.clamp(@floor((ctx.input.mouse.y - bounds.y - C.terminal_inset) / m.height), 0, @as(f32, @floatFromInt(vt.terminal.rows - 1))));
            if (@import("document_links.zig").at(ctx.alloc(), &vt.terminal, x, y) catch null) |target| {
                if (!@import("paths.zig").web(target.text) and !self.trustedPath(owner, target.text)) {
                    ui.column(ctx, .{ .fixed = true, .absolute = true, .layer = 35, .offset = .{ .x = @max(8, ctx.input.mouse.x - 120), .y = @min(ctx.size.h - 44, ctx.input.mouse.y + 16) }, .max_width = 360, .padding = .all(8), .radius = 6, .background = ctx.theme.surface, .border = ctx.theme.border });
                    ui.text(ctx, if (self.path_origin.refusal) |reason| reason.message() else "Only verified local file paths can be previewed", .{ .size = 11, .color = ctx.theme.muted, .wrap = true });
                    ui.end(ctx);
                } else {
                    ctx.cursor = .hand;
                    render.link(ctx, m, target, vt.terminal.cols);
                    if (@import("paths.zig").image(target.text) and !@import("paths.zig").web(target.text)) {
                        self.preview.shown = true;
                        self.preview.anchor = ctx.input.mouse;
                        if ((!self.preview.was_shown or self.preview.pane != owner.pty.id or !std.mem.eql(u8, self.preview.token, target.text)) and self.preview_edge != ctx.frame) {
                            self.preview_edge = ctx.frame;
                            self.host.enqueue(.{ .window = self.id, .workspace = ws.id, .pane = owner.pty.id, .kind = .image_hover, .text = target.text }) catch |err| self.host.problem(err);
                        }
                    }
                }
            }
        };
        if (active and !self.blocksInput()) {
            if (self.marked_pane != owner.pty.id) {
                self.marked.clearRetainingCapacity();
                self.marked_pane = owner.pty.id;
            }
            const cursor = vt.render.cursor;
            const cursor_x = if (cursor.viewport) |point| point.x else 0;
            const cursor_y = if (cursor.viewport) |point| point.y else 0;
            const origin = ctx.rects.get(ctx.node(body).id) orelse rect;
            const marked_text = ctx.alloc().dupe(u8, self.marked.items) catch "";
            ctx.focused_text = .{ .id = owner.pty.id, .editable = false, .text = marked_text, .caret = marked_text.len, .anchor = marked_text.len, .marked = if (marked_text.len > 0) .{ 0, marked_text.len } else null, .caret_rect = .{ .x = origin.x + C.terminal_inset + @as(f32, @floatFromInt(cursor_x)) * m.width, .y = origin.y + C.terminal_inset + @as(f32, @floatFromInt(cursor_y)) * m.height, .w = m.width, .h = m.height } };
            if (marked_text.len > 0) ui.text(ctx, marked_text, .{ .mono = true, .size = m.font.size });
        }
        ui.end(ctx);
        if (self.dragging_pane and self.drag_workspace == ws.id and self.drag_pane != owner.pty.id and owner.screen_rect.contains(ctx.input.mouse)) {
            const bounds = owner.screen_rect;
            const zone = @import("layout_actions.zig").zone((ctx.input.mouse.x - bounds.x) / bounds.w, (ctx.input.mouse.y - bounds.y) / bounds.h);
            var preview = ui.Rect{ .w = rect.w, .h = rect.h };
            switch (zone) {
                .left => preview.w /= 2,
                .right => {
                    preview.x = rect.w / 2;
                    preview.w /= 2;
                },
                .up => preview.h /= 2,
                .down => {
                    preview.y = rect.h / 2;
                    preview.h /= 2;
                },
                .swap => {},
            }
            _ = ctx.leaf(.{ .absolute = true, .layer = 8, .offset = .{ .x = preview.x, .y = preview.y }, .width = .{ .px = preview.w }, .height = .{ .px = preview.h }, .radius = 12, .background = ctx.theme.accent.alpha(0.2) }, .none, "drop-preview");
        }
        ui.end(ctx);
    }
    fn handleInput(self: *Window, ctx: *ui.Context, ws: *Workspace) void {
        const owner = ws.pane(ws.focus) orelse return;
        if (@import("builtin").os.tag == .macos and !self.host.settings.@"macos-option-as-alt") if (ctx.input.shortcut) |event| if (event.alt and !event.ctrl and !event.cmd and ctx.input.ops.len == 0) return;
        for (ctx.input.ops) |op| switch (op) {
            .set_marked => |marked| {
                if (marked.text.len > 65536) {
                    self.host.problem(error.CompositionLimit);
                    continue;
                }
                self.marked.clearRetainingCapacity();
                self.marked_pane = owner.pty.id;
                self.marked.appendSlice(self.host.a, marked.text) catch {};
            },
            .unmark => self.marked.clearRetainingCapacity(),
            .insert => |text| {
                if (self.marked.items.len > 0 and self.marked_pane != owner.pty.id) {
                    self.marked.clearRetainingCapacity();
                    continue;
                }
                self.marked.clearRetainingCapacity();
                self.commitText(ctx, ws, owner, text);
            },
            .command => |command| switch (command) {
                .delete_backward => self.typeKey(ctx, ws, owner, .backspace),
                .delete_forward => self.typeKey(ctx, ws, owner, .delete),
                .insert_newline, .insert_line_break => self.typeKey(ctx, ws, owner, .enter),
                .insert_tab => self.typeKey(ctx, ws, owner, .tab),
                .cancel => self.typeKey(ctx, ws, owner, .escape),
                .move_left => self.typeKey(ctx, ws, owner, .arrow_left),
                .move_right => self.typeKey(ctx, ws, owner, .arrow_right),
                .move_up => self.typeKey(ctx, ws, owner, .arrow_up),
                .move_down => self.typeKey(ctx, ws, owner, .arrow_down),
                .move_line_start => self.typeText(ws, owner, "\x01"),
                .move_line_end => self.typeText(ws, owner, "\x05"),
                .delete_to_line_start => self.typeText(ws, owner, "\x15"),
                .delete_to_line_end => self.typeText(ws, owner, "\x0b"),
                .delete_word_backward => self.typeText(ws, owner, "\x17"),
                .move_word_left => self.typeText(ws, owner, "\x1bb"),
                .move_word_right => self.typeText(ws, owner, "\x1bf"),
                .copy => self.queue(.copy, ws, owner),
                .select_all => owner.pty.terminal.terminal.screens.active.select(owner.pty.terminal.terminal.screens.active.selectAll()) catch |err| self.host.problem(err),
                else => {},
            },
        };
        if (ctx.input.ops.len > 0) return;
        var buf: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        const input = ctx.input;
        var key: ghostty.input.Key = .unidentified;
        if (input.key) |k| key = switch (k) {
            .backspace => .backspace,
            .delete => .delete,
            .left => .arrow_left,
            .right => .arrow_right,
            .up => .arrow_up,
            .down => .arrow_down,
            .home => .home,
            .end => .end,
            .enter => .enter,
            .tab => .tab,
            .escape => .escape,
            .page_up => .page_up,
            .page_down => .page_down,
            .f1 => .f1,
            .f2 => .f2,
            .f3 => .f3,
            .f4 => .f4,
            .f5 => .f5,
            .f6 => .f6,
            .f7 => .f7,
            .f8 => .f8,
            .f9 => .f9,
            .f10 => .f10,
            .f11 => .f11,
            .f12 => .f12,
        };
        var unshifted: u21 = 0;
        const mods: ghostty.input.KeyMods = if (input.shortcut) |shortcut| .{ .ctrl = shortcut.ctrl, .alt = shortcut.alt, .shift = shortcut.shift, .super = shortcut.cmd } else .{ .ctrl = input.ctrl, .alt = input.alt, .shift = input.shift, .super = input.cmd };
        if (input.shortcut) |shortcut| {
            unshifted = shortcut.key;
            if (shortcut.key < 128) key = ghostty.input.Key.fromASCII(@intCast(shortcut.key)) orelse key;
        }
        ghostty.input.encodeKey(&writer, .{ .action = .press, .key = key, .mods = mods, .utf8 = input.chars, .unshifted_codepoint = unshifted }, self.keyOptions(owner)) catch |err| {
            self.host.problem(err);
            return;
        };
        if (writer.buffered().len > 0) {
            self.typeText(ws, owner, writer.buffered());
            if (input.shortcut != null) ctx.shortcut_taken = true;
        }
    }
    fn keyOptions(self: *Window, owner: *Owner) ghostty.input.KeyEncodeOptions {
        var options: ghostty.input.KeyEncodeOptions = .fromTerminal(&owner.pty.terminal.terminal);
        options.macos_option_as_alt = if (self.host.settings.@"macos-option-as-alt") .true else .false;
        return options;
    }
    fn commitText(self: *Window, ctx: *ui.Context, ws: *Workspace, owner: *Owner, text: []const u8) void {
        if (text.len == 0 or text.len > 1024 * 1024) return;
        var local: [512]u8 = undefined;
        const size = text.len * 8 + 256;
        const buffer = if (size <= local.len) &local else self.host.a.alloc(u8, size) catch return;
        defer if (size > local.len) self.host.a.free(buffer);
        var writer: std.Io.Writer = .fixed(buffer);
        var codepoint: u21 = 0;
        var iterator = (std.unicode.Utf8View.init(text) catch return).iterator();
        if (iterator.nextCodepoint()) |cp| if (iterator.nextCodepoint() == null) {
            codepoint = cp;
        };
        const unshifted = if (codepoint < 128) @as(u21, std.ascii.toLower(@intCast(codepoint))) else codepoint;
        const key: ghostty.input.Key = if (unshifted < 128 and unshifted != 0) ghostty.input.Key.fromASCII(@intCast(unshifted)) orelse .unidentified else .unidentified;
        ghostty.input.encodeKey(&writer, .{ .action = .press, .key = key, .utf8 = text, .unshifted_codepoint = unshifted, .mods = .{ .shift = ctx.input.shift } }, self.keyOptions(owner)) catch |err| {
            self.host.problem(err);
            return;
        };
        self.typeText(ws, owner, writer.buffered());
    }
    fn pointer(self: *Window, ctx: *ui.Context, ws: *Workspace, owner: *Owner, bounds: ui.Rect, m: render.Metrics) !void {
        const input = ctx.input;
        const vt = owner.pty.terminal;
        const inside = bounds.contains(input.mouse);
        if (inside and (vt.terminal.flags.mouse_event != .none or (if (@import("builtin").os.tag == .macos) input.cmd else input.ctrl))) ctx.wants_moves = true;
        const dragging = vt.interaction.dragging or owner.mouse_button != null;
        if (!inside and !dragging) return;
        if (inside and (input.pressed or (self.host.settings.@"focus-follows-mouse" and ws.focus != owner.pty.id))) self.queue(.focus, ws, owner);
        const px = input.mouse.x - bounds.x - C.terminal_inset;
        const py = input.mouse.y - bounds.y - C.terminal_inset;
        const col: u16 = @intFromFloat(std.math.clamp(@floor(px / m.width), 0, @as(f32, @floatFromInt(vt.terminal.cols - 1))));
        const row: u16 = @intFromFloat(std.math.clamp(@floor(py / m.height), 0, @as(f32, @floatFromInt(vt.terminal.rows - 1))));
        const link_modifier = if (@import("builtin").os.tag == .macos) input.cmd else input.ctrl;
        if (inside and input.pressed and input.mouse_button == 1 and link_modifier) if (try @import("document_links.zig").at(ctx.alloc(), &vt.terminal, col, row)) |target| {
            if (@import("paths.zig").web(target.text) or self.trustedPath(owner, target.text)) {
                try self.host.enqueue(.{ .window = self.id, .workspace = ws.id, .pane = owner.pty.id, .kind = .open_link, .text = target.text });
                return;
            }
        };
        const reporting = vt.terminal.flags.mouse_event != .none and !input.shift;
        if (reporting) {
            var buf: [2048]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buf);
            const cell_w: u32 = @intFromFloat(@max(1, @round(m.width * ctx.scale)));
            const cell_h: u32 = @intFromFloat(@max(1, @round(m.height * ctx.scale)));
            var options: ghostty.input.MouseEncodeOptions = .fromTerminal(&vt.terminal, .{ .screen = .{ .width = cell_w * vt.terminal.cols, .height = cell_h * vt.terminal.rows }, .cell = .{ .width = cell_w, .height = cell_h }, .padding = .{} });
            options.last_cell = &owner.mouse_cell;
            if (input.pressed) owner.mouse_button = switch (input.mouse_button) {
                1 => .left,
                2 => .right,
                3 => .middle,
                else => null,
            };
            options.any_button_pressed = owner.mouse_button != null;
            const mods: ghostty.input.KeyMods = .{ .shift = input.shift, .ctrl = input.ctrl, .alt = input.alt, .super = input.cmd };
            try ghostty.input.encodeMouse(&writer, .{ .action = if (input.pressed) .press else if (input.released) .release else .motion, .button = owner.mouse_button, .mods = mods, .pos = .{ .x = px * ctx.scale, .y = py * ctx.scale } }, options);
            if (input.released) owner.mouse_button = null;
            if (inside and input.scroll.y != 0) {
                const lines = input.scroll_lines orelse input.scroll.y / m.height;
                const n: usize = @intFromFloat(std.math.clamp(@ceil(@abs(lines)), 1, 32));
                for (0..n) |_| try ghostty.input.encodeMouse(&writer, .{ .action = .press, .button = if (input.scroll.y > 0) .four else .five, .mods = mods, .pos = .{ .x = px * ctx.scale, .y = py * ctx.scale } }, options);
            }
            if (writer.buffered().len > 0) self.typeText(ws, owner, writer.buffered());
            return;
        }
        if (input.pressed and input.mouse_button == 1 and inside) try vt.interaction.press(&vt.terminal, col, row, .{ px, py }, m.width, os.millis());
        if (input.down and vt.interaction.dragging and (py < 0 or py >= @as(f32, @floatFromInt(vt.terminal.rows)) * m.height)) {
            const stamp = ctx.state(struct { time: f64 = 0 }, "selection-scroll-stamp");
            if (ctx.time - stamp.time >= 1.0 / 30.0) {
                stamp.time = ctx.time;
                const distance = if (py < 0) -py else py - @as(f32, @floatFromInt(vt.terminal.rows)) * m.height;
                const count: isize = @intFromFloat(std.math.clamp(@ceil(distance / m.height), 1, 8));
                vt.terminal.scrollViewport(.{ .delta = if (py < 0) -count else count });
            }
            ctx.frameIn(1.0 / 30.0);
        }
        if (input.down and vt.interaction.dragging) try vt.interaction.drag(&vt.terminal, col, row, .{ px, py }, m.width, m.height, input.alt);
        if (input.released and vt.interaction.dragging) {
            vt.interaction.release(&vt.terminal, col, row);
            if (self.host.settings.@"copy-on-select" and vt.terminal.screens.active.selection != null) self.queue(.copy, ws, owner);
        }
        if (inside and input.pressed and input.mouse_button == 2) {
            const mode = self.host.settings.@"right-click-action";
            if (std.mem.eql(u8, mode, "context-menu")) {
                const target = try @import("document_links.zig").at(ctx.alloc(), &vt.terminal, col, row);
                try self.terminal_menu.show(self.host.a, ws.id, owner.pty.id, input.mouse, ctx.frame, if (target) |value| value.text else "", vt.terminal.screens.active.selection != null);
            } else self.queue(if (std.mem.eql(u8, mode, "copy-or-paste") and vt.terminal.screens.active.selection != null) .copy else .paste, ws, owner);
        }
        if (inside and input.scroll.y != 0) {
            if (input.scroll_started) owner.scroll_fraction = 0;
            owner.scroll_fraction -= if (input.scroll_lines) |lines| lines * 3 else input.scroll.y / m.height;
            const whole: isize = @intFromFloat(std.math.clamp(@trunc(owner.scroll_fraction), -128, 128));
            owner.scroll_fraction -= @floatFromInt(whole);
            if (whole != 0) try self.host.enqueue(.{ .window = self.id, .workspace = ws.id, .pane = owner.pty.id, .kind = .scroll, .delta = whole });
        }
    }
    fn typeText(self: *Window, ws: *Workspace, owner: *Owner, bytes: []const u8) void {
        self.host.enqueue(.{ .window = self.id, .workspace = ws.id, .pane = owner.pty.id, .kind = .input, .text = bytes }) catch |err| self.host.problem(err);
    }
    fn typeKey(self: *Window, ctx: *ui.Context, ws: *Workspace, owner: *Owner, key: ghostty.input.Key) void {
        var buffer: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        ghostty.input.encodeKey(&writer, .{ .action = .press, .key = key, .mods = .{ .ctrl = ctx.input.ctrl, .alt = ctx.input.alt, .shift = ctx.input.shift } }, self.keyOptions(owner)) catch |err| {
            self.host.problem(err);
            return;
        };
        self.typeText(ws, owner, writer.buffered());
    }
};
pub const Runtime = struct {
    a: A,
    io: std.Io,
    app: *nano.App,
    settings: Settings,
    bindings: []const []const u8 = &.{},
    config_path: []const u8 = "",
    initial_config: []const u8 = "",
    configuration: ?@import("settings.zig").Config = null,
    detector: ?@import("detect.zig").Engine = null,
    shell_path: []const u8 = "",
    startup_args: []const []const u8 = &.{},
    startup_used: bool = false,
    directory: []const u8,
    hidden: bool = false,
    presentation: @import("ui_state.zig").State = .{},
    presentation_path: []const u8 = "",
    executable_path: []const u8 = "",
    presentation_dirty: bool = false,
    presentation_queued: bool = false,
    document_state_path: []const u8 = "",
    document_state_queued: bool = false,
    restoring_documents: bool = false,
    shutting_down: bool = false,
    windows: std.ArrayList(*Window) = .empty,
    actions: std.ArrayList(Action) = .empty,
    queued_bytes: usize = 0,
    serial: u64 = 0,
    wake_pipe: [2]c_int = .{ -1, -1 },
    signal_pipe: [2]c_int = .{ -1, -1 },
    wake_watch: ?*Watch = null,
    signal_watch: ?*Watch = null,
    problem_text: []const u8 = "",
    private_clipboard: ?[]const u8 = null,
    modal_window: u64 = 0,
    menu_recording: u64 = 0,
    jobs: ?Jobs.Pool = null,
    app_guard: ?*@import("app_guard.zig").Guard = null,
    notifications: ?@import("notifications.zig").Service = null,
    attention_queued: bool = false,
    themes: ?@import("themes.zig").Catalog = null,
    theme_set: @import("themes.zig").Set = .{},
    pub fn init(self: *Runtime) !void {
        try @import("locale.zig").init(self.a, self.settings.language);
        self.configuration = try @import("settings.zig").Config.parse(self.a, self.initial_config);
        self.detector = try @import("detect.zig").Engine.init(self.a);
        self.settings = self.configuration.?.settings;
        self.themes = try @import("themes.zig").Catalog.init(self.a);
        self.theme_set = try self.themes.?.load(self.a, self.settings.theme);
        self.bindings = self.configuration.?.keybind.items;
        if (c.pipe(&self.wake_pipe) != 0 or c.pipe(&self.signal_pipe) != 0) return error.Pipe;
        for (self.wake_pipe ++ self.signal_pipe) |fd| {
            try os.cloexec(fd);
            try os.nonblock(fd);
        }
        self.jobs = .{ .a = self.a, .wake_fd = self.wake_pipe[1] };
        self.wake_watch = try Watch.create(self.wake_pipe[0], false, self, wake);
        self.signal_watch = try Watch.create(self.signal_pipe[0], false, self, children);
        child_signal_fd = self.signal_pipe[1];
        _ = c.signal(c.SIGCHLD, childSignal);
        self.executable_path = try std.process.executablePathAlloc(self.io, self.a);
        self.presentation_path = try std.fmt.allocPrint(self.a, "{s}.ui.json", .{self.config_path});
        self.document_state_path = try std.fmt.allocPrint(self.a, "{s}.documents.json", .{self.config_path});
        if (os.readFile(self.a, self.presentation_path, 1024 * 1024)) |data| {
            defer self.a.free(data);
            self.presentation = @import("ui_state.zig").State.parse(self.a, data) catch .{};
        } else |_| {}
        if (!self.hidden) {
            self.notifications = .{ .ctx = self, .activate = notificationActivated };
            self.notifications.?.install();
        }
        if (self.presentation.font_size > 0) self.settings.@"font-size" = self.presentation.font_size;
        try self.newWindow();
        if (!self.hidden) self.restoreDocuments() catch |err| self.problem(err);
        try @import("menus.zig").install(self);
        self.app_guard = try @import("app_guard.zig").Guard.install(self.app, self, allowQuit);
    }
    pub fn deinit(self: *Runtime) void {
        self.shutting_down = true;
        self.a.free(self.document_state_path);
        child_signal_fd = -1;
        if (self.notifications) |*service| service.deinit();
        self.notifications = null;
        self.presentation.deinit(self.a);
        self.a.free(self.presentation_path);
        self.a.free(self.executable_path);
        if (self.app_guard) |guard| guard.deinit();
        self.app_guard = null;
        if (self.jobs) |*pool| pool.deinit();
        self.jobs = null;
        if (self.wake_watch) |watch| watch.cancel();
        if (self.signal_watch) |watch| watch.cancel();
        for (self.wake_pipe ++ self.signal_pipe) |fd| if (fd >= 0) {
            _ = c.close(fd);
        };
        for (self.windows.items) |window| {
            self.detachSettings(window);
            if (window.pending_document_close) |pending| self.a.free(pending.text);
            window.pending_document_close = null;
            if (window.native) |win| {
                win.on_close = null;
            }
            for (window.workspaces.items) |ws| ws.destroy(self.a);
            window.workspaces.deinit(self.a);
            window.marked.deinit(self.a);
            window.git_view.deinit(self.a);
            window.preferences.deinit(self.a);
            self.a.destroy(window);
        }
        self.windows.deinit(self.a);
        for (self.actions.items) |action| if (action.text.len > 0) self.a.free(action.text);
        self.actions.deinit(self.a);
        if (self.problem_text.len > 0) self.a.free(self.problem_text);
        if (self.private_clipboard) |text| self.a.free(text);
        if (self.configuration) |*config| config.deinit(self.a);
        if (self.detector) |*engine| engine.deinit();
        if (self.themes) |*catalog| catalog.deinit();
        @import("locale.zig").deinit();
    }
    pub fn shutdown(self: *Runtime) void {
        if (!self.hidden) self.saveDocuments() catch |err| self.problem(err);
        self.shutting_down = true;
        self.savePresentation() catch |err| self.problem(err);
        for (self.windows.items) |win| if (win.native) |native| native.close();
    }
    fn allocateId(self: *Runtime) u64 {
        self.serial += 1;
        return self.serial;
    }
    fn findWindow(self: *Runtime, id_: u64) ?*Window {
        for (self.windows.items) |win| if (win.id == id_ and !win.closed) return win;
        return null;
    }
    fn newWindow(self: *Runtime) !void {
        return self.newWindowBase(true);
    }
    fn newWindowBase(self: *Runtime, with_terminal: bool) !void {
        const win = try self.a.create(Window);
        errdefer self.a.destroy(win);
        win.* = .{ .host = self, .id = self.allocateId(), .sidebar = !self.presentation.sidebar_hidden, .changes_open = self.presentation.changes_open };
        try self.windows.ensureUnusedCapacity(self.a, 1);
        errdefer {
            for (win.workspaces.items) |ws| ws.destroy(self.a);
            win.workspaces.deinit(self.a);
        }
        if (with_terminal) try self.newWorkspace(win, self.directory);
        win.native = try self.app.newWindow(.{ .title = "Letty", .title_bar = .hidden, .visible = !self.hidden, .width = 1000, .height = 680, .min_width = 480, .min_height = 240, .content = .{ .view = .init(win, Window.view) }, .on_close = .{ .ctx = win, .func = Window.close } });
        @import("window_chrome.zig").configure(win.native.?);
        win.close_guard = @import("window_guard.zig").Guard.install(self.a, win.native.?, win, Window.closeRequest, Window.focusChanged) catch |err| {
            win.native.?.on_close = null;
            win.native.?.close();
            return err;
        };
        win.window_style.apply(win.native.?, self.settings.@"window-translucent" and !self.hidden);
        if (!self.hidden) win.drop_guard = @import("file_drop.zig").Guard.install(self.a, win.native.?, &win.window_style, win, Window.filesDropped) catch |err| blk: {
            self.problem(err);
            break :blk null;
        };
        win.native_focus = win.native.?.isFocused();
        self.windows.appendAssumeCapacity(win);
    }
    fn markDocuments(self: *Runtime) void {
        if (self.hidden or self.shutting_down or self.restoring_documents or self.document_state_queued) return;
        self.enqueue(.{ .window = 0, .kind = .persist_documents }) catch |err| {
            self.problem(err);
            return;
        };
        self.document_state_queued = true;
    }
    fn saveDocuments(self: *Runtime) !void {
        self.document_state_queued = false;
        if (self.document_state_path.len == 0 or self.restoring_documents) return;
        var records: std.ArrayList(DocumentRestore.Record) = .empty;
        defer records.deinit(self.a);
        for (self.windows.items) |win| if (!win.closed) for (win.workspaces.items) |ws| if (ws.is_file) if (ws.documents.selected()) |document| {
            try records.append(self.a, .{ .window = win.id, .path = document.absolute(), .name = ws.name, .active = win.active == ws.id });
        };
        const output = try DocumentRestore.encode(self.a, records.items);
        defer self.a.free(output);
        if (std.fs.path.dirname(self.document_state_path)) |directory| try os.mkdirs(self.a, directory);
        try os.atomicFile(self.a, self.document_state_path, output);
    }
    fn restoreDocuments(self: *Runtime) !void {
        const bytes = os.readFile(self.a, self.document_state_path, DocumentRestore.limit) catch |err| {
            if (err == error.OpenFile) return;
            return err;
        };
        defer self.a.free(bytes);
        var state = try DocumentRestore.Snapshot.parse(self.a, bytes);
        defer state.deinit();
        try self.restoreDocumentRecords(state.parsed.value.files);
    }
    fn restoreDocumentRecords(self: *Runtime, files: []const DocumentRestore.Record) !void {
        self.restoring_documents = true;
        defer self.restoring_documents = false;
        var windows: std.AutoHashMap(u64, *Window) = .init(self.a);
        defer windows.deinit();
        var selected: std.AutoHashMap(u64, u64) = .init(self.a);
        defer selected.deinit();
        for (files) |record| {
            const win = windows.get(record.window) orelse blk: {
                const candidate = if (windows.count() == 0) self.windows.items[0] else create: {
                    try self.newWindowBase(false);
                    break :create self.windows.items[self.windows.items.len - 1];
                };
                try windows.put(record.window, candidate);
                try selected.put(candidate.id, candidate.active);
                break :blk candidate;
            };
            try self.openDocument(win, record.path, false, self.directory);
            const ws = win.workspace(win.active).?;
            if (record.name.len > 0) {
                const name = try self.a.dupe(u8, record.name);
                self.a.free(ws.name);
                ws.name = name;
            }
            if (record.active) try selected.put(win.id, ws.id);
        }
        var iterator = windows.valueIterator();
        while (iterator.next()) |entry| if (selected.get(entry.*.id)) |id| if (entry.*.workspace(id)) |ws| entry.*.activate(ws);
    }
    fn documentChanged(raw: ?*anyopaque, _: u64) void {
        const win: *Window = @ptrCast(@alignCast(raw.?));
        if (!win.closed) {
            win.host.resumeDocumentClose(win);
            win.redraw();
        }
    }
    fn waitDocumentClose(self: *Runtime, win: *Window, ws: *Workspace, document: *Documents.Document, continuation: Action) void {
        const text = self.a.dupe(u8, continuation.text) catch return;
        if (win.pending_document_close) |pending| self.a.free(pending.text);
        var action = continuation;
        action.text = text;
        // File watches advance the read generation after our own rename. Close
        // continuation belongs to this editor lifetime, not a disk-read epoch.
        win.pending_document_close = .{ .action = action, .workspace = ws.id, .document = document.id, .generation = document.draft_epoch, .text = text };
    }
    fn resumeDocumentClose(self: *Runtime, win: *Window) void {
        const pending = win.pending_document_close orelse return;
        const ws = win.workspace(pending.workspace);
        const document = if (ws) |owner| owner.documents.get(pending.document) else null;
        if (document) |d| if (d.draft_epoch == pending.generation and d.job != null) return;
        win.pending_document_close = null;
        defer self.a.free(pending.text);
        if (document) |d| if (d.draft_epoch == pending.generation and !d.edit_failed) {
            var continuation = pending.action;
            if (continuation.kind == .document_event) {
                continuation.document_generation = d.panel.model.generation;
                continuation.document_edit_epoch = d.draft_epoch;
            }
            self.enqueue(continuation) catch |err| self.problem(err);
        };
    }
    fn confirmDocumentClose(self: *Runtime, win: *Window, ws: *Workspace, document: *Documents.Document, continuation: Action) bool {
        if (!document.hasUnsaved()) return true;
        if (document.panel.editor) |editor| if (editor.composition.range != null) {
            document.panel.notice.set("Finish or cancel the current input before closing.");
            editor.focus = true;
            return false;
        };
        if (document.job != null) {
            if (document.panel.inline_edit) self.waitDocumentClose(win, ws, document, continuation);
            return false;
        }
        if (document.autosaves() and !document.edit_failed and !document.panel.external_changed) {
            document.flushAutosave() catch |err| {
                document.panel.notice.set(Documents.describe(err));
                return false;
            };
            self.waitDocumentClose(win, ws, document, continuation);
            return false;
        }
        const id = document.id;
        const generation = document.panel.model.generation;
        const choice = if (self.hidden) (win.document_close_choice orelse 0) else blk: {
            self.modal_window = win.id;
            defer self.endModal();
            break :blk nano.dialog.message(.{ .title = "Save changes before closing?", .detail = document.absolute(), .buttons = &.{ "Cancel", "Save", "Discard" } }).button;
        };
        win.document_close_choice = null;
        const current = ws.documents.get(id) orelse return false;
        if (current.panel.model.generation != generation) return false;
        if (choice == 2) {
            current.discardDraft();
            return true;
        }
        if (choice == 1) {
            current.panel.edit_request = .save;
            current.edit() catch |err| {
                current.panel.notice.set(Documents.describe(err));
                return false;
            };
            self.waitDocumentClose(win, ws, current, continuation);
        }
        return false;
    }
    fn documentsCanClose(self: *Runtime, win: *Window, only: ?*Workspace, continuation: Action) bool {
        for (win.workspaces.items) |ws| {
            if (only != null and only.? != ws) continue;
            for (ws.documents.documents.items) |document| if (document.hasUnsaved()) {
                ws.documents.active = document.id;
                ws.documents.visible = true;
                win.activate(ws);
                document.panel.focused = true;
                if (document.panel.editor) |editor| editor.focus = true;
                if (self.confirmDocumentClose(win, ws, document, continuation)) continue;
                win.redraw();
                return false;
            };
        }
        return true;
    }
    fn removeWorkspace(self: *Runtime, win: *Window, ws: *Workspace) !void {
        if (!self.documentsCanClose(win, ws, .{ .window = win.id, .workspace = ws.id, .kind = .close_workspace })) return;
        for (ws.panes.items) |pane| if (!self.confirmClose(pane)) return;
        if (win.editor.workspace == ws.id) {
            if (!self.discardEditor(win)) return;
            win.editor.deinit(self.a);
        }
        if (win.active == ws.id) win.closeFind();
        for (win.workspaces.items, 0..) |entry, index| if (entry == ws) {
            _ = win.workspaces.orderedRemove(index);
            ws.destroy(self.a);
            break;
        };
        if (win.workspace(win.active) == null) win.active = if (win.workspaces.items.len > 0) win.workspaces.items[0].id else 0;
        self.queueAttention();
        self.markDocuments();
    }
    fn fileWorkspace(self: *Runtime, win: *Window, absolute_path: []const u8, moving: ?*Workspace) !void {
        if (!win.canLeaveDocument(0)) return error.FinishCompositionBeforeSwitching;
        self.markDocuments();
        for (win.workspaces.items) |existing| if (existing.is_file) if (existing.documents.find(absolute_path)) |document| {
            if (moving != null) return error.DocumentAlreadyOpenInWorkspace;
            existing.documents.active = document.id;
            win.activate(existing);
            return;
        };
        const ws = try self.a.create(Workspace);
        errdefer self.a.destroy(ws);
        const root = try self.a.create(Layout);
        errdefer self.a.destroy(root);
        const empty = try self.a.dupe(u8, "");
        errdefer self.a.free(empty);
        const directory = try self.a.dupe(u8, Documents.path.directory(absolute_path));
        errdefer self.a.free(directory);
        var collection: Documents.Collection = .{};
        errdefer collection.deinit(self.a);
        try win.workspaces.ensureUnusedCapacity(self.a, 1);
        if (moving) |source| {
            try source.documents.moveTo(self.a, &collection, source.documents.active);
        } else _ = try collection.open(self.a, self.allocateId(), absolute_path, .{ .context = win, .changed = documentChanged });
        root.* = .{ .pane = empty };
        ws.* = .{ .id = self.allocateId(), .directory = directory, .layout = root, .focus = 0, .is_file = true, .documents = collection };
        win.workspaces.appendAssumeCapacity(ws);
        win.activate(ws);
        win.setChanges(false);
        if (ws.documents.selected()) |document| document.panel.focused = true;
        self.markDocuments();
    }
    fn openDocument(self: *Runtime, win: *Window, raw: []const u8, side: bool, base: []const u8) !void {
        if (!win.canLeaveDocument(0)) return error.FinishCompositionBeforeSwitching;
        var value = raw;
        var expanded: [8192]u8 = undefined;
        if (std.mem.startsWith(u8, value, "~/")) value = try std.fmt.bufPrint(&expanded, "{s}/{s}", .{ os.env("HOME") orelse return error.HomeUnavailable, value[2..] });
        const host = Documents.terminal_paths.hostname();
        const resolved = try Documents.path.resolve(value, base, host.text());
        if (side) if (win.workspace(win.active)) |ws| if (!ws.is_file) {
            const document = try ws.documents.open(self.a, self.allocateId(), resolved.path.text(), .{ .context = win, .changed = documentChanged });
            document.panel.focused = true;
            win.closeFind();
            win.setChanges(false);
            win.review_focus = false;
            win.redraw();
            return;
        };
        try self.fileWorkspace(win, resolved.path.text(), null);
    }
    fn terminalDocument(self: *Runtime, win: *Window, ws: *Workspace, owner: *Owner, target: []const u8) !void {
        if (win.active != ws.id) return;
        const origin = Documents.terminal_paths.origin(owner.pty.fd, owner.pty.pid, owner.pty.explicit_command, owner.pty.directory);
        const host = Documents.terminal_paths.hostname();
        switch (Documents.terminal_paths.resolve(target, origin, os.env("HOME") orelse "", host.text())) {
            .path => |resolved| try self.openDocument(win, resolved.path.text(), true, origin.cwd.text()),
            .refused => |reason| {
                const text = try self.a.dupe(u8, reason.message());
                self.a.free(self.problem_text);
                self.problem_text = text;
            },
            .invalid => |err| return err,
        }
    }
    fn documentEvent(self: *Runtime, win: *Window, action: Action) !void {
        if (win.settings_open or win.palette_open or win.rename_open) return;
        const ws = win.workspace(action.workspace) orelse return;
        if (win.active != ws.id or !ws.documents.visible) return;
        const document = ws.documents.get(action.document) orelse return;
        if (ws.documents.active != document.id) return;
        if (action.document_edit_epoch != 0) {
            if (document.draft_epoch != action.document_edit_epoch) return;
        } else if (document.panel.model.generation != action.document_generation) return;
        if (action.other != 0) {
            if (document.panel.editor) |editor| if (editor.composition.range != null) {
                document.panel.notice.set("Finish or cancel the current input before switching documents.");
                editor.focus = true;
                return;
            };
            if (ws.documents.get(action.other) != null) {
                document.stopPresentation();
                ws.documents.active = action.other;
                ws.documents.selected().?.panel.focused = true;
                if (ws.documents.selected().?.panel.editor) |editor| editor.focus = true;
            }
            return;
        }
        try document.edit();
        switch (action.document_intent) {
            .none => {},
            .close => {
                if (!self.confirmDocumentClose(win, ws, document, action)) return;
                ws.documents.close(document.id) catch |err| {
                    document.panel.notice.set(Documents.describe(err));
                    return;
                };
                if (ws.is_file and ws.documents.active == 0) try self.removeWorkspace(win, ws);
            },
            .workspace => if (!ws.is_file) try self.fileWorkspace(win, document.absolute(), ws),
            .refresh => if (document.panel.editor != null) try document.gainedFocus() else try document.refresh(),
            .open_file => try self.pickDocument(win, !ws.is_file),
            .open_path => {
                // Restore the identity path before opening another destination.
                document.panel.path.set(document.absolute());
                try self.openDocument(win, action.text, !ws.is_file, Documents.path.directory(document.absolute()));
            },
            .external => if (!self.hidden) try @import("desktop_open.zig").open(document.absolute(), false),
            .link => {
                if (@import("paths.zig").web(action.text)) {
                    if (!self.hidden) try @import("desktop_open.zig").open(action.text, true);
                } else if (std.mem.startsWith(u8, action.text, "file://")) {
                    try self.openDocument(win, action.text, !ws.is_file, Documents.path.directory(document.absolute()));
                } else {
                    const decoded = try Documents.path.percentDecoded(action.text);
                    try self.openDocument(win, decoded.text(), !ws.is_file, Documents.path.directory(document.absolute()));
                }
            },
        }
    }
    fn pickDocument(self: *Runtime, win: *Window, side: bool) !void {
        if (!win.canLeaveDocument(0)) return error.FinishCompositionBeforeSwitching;
        if (self.hidden) return;
        const directory = if (win.workspace(win.active)) |ws| ws.directory else self.directory;
        self.modal_window = win.id;
        defer self.endModal();
        const files = (try nano.dialog.open(self.a, .{ .title = if (side) "Open File in Side Preview" else "Open File in Workspace", .directory = directory, .multiple = false })) orelse return;
        defer nano.dialog.freePaths(self.a, files);
        if (files.len > 0 and !win.closed) try self.openDocument(win, files[0], side, directory);
    }
    fn newWorkspace(self: *Runtime, win: *Window, directory: []const u8) !void {
        const ws = try self.a.create(Workspace);
        errdefer self.a.destroy(ws);
        const id_ = self.allocateId();
        const owner = try Owner.create(self, win.id, id_, directory);
        errdefer owner.destroy();
        const root = try self.a.create(Layout);
        errdefer self.a.destroy(root);
        const key = try self.a.dupe(u8, owner.key);
        errdefer self.a.free(key);
        const dir = try self.a.dupe(u8, directory);
        errdefer self.a.free(dir);
        var panes: std.ArrayList(*Owner) = .empty;
        errdefer panes.deinit(self.a);
        try panes.append(self.a, owner);
        try win.workspaces.ensureUnusedCapacity(self.a, 1);
        root.* = .{ .pane = key };
        ws.* = .{ .id = id_, .directory = dir, .layout = root, .panes = panes, .focus = owner.pty.id };
        win.workspaces.appendAssumeCapacity(ws);
        win.active = id_;
    }
    fn redraw(self: *Runtime, id_: u64) void {
        if (self.findWindow(id_)) |win| win.redraw();
    }
    fn problem(self: *Runtime, err: anyerror) void {
        const text = self.a.dupe(u8, @errorName(err)) catch return;
        if (self.problem_text.len > 0) self.a.free(self.problem_text);
        self.problem_text = text;
    }
    fn enqueue(self: *Runtime, action: Action) !void {
        if (self.actions.items.len >= 256 or action.text.len > 1024 * 1024 or action.text.len > 2 * 1024 * 1024 -| self.queued_bytes) return error.ActionQueueFull;
        var owned = action;
        if (action.text.len > 0) owned.text = try self.a.dupe(u8, action.text);
        errdefer if (owned.text.len > 0) self.a.free(owned.text);
        try self.actions.append(self.a, owned);
        self.queued_bytes += owned.text.len;
        const byte = [_]u8{1};
        _ = c.write(self.wake_pipe[1], &byte, 1);
    }
    fn drain(fd: c_int) void {
        var bytes: [256]u8 = undefined;
        while (c.read(fd, &bytes, bytes.len) > 0) {}
    }
    fn wake(raw: ?*anyopaque) callconv(.c) void {
        const self: *Runtime = @ptrCast(@alignCast(raw.?));
        drain(self.wake_pipe[0]);
        var budget: usize = 32;
        var index: usize = 0;
        while (index < self.actions.items.len and budget > 0) {
            if (self.modal_window != 0 and !duringModal(self.actions.items[index].kind)) {
                index += 1;
                continue;
            }
            const action = self.actions.orderedRemove(index);
            budget -= 1;
            defer if (action.text.len > 0) self.a.free(action.text);
            self.queued_bytes -= action.text.len;
            self.execute(action) catch |err| self.problem(err);
            self.redraw(action.window);
        }
        self.processJobs();
        if (self.actions.items.len > 0 and self.modal_window == 0) {
            const byte = [_]u8{1};
            _ = c.write(self.wake_pipe[1], &byte, 1);
        }
    }
    fn children(raw: ?*anyopaque) callconv(.c) void {
        const self: *Runtime = @ptrCast(@alignCast(raw.?));
        drain(self.signal_pipe[0]);
        if (self.jobs) |*pool| pool.reap();
        for (self.windows.items) |win| if (!win.closed) for (win.workspaces.items) |ws| for (ws.panes.items) |owner| {
            if (owner.pty.reap()) {
                owner.pty.terminal.records.dropLive(self.a);
                owner.transition(if (owner.pty.exit_code.? == 0) "exited" else "error");
                win.redraw();
            }
        };
    }
    fn processJobs(self: *Runtime) void {
        const pool = if (self.jobs) |*value| value else return;
        pool.reap();
        while (pool.take()) |job| {
            defer job.destroy();
            const win = self.findWindow(job.target.window) orelse continue;
            if (job.target.domain == .image) {
                if (job.target.generation == win.preview.generation) {
                    if (job.failure == null and job.status == 0) win.preview.accept(self.a, job.target.generation, job.output.bytes.items) catch |err| self.problem(err) else {
                        win.preview.queued = false;
                        win.preview.failed = true;
                    }
                    win.redraw();
                }
                continue;
            }
            const ws = win.workspace(job.target.workspace) orelse continue;
            const owner = ws.pane(job.target.pane) orelse continue;
            owner.changes.consume(self.a, job) catch |err| self.problem(err);
            win.redraw();
        }
        for (self.windows.items) |win| if (!win.closed and win.preview.shown and win.preview.path.len > 0 and !win.preview.queued and !win.preview.failed and win.preview.png.len == 0) {
            if (win.workspace(win.active)) |ws| if (ws.pane(win.preview.pane)) |_| {
                const arg = std.fmt.allocPrint(self.a, "--internal-image={s}", .{win.preview.path}) catch continue;
                defer self.a.free(arg);
                pool.launch(.{ .target = .{ .window = win.id, .workspace = ws.id, .pane = win.preview.pane, .generation = win.preview.generation, .domain = .image }, .executable = self.executable_path, .args = &.{arg}, .directory = ws.directory, .limit = 8 * 1024 * 1024, .timeout_ms = 3000 }) catch |err| {
                    if (err != error.BackgroundBusy) win.preview.failed = true;
                    continue;
                };
                win.preview.queued = true;
            };
        };
        for (self.windows.items) |win| if (!win.closed) for (win.workspaces.items) |ws| for (ws.panes.items) |owner| {
            owner.changes.pump(self.a, pool) catch |err| {
                owner.changes.stop();
                self.problem(err);
            };
        };
    }
    fn notificationActivated(raw: *anyopaque, target: @import("notifications.zig").Target) void {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        self.enqueue(.{ .window = target.window, .workspace = target.workspace, .pane = target.pane, .kind = .notification_activate }) catch |err| self.problem(err);
    }
    fn queueAttention(self: *Runtime) void {
        if (!self.attention_queued) {
            self.enqueue(.{ .window = 0, .kind = .update_attention }) catch return;
            self.attention_queued = true;
        }
    }
    fn updateAttention(self: *Runtime) void {
        self.attention_queued = false;
        var count: usize = 0;
        for (self.windows.items) |win| if (!win.closed) for (win.workspaces.items) |ws| for (ws.panes.items) |owner| {
            if (owner.unread) count += 1;
        };
        if (self.notifications) |*service| service.badge(count, self.settings.@"dock-badge");
    }
    fn savePresentation(self: *Runtime) !void {
        self.presentation_queued = false;
        if (!self.presentation_dirty or self.presentation_path.len == 0) return;
        const data = try self.presentation.json(self.a);
        defer self.a.free(data);
        if (std.fs.path.dirname(self.presentation_path)) |dir| try os.mkdirs(self.a, dir);
        try os.atomicFile(self.a, self.presentation_path, data);
        self.presentation_dirty = false;
    }
    fn markPresentation(self: *Runtime) void {
        self.presentation_dirty = true;
        if (!self.presentation_queued) {
            self.enqueue(.{ .window = 0, .kind = .persist_ui }) catch return;
            self.presentation_queued = true;
        }
    }
    fn execute(self: *Runtime, action: Action) anyerror!void {
        if (action.kind == .update_attention) return self.updateAttention();
        defer if (action.kind == .close_pane or action.kind == .close_workspace) self.queueAttention();
        if (action.kind == .persist_ui) return self.savePresentation();
        if (action.kind == .persist_documents) return self.saveDocuments();
        const win = self.findWindow(action.window) orelse return;
        if (action.settings_epoch != 0 and (action.kind == .set_setting or action.kind == .set_binding or action.kind == .set_environment or action.kind == .reload_settings or (action.kind == .command and std.mem.startsWith(u8, action.text, "settings."))) and action.settings_epoch != win.preferences.draft.id) return;
        if (self.modal_window != 0 and !duringModal(action.kind)) return;
        if (win.settings_discard and action.kind != .command and !duringModal(action.kind)) return;
        if (action.kind == .editor_close) {
            if (self.discardEditor(win)) win.editor.deinit(self.a);
            return;
        }
        if (action.kind == .image_hide) {
            if (self.jobs) |*pool| pool.cancelImage(win.id);
            win.preview.queued = false;
            win.preview.generation +%= 1;
            return;
        }
        if (action.kind == .toggle_group) {
            try self.presentation.toggle(self.a, action.text);
            self.markPresentation();
            self.redrawAll();
            return;
        }
        if (action.kind == .rename_project) {
            const source = win.workspace(action.workspace) orelse return;
            try self.presentation.rename(self.a, source.directory, action.text);
            self.markPresentation();
            self.redrawAll();
            return;
        }
        if (action.kind == .document_meta) {
            const source = win.workspace(action.workspace) orelse return;
            if (!source.is_file) return;
            const document = source.documents.get(action.document) orelse return;
            if (document.panel.model.generation != action.document_generation) return;
            if (std.mem.eql(u8, action.text, "path")) try self.writeClipboard(document.absolute()) else if (std.mem.eql(u8, action.text, "reveal_file") and !self.hidden) try @import("desktop_open.zig").open(Documents.path.directory(document.absolute()), false);
            return;
        }
        if (action.kind == .session_meta) {
            const source = win.workspace(action.workspace) orelse return;
            if (source.is_file) return;
            if (std.mem.eql(u8, action.text, "read")) {
                for (source.panes.items) |pane| pane.unread = false;
                self.queueAttention();
            } else if (std.mem.eql(u8, action.text, "id")) {
                const id = try std.fmt.allocPrint(self.a, "workspace-{d}", .{source.id});
                defer self.a.free(id);
                try self.writeClipboard(id);
            } else {
                const pane = source.pane(source.focus) orelse return;
                const directory = try @import("paths.zig").directory(self.a, pane.pty.terminal.terminal.getPwd(), pane.pty.directory);
                defer self.a.free(directory);
                if (std.mem.eql(u8, action.text, "directory")) try self.writeClipboard(directory) else if (std.mem.eql(u8, action.text, "reveal") and !self.hidden) try @import("desktop_open.zig").open(directory, false);
            }
            return;
        }
        if (action.kind == .assign_project) {
            const source = win.workspace(action.workspace) orelse return;
            const target = win.workspace(action.other) orelse return;
            if (source.id == target.id or std.mem.eql(u8, source.directory, target.directory)) return;
            const directory = try self.a.dupe(u8, target.directory);
            self.a.free(source.directory);
            source.directory = directory;
            return;
        }
        if (action.kind == .move_workspace or action.kind == .move_project) {
            const source = win.workspace(action.workspace) orelse return;
            const target = win.workspace(action.other) orelse return;
            const order = @import("sidebar_order.zig");
            if (action.kind == .move_workspace) {
                if (!std.mem.eql(u8, source.directory, target.directory)) return;
                _ = order.move(*Workspace, win.workspaces.items, source.id, target.id, action.delta != 0);
            } else _ = try order.project(*Workspace, self.a, win.workspaces.items, source.id, target.id, action.delta != 0);
            self.markDocuments();
            return;
        }
        if (action.kind == .close_project) {
            const source = win.workspace(action.workspace) orelse return;
            const directory = try self.a.dupe(u8, source.directory);
            defer self.a.free(directory);
            for (win.workspaces.items) |candidate| if (std.mem.eql(u8, candidate.directory, directory)) {
                if (!self.documentsCanClose(win, candidate, action)) return;
                for (candidate.panes.items) |pane| if (!self.confirmClose(pane)) return;
                if (win.editor.workspace == candidate.id and !self.discardEditor(win)) return;
            };
            var i = win.workspaces.items.len;
            while (i > 0) {
                i -= 1;
                const candidate = win.workspaces.items[i];
                if (!std.mem.eql(u8, candidate.directory, directory)) continue;
                if (win.editor.workspace == candidate.id) win.editor.deinit(self.a);
                if (win.workspace(win.active) == candidate) win.closeFind();
                _ = win.workspaces.orderedRemove(i);
                candidate.destroy(self.a);
            }
            if (win.workspace(win.active) == null) win.active = if (win.workspaces.items.len > 0) win.workspaces.items[0].id else 0;
            self.queueAttention();
            self.markDocuments();
            return;
        }
        if (action.kind == .sidebar_visibility) {
            win.sidebar = action.delta != 0;
            win.sidebar_forced = win.sidebar;
            self.presentation.sidebar_hidden = !win.sidebar;
            self.markPresentation();
            return;
        }
        if (action.kind == .chrome_resize) {
            if (!std.math.isFinite(action.value)) return;
            if (std.mem.eql(u8, action.text, "sidebar")) self.presentation.sidebar_width = @floatCast(std.math.clamp(action.value, 200, 440)) else self.presentation.changes_width = @floatCast(std.math.clamp(action.value, 300, 1200));
            self.markPresentation();
            return;
        }
        if (action.kind == .window_focus) {
            win.native_focus = action.delta != 0;
            if (!win.native_focus) {
                win.input_settings.recording = null;
                self.recordingMenus(win.id, false);
            }
            win.syncFocus();
            if (win.native_focus) if (win.workspace(win.active)) |ws| if (ws.documents.visible) if (ws.documents.selected()) |document| document.gainedFocus() catch |err| self.problem(err);
            if (win.native_focus and !self.hidden) if (win.workspace(win.active)) |ws| if (ws.pane(ws.focus)) |owner| owner.refreshGit();
            return;
        }
        if (action.kind == .edit_configuration) {
            if (!self.hidden) try @import("desktop_open.zig").open(self.config_path, false);
            return;
        }
        if (action.kind == .set_setting or action.kind == .set_binding or action.kind == .set_environment or action.kind == .reload_settings) {
            if (!win.settings_open) return;
            return self.configure(action);
        }
        if (action.kind == .quit) {
            if (allowQuit(self)) self.app.quit();
            return;
        }
        if (action.kind == .new_window) return self.newWindow();
        if (action.kind == .close_window) {
            if (Window.closeRequest(win)) if (win.native) |native| native.close();
            return;
        }
        if (action.kind == .command) return self.runCommand(win, action);
        if (action.kind == .document_open) return self.openDocument(win, action.text, action.delta != 0, if (win.workspace(win.active)) |ws| ws.directory else self.directory);
        if (action.kind == .document_event) return self.documentEvent(win, action);
        if (action.kind == .document_resize) {
            const source = win.workspace(action.workspace) orelse return;
            if (win.active == source.id and std.math.isFinite(action.value)) source.document_width = @floatCast(std.math.clamp(action.value, 320, 1400));
            return;
        }
        if (action.kind == .new_workspace) return self.newWorkspace(win, if (win.workspace(action.workspace)) |ws| ws.directory else self.directory);
        const ws = win.workspace(action.workspace) orelse return;
        if (action.kind == .close_workspace or (action.kind == .close_pane and ws.is_file)) return self.removeWorkspace(win, ws);
        if (action.kind == .close_pane and ws.panes.items.len == 1 and !self.documentsCanClose(win, ws, action)) return;
        const owner = ws.pane(action.pane) orelse return;
        if (action.kind == .git_context or action.kind == .git_base or action.kind == .git_select or action.kind == .git_open or action.kind == .editor_open or action.kind == .revert_hunk) {
            const pwd = try owner.currentDirectory(self.a);
            defer self.a.free(pwd);
            if (action.review_epoch != owner.changes.epoch or !std.mem.eql(u8, pwd, owner.changes.directory)) return;
        }
        switch (action.kind) {
            .revert_hunk => {
                if (owner.changes.backend != .git or owner.changes.base() != .turn or action.other != owner.changes.patchVersion() or !owner.changes.canOpen(action.text) or !std.mem.eql(u8, action.text, owner.changes.selected())) return;
                for (ws.panes.items) |pane| if (std.mem.eql(u8, pane.status, "working")) return error.AgentStillWorking;
                var file = try @import("review_file.zig").File.open(self.a, owner.changes.root(), action.text);
                defer file.deinit(self.a);
                if (!std.math.isFinite(action.value) or action.value < 0 or action.value > 4 * 1024 * 1024) return;
                const reverted = try @import("review_hunk.zig").revert(self.a, owner.changes.patch(), @intFromFloat(action.value), file.bytes);
                defer self.a.free(reverted);
                try file.write(self.a, reverted);
                owner.refreshGit();
            },
            .editor_open => {
                if (!owner.changes.canOpen(action.text)) return;
                if (win.editor.dirty() and !self.discardEditor(win)) return;
                try win.editor.load(self.a, owner.changes.root(), action.text, owner.pty.id, ws.id, owner.changes.epoch);
                win.review_focus = true;
            },
            .editor_save => {
                if (!win.editor.open() or win.editor.pane != owner.pty.id or win.editor.workspace != ws.id or win.active != ws.id or ws.focus != owner.pty.id) return;
                for (ws.panes.items) |pane| if (std.mem.eql(u8, pane.status, "working")) return error.AgentStillWorking;
                if (!std.mem.eql(u8, win.editor.root, owner.changes.root())) return error.ReviewDirectoryChanged;
                win.editor.save(self.a) catch |err| {
                    self.a.free(win.editor.error_text);
                    win.editor.error_text = try self.a.dupe(u8, @errorName(err));
                    return;
                };
                owner.refreshGit();
            },
            .editor_reload => {
                if (!win.editor.open() or win.editor.pane != owner.pty.id or !self.discardEditor(win)) return;
                const path = try self.a.dupe(u8, win.editor.path);
                defer self.a.free(path);
                try win.editor.load(self.a, owner.changes.root(), path, owner.pty.id, ws.id, owner.changes.epoch);
            },

            .notification_activate => {
                win.activate(ws);
                ws.focus = owner.pty.id;
                win.settings_open = win.preferences.draft.config != null;
                win.palette_open = false;
                win.rename_open = false;
                win.review_focus = false;
                win.closeFind();
                owner.unread = false;
                self.queueAttention();
                if (!self.hidden) {
                    if (win.settings_native) |native| native.focus() else if (win.native) |native| native.focus();
                }
            },
            .image_hover => {
                const paths = @import("paths.zig");
                const pwd = try paths.directory(self.a, owner.pty.terminal.terminal.getPwd(), owner.pty.directory);
                defer self.a.free(pwd);
                const path = try paths.resolve(self.a, action.text, pwd, os.env("HOME") orelse "/");
                defer self.a.free(path);
                const z = try self.a.dupeSentinel(u8, path, 0);
                defer self.a.free(z);
                var canonical: [std.fs.max_path_bytes]u8 = undefined;
                const real = std.c.realpath(z, &canonical) orelse return;
                const fd = c.open(real, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK | c.O_NOFOLLOW);
                if (fd < 0) return;
                defer _ = c.close(fd);
                var st: c.struct_stat = undefined;
                if (c.fstat(fd, &st) != 0 or (st.mode & c.S_IFMT) != c.S_IFREG or st.size < 0 or st.size > 64 * 1024 * 1024) return;
                const time = if (@hasField(c.struct_stat, "mtimespec")) st.mtimespec else st.mtim;
                const stamp = @as(i64, @intCast(time.sec)) * 1000000000 + time.nsec;
                if (try win.preview.request(self.a, std.mem.span(real), action.text, owner.pty.id, stamp)) if (self.jobs) |*pool| pool.cancelImage(win.id);
                win.preview.shown = true;
            },
            .split_resize => {
                const other = ws.pane(action.other) orelse return;
                _ = @import("layout_actions.zig").ratio(ws.layout, owner.key, other.key, action.value);
            },
            .pane_move => {
                const other = ws.pane(action.other) orelse return;
                const replacement = (try @import("layout_actions.zig").move(self.a, ws.layout, owner.key, other.key, std.meta.stringToEnum(@import("layout_actions.zig").Zone, action.text) orelse return)) orelse return;
                const previous = ws.layout;
                ws.layout = replacement;
                previous.deinit(self.a);
                ws.focus = owner.pty.id;
                win.zoom = 0;
            },
            .copy_link => try self.writeClipboard(action.text),
            .open_link => {
                const paths = @import("paths.zig");
                if (!@import("document_links.zig").supported(action.text)) return error.InvalidLink;
                if (paths.web(action.text)) {
                    if (!self.hidden) try @import("desktop_open.zig").open(action.text, true);
                } else try self.terminalDocument(win, ws, owner, action.text);
            },
            .focus_report => {
                owner.focus_queued = false;
                const desired = win.native_focus and self.modal_window == 0 and win.active == ws.id and ws.focus == owner.pty.id and !win.blocksInput();
                const mode = owner.pty.terminal.terminal.modes.get(.focus_event);
                if (!owner.pty.eof and mode and (!owner.focus_mode or owner.focus_reported != desired)) {
                    var bytes: [ghostty.input.max_focus_encode_size]u8 = undefined;
                    var writer: std.Io.Writer = .fixed(&bytes);
                    try ghostty.input.encodeFocus(&writer, if (desired) .gained else .lost);
                    try owner.pty.terminal.enqueue(writer.buffered(), true);
                    try owner.scheduleWrites();
                }
                owner.focus_mode = mode;
                owner.focus_reported = desired;
            },
            .git_show => {
                if (win.active != ws.id) return;
                ws.focus = owner.pty.id;
                win.setChanges(true);
                win.review_focus = true;
                owner.refreshGit();
            },
            .git_refresh, .git_base => {
                owner.git_queued = false;
                if (action.kind == .git_base) {
                    if (action.review_epoch != owner.changes.epoch) return;
                    try owner.changes.setBase(std.meta.stringToEnum(Vcs.git.Base, action.text) orelse return error.InvalidGitBase);
                }
                const pwd = try owner.currentDirectory(self.a);
                defer self.a.free(pwd);
                try owner.changes.request(self.a, .{ .window = win.id, .workspace = ws.id, .pane = owner.pty.id }, pwd, win.changes_open);
            },
            .git_context => {
                if (action.other != owner.changes.patchVersion() or !std.math.isFinite(action.value) or action.value < 0 or action.value > 100000) return;
                try owner.changes.setContext(self.a, @intFromFloat(action.value));
            },
            .git_select => {
                if (action.review_epoch != owner.changes.epoch) return;
                if (owner.changes.find(action.text) == null) return;
                try owner.changes.select(self.a, action.text);
            },
            .git_open => {
                if (self.hidden or action.review_epoch != owner.changes.epoch or !owner.changes.canOpen(action.text)) return;
                const file = try owner.changes.openPath(self.a, action.text);
                defer self.a.free(file);
                try @import("desktop_open.zig").open(file, false);
            },
            .restart => {
                if (!self.confirmClose(owner)) return;
                if (win.editor.pane == owner.pty.id and !self.discardEditor(win)) return;
                const replacement = try Owner.create(self, win.id, ws.id, owner.pty.directory);
                errdefer replacement.destroy();
                if (!try ws.layout.replace(self.a, owner.key, replacement.key)) return error.InvalidLayout;
                if (win.find_pane == owner.pty.id) win.closeFind();
                for (ws.panes.items) |*candidate| if (candidate.* == owner) {
                    candidate.* = replacement;
                    break;
                };
                if (ws.focus == owner.pty.id) ws.focus = replacement.pty.id;
                if (win.zoom == owner.pty.id) win.zoom = replacement.pty.id;
                if (win.editor.pane == owner.pty.id) win.editor.deinit(self.a);
                owner.destroy();
            },
            .search_tick => {
                owner.search_queued = false;
                owner.pumpSearch();
            },
            .focus => {
                if (win.active != ws.id) return;
                if (ws.focus != owner.pty.id) {
                    win.marked.clearRetainingCapacity();
                    win.marked_pane = 0;
                }
                ws.focus = owner.pty.id;
            },
            .input => {
                if (win.active != ws.id or ws.focus != owner.pty.id or win.blocksInput()) return;
                owner.pty.terminal.terminal.screens.active.clearSelection();
                owner.pty.terminal.terminal.scrollViewport(.bottom);
                owner.unread = false;
                _ = try owner.pty.send(action.text);
                try owner.scheduleWrites();
            },
            .resize => {
                if (win.active != ws.id) return;
                try owner.pty.resize(action.cols, action.rows, action.cell_w, action.cell_h);
                owner.last_cols = action.cols;
                owner.last_rows = action.rows;
            },
            .split_right, .split_down => {
                if (win.active != ws.id) return;
                const next = try Owner.create(self, win.id, ws.id, owner.pty.directory);
                errdefer next.destroy();
                try ws.panes.ensureUnusedCapacity(self.a, 1);
                if (!try ws.layout.split(self.a, owner.key, next.key, if (action.kind == .split_right) "right" else "down", 0.5)) return error.InvalidLayout;
                ws.panes.appendAssumeCapacity(next);
                ws.focus = next.pty.id;
            },
            .close_pane => {
                if (!self.confirmClose(owner)) return;
                if (win.editor.pane == owner.pty.id) {
                    if (!self.discardEditor(win)) return;
                    win.editor.deinit(self.a);
                }
                if (win.find_pane == owner.pty.id) win.closeFind();
                if (ws.panes.items.len > 1) {
                    const tree = ws.layout.remove(self.a, owner.key) orelse return error.InvalidLayout;
                    ws.layout = tree;
                    for (ws.panes.items, 0..) |candidate, i| if (candidate == owner) {
                        _ = ws.panes.orderedRemove(i);
                        break;
                    };
                    owner.destroy();
                    ws.focus = ws.panes.items[0].pty.id;
                } else {
                    for (win.workspaces.items, 0..) |candidate, i| if (candidate == ws) {
                        _ = win.workspaces.orderedRemove(i);
                        ws.destroy(self.a);
                        break;
                    };
                    win.active = if (win.workspaces.items.len > 0) win.workspaces.items[0].id else 0;
                }
            },
            .close_workspace => {
                for (ws.panes.items) |pane| if (!self.confirmClose(pane)) return;
                if (win.editor.workspace == ws.id) {
                    if (!self.discardEditor(win)) return;
                    win.editor.deinit(self.a);
                }
                win.closeFind();
                for (win.workspaces.items, 0..) |candidate, i| if (candidate == ws) {
                    _ = win.workspaces.orderedRemove(i);
                    ws.destroy(self.a);
                    break;
                };
                win.active = if (win.workspaces.items.len > 0) win.workspaces.items[0].id else 0;
            },
            .copy => {
                if (win.active != ws.id or ws.focus != owner.pty.id or win.blocksInput()) return;
                const vt = owner.pty.terminal;
                const text = (try vt.interaction.text(self.a, &vt.terminal)) orelse return;
                defer self.a.free(text);
                try self.writeClipboard(text);
            },
            .paste_paths => {
                if (win.active != ws.id or win.blocksInput()) return;
                ws.focus = owner.pty.id;
                const copy = try self.a.dupe(u8, action.text);
                defer self.a.free(copy);
                const parts = ghostty.input.encodePaste(copy, .{ .bracketed = owner.pty.terminal.terminal.modes.get(.bracketed_paste) });
                var bytes: std.ArrayList(u8) = .empty;
                defer bytes.deinit(self.a);
                for (parts) |part| try bytes.appendSlice(self.a, part);
                _ = try owner.pty.send(bytes.items);
                try owner.scheduleWrites();
            },
            .paste => {
                if (win.active != ws.id or ws.focus != owner.pty.id or win.blocksInput()) return;
                self.modal_window = win.id;
                defer self.endModal();
                const text = (try self.pasteText(owner)) orelse return;
                defer self.a.free(text);
                if (win.closed or win.workspace(ws.id) == null or ws.pane(owner.pty.id) == null) return;
                if (text.len > 1024 * 1024 - 12) return error.InputBackpressure;
                const encoded = ghostty.input.encodePaste(@constCast(text), .{ .bracketed = owner.pty.terminal.terminal.modes.get(.bracketed_paste) });
                var bytes: std.ArrayList(u8) = .empty;
                defer bytes.deinit(self.a);
                for (encoded) |part| try bytes.appendSlice(self.a, part);
                _ = try owner.pty.send(bytes.items);
                try owner.scheduleWrites();
            },
            .scroll => {
                const vt = owner.pty.terminal;
                if (vt.terminal.screens.active_key == .alternate and vt.terminal.modes.get(.mouse_alternate_scroll)) {
                    var bytes: [128 * 3]u8 = undefined;
                    var writer: std.Io.Writer = .fixed(&bytes);
                    for (0..@min(@abs(action.delta), 128)) |_| try ghostty.input.encodeKey(&writer, .{ .action = .press, .key = if (action.delta < 0) .arrow_up else .arrow_down }, .fromTerminal(&vt.terminal));
                    _ = try owner.pty.send(writer.buffered());
                    try owner.scheduleWrites();
                } else vt.terminal.scrollViewport(.{ .delta = @intCast(action.delta) });
            },
            else => {},
        }
    }
    fn pasteText(self: *Runtime, owner: *Owner) !?[]const u8 {
        if (self.hidden) return self.readClipboard();
        const paste = @import("paste.zig");
        if (try paste.readFiles(self.a)) |files| {
            defer paste.freeFiles(self.a, files);
            return try paste.paths(self.a, files, owner.pty.shell_path);
        }
        if (try self.readClipboard()) |text| {
            if (text.len > 0) return text;
            self.a.free(text);
        }
        if (try paste.readImage(self.a)) |png| {
            defer self.a.free(png);
            const path = try owner.paste_store.image(self.a, png);
            return try paste.paths(self.a, &.{path}, owner.pty.shell_path);
        }
        return null;
    }
    fn readClipboard(self: *Runtime) !?[]u8 {
        if (self.hidden) return if (self.private_clipboard) |text| try self.a.dupe(u8, text) else null;
        return try nano.clipboard.readText(self.a);
    }
    fn writeClipboard(self: *Runtime, text: []const u8) !void {
        if (self.hidden) {
            const copy = try self.a.dupe(u8, text);
            if (self.private_clipboard) |old| self.a.free(old);
            self.private_clipboard = copy;
        } else nano.clipboard.writeText(text);
    }
    fn recordingMenus(self: *Runtime, window: u64, active: bool) void {
        if (active) {
            self.menu_recording = window;
            @import("menus.zig").enabled(self, false);
        } else if (self.menu_recording == window) {
            self.menu_recording = 0;
            @import("menus.zig").enabled(self, true);
        }
    }
    pub fn menuCommand(self: *Runtime, id: []const u8) void {
        if (self.menu_recording != 0) return;
        var target: ?*Window = null;
        for (self.windows.items) |win| if (!win.closed) {
            target = win;
            if (self.hidden and win.edit_tester != null) break;
            if (win.settings_native) |native| if (native.isFocused()) break;
            if (win.native) |native| if (native.isFocused()) break;
        };
        const win = target orelse {
            if (std.mem.eql(u8, id, "window.new") or std.mem.eql(u8, id, "session.new")) self.newWindow() catch |err| self.problem(err);
            if (std.mem.eql(u8, id, "app.quit") and allowQuit(self)) self.app.quit();
            return;
        };
        if (std.mem.startsWith(u8, id, "edit.") and self.deliverMenuEdit(win, id)) return;
        win.dispatchCommand(id);
    }
    fn deliverMenuEdit(self: *Runtime, win: *Window, id: []const u8) bool {
        const tester = if (self.hidden) win.edit_tester else null;
        const native = if (win.settings_native) |settings| (if (settings.isFocused()) settings else win.native) else win.native;
        const surface = if (native) |window| window.surface else null;
        const ctx = if (tester) |fixture| &fixture.ctx else if (surface) |view| &view.ctx else return false;
        const editable = if (ctx.focused_text) |field| field.editable else false;
        if (!editable and !win.blocksInput()) return false;
        var text: ?[]u8 = null;
        defer if (text) |bytes| self.a.free(bytes);
        var ops: [1]ui.TextOp = undefined;
        if (std.mem.eql(u8, id, "edit.paste")) {
            text = self.readClipboard() catch |err| {
                self.problem(err);
                return true;
            };
            ops[0] = .{ .insert = text orelse "" };
        } else ops[0] = .{ .command = if (std.mem.eql(u8, id, "edit.selectAll")) .select_all else .copy };
        const previous = ctx.input.ops;
        ctx.input.ops = &ops;
        defer ctx.input.ops = previous;
        if (tester) |fixture| fixture.frame() else if (surface) |view| view.frame();
        return true;
    }
    fn resetSettings(self: *Runtime, win: *Window) !void {
        // Other terminal windows do not own the active settings preview.
        if (win.preferences.draft.config == null) return;
        const colors = win.preferences.draft.baseline_themes orelse try self.themes.?.load(self.a, self.configuration.?.settings.theme);
        self.settings = self.configuration.?.settings;
        if (self.presentation.font_size > 0) self.settings.@"font-size" = self.presentation.font_size;
        self.bindings = self.configuration.?.keybind.items;
        self.theme_set = colors;
        @import("locale.zig").select(self.settings.language);
        win.preferences.draft.deinit(self.a);
        win.settings_open = false;
        win.settings_discard = false;
        win.preferences.key = null;
        win.preferences.menu = null;
        win.theme_picker_open = false;
        win.input_settings_open = false;
        win.input_settings.recording = null;
        win.input_settings.loaded = false;
        self.recordingMenus(win.id, false);
        @import("menus.zig").install(self) catch |err| self.problem(err);
        self.applySettingsEffects(false);
        self.redrawAll();
    }
    fn discardSettings(self: *Runtime, win: *Window) bool {
        if (self.modal_window != 0) return false;
        if (win.preferences.draft.config == null) return true;
        if (win.preferences.draft.dirty()) {
            win.settings_discard = true;
            if (win.settings_native) |native| native.focus();
            self.redrawAll();
            return false;
        }
        self.resetSettings(win) catch |err| {
            self.problem(err);
            return false;
        };
        return true;
    }
    fn closeSettings(self: *Runtime, win: *Window) void {
        self.detachSettings(win);
        self.resetSettings(win) catch |err| self.problem(err);
    }
    fn detachSettings(_: *Runtime, win: *Window) void {
        if (win.settings_guard) |guard| guard.deinit();
        win.settings_guard = null;
        if (win.settings_native) |native| {
            native.on_close = null;
            native.close();
        }
        win.settings_native = null;
    }
    fn allowQuit(raw: *anyopaque) bool {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        if (self.modal_window != 0) return false;
        for (self.windows.items) |win| if (!win.closed) {
            win.settings_close_intent = .application;
            if (!self.discardSettings(win)) return false;
            if (!self.discardEditor(win)) return false;
            if (!self.documentsCanClose(win, null, .{ .window = win.id, .kind = .quit })) return false;
            for (win.workspaces.items) |ws| for (ws.panes.items) |owner| if (!self.confirmClose(owner)) return false;
        };
        return true;
    }
    fn duringModal(kind: @FieldType(Action, "kind")) bool {
        return kind == .focus_report or kind == .window_focus or kind == .search_tick;
    }
    fn endModal(self: *Runtime) void {
        self.modal_window = 0;
        const byte = [_]u8{1};
        _ = c.write(self.wake_pipe[1], &byte, 1);
        self.redrawAll();
    }
    fn discardEditor(self: *Runtime, win: *Window) bool {
        if (!win.editor.dirty()) return true;
        if (self.hidden) return false;
        self.modal_window = win.id;
        defer self.endModal();
        return nano.dialog.message(.{ .title = "Discard file edits?", .detail = "The file has unsaved edits.", .kind = .warning, .buttons = &.{ "Cancel", "Discard changes" } }).button == 1;
    }
    fn confirmClose(self: *Runtime, owner: *Owner) bool {
        if (self.hidden or !self.settings.@"confirm-close" or !owner.pty.busy()) return true;
        self.modal_window = owner.window;
        defer self.endModal();
        return nano.dialog.message(.{ .title = "Close this terminal?", .detail = "A program is still running. Closing the terminal ends it.", .kind = .warning, .buttons = &.{ "Cancel", "Close terminal" } }).button == 1;
    }
    fn runCommand(self: *Runtime, win: *Window, request: Action) !void {
        const id = request.text;
        if (std.mem.eql(u8, id, "palette.open") or std.mem.eql(u8, id, "settings.open") or std.mem.eql(u8, id, "session.new") or std.mem.eql(u8, id, "session.next") or std.mem.eql(u8, id, "session.previous") or std.mem.eql(u8, id, "window.new")) {
            if (!win.canLeaveDocument(0)) return;
        }
        if (win.settings_open and std.mem.startsWith(u8, id, "document.")) return;
        const document_ws = win.workspace(win.active);
        const document = if (document_ws) |ws| (if (ws.documents.visible) ws.documents.selected() else null) else null;
        if (std.mem.eql(u8, id, "document.open") or std.mem.eql(u8, id, "document.side")) return self.pickDocument(win, std.mem.endsWith(u8, id, ".side"));
        if (std.mem.eql(u8, id, "document.toggle")) {
            if (document_ws) |ws| {
                if (ws.is_file or ws.documents.documents.items.len == 0) return self.pickDocument(win, !ws.is_file);
                ws.documents.visible = !ws.documents.visible;
                if (!ws.documents.visible) for (ws.documents.documents.items) |d| d.stopPresentation();
            } else return self.pickDocument(win, false);
            return;
        }
        if (document) |d| {
            if (std.mem.eql(u8, id, "document.save") or std.mem.eql(u8, id, "document.edit")) {
                if (std.mem.eql(u8, id, "document.edit") and d.panel.inline_edit and d.panel.editor != null) {
                    d.panel.editor_rendered = false;
                    d.panel.editor.?.focus = true;
                    d.panel.layout_width = -1;
                    return;
                }
                d.panel.edit_request = if (std.mem.endsWith(u8, id, ".save")) .save else .unlock;
                try d.edit();
                return;
            }
            if (std.mem.eql(u8, id, "document.refresh")) {
                if (d.panel.editor != null) try d.gainedFocus() else try d.refresh();
                return;
            }
            if (document_ws.?.is_file and (std.mem.eql(u8, id, "pane.close") or std.mem.eql(u8, id, "session.close"))) return self.removeWorkspace(win, document_ws.?);
            if (d.panel.focused or document_ws.?.is_file) {
                const mapped: ?Documents.panel.Action = if (std.mem.eql(u8, id, "edit.copy")) .copy else if (std.mem.eql(u8, id, "edit.selectAll")) .select_all else if (std.mem.eql(u8, id, "find.open")) .search else if (std.mem.eql(u8, id, "find.next")) .search_next else if (std.mem.eql(u8, id, "find.previous")) .search_previous else if (std.mem.eql(u8, id, "text.bigger")) .font_up else if (std.mem.eql(u8, id, "text.smaller")) .font_down else if (std.mem.eql(u8, id, "text.reset")) .font_reset else null;
                if (mapped) |value| {
                    if (win.document_context) |ctx| {
                        const target = if (d.preview.focused) &d.preview else &d.panel;
                        _ = target.handleAction(value, ctx);
                    }
                    return;
                }
            }
        }
        if (std.mem.eql(u8, id, "session.new") and document_ws != null and document_ws.?.is_file) return self.newWorkspace(win, document_ws.?.directory);
        if (std.mem.eql(u8, id, "session.rename") and document_ws != null and document_ws.?.is_file) {
            win.rename_query.set(document_ws.?.title());
            win.rename_open = true;
            win.field_focus = true;
            return;
        }
        if (std.mem.eql(u8, id, "document.selected")) {
            const ws = document_ws orelse return;
            const pane = ws.pane(ws.focus) orelse return;
            const selected = (try pane.pty.terminal.interaction.text(self.a, &pane.pty.terminal.terminal)) orelse return;
            defer self.a.free(selected);
            return self.terminalDocument(win, ws, pane, selected);
        }
        if (std.mem.eql(u8, id, "settings.keepEditing")) {
            win.settings_discard = false;
            return;
        }
        if (std.mem.eql(u8, id, "settings.discard")) {
            if (!win.settings_discard) return;
            const intent = win.settings_close_intent;
            self.closeSettings(win);
            switch (intent) {
                .settings => if (win.native) |native| native.focus(),
                .window => if (Window.closeRequest(win)) {
                    if (win.native) |native| native.close();
                },
                .application => if (allowQuit(self)) self.app.quit(),
            }
            return;
        }
        if (win.settings_discard) return;
        if (std.mem.eql(u8, id, "settings.cancel")) {
            win.settings_close_intent = .settings;
            if (self.discardSettings(win)) self.closeSettings(win);
            return;
        }
        if (std.mem.eql(u8, id, "settings.open")) {
            // There is one application-wide draft and one native Settings
            // window. Resolve its owner before allocating or mutating a caller.
            for (self.windows.items) |other| if (!other.closed and other.preferences.draft.config != null) {
                if (other.settings_native) |native| native.focus();
                return;
            };
            win.closeFind();
            win.palette_open = false;
            win.rename_open = false;
            if (win.preferences.draft.config == null) {
                try win.preferences.draft.begin(self.a, self.configuration.?.source);
                win.preferences.draft.id = self.allocateId();
                win.preferences.draft.baseline_themes = self.theme_set;
                if (win.preferences.fonts == null) win.preferences.fonts = @import("font_catalog.zig").Catalog.scan(self.a) catch null;
            }
            win.settings_open = true;
            errdefer self.closeSettings(win);
            if (!self.hidden) {
                win.settings_native = try self.app.newWindow(.{ .title = "Letty Settings", .title_bar = .hidden, .width = 820, .height = 620, .min_width = 700, .min_height = 480, .content = .{ .view = .init(win, Window.settingsView) }, .on_close = .{ .ctx = win, .func = Window.settingsClosed } });
                @import("window_chrome.zig").configure(win.settings_native.?);
                win.settings_guard = try @import("window_guard.zig").Guard.install(self.a, win.settings_native.?, win, Window.settingsCloseRequest, Window.settingsFocus);
                win.settings_native.?.focus();
            }
            return;
        }
        if (std.mem.eql(u8, id, "palette.open")) {
            if (win.settings_native) |native| {
                native.focus();
                return;
            }
            win.closeFind();
            win.settings_open = false;
            win.rename_open = false;
            win.palette_open = true;
            win.palette_query.clear();
            win.field_focus = true;
            return;
        }
        if (std.mem.eql(u8, id, "changes.toggle")) {
            win.setChanges(!win.changes_open);
            win.review_focus = win.changes_open;
            if (win.changes_open) if (win.workspace(win.active)) |ws| if (ws.pane(ws.focus)) |owner| owner.refreshGit();
            return;
        }
        if (std.mem.eql(u8, id, "sidebar.toggle")) {
            const shown = win.sidebar and (win.sidebar_forced or (if (win.document_context) |ctx| ctx.size.w >= 680 else true));
            return self.execute(.{ .window = win.id, .kind = .sidebar_visibility, .delta = if (shown) 0 else 1 });
        }
        if (std.mem.eql(u8, id, "window.new")) return self.newWindow();
        if (std.mem.eql(u8, id, "app.quit")) {
            if (allowQuit(self)) self.app.quit();
            return;
        }
        if (std.mem.eql(u8, id, "project.open")) {
            self.modal_window = win.id;
            defer self.endModal();
            const chosen = (try nano.dialog.open(self.a, .{ .title = "Open Project", .files = false, .directories = true, .directory = self.directory })) orelse return;
            defer nano.dialog.freePaths(self.a, chosen);
            if (chosen.len > 0) {
                const current = self.findWindow(request.window) orelse return;
                try self.newWorkspace(current, chosen[0]);
            }
            return;
        }
        if (std.mem.eql(u8, id, "session.newHome")) return self.newWorkspace(win, os.env("HOME") orelse self.directory);
        if (std.mem.eql(u8, id, "text.bigger")) {
            self.settings.@"font-size" = @min(72, self.settings.@"font-size" + 1);
            self.presentation.font_size = self.settings.@"font-size";
            self.markPresentation();
            self.redrawAll();
            return;
        }
        if (std.mem.eql(u8, id, "text.smaller")) {
            self.settings.@"font-size" = @max(6, self.settings.@"font-size" - 1);
            self.presentation.font_size = self.settings.@"font-size";
            self.markPresentation();
            self.redrawAll();
            return;
        }
        if (std.mem.eql(u8, id, "text.reset")) {
            self.settings.@"font-size" = self.configuration.?.settings.@"font-size";
            self.presentation.font_size = 0;
            self.markPresentation();
            self.redrawAll();
            return;
        }
        if (std.mem.eql(u8, id, "session.next") or std.mem.eql(u8, id, "session.previous")) {
            for (win.workspaces.items, 0..) |ws, index| if (ws.id == win.active) {
                const count = win.workspaces.items.len;
                win.activate(win.workspaces.items[(index + if (std.mem.endsWith(u8, id, "next")) @as(usize, 1) else count - 1) % count]);
                return;
            };
            return;
        }
        if (std.mem.eql(u8, id, "session.attention")) {
            const total = win.workspaces.items.len;
            var current: usize = 0;
            for (win.workspaces.items, 0..) |ws, i| if (ws.id == win.active) {
                current = i;
                break;
            };
            inline for (.{ true, false }) |waiting| for (0..total) |offset| {
                const ws = win.workspaces.items[(current + offset + 1) % total];
                for (ws.panes.items) |owner| if (if (waiting) std.mem.eql(u8, owner.status, "blocked") else owner.unread) {
                    ws.focus = owner.pty.id;
                    win.activate(ws);
                    return;
                };
            };
            return;
        }
        const ws = win.workspace(request.workspace) orelse {
            if (std.mem.eql(u8, id, "session.new")) return self.newWorkspace(win, self.directory);
            return;
        };
        if (win.active != ws.id) return;
        const owner = ws.pane(request.pane) orelse return;
        if (ws.focus != owner.pty.id) return;
        var action = request;
        action.text = "";
        if (std.mem.eql(u8, id, "pane.restart")) {
            action.kind = .restart;
            return self.execute(action);
        }
        if (std.mem.eql(u8, id, "session.new")) {
            const mode = self.settings.@"new-session-directory";
            const current = try @import("paths.zig").directory(self.a, owner.pty.terminal.terminal.getPwd(), owner.pty.directory);
            defer self.a.free(current);
            return self.newWorkspace(win, if (std.mem.eql(u8, mode, "home")) os.env("HOME") orelse self.directory else if (std.mem.eql(u8, mode, "project")) ws.directory else current);
        }
        if (std.mem.eql(u8, id, "find.open")) {
            win.closeFind();
            win.find_pane = owner.pty.id;
            win.field_focus = true;
            try owner.pty.terminal.interaction.find(self.a, &owner.pty.terminal.terminal, win.find_query.text());
            owner.pumpSearch();
            return;
        }
        if (std.mem.eql(u8, id, "find.next") or std.mem.eql(u8, id, "find.previous")) {
            if (win.find_pane == 0) {
                action.text = "find.open";
                return self.runCommand(win, action);
            }
            try owner.pty.terminal.interaction.next(&owner.pty.terminal.terminal, std.mem.endsWith(u8, id, "previous"));
            return;
        }
        if (std.mem.eql(u8, id, "session.rename")) {
            win.rename_query.set(ws.title());
            win.rename_open = true;
            win.field_focus = true;
            return;
        }
        if (std.mem.eql(u8, id, "pane.zoom")) {
            win.zoom = if (win.zoom == 0) owner.pty.id else 0;
            return;
        }
        if (std.mem.eql(u8, id, "pane.next") or std.mem.eql(u8, id, "pane.previous")) {
            for (ws.panes.items, 0..) |pane, index| if (pane == owner) {
                ws.focus = ws.panes.items[(index + if (std.mem.endsWith(u8, id, "next")) @as(usize, 1) else ws.panes.items.len - 1) % ws.panes.items.len].pty.id;
                win.marked.clearRetainingCapacity();
                return;
            };
        }
        for ([_][]const u8{ "left", "right", "up", "down" }) |direction| if (std.mem.startsWith(u8, id, "pane.") and std.mem.eql(u8, id[5..], direction)) {
            const x = owner.rect.x + owner.rect.w / 2;
            const y = owner.rect.y + owner.rect.h / 2;
            var best: ?*Owner = null;
            var distance: f32 = std.math.inf(f32);
            for (ws.panes.items) |candidate| {
                if (candidate == owner) continue;
                const dx = candidate.rect.x + candidate.rect.w / 2 - x;
                const dy = candidate.rect.y + candidate.rect.h / 2 - y;
                const valid = if (std.mem.eql(u8, direction, "left")) dx < 0 else if (std.mem.eql(u8, direction, "right")) dx > 0 else if (std.mem.eql(u8, direction, "up")) dy < 0 else dy > 0;
                const score = dx * dx + dy * dy;
                if (valid and score < distance) {
                    best = candidate;
                    distance = score;
                }
            }
            if (best) |candidate| ws.focus = candidate.pty.id;
            win.marked.clearRetainingCapacity();
            return;
        };
        if (std.mem.eql(u8, id, "edit.selectAll")) {
            const screen = owner.pty.terminal.terminal.screens.active;
            try screen.select(screen.selectAll());
            return;
        }
        if (std.mem.eql(u8, id, "terminal.clear")) {
            try owner.pty.terminal.feed("\x1b[2J\x1b[3J\x1b[H");
            return;
        }
        const mappings = .{ .{ "pane.split.right", Action{ .window = win.id, .workspace = ws.id, .pane = owner.pty.id, .kind = .split_right } }, .{ "pane.split.down", Action{ .window = win.id, .workspace = ws.id, .pane = owner.pty.id, .kind = .split_down } }, .{ "pane.close", Action{ .window = win.id, .workspace = ws.id, .pane = owner.pty.id, .kind = .close_pane } }, .{ "session.close", Action{ .window = win.id, .workspace = ws.id, .pane = owner.pty.id, .kind = .close_workspace } }, .{ "edit.copy", Action{ .window = win.id, .workspace = ws.id, .pane = owner.pty.id, .kind = .copy } }, .{ "edit.paste", Action{ .window = win.id, .workspace = ws.id, .pane = owner.pty.id, .kind = .paste } } };
        inline for (mappings) |mapping| if (std.mem.eql(u8, id, mapping[0])) return self.execute(mapping[1]);
    }
    fn redrawAll(self: *Runtime) void {
        for (self.windows.items) |win| {
            win.redraw();
            if (win.settings_native) |native| native.redraw();
        }
    }
    fn configure(self: *Runtime, action: Action) !void {
        const Config = @import("settings.zig").Config;
        const win = self.findWindow(action.window) orelse return;
        const committed = self.configuration.?.source;
        const before = if (win.preferences.draft.config) |value| value.source else committed;
        const disk = os.readFile(self.a, self.config_path, 1024 * 1024) catch |err| blk: {
            if (err != error.OpenFile) return err;
            break :blk try self.a.dupe(u8, "");
        };
        defer self.a.free(disk);
        const reloading = action.kind == .reload_settings;
        if (!reloading and !std.mem.eql(u8, committed, disk)) return error.ConfigurationChangedExternallyReloadFirst;
        const text = if (reloading) try self.a.dupe(u8, disk) else if (action.kind == .set_binding) blk: {
            const at = std.mem.indexOfScalar(u8, action.text, '=') orelse return error.InvalidBinding;
            break :blk try (if (win.preferences.draft.config) |*draft| draft else &self.configuration.?).binding(self.a, action.text[0..at], action.text[at + 1 ..]);
        } else if (action.kind == .set_environment) blk: {
            var values: std.ArrayList([]const u8) = .empty;
            defer values.deinit(self.a);
            var lines = std.mem.splitScalar(u8, action.text, '\n');
            while (lines.next()) |line| {
                if (line.len > 0) try values.append(self.a, std.mem.trimEnd(u8, line, "\r"));
            }
            break :blk try Config.list(self.a, before, "env", values.items);
        } else blk: {
            const at = std.mem.indexOfScalar(u8, action.text, '=') orelse return error.InvalidConfigValue;
            break :blk try Config.change(self.a, before, action.text[0..at], action.text[at + 1 ..]);
        };
        defer self.a.free(text);
        const needs_write = !reloading and !std.mem.eql(u8, text, committed);
        var parsed = try Config.parse(self.a, text);
        var adopted = false;
        defer if (!adopted) parsed.deinit(self.a);
        const colors = try self.themes.?.load(self.a, parsed.settings.theme);
        const had_draft = win.preferences.draft.config != null;
        var saved_draft: @import("settings_draft.zig").Draft = .{};
        defer saved_draft.deinit(self.a);
        // Each accepted edit is one transaction. Allocate and validate first;
        // a failed write must leave the live configuration and controls intact.
        if (had_draft) {
            try saved_draft.begin(self.a, parsed.source);
            // Edits queued by the same Settings session remain valid. Reload
            // and reopen invalidate actions captured from the previous inputs.
            saved_draft.id = if (reloading) self.allocateId() else win.preferences.draft.id;
        }
        saved_draft.baseline_themes = colors;
        if (needs_write) {
            if (std.fs.path.dirname(self.config_path)) |dir| try os.mkdirs(self.a, dir);
            try os.atomicFile(self.a, self.config_path, text);
        }
        var previous = self.configuration.?;
        self.configuration = parsed;
        previous.deinit(self.a);
        win.preferences.draft.deinit(self.a);
        win.preferences.draft = saved_draft;
        saved_draft = .{};
        adopted = true;
        self.theme_set = colors;
        self.settings = parsed.settings;
        self.presentation.font_size = 0;
        self.markPresentation();
        @import("locale.zig").select(self.settings.language);
        self.bindings = parsed.keybind.items;
        @import("menus.zig").install(self) catch |err| self.problem(err);
        if (self.menu_recording != 0) @import("menus.zig").enabled(self, false);
        self.applySettingsEffects(true);
        self.queueAttention();
        self.redrawAll();
    }
    fn applySettingsEffects(self: *Runtime, committed: bool) void {
        for (self.windows.items) |window| if (window.native) |native| window.window_style.apply(native, self.settings.@"window-translucent" and !self.hidden);
        // History eviction follows a successfully persisted edit, never a
        // candidate whose validation or write failed.
        if (committed) for (self.windows.items) |window| for (window.workspaces.items) |ws| for (ws.panes.items) |owner| owner.pty.terminal.terminal.setScrollbackMaxBytes(@as(usize, self.settings.@"scrollback-limit") * 1024 * 1024);
    }
    pub fn verify(self: *Runtime) !void {
        const win = self.windows.items[0];
        if (os.env("LETTY_DOCUMENT_UI_ONLY") != null) {
            var tester: ui.Tester = undefined;
            try tester.init(self.a, .init(win, Window.view), .{ .width = 1200, .height = 780 });
            defer tester.deinit();
            try self.verifyDocuments(win, &tester);
            try os.output("Current document UI checks passed.\n");
            return;
        }
        const ws = win.workspaces.items[0];
        const first = ws.panes.items[0];
        const first_id = first.pty.id;
        try self.execute(.{ .window = win.id, .workspace = ws.id, .pane = first_id, .kind = .split_right });
        try uiCheck(ws.panes.items.len == 2 and ws.layout.row and ws.pane(first_id) != null, "split owns two local PTYs and retains stable identity");
        const second = ws.panes.items[1];
        const queued_before = first.pty.terminal.tx.items.len;
        try self.execute(.{ .window = win.id, .workspace = ws.id, .pane = first_id, .kind = .input, .text = "SHOULD_NOT_REACH_PTY" });
        try uiCheck(first.pty.terminal.tx.items.len == queued_before, "deferred input rejects a pane that lost focus");
        var tester: ui.Tester = undefined;
        try tester.init(self.a, .init(win, Window.view), .{ .width = 1200, .height = 780 });
        defer tester.deinit();
        try uiCheck(C.findIcon(&tester, "letty-f7-gear-alt-ink") != null, "native view shows local terminal navigation");
        try uiCheck(self.app.menuItem("pane.restart") != null and self.app.menuItem("changes.toggle") != null and self.app.menuItem("pane.browser") == null, "native menus expose local terminal actions and exclude browser actions");
        tester.frame();
        var divider_bounds: ui.Rect = .{};
        for (tester.ctx.nodes.items) |node| if (node.style.layer == 2 and node.style.width == .px and node.style.width.px == 8) {
            divider_bounds = node.rect;
            break;
        };
        tester.drag(divider_bounds.x + 4, divider_bounds.y + divider_bounds.h / 2, divider_bounds.x + 74, divider_bounds.y + divider_bounds.h / 2);
        nano.runFor(0.05);
        tester.frame();
        try uiCheck(ws.layout.ratio > 0.55, "dragging a native split divider updates its bounded layout ratio");
        try self.execute(.{ .window = win.id, .workspace = ws.id, .pane = first_id, .other = second.pty.id, .kind = .split_resize, .value = 0.5 });
        tester.frame();
        const source = first.screen_rect;
        const destination = second.screen_rect;
        tester.drag(source.x + 40, source.y + 20, destination.x + destination.w / 2, destination.y + destination.h / 2);
        nano.runFor(0.05);
        tester.frame();
        try uiCheck(std.mem.eql(u8, ws.layout.a.?.pane, second.key) and ws.pane(first_id) == first, "dragging a pane header swaps layout positions while preserving its PTY identity");
        try self.execute(.{ .window = win.id, .workspace = ws.id, .pane = first_id, .other = second.pty.id, .kind = .pane_move, .text = "swap" });
        ws.focus = second.pty.id;
        tester.frame();
        try self.execute(.{ .window = win.id, .kind = .chrome_resize, .text = "sidebar", .value = 275 });
        try self.execute(.{ .window = win.id, .kind = .toggle_group, .text = ws.directory });
        try self.savePresentation();
        const prefs = try os.readFile(self.a, self.presentation_path, 1024 * 1024);
        defer self.a.free(prefs);
        var restored = try @import("ui_state.zig").State.parse(self.a, prefs);
        defer restored.deinit(self.a);
        try uiCheck(restored.sidebar_width == 275 and restored.folded(ws.directory), "local sidebar widths and project folding round trip through a private preferences file");
        try self.execute(.{ .window = win.id, .kind = .toggle_group, .text = ws.directory });
        try self.execute(.{ .window = win.id, .kind = .chrome_resize, .text = "sidebar", .value = 252 });
        tester.frame();

        tester.typeText("printf 'UI_INPUT_%s\\n' MARKER");
        tester.key(.enter);
        nano.runFor(0.3);
        const typed = try second.pty.terminal.text(self.a, false);
        defer self.a.free(typed);
        try uiCheck(std.mem.indexOf(u8, typed, "UI_INPUT_MARKER") != null, "native input traverses deferred actions and executes in its owned PTY");
        const cwd_fixture = try std.fmt.allocPrint(self.a, "{s}/cwd-without-osc", .{self.directory});
        defer self.a.free(cwd_fixture);
        try os.mkdirs(self.a, cwd_fixture);
        const quoted_cwd = try @import("shell.zig").quote(self.a, "sh", cwd_fixture);
        defer self.a.free(quoted_cwd);
        const change_cwd = try std.fmt.allocPrint(self.a, "cd {s}\r", .{quoted_cwd});
        defer self.a.free(change_cwd);
        _ = try second.pty.send(change_cwd);
        try second.scheduleWrites();
        var found_cwd = false;
        const cwd_deadline = os.millis() + 3000;
        while (os.millis() < cwd_deadline and !found_cwd) {
            nano.runFor(0.01);
            const observed = try second.currentDirectory(self.a);
            defer self.a.free(observed);
            found_cwd = std.mem.eql(u8, observed, cwd_fixture);
        }
        try uiCheck(found_cwd and second.pty.terminal.terminal.getPwd() == null, "repository discovery follows the owned shell's real cwd after cd without requiring OSC 7 integration");
        second.changes.deinit(self.a);
        second.changes = .{ .backend = .svn, .initialized = true, .epoch = 1, .directory = try self.a.dupe(u8, cwd_fixture) };
        second.changes.svn_state.data = try Vcs.svn.Data.status(self.a, "<status><target><entry path='local.sv'><wc-status item='modified' props='none'/></entry></target></status>");
        try self.execute(.{ .window = win.id, .workspace = ws.id, .pane = second.pty.id, .kind = .git_select, .review_epoch = second.changes.epoch, .text = "local.sv" });
        try uiCheck(std.mem.eql(u8, second.changes.selected(), "local.sv"), "queued repository file selection validates the real shell cwd without OSC 7");
        second.changes.deinit(self.a);
        second.changes = .{};
        const quoted_root = try @import("shell.zig").quote(self.a, "sh", self.directory);
        defer self.a.free(quoted_root);
        const restore_cwd = try std.fmt.allocPrint(self.a, "cd {s}\r", .{quoted_root});
        defer self.a.free(restore_cwd);
        _ = try second.pty.send(restore_cwd);
        try second.scheduleWrites();
        nano.runFor(0.05);
        try C.clickIcon(&tester, "letty-f7-gear-alt-ink");
        nano.runFor(0.03);
        tester.frame();
        try tester.screenshot(".cache/letty-ui-check-settings.png");
        try uiCheck(win.settings_open and win.preferences.draft.config != null and tester.hasText("General"), "settings opens and blocks terminal input");
        const second_before = second.pty.terminal.tx.items.len;
        try self.execute(.{ .window = win.id, .workspace = ws.id, .pane = second.pty.id, .kind = .input, .text = "BLOCKED_BY_SETTINGS" });
        try uiCheck(second.pty.terminal.tx.items.len == second_before, "settings focus rejects queued terminal input");
        try self.verifySettingsDraft(win, &tester);
        try self.runCommand(win, .{ .window = win.id, .kind = .command, .text = "settings.cancel" });
        tester.frame();
        try uiCheck(!win.settings_open, "terminal focus returns after settings closes");
        // Finish the input integration fixture before drawing deterministic
        // parser fixtures: a live shell may repaint on every find-bar resize.
        _ = try first.pty.send("exit\r");
        _ = try second.pty.send("exit\r");
        try first.scheduleWrites();
        try second.scheduleWrites();
        nano.runFor(0.2);
        try uiCheck(first.pty.exit_code != null and second.pty.exit_code != null, "owned shell fixtures exit and are reaped before deterministic rendering");
        try self.verifyPromptColors(second, &tester);
        try second.pty.terminal.feed("\x1b[2J\x1b[3J\x1b[H\x1b_Ga=T,f=24,s=1,v=1,i=101,c=8,r=3,C=1;/wAA\x1b\\");
        tester.frame();
        var image_rect: ui.Rect = .{};
        for (tester.ctx.nodes.items) |node| if (node.content == .texture) {
            const texture = tester.ctx.textures.items[node.content.texture.slot];
            if (std.mem.eql(u8, texture.bgra, &.{ 0, 0, 255, 255 })) {
                image_rect = node.rect;
                break;
            }
        };
        const image_pixels = try tester.render(self.a);
        defer image_pixels.deinit(self.a);
        const sample_x: usize = @intFromFloat((image_rect.x + image_rect.w * 0.75) * tester.scale);
        const sample_y: usize = @intFromFloat((image_rect.y + image_rect.h * 0.75) * tester.scale);
        if (sample_x >= image_pixels.width or sample_y >= image_pixels.height) return error.ImageOutsideFixture;
        const sample = image_pixels.bytes[(sample_y * image_pixels.width + sample_x) * 4 ..][0..4];
        try uiCheck(image_rect.w > 0 and sample[2] > 240 and sample[0] < 10 and sample[1] < 10, "Kitty protocol pixels pass through native frame textures and the actual renderer");
        try second.pty.terminal.feed("\x1b_Ga=d,d=A\x1b\\");
        tester.frame();
        try uiCheck(second.pty.terminal.graphics.bytes == 0, "Kitty delete releases the terminal-owned texture copy");
        try self.verifySidebar(win, ws, &tester);
        try self.verifyMenus(win, ws, &tester);
        try self.verifyDocumentCapacity(win, ws);
        var pixel_bytes = [_]u8{ 0, 0, 255, 255, 0, 255, 0, 255 };
        const png = try ui.png.encode(self.a, .{ .bytes = &pixel_bytes, .width = 2, .height = 1 });
        defer self.a.free(png);
        const image_path = try std.fmt.allocPrint(self.a, "{s}/private-preview.png", .{self.directory});
        defer self.a.free(image_path);
        try os.atomicFile(self.a, image_path, png);
        try self.execute(.{ .window = win.id, .workspace = ws.id, .pane = second.pty.id, .kind = .image_hover, .text = image_path });
        const image_deadline = os.millis() + 5000;
        while (win.preview.png.len == 0 and !win.preview.failed and os.millis() < image_deadline) {
            self.processJobs();
            nano.runFor(0.01);
        }
        try uiCheck(win.preview.png.len > 24 and !win.preview.failed, "bounded image helper decodes an owned local file and returns a PNG thumbnail");
        const stale_generation = win.preview.generation;
        try self.execute(.{ .window = win.id, .kind = .image_hide });
        const old_png = win.preview.png;
        try win.preview.accept(self.a, stale_generation, "invalid stale response");
        try uiCheck(win.preview.png.ptr == old_png.ptr and win.preview.generation != stale_generation, "leaving an image hover invalidates late helper responses");
        win.preview.shown = false;
        win.preview.was_shown = false;
        var pasted: @import("paste.zig").Store = .{};
        defer pasted.deinit(self.a);
        const stored = try pasted.image(self.a, png);
        const stored_bytes = try os.readFile(self.a, stored, 32 * 1024 * 1024);
        defer self.a.free(stored_bytes);
        const quoted = try @import("paste.zig").paths(self.a, &.{ "/tmp/private file's name.png", stored }, "/bin/sh");
        defer self.a.free(quoted);
        try uiCheck(std.mem.eql(u8, png, stored_bytes) and std.mem.indexOf(u8, quoted, "'\\''") != null, "image paste keeps private owned PNG data and shell-quotes file paths");
        win.settings_open = true;
        second.unread = true;
        try self.execute(.{ .window = win.id, .workspace = ws.id, .pane = first_id, .kind = .notification_activate });
        try uiCheck(ws.focus == first_id and !win.settings_open, "notification activation resolves a live stable target and returns focus to its terminal");
        ws.focus = second.pty.id;

        try second.pty.terminal.feed("\x1b[2J\x1b[3J\x1b[HSELECT_MARKER needle\r\nUnicode 中文 e\xcc\x81\r\n");
        tester.frame();
        try self.runCommand(win, .{ .window = win.id, .workspace = ws.id, .pane = second.pty.id, .kind = .command, .text = "find.open" });
        tester.frame();
        tester.typeText("needle");
        nano.runFor(0.05);
        tester.frame();
        try tester.screenshot(".cache/letty-ui-check-find.png");
        try uiCheck(win.find_pane == second.pty.id and second.pty.terminal.interaction.count() == 1, "find field searches native VT while terminal input is isolated");
        try C.clickIconWithin(&tester, "letty-f7-xmark-ink", .{ .x = second.screen_rect.x, .y = second.screen_rect.y + 44, .w = second.screen_rect.w, .h = 50 });
        try uiCheck(win.find_pane == 0, "closing find restores the terminal input target");
        // Resizing the viewport can legitimately move the former top line
        // into scrollback. Selection uses a fresh visible row after find closes.
        second.pty.terminal.terminal.scrollViewport(.bottom);
        try second.pty.terminal.feed("\x1b[2J\x1b[3J\x1b[HSELECT_MARKER needle\r\nUnicode 中文 e\xcc\x81\r\n");
        tester.frame();
        const marker = tester.findGridCell("SELECT_MARKER") orelse return error.MissingSelectionFixture;
        tester.doubleClick(marker.x + 2, marker.y + marker.h / 2);
        try self.execute(.{ .window = win.id, .workspace = ws.id, .pane = second.pty.id, .kind = .copy });
        try uiCheck(self.private_clipboard != null and std.mem.eql(u8, self.private_clipboard.?, "SELECT_MARKER"), "double click selects and copies only the native terminal word to a private clipboard");
        tester.moveTo(marker.x + 2, marker.y + marker.h / 2);
        tester.ctx.input.mouse_button = 2;
        tester.ctx.pointerDown();
        tester.frame();
        tester.ctx.pointerUp();
        tester.frame();
        tester.ctx.input.mouse_button = 1;
        try uiCheck(win.terminal_menu.open and tester.hasText("Copy selection") and self.private_clipboard != null and std.mem.eql(u8, self.private_clipboard.?, "SELECT_MARKER"), "default right click opens a terminal context menu without pasting");
        try tester.clickText("Copy selection");
        nano.runFor(0.05);
        try uiCheck(!win.terminal_menu.open and std.mem.eql(u8, self.private_clipboard.?, "SELECT_MARKER"), "context menu copies its stable pane selection to the private clipboard");
        try second.pty.terminal.feed("\x1b]52;c;T1NDNTJfUFJJVkFURQ==\x07");
        try uiCheck(self.private_clipboard != null and std.mem.eql(u8, self.private_clipboard.?, "OSC52_PRIVATE"), "OSC 52 writes through native callbacks to the private fixture clipboard");
        self.settings.@"clipboard-read" = "allow";
        const reply_start = second.pty.terminal.tx.items.len;
        try second.pty.terminal.feed("\x1b]52;c;?\x07");
        try uiCheck(std.mem.indexOf(u8, second.pty.terminal.tx.items[reply_start..], "T1NDNTJfUFJJVkFURQ==") != null, "OSC 52 reads respect the allow policy and encode their native reply");
        second.pty.terminal.tx.items.len = reply_start;
        self.settings.@"clipboard-read" = "ask";
        try self.runCommand(win, .{ .window = win.id, .workspace = ws.id, .pane = second.pty.id, .kind = .command, .text = "palette.open" });
        tester.frame();
        tester.typeText("split d");
        try tester.clickText("Split Down");
        nano.runFor(0.05);
        try uiCheck(ws.panes.items.len == 3 and !win.palette_open, "filtered command palette invokes a stable local split action");
        const third_id = ws.focus;
        try self.execute(.{ .window = win.id, .workspace = ws.id, .pane = third_id, .kind = .close_pane });
        ws.focus = second.pty.id;
        try self.runCommand(win, .{ .window = win.id, .kind = .command, .text = "settings.open" });
        try self.execute(.{ .window = win.id, .kind = .set_setting, .text = "font-size=15" });
        const saved = try os.readFile(self.a, self.config_path, 1024 * 1024);
        defer self.a.free(saved);
        try uiCheck(self.settings.@"font-size" == 15 and std.mem.indexOf(u8, saved, "font-size = ") != null, "settings persist to their private configuration file and apply at once");
        try self.execute(.{ .window = win.id, .kind = .set_setting, .text = "font-size=13" });
        tester.frame();
        try tester.clickText("Terminal");
        tester.frame();
        win.preferences.menu = .dark_theme;
        win.preferences.key = "theme";
        win.preferences.popup = .{ .x = 800, .y = 140, .w = 240, .h = 28 };
        win.preferences.font_focus = true;
        tester.frame();
        tester.typeText("Gruvbox Dark");
        tester.frame();
        try tester.screenshot(".cache/letty-ui-check-theme.png");
        // The query field also draws this text. Click the result, rendered last.
        var theme_result: ?ui.Rect = null;
        for (tester.ctx.nodes.items) |node| if (node.content == .text and std.mem.eql(u8, node.content.text.str, "Gruvbox Dark")) {
            theme_result = node.rect;
        };
        const theme_choice = theme_result orelse return error.ThemeChoiceMissing;
        tester.click(theme_choice.x + theme_choice.w / 2, theme_choice.y + theme_choice.h / 2);
        nano.runFor(0.05);
        tester.frame();
        try uiCheck(self.theme_set.dark.background == 0x282828 and self.theme_set.light.background == 0xffffff, "theme picker applies a pinned dark theme without changing the light palette");
        try self.execute(.{ .window = win.id, .kind = .set_setting, .text = "theme=letty" });
        try self.execute(.{ .window = win.id, .kind = .set_setting, .text = "language=zh-Hans" });
        tester.frame();
        try uiCheck(tester.hasText("终端") and tester.hasText("外观"), "Simplified Chinese catalog localizes product labels while keeping terminal text unchanged");
        try self.execute(.{ .window = win.id, .kind = .set_setting, .text = "language=en" });
        win.input_settings_open = true;
        win.input_settings.tab = .shortcuts;
        win.preferences.page = .keyboard;
        win.input_settings.query.set("New Session");
        var recorder: ui.Tester = undefined;
        try recorder.init(self.a, .init(win, Window.settingsView), .{ .width = 820, .height = 620 });
        defer recorder.deinit();
        var record_index: usize = 0;
        for (commands.all, 0..) |command, index| if (std.mem.eql(u8, command.id, "session.new")) {
            record_index = index;
            break;
        };
        const record_label = C.shortcutLabel(&recorder.ctx, commands.keys(record_index, self.bindings, @import("builtin").os.tag == .macos));
        try recorder.clickText(record_label);
        try uiCheck(win.input_settings.recording == record_index and recorder.hasText("…") and self.menu_recording == win.id, "clicking the native Settings shortcut control redraws recording feedback and suspends menu accelerators");
        recorder.textOps(&.{.{ .command = .cancel }});
        try uiCheck(win.input_settings.recording == null and self.menu_recording == 0, "AppKit cancel text operation cancels shortcut recording without creating a binding");
        try recorder.clickText(C.shortcutLabel(&recorder.ctx, commands.keys(record_index, self.bindings, @import("builtin").os.tag == .macos)));
        _ = recorder.shortcut(.{ .key = 27 });
        try uiCheck(win.input_settings.recording == null and self.menu_recording == 0, "native Escape shortcut cancels recording instead of becoming an unmodified binding");
        try recorder.clickText(C.shortcutLabel(&recorder.ctx, commands.keys(record_index, self.bindings, @import("builtin").os.tag == .macos)));
        recorder.key(.escape);
        try uiCheck(win.input_settings.recording == null and self.menu_recording == 0, "Escape cancels native Settings recording and restores native menu accelerators");
        try recorder.clickText(C.shortcutLabel(&recorder.ctx, commands.keys(record_index, self.bindings, @import("builtin").os.tag == .macos)));
        _ = recorder.shortcut(.{ .key = '9', .ctrl = true, .alt = true });
        nano.runFor(0.05);
        try uiCheck(win.input_settings.recording == null and std.mem.eql(u8, commands.match(.{ .key = '9', .ctrl = true, .alt = true }, self.bindings, true) orelse "", "session.new"), "shortcut recorder persists a custom binding without dispatching terminal or menu commands");
        try self.execute(.{ .window = win.id, .kind = .set_binding, .text = "session.new=none" });
        try uiCheck(commands.match(.{ .key = '9', .ctrl = true, .alt = true }, self.bindings, true) == null, "per-action unbind removes the custom shortcut");
        try self.execute(.{ .window = win.id, .kind = .set_binding, .text = "session.new=" });
        try self.execute(.{ .window = win.id, .kind = .set_environment, .text = "LETTY_PRIVATE_ONE=first\nLETTY_PRIVATE_TWO=中文=second\n" });
        try uiCheck(win.preferences.draft.config.?.env.items.len == 2 and std.mem.eql(u8, win.preferences.draft.config.?.env.items[1], "LETTY_PRIVATE_TWO=中文=second"), "environment form persists repeated values including Unicode and equals signs");
        try self.execute(.{ .window = win.id, .kind = .set_environment, .text = "" });
        win.input_settings_open = false;
        self.recordingMenus(win.id, false);
        self.closeSettings(win);
        try first.pty.terminal.feed("\x1b[2J\x1b[H\x1b[1mLetty\x1b[0m · native Zig terminal\r\n\r\n$ uname -s\r\nLinux\r\n\r\n\x1b[32mPTY → libghostty-vt → native renderer\x1b[0m\r\n中文 · e\xcc\x81 · terminal cells\r\n");
        try second.pty.terminal.feed("\x1b[2J\x1b[H$ zig version\r\n0.17.0\r\n\r\n\x1b[34mLocal terminal state\x1b[0m\r\nX11 carries the GUI to the display.\r\n");
        tester.frame();
        if (os.env("LETTY_UI_SCREENSHOT_DIR")) |dir| {
            try os.mkdirs(self.a, dir);
            const path = try std.fmt.allocPrint(self.a, "{s}/letty-light.png", .{dir});
            defer self.a.free(path);
            try tester.screenshot(path);
        }
        var fixture = try @import("git_check.zig").run(self.a, self.directory);
        // Runtime completions must resolve the live owner, not the fixture's window 0.
        fixture.target.window = win.id;
        fixture.target.workspace = ws.id;
        fixture.target.pane = second.pty.id;
        second.changes.deinit(self.a);
        second.changes = .{ .backend = .git, .git_state = fixture, .initialized = true, .directory = try self.a.dupe(u8, fixture.root), .target = .{ .window = win.id, .workspace = ws.id, .pane = second.pty.id } };
        second.changes.git_state.target = .{ .window = win.id, .workspace = ws.id, .pane = second.pty.id, .generation = fixture.generation };
        const git_pwd = try std.fmt.allocPrint(self.a, "\x1b]7;file://localhost{s}\x1b\\", .{fixture.root});
        defer self.a.free(git_pwd);
        try second.pty.terminal.feed(git_pwd);
        win.zoom = second.pty.id;
        win.changes_open = false;
        tester.frame();
        tester.frame();
        const badge_label = try std.fmt.allocPrint(self.a, "Git {s}", .{second.changes.label()});
        defer self.a.free(badge_label);
        try uiCheck(tester.hasText(badge_label) and tester.containsText(" files"), "terminal headers show the active Git branch and owned change summary before opening Changes");
        try tester.clickText(badge_label);
        nano.runFor(0.03);
        try uiCheck(win.changes_open and ws.focus == second.pty.id, "clicking a repository badge opens Changes for its stable workspace and pane target");
        try self.finishReview(second);
        self.settings.@"git-status" = false;
        tester.frame();
        try uiCheck(!tester.hasText(badge_label), "disabling repository status hides the terminal badge");
        self.settings.@"git-status" = true;
        win.zoom = 0;
        win.review_focus = true;
        tester.frame();
        try uiCheck(tester.hasText("Changes") and tester.hasText("Uncommitted"), "native Git panel renders owned snapshot data without terminal input leakage");
        const old_context_version = second.changes.patchVersion();
        try self.execute(.{ .window = win.id, .workspace = ws.id, .pane = second.pty.id, .kind = .git_context, .review_epoch = second.changes.epoch, .other = old_context_version, .value = 23 });
        try self.finishReview(second);
        try uiCheck(second.changes.contextLines() == 23 and second.changes.patch().len > 0, "diff context expansion runs against the owned Git snapshot");
        try self.execute(.{ .window = win.id, .workspace = ws.id, .pane = second.pty.id, .kind = .git_context, .review_epoch = second.changes.epoch, .other = old_context_version, .value = 3 });
        try uiCheck(second.changes.contextLines() == 23, "stale diff context requests cannot replace a newer preview");
        try self.execute(.{ .window = win.id, .workspace = ws.id, .pane = second.pty.id, .kind = .git_context, .review_epoch = second.changes.epoch, .other = second.changes.patchVersion(), .value = 3 });
        try self.finishReview(second);
        win.git_view.query.set("working");
        win.git_view.model.version = null;
        tester.frame();
        try uiCheck(win.git_view.search.matches.items.len > 0, "diff search indexes the currently owned patch separately from terminal input");
        win.git_view.query.set("");
        try win.git_view.search.find(self.a, win.git_view.model.lines.items, "");
        const review_path = try std.fmt.allocPrint(self.a, "{s}/tracked.txt", .{second.changes.root()});
        defer self.a.free(review_path);
        try win.editor.load(self.a, second.changes.root(), "tracked.txt", second.pty.id, ws.id, second.changes.epoch);
        second.status = "idle";
        tester.frame();
        const before_composition = try self.a.dupe(u8, win.editor.buffer.text);
        defer self.a.free(before_composition);
        const before_undo = win.editor.buffer.undo.items.len;
        tester.textOps(&.{.{ .set_marked = .{ .text = "组", .sel_start = 0, .sel_len = "组".len } }});
        tester.frame();
        const marked_first = tester.ctx.focused_text orelse return error.MissingEditorMarkedText;
        try uiCheck(std.mem.eql(u8, before_composition, win.editor.buffer.text) and win.editor.buffer.undo.items.len == before_undo and marked_first.marked != null and marked_first.caret == "组".len, "editor preedit publishes byte caret and marked range without changing document or undo");
        tester.textOps(&.{.{ .set_marked = .{ .text = "组合", .sel_start = "组合".len, .sel_len = 0 } }});
        tester.frame();
        const marked_second = tester.ctx.focused_text orelse return error.MissingEditorMarkedText;
        try uiCheck(std.mem.eql(u8, before_composition, win.editor.buffer.text) and win.editor.buffer.undo.items.len == before_undo and marked_second.marked.?[1] - marked_second.marked.?[0] == "组合".len and marked_second.caret == "组合".len, "editor replaces owned preedit and positions IME candidates from the same displayed bytes");
        tester.textOps(&.{.{ .insert = "最终" }});
        try uiCheck(win.editor.buffer.undo.items.len == before_undo + 1 and win.editor.composition.range == null and std.mem.startsWith(u8, win.editor.buffer.text, "最终"), "IME final commit inserts Chinese text as one undoable document edit");
        tester.textOps(&.{ .{ .command = .select_all }, .{ .insert = "edited 中文 e\xcc\x81\n" } });
        try uiCheck(win.editor.dirty() and std.mem.eql(u8, win.editor.buffer.text, "edited 中文 e\xcc\x81\n"), "native review editor accepts IME text operations without terminal input leakage");
        try self.execute(.{ .window = win.id, .workspace = ws.id, .pane = second.pty.id, .kind = .editor_save });
        const edited = try os.readFile(self.a, review_path, 1024 * 1024);
        defer self.a.free(edited);
        try uiCheck(std.mem.eql(u8, edited, "edited 中文 e\xcc\x81\n") and !win.editor.dirty(), "review editor saves a bounded regular file through a worktree-relative atomic write");
        try win.editor.buffer.insert(self.a, "local edit");
        try os.atomicFile(self.a, review_path, "external edit\n");
        try self.execute(.{ .window = win.id, .workspace = ws.id, .pane = second.pty.id, .kind = .editor_save });
        const external = try os.readFile(self.a, review_path, 1024 * 1024);
        defer self.a.free(external);
        try uiCheck(std.mem.eql(u8, external, "external edit\n") and std.mem.eql(u8, win.editor.error_text, "FileChangedExternallyReloadFirst"), "review editor rejects an external file change instead of overwriting it");
        win.editor.deinit(self.a);
        const parent_link = try std.fmt.allocPrintSentinel(self.a, "{s}/linked-parent", .{second.changes.root()}, 0);
        defer self.a.free(parent_link);
        if (std.c.symlink("/tmp", parent_link) != 0) return error.PrivateSymlinkFixture;
        var escaped = @import("review_file.zig").File.open(self.a, second.changes.root(), "linked-parent/foreign.txt");
        if (escaped) |*file| {
            file.deinit(self.a);
            return error.SymlinkReviewEscaped;
        } else |err| {
            try uiCheck(err == error.OpenReviewDirectory, "review editing rejects symlinked ancestor directories");
        }
        try os.atomicFile(self.a, review_path, "working\n");
        second.changes.git_state.base = .turn;
        try self.execute(.{ .window = win.id, .workspace = ws.id, .pane = second.pty.id, .kind = .git_refresh });
        try self.finishReview(second);
        tester.frame();
        try tester.clickText("Keep");
        tester.frame();
        try uiCheck(tester.hasText("Kept"), "agent-turn review can keep an individual hunk without writing the working file");
        win.git_view.kept.clearRetainingCapacity();
        tester.frame();
        try tester.clickText("Revert hunk");
        nano.runFor(0.05);
        try self.finishReview(second);
        const reverted_file = try os.readFile(self.a, review_path, 1024 * 1024);
        defer self.a.free(reverted_file);
        try uiCheck(std.mem.eql(u8, reverted_file, "before\n"), "agent-turn hunk reversal updates only the verified local working file");
        try self.verifySvnPanel(win, ws, second, &tester);
        tester.frame();
        try C.clickIconWithin(&tester, "letty-f7-xmark-ink", win.git_view.header_rect);
        win.review_focus = false;
        tester.resize(640, 480);
        try uiCheck(C.findIcon(&tester, "letty-f7-sidebar-left-ink") != null, "narrow viewport retains native navigation");
        try self.execute(.{ .window = win.id, .workspace = ws.id, .pane = first_id, .kind = .close_pane });
        try uiCheck(ws.panes.items.len == 1 and ws.layout.leaf() and ws.pane(first_id) == null, "closing one split preserves the sibling PTY");
        try self.execute(.{ .window = win.id, .workspace = ws.id, .pane = first_id, .kind = .input, .text = "STALE_ID" });
        try uiCheck(ws.panes.items[0].pty.id == second.pty.id, "closed pane identity cannot redirect to its sibling");
        try self.execute(.{ .window = win.id, .workspace = ws.id, .pane = second.pty.id, .kind = .restart });
        try uiCheck(ws.panes.items.len == 1 and ws.focus != first_id and ws.layout.contains(ws.panes.items[0].key), "restart publishes a fresh PTY identity into the existing layout");
        try self.newWorkspace(win, self.directory);
        try uiCheck(win.workspaces.items.len == 2 and win.active != ws.id, "new workspaces allocate independent local terminals");
        try self.verifyDocuments(win, &tester);
        try os.output("All UI checks passed.\n");
    }
    fn documentControl(t: *ui.Tester, p: *Documents.panel.Panel, control: Documents.panel.Control) !void {
        t.frame();
        for (p.ax_controls[0..p.ax_count]) |item| if (item.control == control and item.enabled) {
            const rect = t.ctx.rects.get(item.widget) orelse continue;
            t.click(rect.x + rect.w / 2, rect.y + rect.h / 2);
            nano.runFor(0.02);
            t.frame();
            return;
        };
        return error.DocumentControlMissing;
    }
    fn finishDocument(document: *Documents.Document, editing: bool) !void {
        const until = os.millis() + 6000;
        while (os.millis() < until) {
            nano.runFor(0.01);
            try document.drain();
            if (if (editing) document.job == null else document.panel.model.status != .loading) return;
        }
        return error.DocumentFixtureTimeout;
    }
    fn documentScreenshot(self: *Runtime, tester: *ui.Tester, name: []const u8) !void {
        if (os.env("LETTY_UI_SCREENSHOT_DIR")) |directory| {
            const file = try std.fmt.allocPrint(self.a, "{s}/{s}", .{ directory, name });
            defer self.a.free(file);
            try tester.screenshot(file);
        }
    }
    fn documentImagePixels(self: *Runtime, t: *ui.Tester, image: *const Documents.panel.Image, label: []const u8) !void {
        var bounds: ?ui.Rect = null;
        for (t.ctx.nodes.items) |node| if (node.content == .texture) {
            const texture = t.ctx.textures.items[node.content.texture.slot];
            if (texture.width == image.width and texture.height == image.height and texture.bgra.ptr == image.bgra.ptr) {
                bounds = node.rect;
                break;
            }
        };
        const rect = bounds orelse return error.DocumentImageNotPainted;
        try uiCheck(rect.w >= 128 and rect.h >= 40, "document fixture paints a recognizable local PNG on the visible native card");
        const pixels = try t.render(self.a);
        defer pixels.deinit(self.a);
        for ([_]usize{ 8, 24 }) |x| {
            const px: usize = @intFromFloat((rect.x + @as(f32, @floatFromInt(x))) * t.scale);
            const py: usize = @intFromFloat((rect.y + 8) * t.scale);
            if (px >= pixels.width or py >= pixels.height) return error.DocumentImageOutsideViewport;
            const actual = pixels.bytes[(py * pixels.width + px) * 4 ..][0..4];
            const expected = image.bgra[(8 * image.width + x) * 4 ..][0..4];
            for (actual, expected) |got, want| if (@abs(@as(i16, got) - @as(i16, want)) > 8) return error.DocumentImagePixelMismatch;
        }
        try uiCheck(true, label);
    }
    fn verifyDocuments(self: *Runtime, win: *Window, t: *ui.Tester) !void {
        win.edit_tester = t;
        defer win.edit_tester = null;
        const terminal_ws = win.workspace(win.active).?;
        const terminal_pane = terminal_ws.pane(terminal_ws.focus).?;
        const image_path = try std.fmt.allocPrint(self.a, "{s}/document-inline.png", .{self.directory});
        defer self.a.free(image_path);
        defer {
            const z = self.a.dupeSentinel(u8, image_path, 0) catch unreachable;
            defer self.a.free(z);
            _ = c.unlink(z);
        }
        var pixels: [256 * 80 * 4]u8 = undefined;
        for (0..80) |y| for (0..256) |x| {
            const color: [4]u8 = if ((x / 16 + y / 16) % 2 == 0) .{ 0, 0, 255, 255 } else .{ 255, 0, 0, 255 };
            @memcpy(pixels[(y * 256 + x) * 4 ..][0..4], &color);
        };
        const png = try ui.png.encode(self.a, .{ .bytes = &pixels, .width = 256, .height = 80 });
        defer self.a.free(png);
        try os.atomicFile(self.a, image_path, png);
        const path = try std.fmt.allocPrint(self.a, "{s}/document-current.md", .{self.directory});
        defer self.a.free(path);
        defer {
            const z = self.a.dupeSentinel(u8, path, 0) catch unreachable;
            defer self.a.free(z);
            _ = c.unlink(z);
        }
        const fixture = "# Preview fixture\n\n![local image](document-inline.png)\n\nNative **bold**, *italic*, `source`, [local link](document-current.md), needle 中文 é 👩‍💻.\n\n> A quoted paragraph that wraps inside the current card.\n\n- First item\n- [x] Finished item\n\n| Name | Value |\n|:---|---:|\n| Native | 42 |\n\nInline $E=mc^2$ and $\\frac{a}{b}$.\n\n```zig\nconst value = 42;\n```\n\n```mermaid\nflowchart LR\nA[Source] --> B{Preview}\n```\n";
        try os.atomicFile(self.a, path, fixture);
        const workspaces = win.workspaces.items.len;
        try self.openDocument(win, path, false, self.directory);
        const file_ws = win.workspace(win.active).?;
        const document = file_ws.documents.selected().?;
        document.panel.inline_edit = false; // Source/side lifecycle coverage below.
        try finishDocument(document, false);
        t.resize(1200, 780);
        t.frame();
        try uiCheck(file_ws.is_file and file_ws.panes.items.len == 0 and win.workspaces.items.len == workspaces + 1 and t.hasText("Preview fixture"), "current entry opens native Markdown in an independent workspace without allocating a PTY");
        try uiCheck(document.panel.prepared.?.markdown.?.formulas.len > 0 and document.panel.prepared.?.image_count == 1, "current document owns bounded math, Mermaid and local-image preparation");
        try self.documentImagePixels(t, document.panel.imageAt(0).?, "initial Markdown local PNG pixels match the decoded image in the actual renderer");
        try uiCheck(!t.hasText("[Image: local image — document-inline.png]"), "successful standalone Markdown images replace internal fallback labels without changing source offsets");
        try self.openDocument(win, path, false, self.directory);
        try uiCheck(win.workspace(win.active) == file_ws and win.workspaces.items.len == workspaces + 1, "opening the same path reuses the existing file workspace");
        try self.documentScreenshot(t, "document-light.png");
        try documentControl(t, &document.panel, .toggle_source);
        try uiCheck(document.panel.mode == .source, "Source control switches actual document content to numbered UTF-8 source");
        try documentControl(t, &document.panel, .find);
        t.textOps(&.{.{ .insert = "needle" }});
        try uiCheck(document.panel.match_count == 1, "current source Find selects the exact UTF-8 range");
        try documentControl(t, &document.panel, .done);
        try self.runCommand(win, .{ .window = win.id, .text = "edit.copy", .kind = .command });
        try uiCheck(std.mem.eql(u8, t.clipboard.items, "needle"), "document copy uses the owned tester clipboard through the current command route");
        document.panel.show_find = false;
        try documentControl(t, &document.panel, .unlock);
        try finishDocument(document, true);
        t.frame();
        const editor = document.panel.editor orelse return error.DocumentUnlockFailed;
        editor.buffer.move(editor.buffer.text.len, false);
        const paste_before = try self.a.dupe(u8, editor.buffer.text);
        defer self.a.free(paste_before);
        const paste_tx = terminal_pane.pty.terminal.tx.items.len;
        try self.writeClipboard(" native menu paste");
        self.menuCommand("edit.paste");
        try uiCheck(std.mem.endsWith(u8, editor.buffer.text, " native menu paste") and terminal_pane.pty.terminal.tx.items.len == paste_tx, "native Edit Paste reaches the focused source editor without entering the PTY");
        _ = t.shortcut(.{ .key = 'z', .cmd = @import("builtin").os.tag == .macos, .ctrl = @import("builtin").os.tag != .macos });
        try uiCheck(std.mem.eql(u8, editor.buffer.text, paste_before), "native-menu source paste remains undoable through the editor shortcut");
        const before = editor.buffer.text.len;
        t.textOps(&.{.{ .set_marked = .{ .text = "ni", .sel_start = 2, .sel_len = 0 } }});
        try uiCheck(editor.buffer.text.len == before and editor.composition.range != null and t.ctx.focused_text.?.marked != null, "document IME preedit stays outside committed source and publishes its native caret");
        win.activate(terminal_ws);
        try uiCheck(win.active == file_ws.id, "pending source IME prevents switching its commit into a terminal workspace");
        try self.execute(.{ .window = win.id, .workspace = file_ws.id, .kind = .close_workspace });
        try uiCheck(win.workspace(file_ws.id) != null and !allowQuit(self), "uncommitted document IME blocks workspace close and application quit");
        t.textOps(&.{.{ .set_marked = .{ .text = "你好", .sel_start = 3, .sel_len = 3 } }});
        t.frame();
        try self.documentScreenshot(t, "document-ime.png");
        t.textOps(&.{.{ .insert = "你好 live preview\n" }});
        const until = os.millis() + 6000;
        while (document.draft_revision != editor.buffer.revision and os.millis() < until) {
            nano.runFor(0.01);
            try document.drain();
            t.frame();
        }
        if (document.draft_revision != editor.buffer.revision or std.mem.indexOf(u8, document.panel.prepared.?.markdown.?.text, "你好 live preview") == null) {
            std.debug.print("DOCUMENT DRAFT rev={d} accepted={any} pending={} timer={} job={} presented={} enabled={} composition={any} focus={d} body={d} length={d} notice={s}\n", .{ editor.buffer.revision, document.draft_revision, document.panel.draft_pending, document.draft_timer != null, document.draft_job != null, document.presented, document.presentation_enabled, editor.composition.range, t.ctx.focus, document.panel.ax_body, editor.buffer.text.len, document.panel.notice.text() });
            try self.documentScreenshot(t, "document-live-failure.png");
        }
        try uiCheck(document.draft_revision == editor.buffer.revision and std.mem.indexOf(u8, document.panel.prepared.?.markdown.?.text, "你好 live preview") != null, "committed edits update native Markdown through the latest-only background draft pipeline");
        document.panel.show_find = true;
        document.panel.query.set("live preview");
        t.frame();
        document.panel.find(false);
        t.frame();
        const selected_source = editor.buffer.selection();
        try uiCheck(document.panel.match_count == 1 and std.mem.eql(u8, editor.buffer.text[selected_source[0]..selected_source[1]], "live preview"), "Find in a continuously editable source selects the latest committed draft without locking");
        document.panel.show_find = false;
        const undo_count = editor.buffer.undo.items.len;
        const caret = editor.buffer.caret;
        try self.runCommand(win, .{ .window = win.id, .kind = .command, .text = "document.save" });
        try self.execute(.{ .window = win.id, .workspace = file_ws.id, .kind = .close_workspace });
        try uiCheck(win.workspace(file_ws.id) != null and document.panel.edit_busy, "active document save blocks closing while its immutable snapshot is being written");
        try finishDocument(document, true);
        try uiCheck(document.panel.editor == editor and !editor.dirty and editor.buffer.caret == caret and editor.buffer.undo.items.len == undo_count, "Save retains the source editor, caret and undo history");
        document.panel.live_split = true;
        document.panel.show_actions = false;
        t.resize(1400, 820);
        t.frame();
        try uiCheck(document.preview.body_rect.w > 0 and t.hasText("Preview fixture"), "wide document cards show editable source beside live native Markdown");
        try self.documentImagePixels(t, document.panel.imageAt(0).?, "live draft Markdown local PNG pixels match the actual renderer after source edits");
        try self.documentScreenshot(t, "document-live.png");
        const appearance = self.settings.@"window-theme";
        self.settings.@"window-theme" = "dark";
        t.frame();
        try self.documentScreenshot(t, "document-dark.png");
        self.settings.@"window-theme" = appearance;
        document.panel.live_split = false;
        t.resize(600, 480);
        t.frame();
        try self.documentScreenshot(t, "document-narrow.png");
        try uiCheck(document.panel.body_rect.w > 400, "narrow document mode keeps a complete usable content region");
        try editor.buffer.insert(std.heap.page_allocator, "unsaved");
        editor.update();
        try self.execute(.{ .window = win.id, .workspace = file_ws.id, .kind = .close_workspace });
        try uiCheck(win.workspace(file_ws.id) != null and !Window.closeRequest(win), "dirty document blocks workspace and window close without discarding the draft");
        document.panel.edit_request = .discard;
        try document.edit();
        try finishDocument(document, false);
        const stale_generation = document.panel.model.generation;
        try document.gainedFocus();
        try self.execute(.{ .window = win.id, .workspace = file_ws.id, .kind = .document_event, .document = document.id, .document_generation = stale_generation, .document_intent = .close });
        try uiCheck(win.workspace(file_ws.id) != null, "deferred document commands reject a stale generation");
        try self.removeWorkspace(win, file_ws);
        win.activate(terminal_ws);
        try self.openDocument(win, path, true, self.directory);
        const side = terminal_ws.documents.selected().?;
        side.panel.inline_edit = false;
        try finishDocument(side, false);
        t.resize(1200, 780);
        t.frame();
        const tx = terminal_pane.pty.terminal.tx.items.len;
        try self.execute(.{ .window = win.id, .workspace = terminal_ws.id, .pane = terminal_pane.pty.id, .kind = .input, .text = "DOCUMENT_MUST_NOT_TYPE" });
        try uiCheck(terminal_pane.pty.terminal.tx.items.len == tx, "side document focus rejects queued terminal input");
        try self.documentScreenshot(t, "document-side.png");
        side.panel.scroll_y = 27;
        side.panel.zoom = 1.2;
        try self.execute(.{ .window = win.id, .workspace = terminal_ws.id, .kind = .document_event, .document = side.id, .document_generation = side.panel.model.generation, .document_intent = .workspace });
        const moved = win.workspace(win.active).?;
        try uiCheck(moved.is_file and moved.documents.selected() == side and terminal_ws.documents.active == 0 and side.panel.scroll_y == 27 and side.panel.zoom == 1.2, "moving side preview to a file workspace retains identity, zoom and reading state");
        try self.removeWorkspace(win, moved);
        win.activate(terminal_ws);
        terminal_pane.pty.explicit_command = true;
        try self.terminalDocument(win, terminal_ws, terminal_pane, path);
        terminal_pane.pty.explicit_command = false;
        try uiCheck(terminal_ws.documents.documents.items.len == 0, "explicit-command terminal origins cannot open local document paths");
        self.a.free(self.problem_text);
        self.problem_text = "";
        const missing = try std.fmt.allocPrint(self.a, "{s}/missing-document.md", .{self.directory});
        defer self.a.free(missing);
        try self.openDocument(win, missing, false, self.directory);
        const missing_ws = win.workspace(win.active).?;
        const missing_doc = missing_ws.documents.selected().?;
        try finishDocument(missing_doc, false);
        t.frame();
        try uiCheck(missing_doc.panel.model.status == .missing and missing_ws.panes.items.len == 0 and t.hasText("File not found"), "missing file workspaces show an explicit native error without creating a shell");
        missing_ws.name = try self.a.dupe(u8, "Missing report");
        try self.saveDocuments();
        try self.removeWorkspace(win, missing_ws);
        const restore_count = win.workspaces.items.len;
        try self.restoreDocuments();
        const restored_ws = win.workspace(win.active).?;
        const restored_document = restored_ws.documents.selected().?;
        try finishDocument(restored_document, false);
        try uiCheck(restored_ws.is_file and restored_ws.panes.items.len == 0 and restored_document.panel.model.status == .missing and std.mem.eql(u8, restored_ws.title(), "Missing report"), "persisted missing file paths and tab names restore without allocating a PTY");
        try self.restoreDocuments();
        try uiCheck(win.workspaces.items.len == restore_count + 1, "restoring persisted paths reuses existing file workspace identity");
        try self.removeWorkspace(win, restored_ws);
        try self.saveDocuments();
        win.activate(terminal_ws);
        try self.verifyInlineDocuments(win, t, terminal_ws);
        try @import("document_width_check.zig").verify(self.a, self.directory);
    }
    fn inlineClick(t: *ui.Tester, p: *Documents.panel.Panel, needle: []const u8, offset: usize) !void {
        t.frame();
        const doc = p.document() orelse return error.DocumentNotPrepared;
        const at = (std.mem.indexOf(u8, doc.text, needle) orelse return error.DocumentTextMissing) + offset;
        for (p.visual_rows.items, 0..) |row, index| if (at >= row.start and at <= row.end) {
            const original = p.prepared.?;
            var borrowed = original;
            borrowed.markdown = p.rich.?.markdown;
            borrowed.rendered = p.rich.?.rendered;
            p.prepared = borrowed;
            const x = Documents.view.xAt(p, &t.ctx, index, at);
            var y = row.y + @min(@as(f32, 8), row.height / 2);
            if (p.prepared.?.markdown.?.lines[row.row].kind == .table) y = row.y + p.tables.pointAt(&t.ctx, &p.rich.?.markdown, row.row, at, 14 * p.zoom).y + 6;
            p.prepared = original;
            if (y < p.scroll_y or y >= p.scroll_y + p.body_rect.h) {
                p.scroll_y = @max(0, y - 40);
                t.frame();
            }
            t.click(p.body_rect.x + 24 + x - p.scroll_x + 0.1, p.body_rect.y + y - p.scroll_y);
            return;
        };
        return error.DocumentTextOutsideLayout;
    }
    fn settleInline(document: *Documents.Document, t: *ui.Tester) !void {
        const until = os.millis() + 6000;
        while (os.millis() < until) {
            nano.runFor(0.01);
            try document.drain();
            t.frame();
            if (document.panel.editor != null and document.draft_revision == document.panel.editor.?.buffer.revision and document.job == null) return;
        }
        return error.InlineDraftTimeout;
    }
    fn waitAutosave(document: *Documents.Document, t: *ui.Tester) !void {
        const until = os.millis() + 6000;
        while (os.millis() < until) {
            nano.runFor(0.01);
            try document.drain();
            t.frame();
            if (!document.hasUnsaved() and document.autosave_timer == null) return;
            if (document.edit_failed) return error.DocumentAutosaveFailed;
        }
        return error.DocumentAutosaveTimeout;
    }
    fn verifyInlineDocuments(self: *Runtime, win: *Window, t: *ui.Tester, terminal_ws: *Workspace) !void {
        const path = try std.fmt.allocPrint(self.a, "{s}/document-direct.md", .{self.directory});
        defer self.a.free(path);
        defer {
            const z = self.a.dupeSentinel(u8, path, 0) catch unreachable;
            defer self.a.free(z);
            _ = c.unlink(z);
        }
        const initial = "# Editable heading\n\nA **bold** paragraph with [label](document-current.md), 中文 é 👩‍💻.\n\n> Quoted text.\n\n- First list item\n- [x] Done task\n\n| Name | Value |\n|---|---|\n| one | two |\n\nInline $E=mc^2$ stays rendered.\n\n```zig\nconst answer = 42;\n```\n\n```mermaid\nflowchart LR\nA[Source] --> B[Preview]\n```\n";
        try os.atomicFile(self.a, path, initial);
        try self.openDocument(win, path, false, self.directory);
        const ws = win.workspace(win.active).?;
        const document = ws.documents.selected().?;
        try finishDocument(document, false);
        try finishDocument(document, true);
        t.resize(1200, 880);
        try settleInline(document, t);
        const editor = document.panel.editor.?;
        const p = &document.panel;
        try uiCheck(p.inline_edit and p.editor_rendered and t.hasText("Editable heading"), "Markdown opens directly in its rendered editable form without unlocking");
        var locked = false;
        var save_control = false;
        for (p.ax_controls[0..p.ax_count]) |control| {
            locked = locked or control.control == .unlock;
            save_control = save_control or control.control == .save;
        }
        try uiCheck(!locked and !save_control and !t.hasText("Discard"), "clean rendered documents show no lock or permanent editing button group");
        try self.documentScreenshot(t, "document-inline-clean.png");
        try inlineClick(t, p, "bold", 0);
        t.textOps(&.{ .{ .command = .select_right }, .{ .command = .select_right }, .{ .command = .select_right }, .{ .command = .select_right } });
        t.textOps(&.{.{ .insert = "strong" }});
        try uiCheck(std.mem.indexOf(u8, editor.buffer.text, "**strong**") != null and p.rich != null and std.mem.indexOf(u8, p.rich.?.rendered.text, "strong") != null, "clicking rendered bold text edits actual source while retaining its emphasis wrappers");
        try uiCheck(t.ctx.focused_text != null and t.ctx.focused_text.?.editable and std.mem.indexOf(u8, t.ctx.focused_text.?.text, "**strong**") == null, "rendered caret publishes editable native text without Markdown delimiters");
        try inlineClick(t, p, "strong", 6);
        t.textOps(&.{.{ .insert = " " }});
        try settleInline(document, t);
        t.textOps(&.{.{ .insert = "tail" }});
        try uiCheck(std.mem.indexOf(u8, editor.buffer.text, "**strong** tail paragraph") != null, "typing a space at bold end preserves valid Markdown and keeps later text outside the emphasis");
        try inlineClick(t, p, "label", 0);
        t.textOps(&.{ .{ .command = .select_right }, .{ .command = .select_right }, .{ .command = .select_right }, .{ .command = .select_right }, .{ .command = .select_right } });
        try self.writeClipboard("new label");
        self.menuCommand("edit.paste");
        try uiCheck(std.mem.indexOf(u8, editor.buffer.text, "[new label](document-current.md)") != null, "native Edit Paste changes a rendered link label while preserving its destination");
        try inlineClick(t, p, "Quoted text.", 6);
        t.textOps(&.{.{ .insert = " native" }});
        try uiCheck(std.mem.indexOf(u8, editor.buffer.text, "> Quoted native text.") != null, "rendered quote editing preserves its source quote prefix");
        try inlineClick(t, p, "one\ttwo", 3);
        t.textOps(&.{.{ .insert = " edited" }});
        if (std.mem.indexOf(u8, editor.buffer.text, "| one edited | two |") == null) {
            std.debug.print("INLINE TABLE selection={d}:{d} notice={s}\nSOURCE\n{s}\n", .{ p.selection.anchor, p.selection.caret, p.notice.text(), editor.buffer.text });
            try self.documentScreenshot(t, "document-inline-failure.png");
        }
        try uiCheck(std.mem.indexOf(u8, editor.buffer.text, "| one edited | two |") != null, "rendered table cells edit in place without rewriting table separators");
        try inlineClick(t, p, "Editable heading", "Editable heading".len);
        const before_ime = try self.a.dupe(u8, editor.buffer.text);
        defer self.a.free(before_ime);
        t.textOps(&.{.{ .set_marked = .{ .text = "中文", .sel_start = 3, .sel_len = 3 } }});
        try uiCheck(std.mem.eql(u8, before_ime, editor.buffer.text) and editor.composition.range != null and t.ctx.focused_text.?.marked != null and t.ctx.focused_text.?.caret_rect.h > 20, "rendered heading IME preedit paints at its actual rich caret without changing source");
        try self.documentScreenshot(t, "document-inline-ime.png");
        win.activate(terminal_ws);
        try uiCheck(win.active == ws.id, "rendered preedit cannot commit into a different workspace");
        t.textOps(&.{.{ .insert = " 中文" }});
        try uiCheck(std.mem.startsWith(u8, editor.buffer.text, "# Editable heading 中文\n"), "rendered IME commit inserts once while retaining heading syntax");
        _ = t.shortcut(.{ .key = 'z', .cmd = @import("builtin").os.tag == .macos, .ctrl = @import("builtin").os.tag != .macos });
        try uiCheck(std.mem.eql(u8, before_ime, editor.buffer.text), "rendered native Undo restores the exact prior Markdown source");
        _ = t.shortcut(.{ .key = 'z', .cmd = @import("builtin").os.tag == .macos, .ctrl = @import("builtin").os.tag != .macos, .shift = true });
        try uiCheck(std.mem.startsWith(u8, editor.buffer.text, "# Editable heading 中文\n"), "rendered native Redo retains source and displayed caret mapping");
        for (0..12) |_| t.textOps(&.{.{ .insert = "x" }});
        t.textOps(&.{.{ .insert = " " }});
        try settleInline(document, t);
        t.textOps(&.{.{ .insert = "tail" }});
        try settleInline(document, t);
        try uiCheck(std.mem.indexOf(u8, editor.buffer.text, "xxxxxxxxxxxx tail\n") != null, "pausing after a trailing space keeps the next word at the original source caret");
        try uiCheck(std.mem.indexOf(u8, p.document().?.text, "xxxxxxxxxxxx") != null and document.draft_revision == editor.buffer.revision, "rapid rendered typing stays visible before latest-only background reconciliation");
        try documentControl(t, p, .find);
        t.textOps(&.{.{ .insert = "Quoted native" }});
        try uiCheck(p.match_count == 1, "Find searches the current rendered edit projection");
        t.textOps(&.{.{ .command = .cancel }});
        self.menuCommand("edit.copy");
        try uiCheck(!p.show_find and t.ctx.focused_text != null and t.ctx.focused_text.?.editable and std.mem.eql(u8, t.clipboard.items, "Quoted native"), "native Cancel returns Find to the rendered editor and native Copy retains its selection");
        try inlineClick(t, p, "xxxxxxxxxxxx tail", 17);
        try self.documentScreenshot(t, "document-inline-edit.png");
        const prior_theme = self.settings.@"window-theme";
        self.settings.@"window-theme" = "dark";
        t.frame();
        try self.documentScreenshot(t, "document-inline-dark.png");
        self.settings.@"window-theme" = prior_theme;
        t.resize(600, 560);
        t.frame();
        try uiCheck(p.inline_edit and p.editor_rendered and t.ctx.focused_text != null and t.ctx.focused_text.?.editable, "narrow cards retain the actual rendered editor and native caret");
        try self.documentScreenshot(t, "document-inline-narrow.png");
        t.resize(1200, 880);
        t.frame();
        try waitAutosave(document, t);
        const disk_before = try os.readFile(self.a, path, 65536);
        defer self.a.free(disk_before);
        try uiCheck(std.mem.eql(u8, disk_before, editor.buffer.text) and !editor.dirty, "rendered changes automatically reach the original file without a Save button");
        try inlineClick(t, p, "Editable heading", "Editable heading".len);
        t.textOps(&.{.{ .insert = " auto" }});
        nano.runFor(0.20);
        t.textOps(&.{.{ .insert = "-debounced" }});
        nano.runFor(0.35);
        const delayed = try os.readFile(self.a, path, 65536);
        defer self.a.free(delayed);
        try uiCheck(editor.dirty and std.mem.eql(u8, delayed, disk_before), "automatic saving restarts its idle delay after each committed edit");
        try waitAutosave(document, t);
        save_control = false;
        for (p.ax_controls[0..p.ax_count]) |control| save_control = save_control or control.control == .save;
        try uiCheck(!save_control and !editor.dirty and t.hasText("Saved"), "auto-save returns to quiet Saved status and never adds a Save control");
        _ = t.shortcut(.{ .key = 'z', .cmd = @import("builtin").os.tag == .macos, .ctrl = @import("builtin").os.tag != .macos });
        try waitAutosave(document, t);
        const undone = try os.readFile(self.a, path, 65536);
        defer self.a.free(undone);
        try uiCheck(std.mem.eql(u8, undone, editor.buffer.text), "Undo after an automatic save is itself automatically saved");
        try inlineClick(t, p, "Editable heading", "Editable heading".len);
        t.textOps(&.{.{ .insert = " committed" }});
        t.textOps(&.{.{ .set_marked = .{ .text = "预编辑", .sel_start = 3, .sel_len = 3 } }});
        nano.runFor(0.65);
        const preedit_disk = try os.readFile(self.a, path, 65536);
        defer self.a.free(preedit_disk);
        try uiCheck(document.job == null and document.autosave_timer == null and std.mem.eql(u8, preedit_disk, undone), "active IME preedit suspends the pending automatic write without persisting candidate text");
        t.textOps(&.{.{ .insert = " 中文" }});
        try waitAutosave(document, t);
        const committed_disk = try os.readFile(self.a, path, 65536);
        defer self.a.free(committed_disk);
        try uiCheck(std.mem.eql(u8, committed_disk, editor.buffer.text) and std.mem.indexOf(u8, committed_disk, "预编辑") == null, "IME commit resumes automatic saving with committed source only");
        try documentControl(t, p, .toggle_source);
        t.textOps(&.{.{ .insert = " source" }});
        try waitAutosave(document, t);
        const source_saved = try os.readFile(self.a, path, 65536);
        defer self.a.free(source_saved);
        try uiCheck(!p.editor_rendered and std.mem.eql(u8, source_saved, editor.buffer.text), "Markdown Source mode shares automatic saving without a separate Save button");
        try documentControl(t, p, .toggle_source);
        try settleInline(document, t);
        try inlineClick(t, p, "Editable heading", "Editable heading".len);
        t.textOps(&.{.{ .insert = " hidden" }});
        win.activate(terminal_ws);
        try waitAutosave(document, t);
        const blurred = try os.readFile(self.a, path, 65536);
        defer self.a.free(blurred);
        try uiCheck(win.active == terminal_ws.id and std.mem.eql(u8, blurred, editor.buffer.text), "a pending automatic save finishes after its workspace is hidden");
        win.activate(ws);
        t.frame();
        try inlineClick(t, p, "Editable heading", "Editable heading".len);
        t.textOps(&.{.{ .insert = " first" }});
        try self.runCommand(win, .{ .window = win.id, .kind = .command, .text = "document.save" });
        t.textOps(&.{.{ .insert = " later" }});
        try finishDocument(document, true);
        try uiCheck(editor.dirty and std.mem.indexOf(u8, editor.buffer.text, "later") != null and std.mem.indexOf(u8, editor.baseline, "later") == null, "save completion advances its submitted baseline while newer rendered input stays pending");
        try waitAutosave(document, t);
        const saved = try os.readFile(self.a, path, 65536);
        defer self.a.free(saved);
        try uiCheck(std.mem.eql(u8, saved, editor.buffer.text) and !editor.dirty, "input committed during a write automatically schedules the next snapshot");
        try settleInline(document, t);
        try inlineClick(t, p, "Quoted", 0);
        t.textOps(&.{.{ .insert = "changed " }});
        const external = "# External writer\n";
        try os.atomicFile(self.a, path, external);
        const conflict_until = os.millis() + 6000;
        while (!document.edit_failed and os.millis() < conflict_until) {
            nano.runFor(0.01);
            try document.drain();
            t.frame();
        }
        const conflict = try os.readFile(self.a, path, 65536);
        defer self.a.free(conflict);
        try uiCheck(editor.dirty and document.edit_failed and p.external_changed and std.mem.eql(u8, conflict, external), "automatic saving refuses external changes and retains the in-memory draft");
        try inlineClick(t, p, "Quoted", 0);
        t.textOps(&.{.{ .insert = "kept " }});
        nano.runFor(0.65);
        try uiCheck(document.job == null and document.autosave_timer == null and t.hasText("Auto-save paused"), "external conflicts pause automatic writes even after further typing");
        try self.removeWorkspace(win, ws);
        try uiCheck(win.workspace(ws.id) == ws and editor.dirty, "Cancel at a conflicted close retains the draft");
        win.document_close_choice = 2;
        const old_id = ws.id;
        try self.removeWorkspace(win, ws);
        try uiCheck(win.workspace(old_id) == null, "explicit Discard in conflict recovery removes the dirty document");
        try self.openDocument(win, path, false, self.directory);
        const close_ws = win.workspace(win.active).?;
        const close_doc = close_ws.documents.selected().?;
        try finishDocument(close_doc, false);
        try finishDocument(close_doc, true);
        try settleInline(close_doc, t);
        try inlineClick(t, &close_doc.panel, "External writer", "External writer".len);
        t.textOps(&.{.{ .insert = " saved on close" }});
        const close_id = close_ws.id;
        try self.removeWorkspace(win, close_ws);
        try uiCheck(win.workspace(close_id) != null and close_doc.job != null, "closing before the auto-save delay flushes immediately and waits without a save prompt");
        t.textOps(&.{.{ .insert = " remains" }});
        const until = os.millis() + 6000;
        while (win.workspace(close_id) != null and os.millis() < until) nano.runFor(0.01);
        const closed = try os.readFile(self.a, path, 65536);
        defer self.a.free(closed);
        try uiCheck(win.workspace(close_id) == null and std.mem.indexOf(u8, closed, "saved on close remains") != null, "automatic close rechecks newer input and saves the last revision before releasing its workspace");
        win.activate(terminal_ws);
    }
    fn verifySettingsDraft(self: *Runtime, win: *Window, t: *ui.Tester) !void {
        const original_size = self.settings.@"font-size";
        const original_history = self.settings.@"scrollback-limit";
        const original_epoch = win.preferences.draft.id;
        const workspace = win.workspace(win.active).?;
        const owner = workspace.pane(workspace.focus).?;
        try self.execute(.{ .window = win.id, .settings_epoch = original_epoch, .kind = .set_setting, .text = "font-size=17" });
        try self.execute(.{ .window = win.id, .settings_epoch = original_epoch, .kind = .set_setting, .text = "scrollback-limit=0" });
        const saved = try os.readFile(self.a, self.config_path, 1024 * 1024);
        defer self.a.free(saved);
        try uiCheck(!win.preferences.draft.dirty() and self.settings.@"font-size" == 17 and self.configuration.?.settings.@"font-size" == 17 and std.mem.eql(u8, saved, self.configuration.?.source), "Settings edits automatically persist and apply without a Save action");
        try uiCheck(win.preferences.draft.id == original_epoch and self.configuration.?.settings.@"scrollback-limit" == 0 and owner.pty.terminal.terminal.screens.active.pages.limits.bytes.explicit == 0, "successive queued edits retain their Settings session and apply committed history limits");
        t.frame();
        try uiCheck(!t.hasText("Save and apply") and !t.hasText("Cancel"), "modified Settings has no Cancel or Save and apply header controls");
        var invalid: ?anyerror = null;
        self.execute(.{ .window = win.id, .kind = .set_setting, .text = "font-size=invalid" }) catch |err| {
            invalid = err;
        };
        const rejected = try os.readFile(self.a, self.config_path, 1024 * 1024);
        defer self.a.free(rejected);
        try uiCheck(invalid != null and self.settings.@"font-size" == 17 and std.mem.eql(u8, saved, rejected) and !win.preferences.draft.dirty(), "invalid automatic settings edits preserve the last saved configuration and live values");
        const external = try std.fmt.allocPrint(self.a, "{s}# private external edit\n", .{saved});
        defer self.a.free(external);
        try os.atomicFile(self.a, self.config_path, external);
        try std.testing.expectError(error.ConfigurationChangedExternallyReloadFirst, self.execute(.{ .window = win.id, .kind = .set_setting, .text = "font-size=19" }));
        const preserved = try os.readFile(self.a, self.config_path, 1024 * 1024);
        defer self.a.free(preserved);
        try uiCheck(std.mem.eql(u8, preserved, external) and self.settings.@"font-size" == 17, "automatic settings writes refuse an external edit instead of overwriting it");
        try os.atomicFile(self.a, self.config_path, saved);
        {
            // A valid 250-byte filename can be read, but the atomic writer's
            // sibling suffix exceeds NAME_MAX. Exercise failure after parsing.
            const long_name: [250]u8 = @splat('c');
            const long_path = try std.fmt.allocPrintSentinel(self.a, "{s}/{s}", .{ self.directory, long_name }, 0);
            defer self.a.free(long_path);
            const original_path = self.config_path;
            const original_z = try self.a.dupeSentinel(u8, original_path, 0);
            defer self.a.free(original_z);
            if (c.rename(original_z.ptr, long_path.ptr) != 0) return error.SettingsWriteFixture;
            defer _ = c.rename(long_path.ptr, original_z.ptr);
            self.config_path = long_path;
            defer self.config_path = original_path;
            try std.testing.expectError(error.CreateFile, self.execute(.{ .window = win.id, .kind = .set_setting, .text = "font-size=21" }));
            const retained = try os.readFile(self.a, long_path, 1024 * 1024);
            defer self.a.free(retained);
            try uiCheck(self.settings.@"font-size" == 17 and self.configuration.?.settings.@"font-size" == 17 and !win.preferences.draft.dirty() and std.mem.eql(u8, retained, saved), "failed automatic persistence never publishes candidate settings or changes the saved file");
            self.settings.@"font-size" = 19;
            self.presentation.font_size = 19;
            try self.execute(.{ .window = win.id, .kind = .set_setting, .text = "font-size=17" });
            try uiCheck(self.settings.@"font-size" == 17 and self.presentation.font_size == 0, "choosing the saved font size clears temporary zoom without rewriting unchanged configuration");
        }
        try self.newWindow();
        const other = self.windows.items[self.windows.items.len - 1];
        try self.runCommand(other, .{ .window = other.id, .kind = .command, .text = "settings.open" });
        try uiCheck(other.preferences.draft.config == null and !other.settings_open and win.preferences.draft.config != null, "another terminal focuses the existing Settings session without allocating a second one");
        if (other.native) |native| native.close();
        try uiCheck(other.closed and self.settings.@"font-size" == 17, "unrelated window teardown preserves automatically applied settings");
        try self.runCommand(win, .{ .window = win.id, .kind = .command, .text = "settings.cancel" });
        try uiCheck(!win.settings_open and !win.settings_discard and self.settings.@"font-size" == 17 and self.configuration.?.settings.@"font-size" == 17, "closing modified Settings retains saved values without a discard confirmation");
        try self.runCommand(win, .{ .window = win.id, .kind = .command, .text = "settings.open" });
        const reopened_epoch = win.preferences.draft.id;
        try self.execute(.{ .window = win.id, .settings_epoch = original_epoch, .kind = .set_setting, .text = "font-size=31" });
        try uiCheck(reopened_epoch != original_epoch and self.settings.@"font-size" == 17 and !win.preferences.draft.dirty(), "actions from a closed Settings session cannot overwrite a reopened one");
        try self.execute(.{ .window = win.id, .kind = .set_setting, .text = t.ctx.print("font-size={d}", .{original_size}) });
        try self.execute(.{ .window = win.id, .kind = .set_setting, .text = t.ctx.print("scrollback-limit={d}", .{original_history}) });
        win.preferences.page = .terminal;
        t.frame();
        try t.clickText(t.ctx.print("{d} pt", .{original_size}));
        t.key(.down);
        t.key(.enter);
        nano.runFor(0.02);
        t.frame();
        try uiCheck(!win.preferences.draft.dirty() and self.settings.@"font-size" != original_size and self.settings.@"font-size" == self.configuration.?.settings.@"font-size" and !t.hasText("Save and apply"), "keyboard size choices save automatically and leave the Settings header clear");
        try self.execute(.{ .window = win.id, .kind = .set_setting, .text = t.ctx.print("font-size={d}", .{original_size}) });
        win.preferences.page = .general;
        t.frame();
    }
    fn finishReview(self: *Runtime, owner: *Owner) !void {
        const until = os.millis() + 20000;
        while (owner.changes.busy()) {
            if (os.millis() > until) return error.ReviewFixtureDeadline;
            self.processJobs();
            nano.runFor(0.01);
        }
        if (owner.changes.message().len > 0) {
            os.diagnostic(owner.changes.message());
            return error.ReviewFixtureFailed;
        }
    }
    fn verifySvnPanel(self: *Runtime, win: *Window, ws: *Workspace, owner: *Owner, tester: *ui.Tester) !void {
        const old_layout = self.settings.@"diff-layout";
        defer self.settings.@"diff-layout" = old_layout;
        const epoch = owner.changes.epoch +% 1;
        owner.changes.deinit(self.a);
        owner.changes = .{ .backend = .svn, .initialized = true, .epoch = epoch, .directory = try self.a.dupe(u8, self.directory) };
        var svn = &owner.changes.svn_state;
        svn.data = try Vcs.svn.Data.status(self.a, "<status><target><entry path='module.sv'><wc-status item='modified' props='modified'/></entry><entry path='gone.sv'><wc-status item='missing' props='none'/></entry></target></status>");
        svn.root = try self.a.dupe(u8, self.directory);
        svn.selected = try self.a.dupe(u8, "module.sv");
        svn.patch = try self.a.dupe(u8, "Index: module.sv\n===================================================================\n--- module.sv\t(revision 1)\n+++ module.sv\t(working copy)\n@@ -1 +1 @@\n-SVN_BEFORE\n+SVN_AFTER\n");
        svn.patch_version = 1;
        const saved_zoom = win.zoom;
        win.zoom = owner.pty.id;
        win.changes_open = false;
        tester.frame();
        tester.frame();
        try uiCheck(tester.hasText("SVN") and tester.hasText(" · 2 files") and !tester.containsText("Git "), "terminal headers show SVN working-copy changes without inventing a Git branch or line counts");
        win.zoom = saved_zoom;
        win.changes_open = true;
        self.settings.@"diff-layout" = "unified";
        tester.frame();
        try uiCheck(tester.hasText("SVN Working Copy Changes") and !tester.hasText("Uncommitted") and !tester.hasText("Branch") and !tester.hasText("Agent turn") and !tester.hasText("Staged") and !tester.hasText("Unstaged"), "SVN panel shows local changes and hides Git-only controls");
        try uiCheck(tester.hasText("SVN_BEFORE") and tester.hasText("SVN_AFTER") and tester.containsText("properties") and !tester.containsText("+0 −0"), "SVN unified diff shares the renderer and omits unmeasured Git counts");
        if (os.env("LETTY_UI_SCREENSHOT_DIR")) |directory| {
            const path = try std.fmt.allocPrint(self.a, "{s}/svn-unified.png", .{directory});
            defer self.a.free(path);
            try tester.screenshot(path);
        }
        self.settings.@"diff-layout" = "split";
        tester.frame();
        try uiCheck(tester.hasText("SVN_BEFORE") and tester.hasText("SVN_AFTER"), "SVN split diff displays paired BASE and working-copy text");
        if (os.env("LETTY_UI_SCREENSHOT_DIR")) |directory| {
            const path = try std.fmt.allocPrint(self.a, "{s}/svn-split.png", .{directory});
            defer self.a.free(path);
            try tester.screenshot(path);
        }
        try self.execute(.{ .window = win.id, .workspace = ws.id, .pane = owner.pty.id, .kind = .git_select, .text = "gone.sv", .review_epoch = epoch -% 1 });
        try uiCheck(std.mem.eql(u8, owner.changes.selected(), "module.sv") and !owner.changes.canOpen("gone.sv"), "SVN stale selections are ignored and missing paths cannot be opened");
        if (owner.changes.setBase(.branch)) |_| return error.AcceptedSvnBranch else |err| if (err != error.UnsupportedVcsBase) return err;
        try uiCheck(owner.changes.base() == .head and !owner.changes.git_state.capture, "SVN rejects Git comparison operations without creating snapshots");
        if (os.env("LETTY_SVN_UI_CWD")) |directory| {
            const osc = try std.fmt.allocPrint(self.a, "\x1b]7;file://localhost{s}\x1b\\", .{directory});
            defer self.a.free(osc);
            try owner.pty.terminal.feed(osc);
            try self.execute(.{ .window = win.id, .workspace = ws.id, .pane = owner.pty.id, .kind = .git_refresh });
            try self.finishReview(owner);
            try uiCheck(owner.changes.backend == .svn and owner.changes.files().len > 0 and std.mem.eql(u8, owner.changes.root(), directory), "desktop routes SVN discovery and status jobs through the shared Changes owner");
            tester.frame();
            tester.frame();
            try tester.clickText("added.sv");
            nano.runFor(0.02);
            try self.finishReview(owner);
            try uiCheck(std.mem.eql(u8, owner.changes.selected(), "added.sv") and std.mem.indexOf(u8, owner.changes.patch(), "+added") != null, "clicking a real SVN change previews its local diff through deferred actions");
            try self.execute(.{ .window = win.id, .workspace = ws.id, .pane = owner.pty.id, .kind = .git_select, .text = "peg@42.sv", .review_epoch = owner.changes.epoch });
            try self.finishReview(owner);
            try uiCheck(std.mem.indexOf(u8, owner.changes.patch(), "+new") != null and !owner.changes.supportsBase(.turn), "desktop previews literal SVN paths using local BASE without Git operations");
            self.settings.@"diff-layout" = "unified";
            tester.frame();
            try uiCheck(tester.hasText("new") and !tester.hasText("Branch"), "real SVN unified diff renders in the native Changes panel");
            self.settings.@"diff-layout" = "split";
            tester.frame();
            try uiCheck(tester.hasText("new") and tester.hasText("old"), "real SVN split diff renders both versions in the native Changes panel");
            const no_vcs = try std.fmt.allocPrint(self.a, "\x1b]7;file://localhost{s}\x1b\\", .{self.directory});
            defer self.a.free(no_vcs);
            try owner.pty.terminal.feed(no_vcs);
            try self.execute(.{ .window = win.id, .workspace = ws.id, .pane = owner.pty.id, .kind = .git_refresh });
            try self.finishReviewNoRepository(owner);
            tester.frame();
            try uiCheck(owner.changes.backend == .none and owner.changes.patch().len == 0 and tester.hasText("No Git or SVN working copy"), "leaving an SVN working copy clears the panel and cached diff");
        }
    }
    fn finishReviewNoRepository(self: *Runtime, owner: *Owner) !void {
        // .none intentionally has a user-visible explanatory message.
        if (owner.changes.backend != .none) return self.finishReview(owner);
        self.processJobs();
    }
    fn verifyDocumentCapacity(self: *Runtime, win: *Window, terminal_ws: *Workspace) !void {
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(self.a);
        defer {
            for (ids.items) |id| if (win.workspace(id)) |ws| self.removeWorkspace(win, ws) catch {};
            win.activate(terminal_ws);
        }
        for (0..36) |i| {
            const path = try std.fmt.allocPrint(self.a, "{s}/capacity-{d}.md", .{ self.directory, i });
            defer self.a.free(path);
            try os.atomicFile(self.a, path, "# Private capacity fixture\n");
            try self.fileWorkspace(win, path, null);
            const ws = win.workspace(win.active).?;
            try ids.append(self.a, ws.id);
            const document = ws.documents.selected().?;
            try finishDocument(document, false);
            try finishDocument(document, true);
            if (document.panel.model.status != .ready or document.edit_failed or ws.panes.items.len != 0) return error.DocumentCapacityFailed;
        }
        var limit: std.c.rlimit = undefined;
        const known = std.c.getrlimit(.NOFILE, &limit) == 0;
        try uiCheck(ids.items.len == 36 and (!known or limit.max <= 256 or limit.cur > 256), "36 independent Markdown workspaces retain readable documents without exhausting a GUI launch's 256-descriptor soft limit or allocating PTYs");
    }
    fn verifyPromptColors(self: *Runtime, owner: *Owner, t: *ui.Tester) !void {
        const previous = self.settings.@"minimum-contrast";
        defer self.settings.@"minimum-contrast" = previous;
        self.settings.@"minimum-contrast" = 3;
        try owner.pty.terminal.feed("\x1b[2J\x1b[3J\x1b[H\x1b[38;2;249;226;175m\x1b[48;2;166;227;161mAB\x1b[0m");
        t.frame();
        var arrow: ui.Rect = .{};
        var text_count: usize = 0;
        for (t.ctx.nodes.items) |node| if (node.content == .glyph_run) {
            const run = node.content.glyph_run;
            if (std.mem.eql(u8, run.str, "")) {
                try uiCheck(std.meta.eql(run.color, ui.Color.hex(0xf9e2af)), "Starship Powerline separators retain their exact ANSI color under minimum contrast");
                arrow = node.rect;
            } else if (std.mem.eql(u8, run.str, "A") or std.mem.eql(u8, run.str, "B")) {
                if (!std.meta.eql(run.color, ui.Color.hex(0xf9e2af))) text_count += 1;
            }
        };
        try uiCheck(arrow.w > 0 and text_count == 2, "mixed same-style text and Powerline cells split contrast policy without recoloring adjacent letters");
        const pixels = try t.render(self.a);
        defer pixels.deinit(self.a);
        var original_pixels: usize = 0;
        const left: usize = @intFromFloat(@max(0, arrow.x * t.scale));
        const top: usize = @intFromFloat(@max(0, arrow.y * t.scale));
        const right: usize = @min(pixels.width, @as(usize, @intFromFloat(@max(0, (arrow.x + arrow.w) * t.scale))));
        const bottom: usize = @min(pixels.height, @as(usize, @intFromFloat(@max(0, (arrow.y + arrow.h) * t.scale))));
        for (top..bottom) |y| for (left..right) |x| {
            const p = pixels.bytes[(y * pixels.width + x) * 4 ..][0..4];
            if (@abs(@as(i32, p[2]) - 249) <= 2 and @abs(@as(i32, p[1]) - 226) <= 2 and @abs(@as(i32, p[0]) - 175) <= 2) original_pixels += 1;
        };
        try uiCheck(original_pixels > 4, "the actual renderer paints the original pastel Powerline color instead of a contrast-darkened chevron");
        try owner.pty.terminal.feed("\x1b[2J\x1b[3J\x1b[H");
    }
    fn menuBounds(t: *ui.Tester) !ui.Rect {
        for (t.ctx.nodes.items) |node| if (node.style.layer == 40 and node.style.scroll) return node.rect;
        return error.MenuMissing;
    }
    fn verifyMenus(self: *Runtime, win: *Window, terminal_ws: *Workspace, t: *ui.Tester) !void {
        const Menu = @import("menu.zig");
        const original_size = t.size;
        defer t.resize(original_size.w, original_size.h);
        win.activate(terminal_ws);
        for ([_]ui.Point{ .{ .x = -10, .y = -10 }, .{ .x = 5000, .y = -10 }, .{ .x = -10, .y = 5000 }, .{ .x = 5000, .y = 5000 } }) |point| {
            t.resize(480, 240);
            win.session_menu = terminal_ws.id;
            win.session_menu_point = point;
            win.session_menu_state = .{};
            win.project_menu_open = false;
            t.frame();
            t.frame();
            const bounds = try menuBounds(t);
            try uiCheck(bounds.x >= 8 and bounds.y >= 8 and bounds.x + bounds.w <= 472.1 and bounds.y + bounds.h <= 232.1 and bounds.h < 210, "context menus fit a narrow short viewport at each corner without a 500-point empty column");
            const rename = t.findText("Rename") orelse return error.MenuRenameMissing;
            const project = t.findText("Move to project") orelse return error.MenuProjectMissing;
            try uiCheck(@abs(rename.x - (bounds.x + 16)) < 0.1 and @abs(project.x - rename.x) < 0.1 and @abs(project.y - rename.y - Menu.row_height) < 0.1, "menu labels share a left edge and a compact 24-point row rhythm");
            t.key(.escape);
        }
        t.resize(1000, 680);
        win.session_menu = terminal_ws.id;
        win.session_menu_point = .{ .x = 30, .y = 80 };
        win.session_menu_state = .{};
        t.moveTo(5, 5);
        t.frame();
        t.key(.down);
        t.key(.down);
        t.key(.right);
        try uiCheck(win.project_menu_open and win.session_menu == terminal_ws.id, "menu keyboard navigation opens the project submenu without dispatching terminal input");
        t.key(.left);
        try uiCheck(!win.project_menu_open and win.session_menu != 0, "Left returns keyboard navigation from the project submenu");
        t.click(5, 5);
        try uiCheck(win.session_menu == 0 and win.active == terminal_ws.id, "outside dismissal closes the menu without activating an underlying workspace");
        const LongMenu = struct {
            state: Menu.State = .{},
            chosen: ?usize = null,
            fn view(self_: *@This(), ctx: *ui.Context) void {
                var items: [45]Menu.Item = undefined;
                for (&items, 0..) |*item, i| item.* = .{ .label = ctx.print("Private project {d}", .{i}) };
                items[1] = .{ .separator = true };
                items[2].disabled = true;
                const bounds = Menu.place(ctx.size, .{ .x = 5000, .y = 5000 }, 192, Menu.contentHeight(&items));
                if (Menu.draw(&self_.state, ctx, bounds, &items, true)) |chosen| self_.chosen = chosen;
            }
        };
        var long_state: LongMenu = .{};
        var long: ui.Tester = undefined;
        try long.init(self.a, .init(&long_state, LongMenu.view), .{ .width = 480, .height = 240 });
        defer long.deinit();
        long.key(.down);
        long.key(.down);
        try uiCheck(long_state.state.selected == 3, "menu navigation skips disabled choices and group separators");
        long.key(.end);
        long.frame();
        const last = long.findText("Private project 44") orelse return error.LastMenuItemMissing;
        const long_bounds = try menuBounds(&long);
        try uiCheck(last.y >= long_bounds.y and last.y + last.h <= long_bounds.y + long_bounds.h, "long project menus scroll the keyboard selection into the actual visible viewport");
        long.key(.enter);
        try uiCheck(long_state.chosen == 44, "long menus activate their scrolled final item through Enter");
        const path = try std.fmt.allocPrint(self.a, "{s}/menu-private.md", .{self.directory});
        defer self.a.free(path);
        try os.atomicFile(self.a, path, "# Private menu fixture\n");
        defer {
            const z = self.a.dupeSentinel(u8, path, 0) catch unreachable;
            defer self.a.free(z);
            _ = c.unlink(z);
        }
        const pane_count = terminal_ws.panes.items.len;
        try self.fileWorkspace(win, path, null);
        const file_ws = win.workspace(win.active).?;
        const file_id = file_ws.id;
        const document = file_ws.documents.selected().?;
        try finishDocument(document, false);
        t.resize(480, 240);
        win.sidebar = true;
        win.sidebar_forced = false;
        t.frame();
        const mac = @import("builtin").os.tag == .macos;
        _ = t.shortcut(.{ .key = 'b', .cmd = mac, .ctrl = !mac, .shift = !mac });
        nano.runFor(0.03);
        t.frame();
        t.frame();
        const narrow_label = t.findText(file_ws.title());
        try uiCheck(win.sidebar and win.sidebar_forced and narrow_label != null and narrow_label.?.x < 200 and narrow_label.?.w > 0, "one sidebar shortcut reveals an automatically hidden narrow sidebar without allocating a terminal");
        t.resize(1000, 680);
        win.session_menu = file_ws.id;
        win.session_menu_point = .{ .x = 50, .y = 150 };
        win.session_menu_state = .{};
        t.frame();
        t.frame();
        try uiCheck(t.hasText("Rename Workspace") and t.hasText("Copy Path") and t.hasText("Close Workspace") and !t.hasText("Copy session ID") and !t.hasText("Mark as read") and !t.hasText("Close Session") and file_ws.panes.items.len == 0, "file menus expose document and workspace actions without any session or PTY assumptions");
        try t.clickText("Copy Path");
        nano.runFor(0.03);
        try uiCheck(self.private_clipboard != null and std.mem.eql(u8, self.private_clipboard.?, path), "file context Copy Path uses a stable document target and the private clipboard");
        try self.execute(.{ .window = win.id, .workspace = file_ws.id, .document = document.id, .document_generation = document.panel.model.generation + 1, .kind = .document_meta, .text = "path" });
        try uiCheck(std.mem.eql(u8, self.private_clipboard.?, path), "stale document metadata actions leave clipboard ownership unchanged");
        win.palette_open = true;
        win.palette_query.set("Rename");
        win.field_focus = true;
        t.frame();
        try uiCheck(t.hasText("Rename Workspace") and !t.hasText("Rename Session"), "file palette actions use workspace semantics rather than terminal session names");
        win.palette_query.set("no-such-private-item");
        t.frame();
        var empty_height: f32 = 0;
        for (t.ctx.nodes.items) |node| if (node.style.layer == 40 and node.style.radius == 14) {
            empty_height = node.rect.h;
        };
        try uiCheck(t.hasText("No matches") and empty_height >= 90 and empty_height <= 104, "empty command palettes explain no matches and shrink to their content instead of leaving 460 points blank");
        t.click(5, 5);
        try uiCheck(!win.palette_open and win.active == file_id, "palette outside dismissal preserves the underlying selected workspace");
        win.session_menu = file_ws.id;
        win.session_menu_state = .{};
        t.frame();
        t.frame();
        try t.clickText("Close Workspace");
        nano.runFor(0.03);
        try uiCheck(win.workspace(file_id) == null and terminal_ws.panes.items.len == pane_count, "file menu Close Workspace releases only its document workspace and preserves terminal PTYs");
        win.activate(terminal_ws);
    }
    fn verifySidebar(self: *Runtime, win: *Window, original: *Workspace, tester: *ui.Tester) !void {
        try self.newWorkspace(win, original.directory);
        const another = win.workspace(win.active).?;
        const another_id = another.id;
        const pane = another.panes.items[0];
        const pid = pane.pty.pid;
        tester.frame();
        tester.frame();
        const from = another.sidebar_rect;
        const to = original.sidebar_rect;
        tester.drag(from.x + 15, from.y + 17, to.x + to.w / 2, to.y + 3);
        nano.runFor(0.05);
        try uiCheck(win.workspaces.items[0].id == another_id and another.panes.items[0].pty.pid == pid, "sidebar grip dragging reorders local sessions while preserving PTY ownership");
        const directory = try std.fmt.allocPrint(self.a, "{s}/another-project", .{self.directory});
        defer self.a.free(directory);
        try os.mkdirs(self.a, directory);
        try self.newWorkspace(win, directory);
        const group = win.workspace(win.active).?;
        const group_id = group.id;
        try self.execute(.{ .window = win.id, .workspace = another_id, .other = group_id, .kind = .assign_project });
        try uiCheck(std.mem.eql(u8, another.directory, directory) and !std.mem.eql(u8, pane.pty.directory, directory) and pane.pty.pid == pid, "moving a session to another project changes grouping without changing its running shell directory");
        tester.frame();
        tester.frame();
        var project_from = another.project_rect;
        var project_to = original.project_rect;
        tester.drag(project_from.x + 70, project_from.y + 14, project_to.x + 70, project_to.y + project_to.h - 3);
        nano.runFor(0.05);
        tester.frame();
        tester.frame();
        try uiCheck(win.workspaces.items[0].id == original.id and pane.pty.pid == pid, "dragging a project header reorders its whole group without moving or restarting PTY owners");
        project_from = another.project_rect;
        project_to = original.project_rect;
        tester.drag(project_from.x + 70, project_from.y + 14, project_to.x + 70, project_to.y + 3);
        nano.runFor(0.05);
        tester.frame();
        tester.frame();
        try uiCheck(std.mem.eql(u8, win.workspaces.items[0].directory, directory), "project header dragging restores every member together before the destination group");
        project_from = another.project_rect;
        tester.moveTo(project_from.x + 70, project_from.y + 14);
        tester.ctx.input.mouse_button = 2;
        tester.ctx.pointerDown();
        tester.frame();
        tester.ctx.pointerUp();
        tester.frame();
        tester.ctx.input.mouse_button = 1;
        try uiCheck(win.session_menu_project and tester.hasText("Rename Project") and tester.hasText("Close Project"), "right clicking the actual project header opens project actions instead of a session menu");
        try tester.clickText("Rename Project");
        try uiCheck(win.project_rename != 0 and tester.ctx.focused_text != null and tester.ctx.focused_text.?.editable, "project rename publishes a native editable field while terminal input stays blocked");
        tester.textOps(&.{.{ .command = .select_all }});
        tester.typeText("Private Project");
        tester.key(.enter);
        var leaked_enter = false;
        for (self.actions.items) |queued| if (queued.kind == .input) {
            leaked_enter = true;
        };
        try uiCheck(!leaked_enter, "submitting an inline project name never queues its Enter into the terminal in the same frame");
        nano.runFor(0.05);
        tester.frame();
        try uiCheck(std.mem.eql(u8, self.presentation.label(directory), "Private Project") and std.mem.eql(u8, another.directory, directory) and pane.pty.pid == pid, "inline project rename changes only its persisted display name and retains the original directory and PTY");
        win.session_menu = original.id;
        win.session_menu_project = false;
        win.session_menu_frame = tester.ctx.frame;
        win.session_menu_point = .{ .x = 30, .y = 80 };
        tester.frame();
        try tester.clickText("Copy session ID");
        nano.runFor(0.05);
        const id = try std.fmt.allocPrint(self.a, "workspace-{d}", .{original.id});
        defer self.a.free(id);
        try uiCheck(self.private_clipboard != null and std.mem.eql(u8, self.private_clipboard.?, id) and win.session_menu == 0, "sidebar context menu resolves a stable session into the private clipboard");
        try self.execute(.{ .window = win.id, .workspace = group_id, .kind = .close_project });
        try uiCheck(win.workspace(another_id) == null and win.workspace(group_id) == null and win.workspace(original.id) == original, "closing a project closes only its local member PTYs");
        try self.execute(.{ .window = win.id, .workspace = original.id, .other = another_id, .kind = .assign_project });
        try uiCheck(!std.mem.eql(u8, original.directory, directory), "a stale project target cannot move a surviving session");
        win.activate(original);
        tester.frame();
    }
    fn uiCheck(ok: bool, label: []const u8) !void {
        if (!ok) {
            os.diagnostic("FAIL UI ");
            os.diagnostic(label);
            os.diagnostic("\n");
            return error.UiCheckFailed;
        }
        try os.output("PASS UI ");
        try os.output(label);
        try os.output("\n");
    }
};
