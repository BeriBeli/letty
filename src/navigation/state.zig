//! Window display/interaction state only. Tab order/identity stay in Layout.
const std = @import("std");
pub const geometry = @import("geometry.zig");
const snapshot = @import("snapshot.zig");
pub const header_height: f32 = 60;
pub const footer_height: f32 = 36;
pub const section_height: f32 = 31;
pub const row_height: f32 = 35;
pub const Drag = struct { id: u64, origin_y: f32, target: ?usize = null, moved: bool = false };
pub const Resize = struct { origin_x: f32, original_width: f32 };
pub const State = struct {
    width: f32 = geometry.default_width,
    collapsed: bool = false,
    closed_projects: []u64 = &.{},
    closed_project_count: usize = 0,
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
    hover_id: u64 = 0,
    hover_since: f64 = 0,
    pub fn deinit(self: *State) void {
        @import("../dynamic_storage.zig").release(u64, &self.closed_projects);
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
        return index == 0 or self.projectKey(index - 1) != self.projectKey(index);
    }
    pub fn projectKey(self: *const State, index: usize) u64 {
        const row = &self.snapshot.rows[index];
        const path = row.cwd.text();
        const directory = if (row.document) std.fs.path.dirname(path) orelse path else path;
        return std.hash.Wyhash.hash(if (row.pinned) 1 else 0, directory);
    }
    pub fn projectClosed(self: *const State, index: usize) bool {
        const key = self.projectKey(index);
        for (self.closed_projects[0..self.closed_project_count]) |id| if (id == key) return true;
        return false;
    }
    pub fn toggleProject(self: *State, index: usize) void {
        const key = self.projectKey(index);
        for (self.closed_projects[0..self.closed_project_count], 0..) |id, i| if (id == key) {
            self.closed_project_count -= 1;
            self.closed_projects[i] = self.closed_projects[self.closed_project_count];
            return;
        };
        // Retain only currently represented groups before growing storage.
        var kept: usize = 0;
        for (self.closed_projects[0..self.closed_project_count]) |id| {
            for (0..self.snapshot.count) |i| if (self.projectKey(i) == id) {
                self.closed_projects[kept] = id;
                kept += 1;
                break;
            };
        }
        self.closed_project_count = kept;
        @import("../dynamic_storage.zig").ensure(u64, &self.closed_projects, kept + 1, 0) catch return;
        self.closed_projects[kept] = key;
        self.closed_project_count += 1;
    }
    pub fn projectRect(self: *const State, index: usize, nav: geometry.Rect) geometry.Rect {
        const row = self.rowRect(index, nav);
        return .{ .x = row.x, .y = row.y - section_height, .w = row.w, .h = 28 };
    }
    pub fn rowOffset(self: *const State, index: usize) f32 {
        if (self.compact) return @as(f32, @floatFromInt(index)) * 40;
        var y: f32 = 0;
        for (0..@min(index + 1, self.snapshot.count)) |i| {
            if (self.sectionStart(i)) y += section_height + (if (i == 0) @as(f32, 2) else 18);
            if (i < index) y += self.rowHeight(i);
        }
        return y;
    }
    pub fn rowHeight(self: *const State, index: usize) f32 {
        if (self.compact) return 40;
        const row = &self.snapshot.rows[index];
        if (self.projectClosed(index) and !row.active) return 0;
        return row_height + (if (row.git.len > 0) @as(f32, 16) else 0) + (if (row.ports.len > 0) @as(f32, 16) else 0);
    }
    pub fn listRect(self: *const State, nav: geometry.Rect) geometry.Rect {
        return .{ .x = nav.x, .y = nav.y + @min(nav.h, header_height), .w = nav.w, .h = @max(0, nav.h - header_height - (if (self.compact) @as(f32, 80) else footer_height)) };
    }
    pub fn rowRect(self: *const State, index: usize, nav: geometry.Rect) geometry.Rect {
        const list = self.listRect(nav);
        return .{ .x = nav.x + (if (self.compact) @as(f32, 6) else 10), .y = list.y + self.rowOffset(index) - self.scroll, .w = @max(0, nav.w - (if (self.compact) @as(f32, 12) else 20)), .h = @max(0, self.rowHeight(index) - 1) };
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
        // target, including its top margin. Home restores the list origin.
        const top = row_top - (if (!self.compact and self.sectionStart(index)) section_height + (if (index == 0) @as(f32, 2) else 18) else @as(f32, 0));
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
