//! One owned thumbnail per window. Stale helper results cannot revive a closed hover.
const std = @import("std");
const ui = @import("nanoui").ui;
pub const State = struct {
    path: []const u8 = "",
    token: []const u8 = "",
    was_shown: bool = false,
    png: []const u8 = "",
    generation: u64 = 0,
    queued: bool = false,
    shown: bool = false,
    failed: bool = false,
    pane: u64 = 0,
    anchor: ui.Point = .{},
    stamp: i64 = 0,
    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        a.free(self.path);
        a.free(self.token);
        a.free(self.png);
        self.* = .{};
    }
    pub fn request(self: *State, a: std.mem.Allocator, path: []const u8, token: []const u8, pane: u64, stamp: i64) !bool {
        if (std.mem.eql(u8, self.path, path) and self.pane == pane and self.stamp == stamp) {
            if (!std.mem.eql(u8, self.token, token)) {
                const owned_token = try a.dupe(u8, token);
                a.free(self.token);
                self.token = owned_token;
            }
            return false;
        }
        const owned = try a.dupe(u8, path);
        errdefer a.free(owned);
        const owned_token = try a.dupe(u8, token);
        a.free(self.path);
        a.free(self.token);
        self.token = owned_token;
        a.free(self.png);
        self.path = owned;
        self.png = "";
        self.pane = pane;
        self.stamp = stamp;
        self.generation +%= 1;
        self.failed = false;
        self.queued = false;
        return true;
    }
    pub fn accept(self: *State, a: std.mem.Allocator, generation: u64, bytes: []const u8) !void {
        if (generation != self.generation) return;
        self.queued = false;
        if (bytes.len < 24 or bytes.len > 8 * 1024 * 1024 or !std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) {
            self.failed = true;
            return;
        }
        const w = std.mem.readInt(u32, bytes[16..20], .big);
        const h = std.mem.readInt(u32, bytes[20..24], .big);
        if (w == 0 or h == 0 or w > 1024 or h > 1024) {
            self.failed = true;
            return;
        }
        const owned = try a.dupe(u8, bytes);
        a.free(self.png);
        self.png = owned;
    }
    pub fn view(self: *State, ctx: *ui.Context) void {
        if (!self.shown or self.png.len == 0) return;
        const x = std.math.clamp(self.anchor.x, 8, @max(8, ctx.size.w - 380));
        const y = if (self.anchor.y + 300 < ctx.size.h) self.anchor.y + 18 else @max(8, self.anchor.y - 300);
        ui.column(ctx, .{ .absolute = true, .fixed = true, .layer = 25, .offset = .{ .x = x, .y = y }, .padding = .all(8), .gap = 6, .background = ctx.theme.surface, .border = ctx.theme.border, .radius = 10 });
        defer ui.end(ctx);
        const bytes = ctx.alloc().dupe(u8, self.png) catch return;
        _ = ui.image(ctx, .{ .key = ctx.print("peek-{d}-{d}", .{ self.pane, self.generation }), .bytes = bytes, .max_width = 360, .max_height = 260, .scale = 1 });
        ui.text(ctx, ctx.print("{s}", .{std.fs.path.basename(self.path)}), .{ .size = 11 });
    }
};
