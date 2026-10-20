//! Window display/interaction state only. Tab order/identity stay in Layout.
const std = @import("std");
pub const geometry = @import("geometry.zig");
const snapshot = @import("snapshot.zig");
pub const header_height: f32 = 44;
pub const footer_height: f32 = 30;
pub const section_height: f32 = 22;
pub const row_height: f32 = 56;
pub const Drag = struct { id: u64, origin_y: f32, target: ?usize = null, moved: bool = false };
pub const Resize = struct { origin_x: f32, original_width: f32 };
pub const State = struct {
    width: f32 = geometry.default_width,
    collapsed: bool = false,
    compact: bool = false,
    focused: bool = false,
    scroll: f32 = 0,
    snapshot: snapshot.Snapshot = .{},
    seen: []snapshot.Seen = &.{},
    dragging: ?Drag = null,
    resizing: ?Resize = null,
    selected: u64 = 0,
    last_active: u64 = 0,
    last_active_index: usize = 0,
    last_rects: geometry.Rects = .{},
    have_rects: bool = false,
    input_frame: ?u64 = null,
    pub fn deinit(self: *State) void {
        @import("../dynamic_storage.zig").release(snapshot.Row, &self.snapshot.rows);
        @import("../dynamic_storage.zig").release(snapshot.Seen, &self.seen);
    }
    pub fn cancel(self: *State) void {
        if (self.resizing) |r| self.width = r.original_width;
        self.dragging = null;
        self.resizing = null;
        self.focused = false;
    }
    pub fn toggle(self: *State) void {
        self.cancel();
        self.collapsed = !self.collapsed;
    }
    pub fn refresh(self: *State, s: anytype) bool {
        @import("../dynamic_storage.zig").ensure(snapshot.Seen, &self.seen, s.sessions.len, .{}) catch return false;
        return self.snapshot.refresh(s, self.seen);
    }
    pub fn acknowledge(self: *State, s: anytype, tab: usize) void {
        if (tab >= s.layout.tab_count) return;
        @import("../dynamic_storage.zig").ensure(snapshot.Seen, &self.seen, s.sessions.len, .{}) catch return;
        for (s.sessions, 0..) |opt, slot| if (opt) |session| {
            if (s.layout.contains(s.layout.roots[tab], @intCast(slot))) self.seen[slot] = .{ .session = session.id, .bells = session.events.bells };
        };
    }
    pub fn sectionStart(self: *const State, index: usize) bool {
        return (index == 0 and self.snapshot.rows[index].pinned) or (index > 0 and self.snapshot.rows[index - 1].pinned != self.snapshot.rows[index].pinned);
    }
    pub fn rowOffset(self: *const State, index: usize) f32 {
        if (self.compact) return @as(f32, @floatFromInt(index)) * 40;
        var y: f32 = 0;
        for (0..@min(index + 1, self.snapshot.count)) |i| {
            if (self.sectionStart(i)) y += section_height;
            if (i < index) y += self.rowHeight(i);
        }
        return y;
    }
    pub fn rowHeight(self: *const State, index: usize) f32 {
        if (self.compact) return 40;
        const row = &self.snapshot.rows[index];
        return row_height + (if (hasStatus(row)) @as(f32, 18) else 0) + (if (row.git.len > 0) @as(f32, 16) else 0) + (if (row.ports.len > 0) @as(f32, 16) else 0);
    }
    pub fn listRect(self: *const State, nav: geometry.Rect) geometry.Rect {
        return .{ .x = nav.x, .y = nav.y + @min(nav.h, header_height), .w = nav.w, .h = @max(0, nav.h - header_height - (if (self.compact) @as(f32, 80) else footer_height)) };
    }
    pub fn rowRect(self: *const State, index: usize, nav: geometry.Rect) geometry.Rect {
        const list = self.listRect(nav);
        return .{ .x = nav.x + 6, .y = list.y + self.rowOffset(index) - self.scroll, .w = @max(0, nav.w - (if (self.compact) @as(f32, 12) else 16)), .h = self.rowHeight(index) - 4 };
    }
    pub fn fullHeight(self: *const State) f32 {
        return if (self.snapshot.count == 0) 0 else self.rowOffset(self.snapshot.count - 1) + self.rowHeight(self.snapshot.count - 1);
    }
    pub fn clampScroll(self: *State, nav: geometry.Rect) void {
        self.scroll = std.math.clamp(self.scroll, 0, @max(0, self.fullHeight() - self.listRect(nav).h));
    }
    pub fn reveal(self: *State, index: usize, nav: geometry.Rect) void {
        if (index >= self.snapshot.count) {
            self.clampScroll(nav);
            return;
        }
        const height = self.listRect(nav).h;
        const row_top = self.rowOffset(index);
        // A section's first workspace includes its heading in the reveal
        // target. Home must restore the list origin, not leave PINNED hidden
        // exactly one section-height above an otherwise visible first row.
        const top = row_top - (if (!self.compact and self.sectionStart(index)) section_height else @as(f32, 0));
        if (top < self.scroll) self.scroll = top;
        if (row_top + self.rowHeight(index) > self.scroll + height) self.scroll = row_top + self.rowHeight(index) - height;
        self.clampScroll(nav);
    }
    pub fn rowAt(self: *const State, point: anytype, nav: geometry.Rect) ?usize {
        if (!self.listRect(nav).contains(point)) return null;
        for (0..self.snapshot.count) |i| if (self.rowRect(i, nav).contains(point)) return @intCast(i);
        return null;
    }
    /// Insertion gaps map to the closest row; controls/header never do.
    pub fn dropAt(self: *const State, point: anytype, nav: geometry.Rect) ?usize {
        if (!self.listRect(nav).contains(point) or self.snapshot.count == 0) return null;
        var best: usize = 0;
        var distance = std.math.inf(f32);
        for (0..self.snapshot.count) |i| {
            const row = self.rowRect(i, nav);
            const candidate = @abs(point.y - row.y - row.h / 2);
            if (candidate < distance) {
                distance = candidate;
                best = @intCast(i);
            }
        }
        return best;
    }
};

pub fn hasStatus(row: anytype) bool {
    return row.progress_count > 0 or row.unread_bells > 0 or row.failed > 0 or row.done > 0 or row.running > 0 or row.panes > 1;
}
