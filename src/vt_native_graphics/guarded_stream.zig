//! No APC parser is duplicated: the official Stream/Handler still interpret
//! every byte and execute every command. Only decoded APC dispatch is scoped.
const std = @import("std");
const ghostty = @import("ghostty-vt");
const model = @import("../graphics_model.zig");
const native = @import("../vt_native_graphics.zig");
pub const Quota = @import("soft_quota.zig").Quota;
pub const CoreHandler = ghostty.TerminalStream.Handler;
pub const Handler = struct {
    core: CoreHandler,
    quota: *Quota,
    osc52_active: bool = false,
    osc52_oversize: u64 = 0,
    pub fn init(terminal: *ghostty.Terminal, quota: *Quota) Handler {
        return .{ .core = .init(terminal), .quota = quota };
    }
    pub fn deinit(self: *Handler) void {
        self.core.deinit();
    }
    pub fn vt(self: *Handler, comptime action: ghostty.StreamAction.Tag, value: ghostty.StreamAction.Value(action)) void {
        switch (action) {
            .clipboard_contents => {
                // Upstream is still the only OSC parser/base64 decoder. Admit
                // <=64KiB decoded text before its temporary decode allocation.
                if (value.data.len > 4 * ((64 * 1024 + 2) / 3)) {
                    self.osc52_oversize +|= 1;
                    return;
                }
                self.osc52_active = true;
                defer self.osc52_active = false;
                self.core.vt(action, value);
            },
            .apc_start, .apc_put, .apc_put_slice, .apc_end => {
                const soft_before = self.quota.soft_epoch;
                const scope = self.quota.enterApc();
                defer scope.deinit();
                self.core.vt(action, value);
                if (comptime native.compiled) {
                    if (self.quota.soft_epoch != soft_before) {
                        // Upstream can retain storage.loading when appending a
                        // continuation chunk fails. Discard only that incomplete
                        // image: don't leave the pool pinned by an aborted upload.
                        // Completed resident images and the official parser state
                        // remain under upstream's normal protocol semantics.
                        const storage = &self.core.terminal.screens.active.kitty_images;
                        if (storage.loading) |loading| {
                            loading.destroy(self.core.terminal.gpa());
                            storage.loading = null;
                        }
                    }
                }
            },
            else => self.core.vt(action, value),
        }
    }
};
pub const Stream = ghostty.Stream(Handler);
/// Keep terminal, quota, and its child Audit at stable addresses. Effects remain
/// installed on stream.handler.core.effects and retain CoreHandler signatures.
pub fn init(terminal: *ghostty.Terminal, quota: *Quota) error{AllocatorMismatch}!Stream {
    if (Quota.fromAllocator(terminal.gpa()) != quota) return error.AllocatorMismatch;
    return .init(.{ .allocator = quota.allocator(), .handler = .init(terminal, quota) });
}
/// Apply outside feed; this is deliberately NOT native.configure(), whose old
/// standalone BudgetAllocator <=64MiB contract cannot describe the history-aware
/// allocator. No allocator identity swapping/unwrapping after allocation.
pub fn configure(stream: *Stream, enabled: bool) error{ Unsupported, AllocatorMismatch }!void {
    const terminal = stream.handler.core.terminal;
    if (Quota.fromAllocator(terminal.gpa()) != stream.handler.quota) return error.AllocatorMismatch;
    if (enabled and !native.compiled) return error.Unsupported;
    terminal.setKittyGraphicsLoadingLimits(.direct);
    terminal.setKittyGraphicsSizeLimit(terminal.gpa(), if (enabled) native.storage_bytes else 0);
    stream.handler.core.apc_handler.max_bytes.put(.kitty, if (enabled) model.max_png_input_bytes * 4 / 3 + 4096 else 4096);
    stream.handler.core.apc_handler.enable(.kitty, enabled and native.compiled);
    if (!enabled and std.meta.activeTag(stream.handler.core.apc_handler.state) == .kitty) {
        // start() releases the previous owned parser buffer, unlike enable().
        // Ignore the rest of an APC that was in flight during configuration;
        // the next official apc_start will re-enter identification normally.
        stream.handler.core.apc_handler.start();
        stream.handler.core.apc_handler.state = .ignore;
    }
}
