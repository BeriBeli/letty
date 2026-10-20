//! Async CLIPBOARD/PRIMARY and one bounded, stable-target paste transaction.
const std = @import("std");
const builtin = @import("builtin");
const nano = @import("nanoui");
const ui = nano.ui;
const vt_api = @import("vt.zig");
const model = @import("clipboard_model.zig");
const Terminal = @import("terminal_view.zig").View;
extern "c" fn lt_clipboard_request_location(?*anyopaque, bool, *const fn (?*anyopaque, ?[*:0]const u8, ?*anyopaque) callconv(.c) void) c_int;
extern "c" fn lt_primary_write([*]const u8, usize) c_int;
pub fn request(s: anytype, ctx: *ui.Context, primary: bool) void {
    if (s.paste_session != null or s.paste_delivery != null or s.paste_transaction != null) {
        s.status = "A clipboard request or paste confirmation is pending";
        return;
    }
    const session = s.active() orelse return;
    const target = session.id;
    s.paste_session = target;
    if (s.clipboard_read_override) |reader| {
        if (!reader.call(reader.ctx, target, primary)) {
            s.paste_session = null;
            s.status = "Clipboard unavailable";
        }
        return;
    }
    if (builtin.os.tag == .linux) {
        const Callback = struct {
            state: @TypeOf(s),
            target: u64,
            fn received(_: ?*anyopaque, text: ?[*:0]const u8, data: ?*anyopaque) callconv(.c) void {
                const pending: *@This() = @ptrCast(@alignCast(data.?));
                const state = pending.state;
                const id = pending.target;
                defer state.release();
                defer state.gpa.destroy(pending);
                if (state.shutting_down) return;
                if (text) |bytes| {
                    var len: usize = 0;
                    while (len <= model.limit and bytes[len] != 0) len += 1;
                    if (len > model.limit) {
                        state.paste_session = null;
                        state.status = "Paste exceeds 1 MiB budget";
                    } else deliver(state, id, bytes[0..len]);
                } else {
                    state.paste_session = null;
                    state.status = "Clipboard contains no text";
                }
                if (state.window) |window| window.redraw();
            }
        };
        const pending = s.gpa.create(Callback) catch {
            s.paste_session = null;
            s.status = "Cannot allocate clipboard request";
            return;
        };
        pending.* = .{ .state = s, .target = target };
        s.retain();
        if (lt_clipboard_request_location(pending, primary, Callback.received) != 0) {
            s.gpa.destroy(pending);
            s.release();
            s.paste_session = null;
            s.status = "Clipboard unavailable";
        }
    } else {
        if (primary) {
            s.paste_session = null;
            s.status = "PRIMARY selection is only available on Linux";
            return;
        }
        const text = nano.clipboard.readText(s.gpa) catch {
            s.paste_session = null;
            s.status = "Clipboard unavailable";
            return;
        };
        if (text) |bytes| {
            defer s.gpa.free(bytes);
            deliver(s, target, bytes);
            ctx.changed = true;
        } else {
            s.paste_session = null;
            s.status = "Clipboard contains no text";
        }
    }
}
pub fn deliver(s: anytype, target: u64, text: []const u8) void {
    if (s.paste_session != target or s.shutting_down) return;
    s.paste_session = null;
    if (s.paste_delivery != null or s.paste_transaction != null) {
        s.status = "Discarded a duplicate clipboard response";
        return;
    }
    const bytes = model.normalize(s.gpa, text) catch {
        s.status = "Paste refused: size or allocation budget";
        return;
    };
    s.paste_delivery = .{ .target = target, .bytes = bytes };
    if (s.window) |window| window.redraw();
}
fn targetSession(s: anytype, id: u64) ?@TypeOf(s.sessions[0].?) {
    for (s.sessions) |opt| if (opt) |session| if (session.id == id) return session;
    return null;
}
pub fn process(s: anytype, ctx: *ui.Context) void {
    const pending = s.paste_delivery orelse return;
    const session = targetSession(s, pending.target) orelse {
        s.gpa.free(pending.bytes);
        s.paste_delivery = null;
        s.status = "Paste target has closed";
        return;
    };
    if (s.modalOpen()) return;
    s.paste_delivery = null;
    s.paste_transaction = pending;
    if (model.requiresConfirmation(s.cfg.paste_protection, s.cfg.bracketed_paste_safe, vt_api.lt_vt_bracketed(session.vt), pending.bytes)) {
        var preview: std.ArrayList(u8) = .empty;
        var preview_len = @min(4096, pending.bytes.len);
        while (preview_len > 0 and preview_len < pending.bytes.len and pending.bytes[preview_len] & 0xc0 == 0x80) preview_len -= 1;
        for (pending.bytes[0..preview_len]) |byte| {
            if ((byte < 0x20 and byte != '\n' and byte != '\t') or byte == 0x7f) preview.appendSlice(ctx.alloc(), ctx.print("\\x{x:0>2}", .{byte})) catch {} else preview.append(ctx.alloc(), byte) catch {};
        }
        s.confirmation.show(ctx, .paste, "Paste Multiple Lines or Controls?", ctx.print("Paste {d} bytes to Session {d}?\n\n{s}{s}", .{ pending.bytes.len, pending.target, preview.items, if (pending.bytes.len > 4096) "\n… preview truncated" else "" }), "Paste");
    } else finish(s, ctx, true);
}
pub fn finish(s: anytype, ctx: *ui.Context, accepted: bool) void {
    const pending = s.paste_transaction orelse return;
    s.paste_transaction = null;
    defer s.gpa.free(pending.bytes);
    if (!accepted) return;
    const session = targetSession(s, pending.target) orelse {
        s.status = "Paste target exited before confirmation";
        return;
    };
    if (!Terminal.paste(session, s.gpa, pending.bytes)) s.status = "Paste refused: input queue or 1 MiB budget";
    if (s.search_open) s.search_focus = true;
    ctx.changed = true;
}
pub fn copySelection(s: anytype, ctx: *ui.Context, session: anytype) void {
    if (s.cfg.copy_on_select == .none or !vt_api.lt_vt_has_selection(session.vt)) return;
    const buffer = ctx.alloc().alloc(u8, 1024 * 1024) catch return;
    var len: usize = 0;
    if (vt_api.lt_vt_copy(session.vt, buffer.ptr, buffer.len, &len) != 0) {
        s.status = "Selection exceeds 1 MiB copy budget";
        return;
    }
    if (s.cfg.copy_on_select == .clipboard or s.cfg.copy_on_select == .both) ctx.clipboard.write(ctx.clipboard.ctx, buffer[0..len]);
    if (s.cfg.copy_on_select == .primary or s.cfg.copy_on_select == .both) {
        if (s.primary_write_override) |writer| writer.call(writer.ctx, buffer[0..len]) else if (builtin.os.tag == .linux and lt_primary_write(buffer.ptr, len) != 0) s.status = "PRIMARY selection unavailable";
    }
}
