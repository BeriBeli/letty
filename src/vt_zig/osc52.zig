//! Only official OSC 52 dispatch enters this callback scope. Writes are copied
//! to a bounded queue; all OS/confirmation work occurs after feed has returned.
const std = @import("std");
const ghostty = @import("ghostty-vt");
const Context = @import("context.zig").Context;
const model = @import("../osc52_model.zig");
const Handler = ghostty.TerminalStream.Handler;
pub const Policy = model.Policy;
pub const Request = model.Request;
pub fn configure(v: *Context, policy: Policy) !void {
    if (!v.enter()) return v.fatal orelse error.VtUnavailable;
    defer v.leave();
    v.clipboard_state.configure(v.gpa, policy);
    v.stream.handler.core.effects.clipboard_write = if (policy == .deny) null else write;
    // Reads retain readonly null policy: synchronous consent is unsupported.
}
pub fn take(v: *Context, gpa: std.mem.Allocator) !?Request {
    if (!v.enter()) return v.fatal orelse error.VtUnavailable;
    defer v.leave();
    return v.clipboard_state.take(v.gpa, gpa) catch |err| {
        if (err == error.OutOfMemory) v.fail(err);
        return err;
    };
}
fn write(handler: *Handler, request: ghostty.clipboard.Write) void {
    const v: *Context = @alignCast(@fieldParentPtr("terminal", handler.terminal));
    // OSC 1337 and OSC 5522 also share the upstream effect; neither inherits
    // OSC 52 consent or returns a false success to a synchronous write protocol.
    if (!v.stream.handler.osc52_active or request.location != .standard) {
        request.reply(.unsupported);
        return;
    }
    const bytes: []const u8 = if (request.contents.len == 0) "" else bytes: {
        if (request.contents.len != 1 or !ghostty.clipboard.isTextMime(request.contents[0].mime)) {
            request.reply(.invalid_data);
            return;
        }
        break :bytes request.contents[0].data;
    };
    v.clipboard_state.queue(v.gpa, bytes) catch |err| {
        if (err == error.OutOfMemory) v.fail(err);
        request.reply(if (err == error.ClipboardWriteBusy) .busy else .denied);
        return;
    };
    // OSC 52 ignores acknowledgements. Do not claim a synchronous write: the
    // eventual explicit host policy/confirmation may still deny this request.
    request.reply(.denied);
}
