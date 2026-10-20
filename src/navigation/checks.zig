//! Pure bounded snapshot/interaction tests; no native UI or system services.
const std = @import("std");
const State = @import("state.zig").State;
const geometry = @import("geometry.zig");
const Layout = @import("../layout.zig").Layout;
const Text = @import("../fixed_text.zig").Text;
const Events = @import("../vt_types.zig").Events;
const NativeSnapshot = @import("providers/native.zig").Snapshot;
const Session = struct {
    id: u64,
    events: Events = .{},
    cwd: Text(4096) = .{},
    command_running: bool = false,
    command_pending: bool = false,
    attention: enum { none, bell, done, failed } = .none,
    fatal: bool = false,
    eof: bool = false,
    closing: bool = false,
    status: ?i32 = null,
    metadata: struct { snapshot: ?NativeSnapshot = null, generation: u64 = 0 } = .{},
};
const Host = struct {
    layout: Layout = .{},
    sessions: [16]?*Session = @splat(null),
    title: []const u8 = "终端项目",
    cfg: struct { sidebar_show_git: bool = false, sidebar_show_ports: bool = false } = .{},
    pub fn tabLabel(self: *@This(), _: usize) []const u8 {
        return self.title;
    }
};

test "sidebar snapshot aggregates every split and owns sanitized display strings" {
    var first: Session = .{ .id = 7, .events = .{ .bells = 2 }, .command_running = true };
    first.cwd.set("/tmp/项目");
    var second: Session = .{ .id = 8, .events = .{ .bells = 3, .progress_state = 1, .progress = 40 }, .attention = .failed };
    second.cwd.set("/tmp/other");
    var h: Host = .{};
    defer h.layout.deinit();
    try h.layout.newTab(0, 0);
    try h.layout.split(1, 0, .horizontal);
    h.sessions[0] = &first;
    h.sessions[1] = &second;
    h.title = "项目\x1b\n";
    var st: State = .{};
    defer st.deinit();
    try std.testing.expect(st.refresh(&h));
    const row = &st.snapshot.rows[0];
    try std.testing.expectEqual(@as(u8, 2), row.panes);
    try std.testing.expectEqual(@as(u8, 1), row.running);
    try std.testing.expectEqual(@as(u64, 5), row.unread_bells);
    try std.testing.expectEqual(@as(i32, 40), row.progress);
    try std.testing.expectEqual(@as(u8, 1), row.failed);
    try std.testing.expectEqualStrings("项目  ", row.title.text());
    try std.testing.expectEqualStrings("/tmp/other", row.cwd.text());
    try std.testing.expect(std.mem.indexOf(u8, row.split_paths.text(), "/tmp/项目") != null);
    const generation = st.snapshot.generation;
    try std.testing.expect(!st.refresh(&h) and st.snapshot.generation == generation);
    first.cwd.set("/changed");
    try std.testing.expect(std.mem.indexOf(u8, row.split_paths.text(), "/tmp/项目") != null);
    try std.testing.expect(st.refresh(&h));
}

test "sidebar acknowledgement covers all splits and never aliases reused session slots" {
    var first: Session = .{ .id = 7, .events = .{ .bells = 2 } };
    var second: Session = .{ .id = 8, .events = .{ .bells = 3 } };
    var h: Host = .{};
    defer h.layout.deinit();
    try h.layout.newTab(0, 0);
    try h.layout.split(1, 0, .horizontal);
    h.sessions[0] = &first;
    h.sessions[1] = &second;
    var st: State = .{};
    defer st.deinit();
    st.acknowledge(&h, 0);
    _ = st.refresh(&h);
    try std.testing.expectEqual(@as(u64, 0), st.snapshot.rows[0].unread_bells);
    first.events.bells += 1;
    _ = st.refresh(&h);
    try std.testing.expectEqual(@as(u64, 1), st.snapshot.rows[0].unread_bells);
    second.id = 9;
    second.events.bells = 1;
    _ = st.refresh(&h);
    try std.testing.expectEqual(@as(u64, 2), st.snapshot.rows[0].unread_bells);
    try std.testing.expectEqual(@as(u64, 3), first.events.bells); // Read-only to VT/session metadata.
}

test "sidebar row scroll and cancel preserve width preference and authoritative tab order" {
    var h: Host = .{};
    defer h.layout.deinit();
    for (0..8) |i| try h.layout.newTab(@intCast(i), 0);
    const active_id = h.layout.tabs[h.layout.active_tab].id;
    var st: State = .{};
    defer st.deinit();
    _ = st.refresh(&h);
    const nav = geometry.compute(900, 200, .sidebar, true, st.width, false).navigation;
    st.reveal(7, nav);
    try std.testing.expect(st.scroll > 0);
    const selected = st.rowRect(7, nav);
    const list = st.listRect(nav);
    try std.testing.expect(selected.y >= list.y and selected.y + selected.h <= list.y + list.h);
    try std.testing.expectEqual(@as(?usize, 7), st.rowAt(.{ .x = selected.x + 10, .y = selected.y + 10 }, nav));
    try std.testing.expect(st.rowAt(.{ .x = 500, .y = selected.y }, nav) == null);
    st.reveal(0, nav);
    try std.testing.expectEqual(@as(f32, 0), st.scroll);
    try std.testing.expectEqual(list.y, st.rowRect(0, nav).y);
    st.dragging = .{ .id = active_id, .origin_y = 0, .target = 0, .moved = true };
    st.resizing = .{ .origin_x = 240, .original_width = 240 };
    st.width = 310;
    st.focused = true;
    st.cancel();
    try std.testing.expect(st.dragging == null and st.resizing == null and !st.focused and st.width == 240);
    try std.testing.expectEqual(active_id, h.layout.tabs[h.layout.active_tab].id);
    st.toggle();
    try std.testing.expect(st.collapsed and st.width == 240);
    const compact = geometry.compute(900, 200, .sidebar, true, st.width, st.collapsed);
    try std.testing.expect(compact.compact != null);
}

