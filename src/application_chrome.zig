//! Stable window-owned UI requests, drained outside native callbacks.
const ui = @import("nanoui").ui;
pub fn Runtime(comptime Window: type) type {
    return struct {
        const Self = @This();
        pub const Action = enum { preview, commands };
        const Pending = struct { action: Action, tab: u64, document: u64, generation: u64 };
        pending: ?Pending = null,
        pub fn enqueue(self: *Self, s: *Window, action: Action) void {
            if (s.closing or s.deinitialized or s.layout.tab_count == 0) return;
            const tab = s.layout.tabs[s.layout.active_tab].id;
            const d = s.preview.active(tab);
            self.pending = .{ .action = action, .tab = tab, .document = if (d) |v| v.id else 0, .generation = if (d) |v| v.panel.model.generation else 0 };
            if (s.window) |w| w.redraw();
        }
        pub fn drain(self: *Self, s: *Window, ctx: *ui.Context) void {
            const p = self.pending orelse return;
            self.pending = null;
            if (s.closing or s.deinitialized or s.modalOpen() or s.layout.tab_count == 0) return;
            if (s.layout.tabs[s.layout.active_tab].id != p.tab) return;
            const d = s.preview.active(p.tab);
            if ((if (d) |v| v.id else @as(u64, 0)) != p.document) return;
            if (d) |v| if (v.panel.model.generation != p.generation) return;
            if (@import("application_preview.zig").composing(s, ctx)) return;
            s.pending = .{ .action = if (p.action == .preview) .toggle_file_preview else .palette };
            s.perform(ctx);
        }
        pub fn detach(self: *Self) void {
            self.* = .{};
        }
    };
}
