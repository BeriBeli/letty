const std = @import("std");
const geometry = @import("layout_geometry.zig");
const Direction = @import("actions.zig").Direction;
const storage = @import("dynamic_storage.zig");
/// A file workspace has no split root and consumes no pane/node slot.
pub const document_root: usize = std.math.maxInt(usize);
pub const Kind = enum { unused, pane, horizontal, vertical };
pub const Node = struct { kind: Kind = .unused, first: usize = 0, second: usize = 0, pane: usize = 0, profile: u8 = 0, ratio: f32 = 0.5 };
pub const Tab = struct {
    id: u64 = 0,
    pinned: bool = false,
    focused: usize = 0,
    previous: ?usize = null,
    title: [128]u8 = @splat(0),
    title_len: u8 = 0,
    pub fn name(t: *const Tab) []const u8 {
        return t.title[0..t.title_len];
    }
};
pub const Layout = struct {
    version: u8 = 4,
    tabs: []Tab = &.{},
    next_tab_id: u64 = 1,
    nodes: []Node = &.{},
    roots: []usize = &.{},
    tab_count: usize = 0,
    active_tab: usize = 0,
    active_pane: usize = 0,
    pub fn deinit(s: *Layout) void {
        storage.release(Tab, &s.tabs);
        storage.release(Node, &s.nodes);
        storage.release(usize, &s.roots);
        s.* = .{};
    }
    pub fn same(a: Layout, b: Layout) bool {
        if (a.version != b.version or a.next_tab_id != b.next_tab_id or a.tab_count != b.tab_count or a.active_tab != b.active_tab or a.active_pane != b.active_pane) return false;
        if (!std.mem.eql(usize, a.roots[0..a.tab_count], b.roots[0..b.tab_count])) return false;
        if (a.nodes.len != b.nodes.len) return false;
        for (a.tabs[0..a.tab_count], b.tabs[0..b.tab_count]) |x, y| if (!std.meta.eql(x, y)) return false;
        for (a.nodes, b.nodes) |x, y| if (!std.meta.eql(x, y)) return false;
        return true;
    }
    pub fn clone(s: Layout) !Layout {
        var result = s;
        result.tabs = try storage.allocator.dupe(Tab, s.tabs);
        errdefer storage.allocator.free(result.tabs);
        result.nodes = try storage.allocator.dupe(Node, s.nodes);
        errdefer storage.allocator.free(result.nodes);
        result.roots = try storage.allocator.dupe(usize, s.roots);
        return result;
    }
    fn reserveTab(s: *Layout) !void {
        try storage.ensure(Tab, &s.tabs, s.tab_count + 1, .{});
        try storage.ensure(usize, &s.roots, s.tab_count + 1, 0);
    }
    pub fn alloc(s: *Layout, node: Node) !usize {
        for (s.nodes, 0..) |*n, i| if (n.kind == .unused) {
            n.* = node;
            return @intCast(i);
        };
        const at = s.nodes.len;
        try storage.ensure(Node, &s.nodes, at + 1, .{});
        s.nodes[at] = node;
        return at;
    }
    pub fn newTab(s: *Layout, pane: usize, profile: u8) !void {
        if (s.next_tab_id == std.math.maxInt(u64)) return error.InvalidTabId;
        try s.reserveTab();
        s.roots[s.tab_count] = try s.alloc(.{ .kind = .pane, .pane = pane, .profile = profile });
        s.tabs[s.tab_count] = .{ .id = s.next_tab_id, .focused = pane };
        s.next_tab_id += 1;
        s.active_tab = s.tab_count;
        s.tab_count += 1;
        s.active_pane = pane;
    }
    pub fn isDocument(s: Layout, index: usize) bool {
        return index < s.tab_count and s.roots[index] == document_root;
    }
    pub fn newDocument(s: *Layout) !u64 {
        if (s.next_tab_id == std.math.maxInt(u64)) return error.InvalidTabId;
        try s.reserveTab();
        const id = s.next_tab_id;
        s.version = 4;
        s.roots[s.tab_count] = document_root;
        s.tabs[s.tab_count] = .{ .id = id };
        s.next_tab_id += 1;
        s.active_tab = s.tab_count;
        s.tab_count += 1;
        s.active_pane = 0; // bounded placeholder, never a terminal recipient
        return id;
    }
    pub fn closeDocument(s: *Layout, id: u64) void {
        const index = s.tabIndex(id) orelse return;
        if (!s.isDocument(index)) return;
        const active_id = s.tabs[s.active_tab].id;
        var i = index;
        while (i + 1 < s.tab_count) : (i += 1) {
            s.tabs[i] = s.tabs[i + 1];
            s.roots[i] = s.roots[i + 1];
        }
        s.tab_count -= 1;
        s.tabs[s.tab_count] = .{};
        s.roots[s.tab_count] = 0;
        if (s.tab_count == 0) {
            s.active_tab = 0;
            s.active_pane = 0;
            return;
        }
        s.active_tab = s.tabIndex(active_id) orelse @min(index, s.tab_count - 1);
        s.active_pane = if (s.isDocument(s.active_tab)) 0 else s.tabs[s.active_tab].focused;
    }
    pub fn split(s: *Layout, pane: usize, profile: u8, direction: Kind) !void {
        if (s.isDocument(s.active_tab)) return error.PaneMissing;
        const at = s.findPane(s.active_pane) orelse return error.PaneMissing;
        const old = s.nodes[at];
        const first = try s.alloc(old);
        errdefer s.nodes[first] = .{};
        const second = try s.alloc(.{ .kind = .pane, .pane = pane, .profile = profile });
        s.nodes[at] = .{ .kind = direction, .first = first, .second = second };
        s.focus(pane);
    }
    pub fn findPane(s: Layout, pane: usize) ?usize {
        for (s.nodes, 0..) |n, i| if (n.kind == .pane and n.pane == pane) return @intCast(i);
        return null;
    }
    pub fn firstPane(s: Layout, root: usize) usize {
        if (root == document_root) return 0;
        var at = root;
        while (s.nodes[at].kind != .pane) at = s.nodes[at].first;
        return s.nodes[at].pane;
    }
    pub fn contains(s: Layout, root: usize, pane: usize) bool {
        if (root == document_root) return false;
        var buffer: [1024]u8 = undefined;
        var fallback = std.heap.BufferFirstAllocator.init(&buffer, storage.allocator);
        const a = fallback.allocator();
        var pending: std.ArrayList(usize) = .empty;
        defer pending.deinit(a);
        pending.append(a, root) catch return false;
        while (pending.pop()) |at| {
            const n = s.nodes[at];
            switch (n.kind) {
                .pane => if (n.pane == pane) return true,
                .horizontal, .vertical => {
                    pending.appendSlice(a, &.{ n.second, n.first }) catch return false;
                },
                .unused => {},
            }
        }
        return false;
    }
    pub fn visible(s: Layout, pane: usize) bool {
        return s.tab_count > 0 and s.contains(s.roots[s.active_tab], pane);
    }
    fn remove(s: *Layout, root: usize, pane: usize) ?usize {
        const at = s.findPane(pane) orelse return root;
        s.nodes[at] = .{};
        if (at == root) return null;
        for (s.nodes, 0..) |n, parent| {
            if (n.kind != .horizontal and n.kind != .vertical) continue;
            if (n.first != at and n.second != at) continue;
            const sibling = if (n.first == at) n.second else n.first;
            // Reuse the parent node: no ancestor or other workspace is rewritten.
            s.nodes[parent] = s.nodes[sibling];
            s.nodes[sibling] = .{};
            return root;
        }
        unreachable;
    }
    pub fn close(s: *Layout, pane: usize) void {
        const prior_pane = s.active_pane;
        var i: usize = 0;
        while (i < s.tab_count) {
            if (!s.contains(s.roots[i], pane)) {
                i += 1;
                continue;
            }
            if (s.remove(s.roots[i], pane)) |root| {
                s.roots[i] = root;
            } else {
                var j = i;
                while (j + 1 < s.tab_count) : (j += 1) {
                    s.roots[j] = s.roots[j + 1];
                    s.tabs[j] = s.tabs[j + 1];
                }
                s.tab_count -= 1;
                s.tabs[s.tab_count] = .{};
                if (i < s.active_tab) s.active_tab -= 1;
            }
            break;
        }
        for (0..s.tab_count) |tab| {
            if (s.tabs[tab].focused == pane) s.tabs[tab].focused = s.firstPane(s.roots[tab]);
            if (s.tabs[tab].previous == pane) s.tabs[tab].previous = null;
        }
        if (s.tab_count > 0) {
            s.active_tab = @min(s.active_tab, s.tab_count - 1);
            s.active_pane = if (s.contains(s.roots[s.active_tab], prior_pane)) prior_pane else s.tabs[s.active_tab].focused;
            s.tabs[s.active_tab].focused = s.active_pane;
        }
    }
    pub fn validate(s: Layout, profiles: usize) !void {
        if ((s.version != 1 and s.version != 2 and s.version != 3 and s.version != 4) or s.tab_count == 0 or s.tab_count > s.tabs.len or s.tab_count > s.roots.len or s.active_tab >= s.tab_count) return error.InvalidLayout;
        if (s.version >= 2) {
            if (s.next_tab_id == 0 or s.next_tab_id == std.math.maxInt(u64)) return error.InvalidTabId;
            for (s.tabs[0..s.tab_count], 0..) |tab, i| {
                if (tab.id == 0 or tab.id >= s.next_tab_id) return error.InvalidTabId;
                for (s.tabs[0..i]) |other| if (tab.id == other.id) return error.InvalidTabId;
                if (tab.title_len > tab.title.len or !std.unicode.utf8ValidateSlice(tab.name())) return error.InvalidTabTitle;
                for (tab.name()) |ch| if (ch < 32 or ch == 127) return error.InvalidTabTitle;
            }
        }
        const seen = try storage.allocator.alloc(bool, s.nodes.len);
        defer storage.allocator.free(seen);
        @memset(seen, false);
        var panes: std.AutoHashMap(usize, void) = .init(storage.allocator);
        defer panes.deinit();
        for (s.roots[0..s.tab_count]) |r| {
            if (s.version >= 3 and r == document_root) continue;
            try s.walk(r, profiles, seen, &panes);
        }
        for (s.nodes, 0..) |n, i| if (n.kind != .unused and !seen[i]) return error.OrphanNode;
        if (s.version >= 2) for (0..s.tab_count) |tab| {
            if (s.isDocument(tab)) {
                if (s.tabs[tab].focused != 0 or s.tabs[tab].previous != null) return error.InvalidActivePane;
                continue;
            }
            if (!s.contains(s.roots[tab], s.tabs[tab].focused)) return error.InvalidActivePane;
            if (s.tabs[tab].previous) |pane| if (!s.contains(s.roots[tab], pane)) return error.InvalidActivePane;
        };
        if (s.isDocument(s.active_tab)) {
            if (s.active_pane != 0) return error.InvalidActivePane;
        } else if (!panes.contains(s.active_pane) or !s.visible(s.active_pane)) return error.InvalidActivePane;
    }
    pub fn migrate(s: *Layout) void {
        if (s.version != 1) return;
        s.next_tab_id = 1;
        for (0..s.tab_count) |i| {
            s.tabs[i] = .{ .id = s.next_tab_id, .focused = if (i == s.active_tab) s.active_pane else s.firstPane(s.roots[i]) };
            s.next_tab_id += 1;
        }
        s.version = 2;
    }
    pub fn tabIndex(s: Layout, id: u64) ?usize {
        for (s.tabs[0..s.tab_count], 0..) |tab, i| if (tab.id == id) return @intCast(i);
        return null;
    }
    pub fn focus(s: *Layout, pane: usize) void {
        if (!s.visible(pane)) return;
        if (s.active_pane != pane) s.tabs[s.active_tab].previous = s.active_pane;
        s.active_pane = pane;
        s.tabs[s.active_tab].focused = pane;
    }
    pub fn activate(s: *Layout, index: usize) void {
        if (index >= s.tab_count) return;
        s.tabs[s.active_tab].focused = s.active_pane;
        s.active_tab = index;
        const remembered = s.tabs[index].focused;
        s.active_pane = if (s.contains(s.roots[index], remembered)) remembered else s.firstPane(s.roots[index]);
    }
    pub fn rename(s: *Layout, id: u64, title: []const u8) !void {
        const index = s.tabIndex(id) orelse return error.TabMissing;
        if (title.len > 128 or !std.unicode.utf8ValidateSlice(title)) return error.InvalidTabTitle;
        for (title) |ch| if (ch < 32 or ch == 127) return error.InvalidTabTitle;
        @memcpy(s.tabs[index].title[0..title.len], title);
        s.tabs[index].title_len = @intCast(title.len);
    }
    pub fn move(s: *Layout, from: usize, to: usize) void {
        if (from >= s.tab_count or to >= s.tab_count or from == to) return;
        var lower: usize = from;
        var upper: usize = from;
        while (lower > 0 and s.tabs[lower - 1].pinned == s.tabs[from].pinned) lower -= 1;
        while (upper + 1 < s.tab_count and s.tabs[upper + 1].pinned == s.tabs[from].pinned) upper += 1;
        s.moveUnchecked(from, std.math.clamp(to, lower, upper));
    }
    pub fn togglePin(s: *Layout, id: u64) void {
        const from = s.tabIndex(id) orelse return;
        var pins: usize = 0;
        for (s.tabs[0..s.tab_count]) |tab| pins += @intFromBool(tab.pinned);
        const was_pinned = s.tabs[from].pinned;
        s.tabs[from].pinned = !was_pinned;
        s.moveUnchecked(from, if (was_pinned) pins - 1 else pins);
    }
    fn moveUnchecked(s: *Layout, from: usize, to: usize) void {
        if (from == to) return;
        const id = s.tabs[s.active_tab].id;
        const root = s.roots[from];
        const tab = s.tabs[from];
        var i = from;
        while (i < to) : (i += 1) {
            s.roots[i] = s.roots[i + 1];
            s.tabs[i] = s.tabs[i + 1];
        }
        while (i > to) : (i -= 1) {
            s.roots[i] = s.roots[i - 1];
            s.tabs[i] = s.tabs[i - 1];
        }
        s.roots[to] = root;
        s.tabs[to] = tab;
        s.active_tab = s.tabIndex(id).?;
    }
    pub fn splitBefore(s: *Layout, pane: usize, profile: u8, direction: Kind) !void {
        if (s.isDocument(s.active_tab)) return error.PaneMissing;
        const at = s.findPane(s.active_pane) orelse return error.PaneMissing;
        try s.split(pane, profile, direction);
        const n = &s.nodes[at];
        const first = n.first;
        n.first = n.second;
        n.second = first;
    }
    pub fn cyclePane(s: *Layout, previous: bool) void {
        if (s.tab_count == 0) return;
        const slots = storage.allocator.alloc(usize, s.nodes.len) catch return;
        defer storage.allocator.free(slots);
        var count: usize = 0;
        s.ordered(s.roots[s.active_tab], slots, &count);
        for (slots[0..count], 0..) |pane, i| if (pane == s.active_pane) {
            s.focus(slots[(i + count + (if (previous) count - 1 else @as(usize, 1))) % count]);
            return;
        };
    }
    fn ordered(s: Layout, index: usize, output: []usize, count: *usize) void {
        if (index == document_root) return;
        const pending = storage.allocator.alloc(usize, s.nodes.len) catch return;
        defer storage.allocator.free(pending);
        pending[0] = index;
        var length: usize = 1;
        while (length > 0) {
            length -= 1;
            const n = s.nodes[pending[length]];
            if (n.kind == .pane) {
                output[count.*] = n.pane;
                count.* += 1;
            } else if (n.kind == .horizontal or n.kind == .vertical) {
                pending[length] = n.second;
                pending[length + 1] = n.first;
                length += 2;
            }
        }
    }
    pub fn neighbor(s: Layout, direction: Direction, width: f32, height: f32) ?usize {
        return geometry.neighbor(s, direction, width, height);
    }
    pub fn equalize(s: *Layout, width: f32, height: f32, min_w: f32, min_h: f32) void {
        if (s.tab_count > 0) geometry.equalize(s, s.roots[s.active_tab], .{ .w = width, .h = height }, min_w, min_h);
    }
    pub fn resize(s: *Layout, direction: Direction, pixels: u16, width: f32, height: f32, min_w: f32, min_h: f32) bool {
        return s.tab_count > 0 and geometry.resize(s, s.roots[s.active_tab], .{ .w = width, .h = height }, direction, pixels, min_w, min_h);
    }
    fn walk(s: Layout, index: usize, profiles: usize, seen: []bool, panes: *std.AutoHashMap(usize, void)) !void {
        var pending: std.ArrayList(usize) = .empty;
        defer pending.deinit(storage.allocator);
        try pending.append(storage.allocator, index);
        while (pending.pop()) |at| {
            if (at >= s.nodes.len or seen[at]) return error.LayoutCycle;
            seen[at] = true;
            const n = s.nodes[at];
            if (!std.math.isFinite(n.ratio) or n.ratio < 0.1 or n.ratio > 0.9) return error.InvalidRatio;
            switch (n.kind) {
                .unused => return error.MissingNode,
                .pane => {
                    if (n.pane >= s.nodes.len or panes.contains(n.pane) or n.profile >= profiles) return error.InvalidPane;
                    try panes.put(n.pane, {});
                },
                .horizontal, .vertical => try pending.appendSlice(storage.allocator, &.{ n.second, n.first }),
            }
        }
    }
};
test "closing a split collapses only its branch; IDs in other tabs survive" {
    var s: Layout = .{};
    defer s.deinit();
    try s.newTab(0, 0);
    try s.split(1, 0, .horizontal);
    try s.newTab(2, 0);
    s.close(1);
    try s.validate(1);
    try std.testing.expect(s.findPane(0) != null);
    try std.testing.expect(s.findPane(2) != null);
    s.close(0);
    try s.validate(1);
    try std.testing.expectEqual(@as(u8, 1), s.tab_count);
}
test "reject persisted cycles before following or spawning commands" {
    var s: Layout = .{};
    defer s.deinit();
    try s.newTab(0, 0);
    s.nodes[0] = .{ .kind = .horizontal, .first = 0, .second = 0 };
    try std.testing.expectError(error.LayoutCycle, s.validate(1));
}

