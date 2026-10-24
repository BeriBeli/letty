//! Stable workspace/document ownership. Preview documents never own a PTY.
const std = @import("std");
const builtin = @import("builtin");
const nano = @import("nanoui");
const ui = nano.ui;
const c = @import("platform_ffi.zig");
const paths = @import("preview/path.zig");
const panel = @import("preview/panel.zig");
const hooks = @import("preview/prepare_hooks.zig");
const actions = @import("actions.zig");
const storage = @import("dynamic_storage.zig");
const Text = @import("fixed_text.zig").Text;

/// Kero card header shared with the document view.
pub const header_height: f32 = @import("preview/view.zig").header_height;
pub const max_workspace_documents = 4;
const terminal_paths = @import("terminal_paths.zig");
const hostname = terminal_paths.hostname;
fn tab(s: anytype) u64 {
    return if (s.layout.tab_count > 0) s.layout.tabs[s.layout.active_tab].id else 0;
}
pub fn focused(s: anytype) bool {
    return s.preview.focused(tab(s));
}
pub fn documentCount(h: anytype) usize {
    var count: usize = 0;
    for (h.windows) |opt| if (opt) |w| {
        count += w.preview.count();
    };
    return count;
}
pub fn Runtime(comptime Window: type) type {
    return struct {
        const Self = @This();
        pub const Document = struct {
            owner: *Window,
            id: u64,
            tab_id: u64,
            panel: panel.Panel = .{},
            edit_job: ?*@import("preview/edit_job.zig").Job = null,
            edit_watch: c_uint = 0,
            edit_mac_watch: ?nano.fdwatch.Watch = null,
            watch: c_uint = 0,
            mac_watch: ?nano.fdwatch.Watch = null,
            fallback: ?paths.Resolved = null,
            first_completed: bool = false,
            location: paths.Resolved = .{},
            uploaded_revision: u64 = 0,
            pending_anchor: Text(256) = .{},
            pending_location: bool = false,
            closing: bool = false,
            reuse: u64 = 0,
        };
        pub const Dock = struct { tab_id: u64 = 0, active: u64 = 0, width: f32 = 440, collapsed: bool = false, workspace: bool = false };
        documents: []?*Document = &.{},
        docks: []Dock = &.{},
        next_id: u64 = 1,
        rect: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        base: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        resizing: bool = false,
        resize_original: f32 = 440,
        resize_tab: u64 = 0,
        resize_document: u64 = 0,
        picker_override: ?[]const u8 = null,
        pending_close: u64 = 0,
        pending_picker: bool = false,
        pending_focus: u64 = 0,
        composition_active: bool = false,
        pub fn count(self: *const Self) usize {
            var n: usize = 0;
            for (self.documents) |d| if (d != null) {
                n += 1;
            };
            return n;
        }
        pub fn find(self: *Self, id: u64) ?*Document {
            for (self.documents) |opt| if (opt) |d| if (d.id == id) return d;
            return null;
        }
        pub fn active(self: *Self, target: u64) ?*Document {
            for (self.docks) |*dock| if (dock.tab_id == target) {
                for (self.documents) |opt| if (opt) |d| if (d.tab_id == target and d.id == dock.active) return d;
            };
            return null;
        }
        pub fn dockFor(self: *Self, target: u64) *Dock {
            for (self.docks) |*dock| if (dock.tab_id == target) return dock;
            for (self.docks) |*dock| if (dock.tab_id == 0) {
                dock.* = .{ .tab_id = target };
                return dock;
            };
            unreachable; // open/promote reserve space before publishing a document
        }
        pub fn focused(self: *Self, target: u64) bool {
            const d = self.active(target) orelse return false;
            const dock = self.dockFor(target);
            return !dock.collapsed and d.panel.opened and (d.panel.focused or dock.workspace);
        }
        pub fn geometry(self: *Self, target: u64, base: ui.Rect) ui.Rect {
            self.base = base;
            self.rect = .{ .x = base.x + base.w, .y = base.y, .w = 0, .h = base.h };
            if (self.active(target) == null) return base;
            const dock = self.dockFor(target);
            if (dock.workspace) {
                self.rect = insetCard(base);
                return .{ .x = base.x, .y = base.y, .w = 0, .h = base.h };
            }
            if (dock.collapsed) return base;
            const width = if (base.w < 780) base.w else std.math.clamp(dock.width, 320, @max(320, base.w - 240));
            self.rect = insetCard(.{ .x = base.x + base.w - width, .y = base.y, .w = width, .h = base.h });
            return .{ .x = base.x, .y = base.y, .w = base.w - width, .h = base.h };
        }
        pub fn stopWatch(d: *Document) void {
            if (d.watch != 0) c.lt_unwatch(d.watch);
            if (d.mac_watch) |watch| watch.cancel();
            d.watch = 0;
            d.mac_watch = null;
        }
        fn watchDocument(d: *Document) !void {
            const fd = d.panel.model.fd() orelse return;
            if (builtin.os.tag == .linux) {
                d.watch = c.lt_fd_watch(fd, 1 | 8 | 16, linuxReady, d);
                if (d.watch == 0) return error.PreviewNotificationUnavailable;
            } else d.mac_watch = try nano.fdwatch.readable(fd, d, ready);
        }
        fn linuxReady(_: c_int, _: c_uint, raw: ?*anyopaque) callconv(.c) c_int {
            const d: *Document = @ptrCast(@alignCast(raw.?));
            ready(raw);
            return @intFromBool(d.watch != 0);
        }
        fn ready(raw: ?*anyopaque) callconv(.c) void {
            const d: *Document = @ptrCast(@alignCast(raw.?));
            const s = d.owner;
            if (s.closing or s.deinitialized or s.layout.tabIndex(d.tab_id) == null) return;
            var changed = false;
            while (true) {
                const received = d.panel.model.drain(s.gpa) catch {
                    s.status = "Cannot receive document update";
                    break;
                };
                if (!received) break;
                changed = true;
            }
            if (!changed) return;
            if (!d.first_completed and d.panel.model.status != .loading) {
                d.first_completed = true;
                const fallback = d.fallback;
                d.fallback = null;
                if (d.panel.model.status == .missing and fallback != null) {
                    const location = fallback.?;
                    for (s.preview.documents) |opt| if (opt) |existing| if (existing != d and existing.tab_id == d.tab_id and std.mem.eql(u8, existing.panel.model.path.text(), location.path.text())) {
                        d.location = location;
                        d.reuse = existing.id;
                        if (s.window) |window| window.redraw();
                        return;
                    };
                    stopWatch(d);
                    d.panel.model.open(s.gpa, location.path.text()) catch {
                        watchDocument(d) catch {
                            d.closing = true;
                        };
                        s.status = "Cannot open located file";
                        if (s.window) |window| window.redraw();
                        return;
                    };
                    d.location = location;
                    d.panel.path.set(location.path.text());
                    d.panel.path_truncated = location.path.len > d.panel.path.buf.len;
                    watchDocument(d) catch {
                        s.status = "Document notification unavailable; preview closed";
                        d.closing = true;
                        if (s.window) |window| window.redraw();
                        return;
                    };
                }
            }
            if (d.tab_id == tab(s)) if (s.window) |window| window.redraw();
        }
        pub fn applyPending(d: *Document) void {
            const s = d.owner;
            if (d.panel.model.takePrepared()) |prepared| {
                clearImages(s, d);
                const had_content = d.panel.prepared != null;
                const scroll_y = d.panel.scroll_y;
                const scroll_x = d.panel.scroll_x;
                d.panel.apply(hooks.take(prepared), d.panel.model.revision);
                if (had_content) {
                    d.panel.scroll_y = scroll_y;
                    d.panel.scroll_x = scroll_x;
                }
                // The reader's source location is applied after the new line index exists.
                if (d.location.line > 0) {
                    d.panel.mode = .source;
                    d.pending_location = true;
                }
            }
        }
        pub fn clearImages(s: *Window, d: *Document) void {
            if (s.graphics_store) |*store| {
                for (&d.panel.image_keys) |*entry| if (entry.* != 0) {
                    store.resources().remove(store.resources().ctx, entry.*);
                    entry.* = 0;
                };
            }
            d.uploaded_revision = 0;
        }
        pub fn close(self: *Self, s: *Window, id: u64) void {
            for (self.documents) |*slot| if (slot.*) |d| if (d.id == id) {
                if (!s.shutting_down and !s.deinitialized and !s.closing and d.panel.hasUnsaved()) {
                    _ = @import("application_preview_edit.zig").blocked(s, d.tab_id);
                    return;
                }
                @import("application_preview_edit.zig").stop(d);
                if (d.edit_job) |job| job.release();
                const target = d.tab_id;
                stopWatch(d);
                clearImages(s, d);
                d.panel.deinit(s.gpa);
                s.gpa.destroy(d);
                slot.* = null;
                const dock = self.dockFor(target);
                if (dock.active == id) {
                    dock.active = 0;
                    for (self.documents) |opt| if (opt) |other| if (other.tab_id == target) {
                        dock.active = other.id;
                        break;
                    };
                }
                if (dock.active == 0) dock.* = .{};
                self.resizing = false;
                if (!s.shutting_down and !s.deinitialized and !s.closing) if (s.layout.tabIndex(target)) |index| if (s.layout.isDocument(index)) {
                    s.layout.closeDocument(target);
                    if (s.layout.tab_count == 0) s.host.closeWindow(s) else s.save();
                };
                if (!s.shutting_down and !s.deinitialized and !s.closing) s.syncFocus();
                return;
            };
        }
        pub fn prune(self: *Self, s: *Window) void {
            for (self.documents) |opt| if (opt) |d| if (s.layout.tabIndex(d.tab_id) == null) self.close(s, d.id);
        }
        pub fn deinit(self: *Self, s: *Window) void {
            for (self.documents) |opt| if (opt) |d| self.close(s, d.id);
            storage.release(?*Document, &self.documents);
            storage.release(Dock, &self.docks);
        }
    };
}
/// Explicit user input (picker, path field, drop): relative to the reported CWD.
pub fn open(s: anytype, raw: []const u8) !void {
    if (tab(s) == 0) return error.PreviewWorkspaceUnavailable;
    const host = hostname();
    const base = if (s.active()) |session| session.cwd.text() else if (s.preview.active(tab(s))) |d| paths.directory(d.panel.model.path.text()) else "";
    const resolved = try paths.resolve(raw, base, host.text());
    if (s.layout.isDocument(s.layout.active_tab)) return openWorkspaceResolved(s, resolved);
    return openResolved(s, resolved);
}
/// Terminal-originated text (modified click, Preview Selected Path). The source
/// session is revalidated by stable ID and its live process origin decides trust.
pub fn openTerminalPath(s: anytype, raw: []const u8, session_id: u64) void {
    openTerminalText(s, raw, session_id, true);
}
/// A deliberate selection need not pass the hover heuristic, only the trust policy.
pub fn openTerminalText(s: anytype, raw: []const u8, session_id: u64, path_like: bool) void {
    const session = for (s.sessions) |opt| {
        if (opt) |candidate| if (candidate.id == session_id) break candidate;
    } else {
        s.status = "The terminal that showed this path has closed";
        return;
    };
    if (path_like and terminal_paths.classify(raw, true) != .file and !terminal_paths.isPath(raw)) {
        s.status = "Not a local file path";
        return;
    }
    switch (terminal_paths.resolveFor(session, raw)) {
        .refused => |reason| s.status = reason.message(),
        .invalid => |err| s.status = terminal_paths.invalidMessage(err),
        .path => |resolved| openResolved(s, resolved) catch |err| {
            s.status = terminal_paths.invalidMessage(err);
        },
    }
}
/// Files use the same stable workspace IDs as terminals, without allocating a PTY.
pub fn openWorkspace(s: anytype, raw: []const u8) !void {
    const host = hostname();
    const base = if (s.active()) |session| session.cwd.text() else if (s.preview.active(tab(s))) |d| paths.directory(d.panel.model.path.text()) else "";
    try openWorkspaceResolved(s, try paths.resolve(raw, base, host.text()));
}
pub fn openWorkspaceResolved(s: anytype, resolved: paths.Resolved) !void {
    for (s.preview.documents) |opt| if (opt) |d| {
        const index = s.layout.tabIndex(d.tab_id) orelse continue;
        if (!s.layout.isDocument(index) or !std.mem.eql(u8, d.panel.model.path.text(), resolved.path.text())) continue;
        s.activateTab(index);
        if (resolved.line > 0) {
            d.location = resolved;
            d.pending_location = true;
            d.panel.mode = .source;
        }
        activate(s, d);
        return;
    };
    var previous = try s.layout.clone();
    defer previous.deinit();
    const id = try s.layout.newDocument();
    errdefer {
        s.layout.deinit();
        s.layout = previous;
        previous = .{};
    }
    try openInto(s, resolved, id);
    s.zoom = null;
    s.search_open = false;
    s.clearSearch();
    s.save();
}
/// Restore a validated file-workspace record after terminal sessions are created.
pub fn restoreWorkspace(s: anytype, id: u64, path: []const u8) !void {
    const host = hostname();
    try openInto(s, try paths.resolve(path, "", host.text()), id);
}
pub fn moveToWorkspace(s: anytype) !void {
    const d = s.preview.active(tab(s)) orelse return error.PreviewWorkspaceUnavailable;
    if (s.layout.isDocument(s.layout.active_tab)) return;
    const old_tab = d.tab_id;
    try storage.ensure(@TypeOf(s.preview).Dock, &s.preview.docks, s.layout.tab_count + 1, .{});
    const id = try s.layout.newDocument();
    const old = s.preview.dockFor(old_tab);
    old.active = 0;
    for (s.preview.documents) |opt| if (opt) |other| if (other != d and other.tab_id == old_tab) {
        old.active = other.id;
        break;
    };
    if (old.active == 0) old.* = .{};
    d.tab_id = id; // queued callbacks with the old workspace can no longer resolve
    s.preview.dockFor(id).workspace = true;
    s.preview.resizing = false;
    s.zoom = null;
    s.search_open = false;
    s.clearSearch();
    activate(s, d);
    s.save();
}
pub fn openResolved(s: anytype, resolved: paths.Resolved) !void {
    return openInto(s, resolved, tab(s));
}
fn openInto(s: anytype, resolved: paths.Resolved, target: u64) !void {
    const index = s.layout.tabIndex(target) orelse return error.PreviewWorkspaceUnavailable;
    const path = resolved.path.text();
    var same_tab: usize = 0;
    for (s.preview.documents) |opt| if (opt) |d| if (d.tab_id == target) {
        same_tab += 1;
        if (std.mem.eql(u8, d.panel.model.path.text(), path)) {
            activate(s, d);
            return;
        }
    };
    if (same_tab >= max_workspace_documents) return error.WorkspaceDocumentLimit;
    var available: usize = s.preview.documents.len;
    for (s.preview.documents, 0..) |d, i| if (d == null) {
        available = i;
        break;
    };
    const D = @TypeOf(s.preview).Document;
    try storage.ensure(?*D, &s.preview.documents, available + 1, null);
    try storage.ensure(@TypeOf(s.preview).Dock, &s.preview.docks, s.layout.tab_count, .{});
    if (s.preview.next_id == std.math.maxInt(u64)) return error.DocumentIdExhausted;
    const d = try s.gpa.create(D);
    errdefer s.gpa.destroy(d);
    d.* = .{ .owner = s, .id = s.preview.next_id, .tab_id = target, .location = resolved, .fallback = paths.locationFallback(resolved) };
    s.preview.next_id += 1;
    d.panel.model.id = d.id;
    d.panel.model.hooks = hooks.hooks;
    try d.panel.model.open(s.gpa, path);
    errdefer d.panel.deinit(s.gpa);
    d.panel.path.set(path);
    d.panel.path_truncated = path.len > d.panel.path.buf.len;
    d.panel.opened = true;
    d.panel.focused = true;
    try @TypeOf(s.preview).watchDocument(d);
    s.preview.documents[available] = d;
    s.preview.dockFor(target).workspace = s.layout.isDocument(index);
    activate(s, d);
}
pub fn picker(s: anytype, ctx: *ui.Context) void {
    pickerMode(s, ctx, s.layout.isDocument(s.layout.active_tab));
}
fn pickerMode(s: anytype, ctx: *ui.Context, workspace: bool) void {
    if (composing(s, ctx)) {
        s.status = "Finish text composition before opening a file";
        return;
    }
    var opened = false;
    if (s.preview.picker_override) |path| {
        (if (workspace) openWorkspace(s, path) else open(s, path)) catch |err| {
            s.status = terminal_paths.invalidMessage(err);
            return;
        };
        opened = true;
    } else if (s.app.flags.hidden) {
        s.status = "Hidden checks do not open the system file chooser";
    } else {
        const result = nano.dialog.open(s.gpa, .{ .title = if (workspace) "Open File in Workspace" else "Open File in Side Preview", .button = "Open", .directory = if (s.active()) |session| session.cwd.text() else "", .multiple = false }) catch {
            s.status = "Cannot open file chooser";
            return;
        };
        if (result) |files| {
            defer nano.dialog.freePaths(s.gpa, files);
            if (files.len > 0) {
                (if (workspace) openWorkspace(s, files[0]) else open(s, files[0])) catch |err| {
                    s.status = terminal_paths.invalidMessage(err);
                    return;
                };
                opened = true;
            }
        }
    }
    if (opened) {
        ctx.focus = 0;
        ctx.active = 0;
    }
    ctx.input.clearEdges();
    ctx.changed = true;
}
pub fn handle(s: anytype, ctx: *ui.Context, request: actions.Request) bool {
    if (composing(s, ctx)) switch (request.action) {
        .open_file_workspace,
        .move_preview_to_workspace,
        .open_file_preview,
        .preview_selected_path,
        .close_file_preview,
        .toggle_file_preview,
        .close,
        .font_up,
        .font_down,
        .font_reset,
        .tab,
        .horizontal,
        .vertical,
        .split_left,
        .split_up,
        .close_tab,
        .close_other_tabs,
        .close_window,
        .next_tab,
        .previous_tab,
        .goto_tab,
        .next_pane,
        .previous_pane,
        .focus_pane,
        .next_window,
        .previous_window,
        .new_window,
        .open_settings,
        .palette,
        .inspector,
        .open_theme_browser,
        .toggle_quick_terminal,
        => {
            s.status = "Finish text composition before changing document focus";
            return true;
        },
        else => {},
    };
    switch (request.action) {
        .open_file_workspace => pickerMode(s, ctx, true),
        .move_preview_to_workspace => moveToWorkspace(s) catch |err| {
            s.status = @errorName(err);
        },
        .open_file_preview => {
            if (s.layout.isDocument(s.layout.active_tab)) s.status = "Select a terminal workspace for a side preview" else pickerMode(s, ctx, false);
        },
        .preview_selected_path => {
            const session = s.active() orelse return true;
            var value: [4096]u8 = undefined;
            var length: usize = 0;
            if (@import("vt.zig").lt_vt_copy(session.vt, &value, value.len, &length) != 0) {
                s.status = "Select one local path, at most 4095 bytes";
                return true;
            }
            openTerminalText(s, value[0..length], session.id, false);
        },
        .close_file_preview => if (s.preview.active(tab(s))) |d| s.preview.close(s, d.id),
        .toggle_file_preview => if (s.preview.active(tab(s))) |d| {
            const dock = s.preview.dockFor(d.tab_id);
            if (dock.workspace) {
                pickerMode(s, ctx, true);
                return true;
            }
            dock.collapsed = !dock.collapsed;
            d.panel.focused = !dock.collapsed;
            if (dock.collapsed) @TypeOf(s.preview).clearImages(s, d);
            s.sidebar.focused = false;
            ctx.focus = 0;
            ctx.active = 0;
            s.syncFocus();
        } else picker(s, ctx),
        .refresh_file_preview => if (s.preview.active(tab(s))) |d| {
            d.panel.model.refresh() catch {
                s.status = "Cannot refresh document";
            };
        },
        else => {
            if (!focused(s)) return false;
            if (s.preview.active(tab(s))) |d| {
                if (request.action == .close) {
                    s.preview.close(s, d.id);
                    ctx.focus = 0;
                    ctx.active = 0;
                    return true;
                }
                if (d.panel.handleAction(request.action, ctx)) return true;
            }
            return false;
        },
    }
    return true;
}
pub fn activate(s: anytype, d: anytype) void {
    const dock = s.preview.dockFor(d.tab_id);
    dock.active = d.id;
    dock.collapsed = false;
    d.panel.opened = true;
    d.panel.focused = true;
    if (d.tab_id == tab(s)) {
        s.preview.pending_focus = d.id;
        s.search_focus = false;
        s.drag_split = null;
        s.views[s.layout.active_pane].preedit.clearRetainingCapacity();
        s.sidebar.focused = false;
        @import("input_dispatch.zig").cancel(s, .editing);
        s.syncFocus();
    }
}
pub fn process(s: anytype, ctx: *ui.Context) void {
    validateResize(s);
    for (s.preview.documents) |opt| if (opt) |d| @import("application_preview_edit.zig").process(s, ctx, d);
    for (s.preview.documents) |opt| if (opt) |d| if (d.reuse != 0) {
        const is_active = if (s.preview.active(tab(s))) |current| current == d else false;
        if (is_active and composing(s, ctx)) continue;
        if (s.preview.find(d.reuse)) |existing| {
            const transfer = is_active and focused(s);
            if (transfer) {
                existing.location = d.location;
                existing.pending_location = true;
                existing.panel.mode = .source;
                activate(s, existing);
            } else if (is_active) {
                s.preview.dockFor(d.tab_id).active = existing.id;
                existing.panel.focused = false;
            }
        }
        s.preview.close(s, d.id);
    };
    for (s.preview.documents) |opt| if (opt) |d| if (!d.closing) @TypeOf(s.preview).applyPending(d);
    if (s.preview.pending_close != 0) {
        const id = s.preview.pending_close;
        s.preview.pending_close = 0;
        s.preview.close(s, id);
    }
    for (s.preview.documents) |opt| if (opt) |d| if (d.closing) s.preview.close(s, d.id);
    s.preview.prune(s);
}
pub fn prepareInput(s: anytype, ctx: *ui.Context) bool {
    s.preview.composition_active = composing(s, ctx);
    for (s.preview.documents) |opt| if (opt) |hidden| if (hidden.tab_id != tab(s)) @TypeOf(s.preview).clearImages(s, hidden);
    const d = s.preview.active(tab(s)) orelse return false;
    const dock = s.preview.dockFor(d.tab_id);
    if (s.preview.pending_focus != 0 and !composing(s, ctx)) {
        if (s.preview.pending_focus == d.id) {
            ctx.focus = 0;
            ctx.active = 0;
            d.panel.field = .body;
            if (d.panel.editor) |editor| editor.focus = true;
        }
        s.preview.pending_focus = 0;
    }
    if (dock.collapsed or s.modalOpen()) return false;
    const body = s.preview.rect;
    const was_focused = d.panel.focused;
    if (dock.workspace and !s.sidebar.focused) d.panel.focused = true;
    const consumed = d.panel.prepareInput(ctx, body);
    if (s.preview.rect.contains(ctx.input.mouse) and ctx.input.pressed) {
        d.panel.focused = true;
        s.sidebar.focused = false;
    }
    if (was_focused != d.panel.focused) {
        if (d.panel.focused) s.views[s.layout.active_pane].preedit.clearRetainingCapacity();
        @import("input_dispatch.zig").cancel(s, .editing);
        s.syncFocus();
    }
    if (composing(s, ctx)) return consumed;
    if (d.panel.focused and d.panel.editor != null) if (ctx.input.shortcut) |sc| {
        if ((sc.cmd or sc.ctrl) and sc.key == 's' and !sc.alt) {
            _ = ctx.shortcut(sc);
            d.panel.edit_request = .save;
            ctx.input.clearEdges();
            ctx.changed = true;
            return true;
        }
    };

    if (d.panel.focused) if (ctx.input.shortcut) |sc| {
        const keys = @import("keybindings.zig");
        if (keys.lookup(s.cfg.keybinds, s.cfg.clear_default_keybinds, .{ .key = sc.key, .cmd = sc.cmd, .ctrl = sc.ctrl, .alt = sc.alt, .shift = sc.shift })) |binding| {
            if (d.panel.field == .body and d.panel.handleAction(binding.action, ctx)) {
                _ = ctx.shortcut(sc);
                ctx.input.key = null;
                ctx.input.ops = &.{};
                ctx.input.chars = "";
            } else if (binding.action == .close) {
                _ = ctx.shortcut(sc);
                s.preview.pending_close = d.id;
                ctx.input.clearEdges();
                ctx.changed = true;
            }
        }
    };
    return consumed;
}
fn images(s: anytype, ctx: *ui.Context, d: anytype) void {
    if (d.panel.prepared == null or d.panel.prepared.?.image_count == 0) return;
    if (s.graphics_store == null) s.graphics_store = @import("nanoui_graphics_resources.zig").Store.init(ctx.text);
    const store = &s.graphics_store.?;
    if (store.text != ctx.text) {
        s.status = "Preview image belongs to another text surface";
        return;
    }
    for (&d.panel.image_keys, 0..) |*key, index| {
        if (key.* != 0) continue;
        const image = d.panel.imageAt(index) orelse continue;
        const next = store.keys.next() catch {
            s.status = "Image resource keys exhausted";
            return;
        };
        const resources = store.resources();
        resources.putRaw(resources.ctx, .{ .key = next, .width = image.width, .height = image.height, .bgra = image.bgra }) catch {
            s.status = "Preview image unavailable: shared image budget or atlas limit";
            continue;
        };
        key.* = next;
    }
}
pub fn draw(s: anytype, ctx: *ui.Context) void {
    validateResize(s);
    const d = s.preview.active(tab(s)) orelse return;
    const dock = s.preview.dockFor(d.tab_id);
    const rect = s.preview.rect;
    if (rect.w <= 0 or rect.h <= 0) return;
    const ui_input = ctx.input;
    const composing_now = composing(s, ctx);
    if (s.modalOpen()) ctx.input = .{};
    defer ctx.input = ui_input;
    ui.key(ctx, ctx.print("document-dock-{d}", .{d.tab_id}));
    const chrome = @import("chrome.zig");
    _ = ctx.open(.{ .absolute = true, .offset = .{ .x = rect.x, .y = rect.y }, .width = .{ .px = rect.w }, .height = .{ .px = rect.h }, .clip = true, .radius = 14, .background = ctx.theme.background, .border = @import("rex_chrome.zig").edge(ctx), .shadow = .{ .color = @import("rex_chrome.zig").shadow(ctx), .blur = 6, .y = 2 } }, null);
    var dock_open = true;
    defer if (dock_open) ctx.end();
    const divider = if (s.cfg.split_divider_color) |color| ui.Color.hex(color) else ctx.theme.border;
    const resize: ui.Rect = .{ .x = rect.x, .y = rect.y, .w = 5, .h = rect.h };
    if (!dock.workspace and s.preview.base.w >= 780 and (resize.contains(ctx.input.mouse) or s.preview.resizing)) {
        ctx.cursor = .resize_left_right;
        if (ctx.input.pressed and resize.contains(ctx.input.mouse)) {
            s.preview.resizing = true;
            s.preview.resize_original = dock.width;
            s.preview.resize_tab = d.tab_id;
            s.preview.resize_document = d.id;
        }
    }
    if (s.preview.resizing) {
        if (ctx.input.key == .escape) {
            dock.width = s.preview.resize_original;
            s.preview.resizing = false;
        } else if (ctx.input.down) dock.width = std.math.clamp(s.preview.base.x + s.preview.base.w - ctx.input.mouse.x, 320, @max(320, s.preview.base.w - 240)) else s.preview.resizing = false;
        ctx.changed = true;
    }
    if (!dock.workspace) chrome.box(ctx, 0, 0, 1, rect.h, divider);
    images(s, ctx, d);
    ctx.end();
    dock_open = false;
    d.panel.embedded_header = true;
    ui.key(ctx, ctx.print("document-{d}", .{d.id}));
    const intent = d.panel.draw(ctx, rect);
    const window_controls: f32 = if (builtin.os.tag == .linux) 88 else 0;
    // Overlay document tabs and collapse in the unused leading header region.
    // Panel actions remain on the same row at the trailing edge.
    ui.row(ctx, .{ .absolute = true, .offset = .{ .x = rect.x + 16, .y = rect.y }, .width = .{ .px = @max(1, rect.w - 120 - window_controls) }, .height = .{ .px = header_height }, .align_items = .center, .clip = true });
    if (!dock.workspace) {
        ui.key(ctx, "document-collapse");
        s.ax.note(.{ .widget = ctx.peekId(null), .role = .button, .target = .{ .window = s.id, .tab = d.tab_id, .document = d.id, .document_generation = d.panel.model.generation }, .intent = .preview_toggle, .label = "Hide File Preview" });
        if (chrome.iconButton(ctx, .right, 24) and !composing_now) s.pending = .{ .action = .toggle_file_preview };
        ui.key(ctx, "document-workspace");
        s.ax.note(.{ .widget = ctx.peekId(null), .role = .button, .target = .{ .window = s.id, .tab = d.tab_id, .document = d.id, .document_generation = d.panel.model.generation }, .intent = .document_workspace, .label = "Move Preview to Workspace", .enabled = true });
        if (chrome.iconControl(ctx, .external, 24, false, false).clicked and !composing_now) s.pending = .{ .action = .move_preview_to_workspace };
    }
    _ = ctx.leaf(.{ .width = .{ .px = 4 } }, .none, null);
    var count: usize = 0;
    for (s.preview.documents) |opt| if (opt) |item| if (item.tab_id == d.tab_id) {
        count += 1;
    };
    const controls: f32 = (if (dock.workspace) @as(f32, 116) else 168) + window_controls;
    const width = @floor(@min(200, @max(1, (rect.w - controls) / @as(f32, @floatFromInt(@max(1, count))))));

    d.panel.ax_close = 0;
    for (s.preview.documents) |opt| if (opt) |item| if (item.tab_id == d.tab_id) {
        const selected = item.id == d.id;
        ui.key(ctx, ctx.print("document-tab-{d}", .{item.id}));
        const tab_id = ctx.peekId(null);
        const it = chrome.control(ctx, .{ .width = .{ .px = width }, .height = .{ .px = 28 }, .radius = 8, .background = if (selected and count > 1) chrome.selected(ctx) else ctx.theme.surface, .direction = .row, .padding = .{ .left = 4, .right = 24 }, .gap = 7, .control = true, .align_items = .center, .clip = true }, if (selected) null else ctx.theme.surface_hover);
        if (it.clicked and !composing_now) {
            activate(s, item);
            ctx.changed = true;
        }
        const name = std.fs.path.basename(item.panel.model.path.text());
        chrome.icon(ctx, @import("ui_icons/icons.zig").file(item.panel.model.path.text()), 16);
        ui.text(ctx, chrome.ellipsize(ctx, name, @max(1, width - 58), 13.5), .{ .size = 13.5, .color = if (selected) ctx.theme.text else ctx.theme.muted, .weight = if (selected) .semibold else .regular });
        if (it.hovered or selected) {
            _ = ctx.open(.{ .absolute = true, .offset = .{ .x = width - 30, .y = 2 } }, null);
            ui.key(ctx, ctx.print("document-close-{d}", .{item.id}));
            if (selected) d.panel.ax_close = ctx.peekId(null);
            if (chrome.iconButton(ctx, .close, 24) and !composing_now) {
                s.preview.pending_close = item.id;
                ctx.changed = true;
            }
            ctx.end();
        }
        ui.end(ctx);
        s.ax.note(.{ .widget = tab_id, .role = .tab, .target = .{ .window = s.id, .tab = d.tab_id, .document = item.id, .document_generation = item.panel.model.generation }, .intent = .document_tab, .label = safeLabel(name), .selected = selected });
    };
    ui.key(ctx, "document-window-drag");
    const drag = ctx.open(.{ .width = .fill, .height = .fill }, null);
    _ = ctx.interact(drag, .{});
    ctx.end();
    if (!composing_now) if (ctx.rects.get(ctx.node(drag).id)) |r| @import("window_chrome.zig").drag(s.window, ctx, r);
    ui.end(ctx);
    if (builtin.os.tag == .linux) {
        ui.row(ctx, .{ .absolute = true, .offset = .{ .x = rect.x + rect.w - 94, .y = rect.y + 8 } });
        if (@import("window_chrome.zig").controls(ctx, s.window) and !composing_now and !s.modalOpen()) s.pending = .{ .action = .close_window };
        ui.end(ctx);
    }
    // Cache the resulting edit state, not this frame's already consumed
    // unmark op, so a completed composition cannot block later callbacks.
    s.preview.composition_active = (if (ctx.edits.getPtr(ctx.focus)) |edit| edit.marked != null else false) or s.views[s.layout.active_pane].preedit.items.len != 0;
    noteDocument(s, ctx, d);
    if (d.panel.row_y.items.len > 0) {
        if (d.pending_location) {
            d.panel.scrollToLine(d.location.line, d.location.column);
            d.pending_location = false;
            d.location.line = 0;
            d.location.column = 0;
            ctx.changed = true;
        }
        if (d.pending_anchor.len > 0) {
            if (!d.panel.anchor(d.pending_anchor.text())) s.status = "Document anchor was not found";
            d.pending_anchor.set("");
            ctx.changed = true;
        }
    }
    if (composing_now and intent != .none and intent != .refresh) {
        s.status = "Finish text composition before changing document focus";
        return;
    }
    switch (intent) {
        .none => {},
        .close => {
            s.preview.pending_close = d.id;
            ctx.changed = true;
        },
        .refresh => d.panel.model.refresh() catch {
            s.status = "Cannot refresh document";
        },
        .open_file => {
            s.preview.pending_picker = true;
            ctx.changed = true;
        },
        .open_path => openDraft(s, d),
        .external => @import("application_commands.zig").openPath(s, ctx, d.panel.model.path.text()),
        .link => followLink(s, ctx, d, d.panel.link_target.text()),
    }
}
pub fn openDraft(s: anytype, d: anytype) void {
    var requested: Text(4096) = .{};
    requested.set(d.panel.path.text());
    d.panel.path.set(d.panel.model.path.text());
    d.panel.path_truncated = d.panel.model.path.len > d.panel.path.buf.len;
    open(s, requested.text()) catch |err| {
        s.status = terminal_paths.invalidMessage(err);
    };
}
fn followLink(s: anytype, ctx: *ui.Context, d: anytype, target: []const u8) void {
    if (std.mem.startsWith(u8, target, "#")) {
        const decoded = paths.percentDecoded(target) catch {
            s.status = "Invalid document anchor";
            return;
        };
        if (!d.panel.anchor(decoded.text())) s.status = "Document anchor was not found";
        return;
    }
    if (@import("url.zig").allowed(target)) {
        @import("application_commands.zig").openTarget(s, ctx, target, true);
        return;
    }
    const end = std.mem.indexOfScalar(u8, target, '#') orelse target.len;
    const host = hostname();
    const decoded = if (std.mem.startsWith(u8, target, "file://")) value: {
        var text: Text(4096) = .{};
        text.set(target[0..end]);
        break :value text;
    } else paths.percentDecoded(target[0..end]) catch {
        s.status = "Invalid document link";
        return;
    };
    const resolved = paths.resolve(decoded.text(), paths.directory(d.panel.model.path.text()), host.text()) catch |err| {
        s.status = terminal_paths.invalidMessage(err);
        return;
    };
    open(s, resolved.path.text()) catch |err| {
        s.status = terminal_paths.invalidMessage(err);
        return;
    };
    if (end < target.len) if (s.preview.active(tab(s))) |next| {
        const anchor = paths.percentDecoded(target[end..]) catch return;
        next.pending_anchor.set(anchor.text());
    };
}
/// Rechecked by enqueue, wake, execution and ordinary command dispatch.
pub fn blocksAction(s: anytype, action: actions.Action) bool {
    if (comptime !@hasField(@typeInfo(@TypeOf(s)).pointer.child, "preview")) return false;
    if (!focused(s)) return false;
    if (s.preview.composition_active and (action == .new_window or action == .toggle_quick_terminal or action == .open_settings)) return true;
    return switch (action) {
        .send_bytes, .paste, .paste_primary, .clear_screen, .reset, .search_selection, .prompt_previous, .prompt_next, .open_link, .copy_link => true,
        else => false,
    };
}
fn noteDocument(s: anytype, ctx: *ui.Context, d: anytype) void {
    const ax = @import("accessibility.zig");
    const target: @import("application_accessibility.zig").Target = .{ .window = s.id, .tab = d.tab_id, .document = d.id, .document_generation = d.panel.model.generation };
    var visible: []const u8 = "";
    var offset: usize = 0;
    if (d.panel.editor == null) if (d.panel.document()) |doc| {
        const rows = d.panel.visual_rows.items;
        if (rows.len > 0) {
            const first = @import("preview/view.zig").visualAt(&d.panel, d.panel.scroll_y);
            const last = @import("preview/view.zig").visualAt(&d.panel, d.panel.scroll_y + d.panel.body_rect.h);
            offset = rows[first].start;
            const end = doc.floor(@min(rows[last].end, offset + ax.max_value));
            visible = doc.text[offset..end];
        }
    };
    const selection = d.panel.selection;
    const start = @min(selection.anchor, selection.caret);
    const end = @max(selection.anchor, selection.caret);
    const caret: u32 = @intCast(@min(selection.caret -| offset, visible.len));
    if (d.panel.ax_path != 0) s.ax.note(.{ .widget = d.panel.ax_path, .role = .text_field, .target = target, .intent = .document_path, .label = "Local File Path", .value = d.panel.path.text(), .focused = d.panel.focused and d.panel.field == .path and s.window_focused });
    if (d.panel.ax_close != 0) s.ax.note(.{ .widget = d.panel.ax_close, .role = .button, .target = target, .intent = .document_close, .label = "Close Document" });
    for (d.panel.ax_controls[0..d.panel.ax_count]) |item| {
        if (item.control == .previous) {
            if (d.panel.ax_query != 0) s.ax.note(.{ .widget = d.panel.ax_query, .role = .search, .target = target, .intent = .document_query, .label = "Find in Document", .value = d.panel.query.text(), .focused = d.panel.focused and d.panel.field == .query and s.window_focused });
        }
        if (item.control == .copy_path) {
            if (d.panel.ax_copy != 0) s.ax.note(.{ .widget = d.panel.ax_copy, .role = .button, .target = target, .intent = .document_copy, .label = "Copy Document Selection", .enabled = selection.anchor != selection.caret });
        }
        if (item.control == .external) {
            if (d.panel.ax_refresh != 0) s.ax.note(.{ .widget = d.panel.ax_refresh, .role = .button, .target = target, .intent = .document_refresh, .label = "Refresh Document" });
        }
        const intent: @import("application_ax_lifecycle.zig").Intent = switch (item.control) {
            .unlock => .document_unlock,
            .save => .document_save,
            .discard => .document_discard,
            .open => .document_open,
            .browse => .document_browse,
            .rendered => .document_rendered,
            .source => .document_source,
            .toggle_source => .document_toggle_source,
            .more => .document_more,
            .copy_code => .document_copy_code,
            .fit => .document_fit,
            .actual => .document_actual,
            .zoom_out => .document_zoom_out,
            .zoom_in => .document_zoom_in,
            .previous => .document_previous,
            .next => .document_next,
            .done => .document_done,
            .find => .document_find,
            .copy_path => .document_copy_path,
            .external => .document_external,
        };
        s.ax.note(.{ .widget = item.widget, .role = .button, .target = target, .intent = intent, .modal = if (item.control == .copy_code) .{ .ordinal = @intCast(item.offset), .generation = d.panel.model.revision } else .{}, .label = item.label, .enabled = item.enabled, .selected = item.selected, .focused = d.panel.focused and ctx.focus == item.widget and s.window_focused });
    }
    if (d.panel.ax_results != 0) s.ax.note(.{ .widget = d.panel.ax_results, .role = .label, .target = target, .label = "Document search results", .value = if (composing(s, ctx)) "Composing" else if (d.panel.searching) ctx.print("Searching, {d} found", .{d.panel.match_count}) else ctx.print("{d} of {d}{s}", .{ if (d.panel.match_count > 0) d.panel.match_current + 1 else 0, d.panel.match_count, if (d.panel.match_count == d.panel.matches.len) "+" else "" }), .modal = .{ .ordinal = 1 } });
    if (d.panel.ax_status != 0) s.ax.note(.{ .widget = d.panel.ax_status, .role = .label, .target = target, .label = "Document status", .value = @import("preview/view.zig").statusLabel(d.panel.model.status, d.panel.model.stale), .modal = .{ .ordinal = 2 } });
    if (d.panel.editor) |editor| {
        const value = editor.buffer.text();
        const edit = ctx.edits.getPtr(d.panel.ax_body);
        const at = @min(if (edit) |e| e.caret else 0, value.len);
        const anchor = @min(if (edit) |e| e.anchor else 0, value.len);
        var lo = at -| (ax.max_value / 2);
        while (lo < value.len and value[lo] & 0xc0 == 0x80) lo += 1;
        var hi = @min(value.len, lo + ax.max_value);
        while (hi > lo and hi < value.len and value[hi] & 0xc0 == 0x80) hi -= 1;
        s.ax.note(.{ .widget = d.panel.ax_body, .role = .text_field, .target = target, .intent = .document_editor, .label = "Document Source Editor", .value = value[lo..hi], .focused = d.panel.focused and s.window_focused and ctx.focus == d.panel.ax_body, .truncated = lo > 0 or hi < value.len, .caret = @intCast(@min(at -| lo, hi - lo)), .selection_start = @intCast(@min(@min(at, anchor) -| lo, hi - lo)), .selection_end = @intCast(@min(@max(at, anchor) -| lo, hi - lo)) });
    } else if (d.panel.ax_body != 0) s.ax.note(.{ .widget = d.panel.ax_body, .role = .document, .target = target, .intent = .document_body, .label = "Document Preview", .value = visible, .focused = d.panel.focused and d.panel.field == .body and s.window_focused and (ctx.focus == 0 or ctx.focus == d.panel.ax_body), .caret = caret, .selection_start = @intCast(@min(start -| offset, visible.len)), .selection_end = @intCast(@min(end -| offset, visible.len)) });
}

