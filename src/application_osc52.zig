//! OSC 52 write delivery happens only after VT parsing. Confirmation holds an
//! owned payload and stable Session ID; it never holds an upstream reply token.
const std = @import("std");
const ui = @import("nanoui").ui;
const vt = @import("vt.zig");
const model = @import("osc52_model.zig");
pub const Pending = struct { target: u64, request: model.Request, generation: u64 };
pub fn deinit(s: anytype) void {
    if (s.osc52_pending) |pending| s.gpa.free(pending.request.bytes);
    s.osc52_pending = null;
}
fn find(s: anytype, id: u64) ?@TypeOf(s.sessions[0].?) {
    for (s.sessions) |entry| if (entry) |session| if (session.id == id and !session.closing and !session.fatal and !session.eof) return session;
    return null;
}
pub fn process(s: anytype, ctx: *ui.Context) void {
    if (s.osc52_pending) |pending| {
        if (find(s, pending.target) == null or s.cfg.clipboard_write != pending.request.policy or !s.confirmation.open or s.confirmation.kind != .osc52_write or s.confirmation.generation != pending.generation) {
            deinit(s);
            if (s.confirmation.kind == .osc52_write and s.confirmation.open) s.confirmation.dismiss(ctx);
            if (s.status.len == 0) s.status = "Clipboard write cancelled: source, policy or prompt changed";
        }
        return;
    }
    if (s.modalOpen() or s.cfg.clipboard_write == .deny) return;
    for (s.sessions) |entry| if (entry) |session| {
        if (find(s, session.id) == null) continue;
        const request = (vt.takeClipboardWrite(session.vt, s.gpa) catch |err| {
            s.status = @errorName(err);
            if (err == error.OutOfMemory) session.renderFailed();
            return;
        }) orelse continue;
        if (request.policy != s.cfg.clipboard_write) {
            s.gpa.free(request.bytes);
            continue;
        }
        if (request.policy == .allow) {
            ctx.clipboard.write(ctx.clipboard.ctx, request.bytes);
            s.gpa.free(request.bytes);
            s.status = "OSC 52 wrote the clipboard";
            return;
        }
        var preview: std.ArrayList(u8) = .empty;
        var end = @min(1024, request.bytes.len);
        while (end > 0 and end < request.bytes.len and request.bytes[end] & 0xc0 == 0x80) end -= 1;
        for (request.bytes[0..end]) |byte| {
            if ((byte < 0x20 and byte != '\n' and byte != '\t') or byte == 0x7f)
                preview.appendSlice(ctx.alloc(), ctx.print("\\x{x:0>2}", .{byte})) catch {}
            else
                preview.append(ctx.alloc(), byte) catch {};
        }
        s.confirmation.show(ctx, .osc52_write, "Terminal requests clipboard write", ctx.print("Source: Session {d} ({s})\nWrite {d} bytes to CLIPBOARD?\n\n{s}{s}", .{ session.id, if (session.title_len > 0) session.title[0..session.title_len] else "terminal", request.bytes.len, preview.items, if (end < request.bytes.len) "\n… preview truncated" else "" }), "Write Clipboard");
        s.osc52_pending = .{ .target = session.id, .request = request, .generation = s.confirmation.generation };
        return;
    };
}
pub fn finish(s: anytype, ctx: *ui.Context, accepted: bool, generation: u64) void {
    const pending = s.osc52_pending orelse return;
    s.osc52_pending = null;
    defer s.gpa.free(pending.request.bytes);
    if (!accepted) return;
    if (generation != pending.generation) {
        s.status = "Clipboard write cancelled: confirmation changed";
        return;
    }
    if (find(s, pending.target) == null or s.cfg.clipboard_write != pending.request.policy) {
        s.status = "Clipboard write cancelled: source closed or policy changed";
        return;
    }
    ctx.clipboard.write(ctx.clipboard.ctx, pending.request.bytes);
    s.status = "OSC 52 wrote the clipboard";
    ctx.changed = true;
}