test "hidden pane exit preserves active split, JSON round trip keeps topology" {
    var s: Layout = .{};
    defer s.deinit();
    try s.newTab(0, 0);
    try s.split(1, 0, .horizontal);
    try s.newTab(2, 0);
    s.active_tab = 0;
    s.active_pane = 1;
    s.close(2);
    try std.testing.expectEqual(@as(u8, 1), s.active_pane);
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, s, .{});
    defer std.testing.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Layout, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    try parsed.value.validate(1);
    try std.testing.expect(parsed.value.visible(0) and parsed.value.visible(1));
}

test "v1 migration gives stable tab identity and remembers pane focus" {
    var s: Layout = .{};
    defer s.deinit();
    try s.newTab(0, 0);
    try s.split(1, 0, .horizontal);
    try s.newTab(2, 0);
    s.version = 1;
    @memset(s.tabs, .{});
    s.next_tab_id = 1;
    try s.validate(1);
    s.migrate();
    try s.validate(1);
    s.activate(0);
    s.focus(1);
    const id = s.tabs[0].id;
    s.activate(1);
    s.activate(0);
    try std.testing.expectEqual(@as(u8, 1), s.active_pane);
    try s.rename(id, "工作区");
    s.move(0, 1);
    s.close(0);
    try std.testing.expectEqual(id, s.tabs[s.active_tab].id);
    try std.testing.expectEqualStrings("工作区", s.tabs[s.active_tab].name());
    try s.validate(1);
}
test "direction navigation, equal areas and bounded nearest divider resize" {
    var s: Layout = .{};
    defer s.deinit();
    try s.newTab(0, 0);
    try s.split(1, 0, .horizontal);
    try s.split(2, 0, .vertical);
    s.focus(0);
    try s.splitBefore(3, 0, .vertical);
    s.nodes[s.roots[0]].ratio = 0.3;
    s.focus(3);
    try std.testing.expectEqual(@as(?usize, 1), s.neighbor(.right, 1000, 680));
    try std.testing.expectEqual(@as(?usize, 0), s.neighbor(.down, 1000, 680));
    try std.testing.expect(s.neighbor(.left, 1000, 680) == null);
    s.equalize(1000, 680, 40, 20);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s.nodes[s.roots[0]].ratio, 0.001);
    const root = s.roots[0];
    const before = s.nodes[root].ratio;
    try std.testing.expect(s.resize(.right, 20, 1000, 680, 40, 20));
    try std.testing.expect(s.nodes[root].ratio > before);
    try std.testing.expect(s.resize(.left, 65535, 1000, 680, 40, 20));
    try s.validate(1);
    // Three leaves: root should allocate 2/3 to its two-leaf subtree.
    s.close(3);
    s.equalize(1000, 680, 40, 20);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), s.nodes[s.roots[0]].ratio, 0.001);
}
test "layout rejects duplicate tab IDs and stale focus before PTY creation" {
    var s: Layout = .{};
    defer s.deinit();
    try s.newTab(0, 0);
    try s.newTab(1, 0);
    s.tabs[1].id = s.tabs[0].id;
    try std.testing.expectError(error.InvalidTabId, s.validate(1));
    s.tabs[1].id += 1;
    s.tabs[1].focused = 0;
    try std.testing.expectError(error.InvalidActivePane, s.validate(1));
}
test "pin groups and bounded reorder keep active identity and complete split roots" {
    var layout: Layout = .{};
    defer layout.deinit();
    try layout.newTab(0, 0);
    try layout.split(1, 0, .horizontal);
    try layout.newTab(2, 0);
    try layout.newTab(3, 0);
    const first = layout.tabs[0].id;
    const last = layout.tabs[2].id;
    const root = layout.roots[0];
    layout.togglePin(last);
    try std.testing.expect(layout.tabs[0].id == last and layout.tabs[0].pinned);
    try std.testing.expect(layout.tabs[layout.active_tab].id == last and layout.active_pane == 3);
    layout.move(0, 2);
    try std.testing.expectEqual(last, layout.tabs[0].id);
    layout.togglePin(first);
    try std.testing.expect(layout.tabs[1].id == first and layout.roots[1] == root);
    layout.togglePin(last);
    try std.testing.expect(layout.tabs[0].id == first and layout.tabs[0].pinned);
    try std.testing.expect(layout.tabs[1].id == last and !layout.tabs[1].pinned);
    try layout.validate(1);
}

