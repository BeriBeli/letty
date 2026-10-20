//! Settings-only overlay scrollbar. Idle frames are scheduled, never polled.
//! Keep offsets in Context so keyboard/AX reveal shares the same coordinates.
const std = @import("std");
const ui = @import("nanoui").ui;
pub const Area = struct {
    id: u64 = 0,
    content_id: u64 = 0,
    viewport: ui.Rect = .{},
    maximum: f32 = 0,
    offset: f32 = 0,
    alpha: f32 = 0,
    active_at: ?f64 = null,
    dragging: bool = false,
    grab: f32 = 0,
    mouse: ui.Point = .{ .x = -1e6, .y = -1e6 },
    input_frame: ?u64 = null,
    pub fn begin(self: *Area, ctx: *ui.Context, id: u64, gap: f32) void {
        if (self.id != id) self.* = .{ .id = id };
        self.viewport = ctx.rects.get(id) orelse .{};
        const content: ui.Rect = ctx.rects.get(self.content_id) orelse .{};
        self.maximum = @max(0, content.h - self.viewport.h);
        var position = std.math.clamp(ctx.scroll.get(id) orelse 0, 0, self.maximum);
        ctx.wants_moves = true;
        ctx.wants_wheel = true;
        const edge: ui.Rect = .{ .x = self.viewport.x + self.viewport.w - 12, .y = self.viewport.y, .w = 12, .h = self.viewport.h };
        const moved = ctx.input.mouse.x != self.mouse.x or ctx.input.mouse.y != self.mouse.y;
        if (position != self.offset) self.active_at = ctx.time;
        if (self.input_frame != ctx.frame) {
            self.input_frame = ctx.frame;
            if (self.viewport.contains(ctx.input.mouse) and ctx.input.scroll.y != 0) {
                position = std.math.clamp(position - ctx.input.scroll.y, 0, self.maximum);
                self.active_at = ctx.time;
                ctx.input.scroll.y = 0;
                ctx.changed = true;
            }
            if (self.maximum > 0 and moved and edge.contains(ctx.input.mouse)) self.active_at = ctx.time;
            if (self.maximum > 0 and ctx.input.pressed and ctx.input.mouse_button == 1 and edge.contains(ctx.input.mouse)) {
                const indicator = self.thumb(position);
                self.dragging = true;
                self.grab = if (indicator.contains(ctx.input.mouse)) ctx.input.mouse.y - indicator.y else indicator.h / 2;
                self.active_at = ctx.time;
            }
            if (self.dragging) {
                if (ctx.input.released or !ctx.input.down) {
                    self.dragging = false;
                } else {
                    const indicator = self.thumb(position);
                    position = std.math.clamp((ctx.input.mouse.y - self.viewport.y - self.grab) / @max(1, self.viewport.h - indicator.h), 0, 1) * self.maximum;
                }
                self.active_at = ctx.time;
                ctx.input.pressed = false;
                ctx.input.released = false;
                ctx.changed = true;
            }
            self.mouse = ctx.input.mouse;
        }
        self.offset = position;
        ctx.scroll.put(ctx.gpa, id, position) catch {};
        self.alpha = 0;
        if (self.maximum > 0) if (self.active_at) |at| {
            const idle = @max(0, ctx.time - at);
            self.alpha = if (idle <= 1.2) 1 else @floatCast(std.math.clamp(1 - (idle - 1.2) / 0.2, 0, 1));
            if (!self.dragging) {
                if (idle < 1.2) ctx.frameIn(@floatCast(1.2 - idle)) else if (self.alpha > 0) ctx.animationFrame();
            }
        };
        ui.column(ctx, .{ .width = .fill, .height = .fill, .clip = true });
        ui.key(ctx, "scroll-content");
        self.content_id = ctx.peekId(null);
        ui.column(ctx, .{ .absolute = true, .offset = .{ .y = -position }, .width = .fill, .padding = .{ .right = 10 }, .gap = gap });
        if (self.viewport.h == 0) ctx.frameIn(0);
    }
    pub fn end(self: *Area, ctx: *ui.Context) void {
        ui.end(ctx);
        if (self.alpha > 0 and self.maximum > 0) {
            const r = self.thumb(self.offset);
            _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = r.x - self.viewport.x, .y = r.y - self.viewport.y }, .width = .{ .px = r.w }, .height = .{ .px = r.h }, .radius = 2, .background = ctx.theme.muted.alpha(0.5 * self.alpha) }, .none, null);
        }
        ui.end(ctx);
    }
    pub fn thumb(self: *const Area, position: f32) ui.Rect {
        const h = @min(self.viewport.h, @max(24, self.viewport.h * self.viewport.h / @max(1, self.maximum + self.viewport.h)));
        return .{ .x = self.viewport.x + self.viewport.w - 6, .y = self.viewport.y + (self.viewport.h - h) * position / @max(1, self.maximum), .w = 4, .h = h };
    }
};
