//! The official Ghostty stream parses every byte. Only APC dispatch receives
//! the separate graphics allocation quota; ordinary text retains core headroom.
const ghostty = @import("ghostty-vt");
pub const Quota = @import("graphics_quota.zig").Quota;
pub const Handler = struct {
    core: ghostty.TerminalStream.Handler,
    quota: *Quota,
    pub fn deinit(self: *Handler) void {
        self.core.deinit();
    }
    pub fn resize(self: *Handler, opts: ghostty.Terminal.Resize) !void {
        try self.core.resize(opts);
    }
    pub fn vt(self: *Handler, comptime action: ghostty.StreamAction.Tag, value: ghostty.StreamAction.Value(action)) void {
        switch (action) {
            .apc_start, .apc_put, .apc_put_slice, .apc_end => {
                const before = self.quota.soft_epoch;
                const scope = self.quota.enterApc();
                defer scope.deinit();
                self.core.vt(action, value);
                if (self.quota.soft_epoch != before) {
                    const storage = &self.core.terminal.screens.active.kitty_images;
                    if (storage.loading) |loading| {
                        loading.destroy(self.core.terminal.gpa());
                        storage.loading = null;
                    }
                }
            },
            else => self.core.vt(action, value),
        }
    }
};
pub const Stream = ghostty.Stream(Handler);