test "file workspaces coexist with all sixteen panes without exposing placeholder pane zero" {
    var s: Layout = .{};
    defer s.deinit();
    try s.newTab(0, 0);
    for (1..16) |slot| try s.split(@intCast(slot), 0, .horizontal);
    const terminal = s.tabs[0].id;
    const file = try s.newDocument();
    try s.validate(1);
    try std.testing.expect(!s.visible(0) and !s.visible(15));
    try std.testing.expectError(error.PaneMissing, s.split(0, 0, .horizontal));
    try std.testing.expect(s.neighbor(.left, 1000, 700) == null);
    try std.testing.expect(!s.resize(.left, 20, 1000, 700, 10, 10));
    s.equalize(1000, 700, 10, 10);
    s.cyclePane(false);
    s.togglePin(file);
    try s.rename(file, "README.md");
    s.close(0); // Background terminal exit must keep the file workspace active.
    try s.validate(1);
    try std.testing.expectEqual(file, s.tabs[s.active_tab].id);
    s.closeDocument(file);
    try s.validate(1);
    try std.testing.expectEqual(terminal, s.tabs[s.active_tab].id);
    try std.testing.expect(s.visible(s.active_pane));
}
test "files-only workspaces grow and stale closes cannot affect new files" {
    var s: Layout = .{};
    defer s.deinit();
    const first = try s.newDocument();
    for (1..16) |_| _ = try s.newDocument();
    try s.validate(0);
    _ = try s.newDocument();
    s.closeDocument(first);
    const next = try s.newDocument();
    s.closeDocument(first);
    try std.testing.expectEqual(@as(usize, 17), s.tab_count);
    try std.testing.expect(next > first);
    try s.validate(0);
}

