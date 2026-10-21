//! Document edit commands run on stable owned documents; workers own no UI state.
const std = @import("std");
const nano = @import("nanoui");
const c = @import("platform_ffi.zig");
const Job = @import("preview/edit_job.zig").Job;
pub fn stop(d: anytype) void {
    if (d.edit_watch != 0) c.lt_unwatch(d.edit_watch);
    if (d.edit_mac_watch) |watch| watch.cancel();
    d.edit_watch = 0;
    d.edit_mac_watch = null;
}
pub fn process(_: anytype, ctx: *nano.ui.Context, d: anytype) void {
    if (d.edit_job) |job| {
        if (job.done.load(.acquire)) {
            stop(d);
            d.edit_job = null;
            d.panel.edit_busy = false;
            defer job.release();
            if (job.failure) |err| {
                d.panel.notice.set(if (err == error.ConcurrentChange) "File changed on disk. Draft kept; copy it or discard and reopen." else ctx.print("Cannot {s}: {s}. Draft kept.", .{ if (job.saving) "save" else "unlock", @errorName(err) }));
            } else if (job.saving) {
                if (d.panel.editor) |editor| editor.release();
                d.panel.editor = null;
                d.panel.mode = if (d.panel.model.kind == .markdown) .rendered else .source;
                d.panel.notice.set(if (job.directory_synced) "Saved" else "Saved; directory durability could not be confirmed");
                d.panel.model.refresh() catch {};
                ctx.focus = 0;
            } else if (job.editor) |editor| {
                // A file may change between the preview load and unlocking.
                if (d.panel.prepared != null and std.mem.eql(u8, editor.baseline, d.panel.prepared.?.source.text)) {
                    editor.retain();
                    d.panel.editor = editor;
                    d.panel.mode = .source;
                    d.panel.show_find = false;
                    d.panel.show_actions = false;
                    d.panel.field = .body;
                    d.panel.notice.set("");
                } else d.panel.notice.set("File changed before unlocking. Refresh and try again.");
            }
            ctx.changed = true;
        }
    }
    const request = d.panel.edit_request;
    d.panel.edit_request = .none;
    if (request == .none or d.panel.edit_busy) return;
    if (request == .discard) {
        if (d.panel.editor) |editor| editor.release();
        d.panel.editor = null;
        d.panel.notice.set("Changes discarded");
        d.panel.mode = if (d.panel.model.kind == .markdown) .rendered else .source;
        d.panel.model.refresh() catch {};
        ctx.focus = 0;
        ctx.changed = true;
        return;
    }
    if (request == .unlock and d.panel.editor != null) {
        if (d.panel.editor.?.dirty) {
            d.panel.notice.set("Unsaved changes — Save or Discard before locking.");
            return;
        }
        d.panel.editor.?.release();
        d.panel.editor = null;
        ctx.focus = 0;
        ctx.changed = true;
        return;
    }
    if (request == .save and d.panel.editor == null) return;
    if (request == .unlock and (d.panel.model.status != .ready or d.panel.model.kind == .image or d.panel.model.kind == .unsupported)) return;
    const job = Job.create(d.panel.model.path.text(), if (request == .save) d.panel.editor else null) catch |err| {
        d.panel.notice.set(ctx.print("Cannot start edit operation: {s}", .{@errorName(err)}));
        return;
    };
    d.edit_job = job;
    d.panel.edit_busy = true;
    d.panel.notice.set(if (job.saving) "Saving…" else "Unlocking…");
    const Callbacks = struct {
        fn ready(raw: ?*anyopaque) callconv(.c) void {
            const doc: @TypeOf(d) = @ptrCast(@alignCast(raw.?));
            stop(doc);
            if (doc.owner.window) |window| window.redraw();
        }
        fn linuxReady(_: c_int, _: c_uint, raw: ?*anyopaque) callconv(.c) c_int {
            ready(raw);
            return 0;
        }
    };
    if (@import("builtin").os.tag == .linux) d.edit_watch = c.lt_fd_watch(job.pipe[0], 1 | 8 | 16, Callbacks.linuxReady, d) else d.edit_mac_watch = nano.fdwatch.readable(job.pipe[0], d, Callbacks.ready) catch null;
    if (d.edit_watch == 0 and d.edit_mac_watch == null) {
        d.edit_job = null;
        d.panel.edit_busy = false;
        job.release();
        d.panel.notice.set("Cannot monitor file operation; draft retained.");
        return;
    }
    job.launch() catch {
        stop(d);
        d.edit_job = null;
        d.panel.edit_busy = false;
        job.release();
        d.panel.notice.set("Cannot start file worker; draft retained.");
        return;
    };
    ctx.changed = true;
}
pub fn blocked(s: anytype, target: ?u64) bool {
    for (s.preview.documents) |opt| if (opt) |d| {
        if (target != null and d.tab_id != target.?) continue;
        if (!d.panel.hasUnsaved()) continue;
        d.panel.notice.set(if (d.panel.edit_busy) "Wait for the file operation before closing." else "Unsaved changes — Save or Discard before closing.");
        s.status = "Document has unsaved changes or a file operation in progress";
        if (s.layout.tabIndex(d.tab_id)) |index| s.activateTab(index);
        @import("application_preview.zig").activate(s, d);
        if (s.window) |window| window.redraw();
        return true;
    };
    return false;
}
pub fn guardClose(s: anytype, scope: @import("close_request.zig").Scope) bool {
    const tab_id = if (s.layout.tab_count > 0) s.layout.tabs[s.layout.active_tab].id else 0;
    for (s.host.windows) |opt| if (opt) |w| {
        if (scope != .quit and w != s) continue;
        if (scope == .window or scope == .quit) {
            if (blocked(w, null)) return false;
        } else if (scope == .others) {
            for (w.preview.documents) |doc| if (doc) |d| if (d.tab_id != tab_id and blocked(w, d.tab_id)) return false;
        } else if (blocked(w, tab_id)) return false;
    };
    return true;
}

/// Revalidate the captured close targets, even if focus changed during a dialog.
pub fn guardPending(s: anytype, pending: @import("close_request.zig").Pending) bool {
    if (pending.scope == .window or pending.scope == .quit) return guardClose(s, pending.scope);
    for (pending.document_tabs[0..pending.document_count]) |id| if (blocked(s, id)) return false;
    for (s.host.windows) |opt| if (opt) |w| for (w.sessions, 0..) |session, slot| if (session) |item| {
        if (!pending.contains(item.id)) continue;
        for (w.layout.roots[0..w.layout.tab_count], 0..) |root, index| {
            if (w.layout.contains(root, @intCast(slot)) and blocked(w, w.layout.tabs[index].id)) return false;
        }
    };
    return true;
}
