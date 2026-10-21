//! Config opening/diagnostics and stable-ID close transactions. No UI window ownership.
const std = @import("std");
const builtin = @import("builtin");
const nano = @import("nanoui");
const ui = nano.ui;
const vt_api = @import("vt.zig");
const c = @import("platform_ffi.zig");
const config = @import("config.zig");
const close = @import("close_request.zig");
const Request = @import("actions.zig").Request;
const sample = "# Letty configuration\nfont-family = Maple Mono Normal NL NF CN\ntheme = paper\nfont-size = 14\n";
pub fn handle(s: anytype, ctx: *ui.Context, request: Request) bool {
    switch (request.action) {
        .close, .close_tab, .close_other_tabs, .close_window, .quit => {
            requestClose(s, ctx, switch (request.action) {
                .close => .pane,
                .close_tab => .tab,
                .close_other_tabs => .others,
                .close_window => .window,
                .quit => .quit,
                else => unreachable,
            });
        },
        .open_config => openConfig(s, ctx),
        .open_link => if (@import("url.zig").allowed(s.link_target.text()))
            openTarget(s, ctx, s.link_target.text(), true)
        else
            @import("application_preview.zig").openTerminalPath(s, s.link_target.text(), s.link_session),
        .copy_link => ctx.clipboard.write(ctx.clipboard.ctx, s.link_target.text()),
        .diagnostics => diagnostics(s, ctx),
        .inspector => {
            if (s.inspector.open) s.inspector.close(ctx) else if (s.active()) |session| s.inspector.show(ctx, session);
        },
        .search_selection => if (s.active()) |session| {
            var text: [1024]u8 = undefined;
            var len: usize = 0;
            if (vt_api.lt_vt_copy(session.vt, &text, text.len, &len) != 0) {
                s.status = "Selection is empty or exceeds 1024 bytes";
                return true;
            }
            s.query.set(text[0..len]);
            s.search_open = true;
            s.search_focus = true;
            s.last_query.clearRetainingCapacity();
        },
        else => return false,
    }
    return true;
}
pub fn requestClose(s: anytype, ctx: *ui.Context, scope: close.Scope) void {
    if (!@import("application_preview_edit.zig").guardClose(s, scope)) return;
    if (scope == .quit and !s.host.settings.guardQuit()) return;
    const refs = ctx.alloc().alloc(close.Ref, s.host.paneCount()) catch {
        s.status = "Cannot allocate close request";
        return;
    };
    var count: usize = 0;
    for (s.host.windows) |window_opt| if (window_opt) |w| {
        if (scope != .quit and w != s) continue;
        for (w.sessions, 0..) |opt, slot| if (opt) |session| {
            var tab_id: u64 = 0;
            for (w.layout.roots[0..w.layout.tab_count], 0..) |root, index| if (w.layout.contains(root, @intCast(slot))) {
                tab_id = w.layout.tabs[index].id;
                break;
            };
            refs[count] = .{ .id = session.id, .tab = tab_id };
            count += 1;
        };
    };
    const active_id = if (s.active()) |session| session.id else 0;
    const tab_id = if (s.layout.tab_count > 0) s.layout.tabs[s.layout.active_tab].id else 0;
    var pending = close.Pending.capture(scope, tab_id, active_id, refs[0..count]) catch {
        s.status = "Cannot allocate close request";
        return;
    };
    pending.document_tabs = std.heap.page_allocator.alloc(u64, s.layout.tab_count) catch {
        pending.deinit();
        s.status = "Cannot allocate close request";
        return;
    };
    s.close_pending.deinit();
    s.close_pending = pending;
    if (scope == .pane or scope == .tab or scope == .others) for (s.layout.tabs[0..s.layout.tab_count], 0..) |workspace, index| {
        if (!s.layout.isDocument(index)) continue;
        if ((scope == .others and workspace.id == tab_id) or (scope != .others and workspace.id != tab_id)) continue;
        s.close_pending.document_tabs[s.close_pending.document_count] = workspace.id;
        s.close_pending.document_count += 1;
    };
    if (s.close_pending.count == 0 or s.cfg.confirm_close == .never) {
        executeClose(s);
        return;
    }
    var uncertain = false;
    var busy: usize = 0;
    var names: []const u8 = "";
    for (s.host.windows) |window_opt| if (window_opt) |w| for (w.sessions) |opt| if (opt) |session| if (s.close_pending.contains(session.id)) {
        uncertain = uncertain or !session.idle();
        if (c.lt_foreground_state(session.fd, if (session.shell_group > 0) session.shell_group else session.pid) > 0) busy += 1;
        names = ctx.print("{s}\nWindow {d}, Session {d}, PID {d}: {s}", .{ names, w.id, session.id, session.pid, session.title[0..session.title_len] });
    };
    if (!uncertain and s.cfg.confirm_close != .always) {
        executeClose(s);
        return;
    }
    const description = ctx.print("Close {d} terminal session(s)?\n\n{d} foreground task(s) detected. Other sessions may have running tasks.\n\nCancel keeps every process and window open.\n{s}", .{ s.close_pending.count, busy, names });
    s.confirmation.show(ctx, .close_sessions, "Close Terminal Sessions?", description, "Close Sessions");
}
pub fn executeClose(s: anytype) void {
    var pending = s.close_pending;
    defer pending.deinit();
    s.close_pending = .{};
    if (!@import("application_preview_edit.zig").guardPending(s, pending)) return;
    if (pending.scope == .quit) {
        for (s.host.windows) |window_opt| if (window_opt) |w| for (w.sessions) |opt| if (opt) |session| if (!pending.contains(session.id)) {
            s.status = "Sessions changed during confirmation; request Quit again";
            return;
        };
        s.host.save();
        s.host.quitting = true;
    }
    for (pending.ids[0..pending.count]) |id| {
        for (s.host.windows) |window_opt| if (window_opt) |w| {
            for (w.sessions, 0..) |opt, slot| if (opt) |session| if (session.id == id) {
                w.close(@intCast(slot));
                break;
            };
        };
    }
    for (pending.document_tabs[0..pending.document_count]) |tab_id| {
        if (s.preview.active(tab_id)) |d| s.preview.close(s, d.id);
    }
    if (pending.scope == .window) s.host.closeWindow(s);
    if (pending.scope == .quit) s.app.quit();
}