pub fn composing(s: anytype, ctx: *ui.Context) bool {
    if (ctx.marked_text_id != 0 and ctx.focus == ctx.marked_text_id) return true;
    if (ctx.edits.getPtr(ctx.focus)) |edit| if (edit.marked != null) return true;
    if (ctx.focused_text) |field| if (field.marked != null) return true;
    for (ctx.input.ops) |op| if (op == .set_marked or op == .unmark) return true;
    return s.views[s.layout.active_pane].preedit.items.len != 0;
}

fn safeLabel(text: []const u8) []const u8 {
    var end = @min(255, text.len);
    while (end > 0 and end < text.len and text[end] & 0xc0 == 0x80) end -= 1;
    return text[0..end];
}

fn validateResize(s: anytype) void {
    if (!s.preview.resizing) return;
    const current = s.preview.active(tab(s));
    if (!s.window_focused or s.modalOpen() or current == null or current.?.id != s.preview.resize_document or tab(s) != s.preview.resize_tab) {
        for (s.preview.docks) |*dock| if (dock.tab_id == s.preview.resize_tab) {
            dock.width = s.preview.resize_original;
            break;
        };
        s.preview.resizing = false;
    }
}

fn insetCard(rect: ui.Rect) ui.Rect {
    const pad = @min(8, @min(rect.w, rect.h) / 2);
    return .{ .x = rect.x + pad, .y = rect.y + pad, .w = @max(0, rect.w - 2 * pad), .h = @max(0, rect.h - 2 * pad) };
}
