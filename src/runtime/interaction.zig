//! Local terminal selection and incremental history search, owned by the VT.
const std = @import("std");
const ghostty = @import("ghostty-vt");
pub const Interaction = struct {
    gesture: ghostty.SelectionGesture = .init,
    search: ?ghostty.search.Terminal = null,
    searched_revision: u64 = std.math.maxInt(u64),
    dragging: bool = false,
    pub const boundaries: []const u21 = &.{ ' ', '\t', '"', '\'', '`', '|', '(', ')', '[', ']', '{', '}', '<', '>' };

    pub fn deinit(self: *Interaction, t: *ghostty.Terminal) void {
        self.gesture.deinit(t);
        self.endFind(t);
    }
    pub fn find(self: *Interaction, a: std.mem.Allocator, t: *ghostty.Terminal, query: []const u8) !void {
        if (query.len > 4096 or !std.unicode.utf8ValidateSlice(query)) return error.SearchLimit;
        if (self.search) |*s| if (std.mem.eql(u8, s.needle(), query)) return;
        var replacement = if (query.len > 0) try ghostty.search.Terminal.init(a, query) else null;
        errdefer if (replacement) |*s| s.deinit(t);
        self.endFind(t);
        self.search = replacement;
        self.searched_revision = std.math.maxInt(u64);
    }
    pub fn endFind(self: *Interaction, t: *ghostty.Terminal) void {
        if (self.search) |*s| s.deinit(t);
        self.search = null;
    }
    /// One bounded native search tick per wake. No search timer at idle.
    pub fn step(self: *Interaction, t: *ghostty.Terminal, revision: u64) bool {
        const s = if (self.search) |*v| v else return false;
        if (self.searched_revision != revision) {
            s.feed(t, true);
            self.searched_revision = revision;
        } else if (s.status() == .feed_required) s.feed(t, false);
        _ = s.tick();
        return s.status() != .complete;
    }
    pub fn next(self: *Interaction, t: *ghostty.Terminal, backwards: bool) !void {
        const s = if (self.search) |*v| v else return;
        _ = try s.select(t, if (backwards) .prev else .next, .if_needed);
    }
    pub fn count(self: *Interaction) usize {
        if (self.search) |*s| if (s.activeScreenSearch()) |screen| return screen.matchesLen();
        return 0;
    }
    pub fn selected(self: *Interaction) usize {
        if (self.search) |*s| if (s.activeScreenSearch()) |screen| if (screen.selected) |m| return m.idx + 1;
        return 0;
    }
    pub fn press(self: *Interaction, t: *ghostty.Terminal, x: u16, y: u16, pixels: [2]f32, cell_width: f32, now_ms: i64) !void {
        const pin = t.screens.active.pages.pin(.{ .viewport = .{ .x = x, .y = y } }) orelse return;
        const selection = try self.gesture.press(t, .{ .time = .{ .nanoseconds = @as(i96, now_ms) * std.time.ns_per_ms }, .pin = pin, .xpos = pixels[0], .ypos = pixels[1], .max_distance = cell_width, .repeat_interval = 500 * std.time.ns_per_ms, .word_boundary_codepoints = boundaries });
        try t.screens.active.select(selection);
        self.dragging = true;
    }
    pub fn drag(self: *Interaction, t: *ghostty.Terminal, x: u16, y: u16, pixels: [2]f32, cell_width: f32, cell_height: f32, rectangle: bool) !void {
        if (!self.dragging) return;
        const pin = t.screens.active.pages.pin(.{ .viewport = .{ .x = x, .y = y } }) orelse return;
        if (self.gesture.drag(t, .{ .pin = pin, .xpos = pixels[0], .ypos = pixels[1], .rectangle = rectangle, .word_boundary_codepoints = boundaries, .geometry = .{ .columns = t.cols, .cell_width = @intFromFloat(@max(1, cell_width)), .padding_left = 0, .screen_height = @intFromFloat(@max(1, @as(f32, @floatFromInt(t.rows)) * cell_height)) } })) |selection| try t.screens.active.select(selection);
    }
    pub fn release(self: *Interaction, t: *ghostty.Terminal, x: u16, y: u16) void {
        self.gesture.release(t, .{ .pin = t.screens.active.pages.pin(.{ .viewport = .{ .x = x, .y = y } }) });
        self.dragging = false;
    }
    pub fn text(_: *Interaction, a: std.mem.Allocator, t: *ghostty.Terminal) !?[:0]const u8 {
        const screen = t.screens.active;
        const selection = screen.selection orelse return null;
        return try screen.selectionString(a, .{ .sel = selection });
    }
};

test "native selection retains Unicode and soft wrapped text; search covers history and resize" {
    const a = std.testing.allocator;
    var t = try ghostty.Terminal.init(std.testing.io, a, .{ .cols = 12, .rows = 3, .max_scrollback_bytes = 1024 * 1024 });
    defer t.deinit(a);
    var stream = t.vtStream();
    defer stream.deinit();
    var i: Interaction = .{};
    defer i.deinit(&t);
    stream.nextSlice("one needle\r\n中文 e\xcc\x81\r\nsecond needle\r\ntail\r\n");
    try t.screens.active.select(t.screens.active.selectAll());
    const copied = (try i.text(a, &t)).?;
    defer a.free(copied);
    try std.testing.expect(std.mem.indexOf(u8, copied, "中文 e\xcc\x81") != null);
    try std.testing.expect(std.mem.indexOf(u8, copied, "second needle") != null);
    try i.find(a, &t, "needle");
    var ticks: usize = 0;
    while (i.step(&t, 0) and ticks < 256) : (ticks += 1) {}
    try std.testing.expect(ticks < 256);
    try std.testing.expectEqual(@as(usize, 2), i.count());
    try i.next(&t, false);
    try std.testing.expect(i.selected() > 0);
    try stream.handler.resize(.{ .cols = 20, .rows = 4 });
    ticks = 0;
    while (i.step(&t, 1) and ticks < 256) : (ticks += 1) {}
    try std.testing.expectEqual(@as(usize, 2), i.count());
    i.endFind(&t);
    try std.testing.expect(i.search == null);
}