fn resolvedPath(s: anytype, ctx: *ui.Context) ?[:0]const u8 {
    const selected = config.selectPath(ctx.alloc(), s.explicit_config) catch {
        s.status = "Cannot resolve configuration path";
        return null;
    };
    const z = ctx.alloc().dupeSentinel(u8, selected, 0) catch return null;
    const buffer = ctx.alloc().alloc(u8, 4096) catch return null;
    if (c.lt_absolute_path(z, buffer.ptr, buffer.len) != 0) {
        s.status = "Cannot resolve absolute configuration path";
        return null;
    }
    return std.mem.sliceTo(@as([*:0]u8, @ptrCast(buffer.ptr)), 0);
}
pub fn openConfig(s: anytype, ctx: *ui.Context) void {
    const path = resolvedPath(s, ctx) orelse return;
    if (config.exists(path)) {
        openPath(s, ctx, path);
        return;
    }
    if (s.config_create_path) |old| s.gpa.free(old);
    s.config_create_path = s.gpa.dupeSentinel(u8, path, 0) catch {
        s.status = "Cannot allocate configuration path";
        return;
    };
    s.confirmation.show(ctx, .create_config, "Create Configuration?", ctx.print("No configuration exists at:\n{s}\n\nCreate a starter configuration, then open it in the system editor?", .{path}), "Create & Open");
}
pub fn diagnostics(s: anytype, ctx: *ui.Context) void {
    const d = &s.config_diagnostic;
    const path = if (d.path_len > 0) d.path[0..d.path_len] else resolvedPath(s, ctx) orelse "Unavailable";
    const body = if (d.reason_len > 0) ctx.print("{s}\nLine: {d}\nKey: {s}\nReason: {s}\n\nIncluded from:\n{s}{s}\nThe previous working configuration and PTYs remain active.", .{ path, d.line, d.key[0..d.key_len], d.reason[0..d.reason_len], d.chain[0..d.chain_len], if (d.chain_truncated) "[include chain truncated]\n" else "" }) else ctx.print("Configuration path:\n{s}\n\nNo configuration errors recorded.", .{path});
    s.confirmation.show(ctx, .diagnostics, "Configuration Diagnostics", body, "Open Config");
}
pub fn resolveDialog(s: anytype, ctx: *ui.Context) void {
    const kind = s.confirmation.kind;
    const generation = s.confirmation.generation;
    switch (s.confirmation.draw(ctx)) {
        .none => {},
        .copy => ctx.clipboard.write(ctx.clipboard.ctx, s.confirmation.body.text()),
        .cancel => {
            if (kind == .paste) @import("clipboard.zig").finish(s, ctx, false);
            if (kind == .osc52_write) @import("application_osc52.zig").finish(s, ctx, false, generation);
            s.close_pending.deinit();
            clearCreate(s);
        },
        .accept => {
            s.confirmation.dismiss(ctx);
            switch (kind) {
                .close_sessions => executeClose(s),
                .paste => @import("clipboard.zig").finish(s, ctx, true),
                .osc52_write => @import("application_osc52.zig").finish(s, ctx, true, generation),
                .drop_preview => {},
                .target_error => openTarget(s, ctx, s.link_target.text(), true),
                .diagnostics => openConfig(s, ctx),
                .create_config => {
                    const path = s.config_create_path orelse return;
                    const rc = c.lt_create_config(path, sample, sample.len);
                    if (rc < 0) s.status = "Cannot create configuration; check directory permissions" else openPath(s, ctx, path);
                    clearCreate(s);
                },
            }
        },
    }
}
fn clearCreate(s: anytype) void {
    if (s.config_create_path) |path| s.gpa.free(path);
    s.config_create_path = null;
}
pub fn openPath(s: anytype, ctx: *ui.Context, path: []const u8) void {
    openTarget(s, ctx, path, false);
}
pub fn openTarget(s: anytype, ctx: *ui.Context, path: []const u8, is_url: bool) void {
    if (is_url and !@import("url.zig").allowed(path)) {
        s.status = "Only valid HTTP(S) links can be opened";
        return;
    }
    if (builtin.os.tag == .linux and s.opener_watch != 0) {
        s.status = "An opener request is still pending";
        return;
    }
    s.opener_is_url = is_url;
    if (s.opener_override) |opener| {
        if (!opener.call(opener.ctx, path)) showOpenerFailure(s, ctx, path, "System editor unavailable");
        return;
    }
    if (builtin.os.tag == .macos) {
        if (!(if (is_url) nano.shell.openUrl(path) else nano.shell.openPath(path))) {
            showOpenerFailure(s, ctx, path, if (is_url) "No browser accepted this link" else "No system editor accepted this file");
        }
    } else {
        if (s.opener_watch != 0) {
            s.status = "An opener request is still pending";
            return;
        }
        const z = ctx.alloc().dupeSentinel(u8, path, 0) catch return;
        var pid: c_int = 0;
        if (c.lt_launch_opener(z, &pid) != 0) {
            showOpenerFailure(s, ctx, path, "xdg-open is unavailable");
            return;
        }
        s.opener_target.set(path);
        const Handler = struct {
            fn done(_: c_int, status: c_int, data: ?*anyopaque) callconv(.c) void {
                const state: @TypeOf(s) = @ptrCast(@alignCast(data.?));
                state.opener_watch = 0;
                if (status != 0) state.opener_failed = true;
                if (state.window) |window| window.redraw();
            }
        };
        s.opener_watch = c.lt_child_watch(pid, Handler.done, s);
        if (s.opener_watch == 0) s.status = "Could not watch xdg-open completion";
    }
}

pub fn showOpenerFailure(s: anytype, ctx: *ui.Context, path: []const u8, reason: []const u8) void {
    if (s.opener_is_url) s.link_target.set(path);
    s.confirmation.show(ctx, if (s.opener_is_url) .target_error else .diagnostics, if (s.opener_is_url) "Cannot Open Link" else "Cannot Open Configuration", ctx.print("{s}\n\nPath:\n{s}\n\nUse Copy Details to copy this path.", .{ reason, path }), "Retry");
}
