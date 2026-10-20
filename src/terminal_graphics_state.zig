//! A pane's renderer cache. The window Store and TextSystem outlive this value.
const std = @import("std");
const ui = @import("nanoui").ui;
const vt = @import("vt.zig");
const Session = @import("session.zig").Session;
const Config = @import("config.zig").Config;
const graphics = @import("terminal_graphics_view.zig");
const bridge = @import("nanoui_graphics_resources.zig");
pub const State = struct {
    renderer: ?graphics.View = null,
    store: ?*bridge.Store = null,
    error_name: ?[]const u8 = null,
    skipped: usize = 0,
    rejection_count: u64 = 0,

    pub fn deactivate(self: *State) void {
        if (self.renderer) |*renderer| renderer.deactivate();
        self.skipped = 0;
    }
    pub fn deinit(self: *State) void {
        if (self.renderer) |*renderer| renderer.deinit();
        self.* = .{};
    }
    pub fn active(self: *const State) bool {
        return if (self.renderer) |renderer| renderer.active and renderer.command_count > 0 else false;
    }
    /// Must run before the text frame opens. The owned snapshot is temporary;
    /// sync uploads copy pixels, and no VT/image borrow reaches a paint node.
    pub fn prepare(self: *State, s: *Session, ctx: *ui.Context, cfg: Config, cw: f32, ch: f32, rect: ui.Rect, store: *bridge.Store) !void {
        if (!cfg.kitty_graphics) {
            self.deactivate();
            return;
        }
        self.error_name = null;
        if (self.store != null and self.store.? != store) return error.ForeignGraphicsStore;
        if (store.text != ctx.text) return error.ForeignTextSystem;
        self.store = store;
        if (self.renderer == null) {
            const renderer = try store.initView(s.gpa, .{});
            self.renderer = renderer;
        }
        var snapshot: vt.GraphicsSnapshot = .{};
        defer snapshot.deinit(s.gpa);
        errdefer self.deactivate();
        try vt.captureGraphics(s.vt, s.gpa, &snapshot);
        const info = vt.graphicsInfo(s.vt);
        self.rejection_count = info.rejections;
        const stats = try self.renderer.?.sync(&snapshot, .{
            .viewport = .{ .x = cfg.padding_x[0], .y = cfg.padding_y[0], .width = @min(@as(f32, @floatFromInt(s.cols)) * cw, @max(0, rect.w - cfg.padding_x[0] - cfg.padding_x[1])), .height = @min(@as(f32, @floatFromInt(s.rows)) * ch, @max(0, rect.h - cfg.padding_y[0] - cfg.padding_y[1])) },
            .origin_x = cfg.padding_x[0],
            .origin_y = cfg.padding_y[0],
            .cell_width = cw,
            .cell_height = ch,
            .scale = ctx.scale,
        }, .{ .enabled = info.enabled, .visible = true, .epoch = info.epoch });
        self.skipped = stats.skipped + snapshot.skipped_images + snapshot.skipped_placements + snapshot.virtual_placements;
    }
    /// On any failed layer clear every resource before paint. Already enqueued
    /// image nodes resolve absent keys, so a partial image frame is not shown.
    pub fn layer(self: *State, ctx: *ui.Context, wanted: graphics.Layer) void {
        if (!self.active()) return;
        _ = self.store.?.drawLayer(&self.renderer.?, ctx, .parent_local, wanted) catch |err| {
            self.error_name = @errorName(err);
            self.deactivate();
        };
    }
};
