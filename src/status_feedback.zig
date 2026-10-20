//! Short success notices expire; rejected actions remain until their condition
//! changes. Unknown failures are deliberately persistent and dismissible.
const std = @import("std");
const timer = @import("one_shot.zig");
pub const Feedback = struct {
    observed: u64 = 0,
    handle: timer.Handle = .{},
    condition: ?@import("actions.zig").Request = null,
    condition_text: []const u8 = "",
    pub fn deinit(self: *Feedback) void {
        self.handle.cancel();
        self.handle = .{};
    }
    pub fn update(self: *Feedback, w: anytype, ctx: anytype) void {
        // These are prerequisites, not durable failures. Their originating
        // modal may close without another action replacing the notice.
        if ((std.mem.eql(u8, w.status, "Finish or cancel the current prompt first") and !w.modalOpen()) or
            (std.mem.eql(u8, w.status, "Finish or cancel the theme browser first") and !w.theme_browser.open) or
            (std.mem.eql(u8, w.status, "Select sidebar navigation in Settings first") and w.cfg.workspace_navigation == .sidebar)) w.status = "";
        if (self.condition) |request| {
            if (std.mem.eql(u8, w.status, self.condition_text)) {
                w.status = w.capabilities(ctx).disabled(request) orelse "";
                self.condition_text = w.status;
                if (w.status.len == 0) self.condition = null;
            } else self.condition = null;
        }
        const hash = std.hash.Wyhash.hash(0, w.status);
        if (hash == self.observed) return;
        self.observed = hash;
        self.deinit();
        if (!transient(w.status)) return;
        const Window = @typeInfo(@TypeOf(w)).pointer.child;
        self.handle = timer.start(4000, w, struct {
            fn fire(raw: ?*anyopaque) callconv(.c) void {
                const owner: *Window = @ptrCast(@alignCast(raw.?));
                owner.status_feedback.handle.fired();
                owner.status_feedback.handle = .{};
                if (owner.closing or owner.shutting_down) return;
                if (owner.status_feedback.observed == std.hash.Wyhash.hash(0, owner.status) and transient(owner.status)) owner.status = "";
                if (owner.window) |window| window.redraw();
            }
        }.fire) catch .{};
    }
};
pub fn transient(message: []const u8) bool {
    return std.mem.eql(u8, message, "Settings saved and applied") or
        std.mem.eql(u8, message, "Layout saved; restore creates fresh sessions") or
        std.mem.eql(u8, message, "Configuration reloaded") or
        std.mem.eql(u8, message, "Configuration applied");
}