test "dynamic layouts cross byte indices, clone independently and retain stable file identities" {
    var original: Layout = .{};
    defer original.deinit();
    for (0..600) |i| try original.newTab(i, 0);
    const file = try original.newDocument();
    try original.validate(1);
    var copy = try original.clone();
    defer copy.deinit();
    copy.close(599);
    copy.closeDocument(file);
    try std.testing.expect(original.tab_count == 601 and copy.tab_count == 599);
    original.activate(599);
    try original.split(600, 0, .horizontal);
    try original.validate(1);
    try std.testing.expect(original.visible(600));
    try std.testing.expectEqual(@as(?usize, 599), original.neighbor(.left, 1000, 700));
    original.close(599);
    try original.validate(1);
    try std.testing.expect(original.visible(600) and original.tabIndex(file) != null);
}
test "deep persisted trees validate without recursive stack growth and reject cycles" {
    var tree: Layout = .{};
    defer tree.deinit();
    try tree.newTab(0, 0);
    for (1..4096) |i| try tree.split(i, 0, .horizontal);
    try tree.validate(1);
    try std.testing.expect(tree.visible(4095));
    tree.cyclePane(false);
    try std.testing.expect(tree.active_pane == 0);
    tree.equalize(1000, 700, 10, 10);
    _ = tree.neighbor(.right, 1000, 700);
    try std.testing.expect(tree.resize(.right, 10, 1000, 700, 10, 10));
    tree.close(4095);
    try tree.validate(1);
    tree.nodes[tree.roots[0]].first = tree.roots[0];
    try std.testing.expectError(error.LayoutCycle, tree.validate(1));
}