test "sidebar path sanitation is bounded valid UTF8 even for invalid filesystem bytes" {
    var session: Session = .{ .id = 1 };
    session.cwd.set("/tmp/\xff\x00项目\r");
    var h: Host = .{};
    defer h.layout.deinit();
    try h.layout.newTab(0, 0);
    h.sessions[0] = &session;
    var st: State = .{};
    defer st.deinit();
    _ = st.refresh(&h);
    try std.testing.expectEqualStrings("/tmp/? 项目 ", st.snapshot.rows[0].cwd.text());
    try std.testing.expect(std.unicode.utf8ValidateSlice(st.snapshot.rows[0].cwd.text()));
}

fn providerFixture(id: u64, generation: u64, pid: i32, branch: []const u8) NativeSnapshot {
    var result: NativeSnapshot = .{ .session_id = id, .generation = generation, .root_birth = 1, .root_pid = pid, .git_state = .ok, .ports_state = .ok, .git_dirty = false, .git_detached = false, .branch = @splat(0), .head = @splat(0), .ports = undefined, .port_count = 0, .partial = false, .scanned_pids = 1, .scanned_fds = 0, .elapsed_us = 1 };
    @memcpy(result.branch[0..branch.len], branch);
    @memcpy(result.head[0..7], "abcdef1");
    return result;
}

test "sidebar provider reduction gates real current values and deduplicates ports across splits" {
    var first: Session = .{ .id = 7 };
    first.metadata = .{ .generation = 2, .snapshot = providerFixture(7, 2, 100, "main") };
    first.metadata.snapshot.?.port_count = 1;
    first.metadata.snapshot.?.ports[0] = .{ .pid = 100, .port = 8000, .family = 4, .birth = 1 };
    var second: Session = .{ .id = 8 };
    second.metadata = .{ .generation = 3, .snapshot = providerFixture(8, 3, 101, "feature") };
    second.metadata.snapshot.?.git_dirty = true;
    second.metadata.snapshot.?.port_count = 2;
    second.metadata.snapshot.?.ports[0] = .{ .pid = 101, .port = 8000, .family = 6, .birth = 2 };
    second.metadata.snapshot.?.ports[1] = .{ .pid = 101, .port = 9000, .family = 4, .birth = 2 };
    var h: Host = .{};
    defer h.layout.deinit();
    try h.layout.newTab(0, 0);
    try h.layout.split(1, 0, .horizontal);
    h.sessions[0] = &first;
    h.sessions[1] = &second;
    var st: State = .{};
    defer st.deinit();
    _ = st.refresh(&h);
    try std.testing.expect(st.snapshot.rows[0].git.len == 0 and st.snapshot.rows[0].ports.len == 0);
    h.cfg.sidebar_show_git = true;
    h.cfg.sidebar_show_ports = true;
    _ = st.refresh(&h);
    try std.testing.expectEqualStrings("feature *", st.snapshot.rows[0].git.text());
    try std.testing.expectEqualStrings("8000, 9000", st.snapshot.rows[0].ports.text());
    try std.testing.expect(std.mem.indexOf(u8, st.snapshot.rows[0].provider_sources.text(), "PID 100") != null);
    try std.testing.expect(std.mem.indexOf(u8, st.snapshot.rows[0].provider_sources.text(), "PID 101") != null);
    try std.testing.expectEqual(@as(f32, 106), st.rowHeight(0));
    second.metadata.snapshot.?.git_detached = true;
    _ = st.refresh(&h);
    try std.testing.expectEqualStrings("HEAD abcdef1 *", st.snapshot.rows[0].git.text());
    second.metadata.snapshot.?.git_state = .permission;
    _ = st.refresh(&h);
    try std.testing.expect(st.snapshot.rows[0].git.len == 0);
    second.metadata.generation += 1;
    _ = st.refresh(&h);
    try std.testing.expectEqualStrings("8000", st.snapshot.rows[0].ports.text());
    // A hold window may retain Session and a previously valid provider cache
    // after exit. It must not advertise ports/Git as current local metadata.
    second.metadata.generation -= 1;
    second.metadata.snapshot.?.git_state = .ok;
    inline for (.{ "eof", "closing", "fatal" }) |field| {
        @field(first, field) = true;
        @field(second, field) = true;
        _ = st.refresh(&h);
        try std.testing.expect(st.snapshot.rows[0].git.len == 0 and st.snapshot.rows[0].ports.len == 0 and st.snapshot.rows[0].provider_sources.len == 0);
        @field(first, field) = false;
        @field(second, field) = false;
    }
    first.status = 0;
    second.status = 1;
    _ = st.refresh(&h);
    try std.testing.expect(st.snapshot.rows[0].git.len == 0 and st.snapshot.rows[0].ports.len == 0 and st.snapshot.rows[0].provider_sources.len == 0);
    first.status = null;
    second.status = null;
    h.cfg.sidebar_show_git = false;
    h.cfg.sidebar_show_ports = false;
    _ = st.refresh(&h);
    try std.testing.expect(st.snapshot.rows[0].git.len == 0 and st.snapshot.rows[0].ports.len == 0 and st.snapshot.rows[0].provider_sources.len == 0);
    try std.testing.expectEqual(@as(f32, 74), st.rowHeight(0));
}
