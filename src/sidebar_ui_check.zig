//! Real application navigation fixtures, isolated Host/PTYs and private Tester
//! input. No user window, system clipboard, native key registration or shell
//! configuration is touched. Source presence is not a passed acceptance run.
const std = @import("std");
const nano = @import("nanoui");
const ui = nano.ui;
const vt = @import("vt.zig");
const Config = @import("config.zig").Config;
const Profile = @import("config.zig").Profile;
const Layout = @import("layout.zig").Layout;
const actions = @import("actions.zig");
const Session = @import("session.zig").Session;
const raw_command = "exec /bin/sh -c 'stty raw -echo || exit 90; printf \"\\r\\n__SIDEBAR_READY__\\r\\n\"; output=$(od -An -tx1 -N 5); result=$?; printf \"\\r\\n__SIDEBAR_RESULT__%s__SIDEBAR_DONE__\\r\\n\" \"$output\"; exit \"$result\"'";
const control_command = "exec /bin/sh -c 'sleep 30'";

fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI Sidebar {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.SidebarUiCheck;
}
fn action(w: anytype, t: *ui.Tester, request: actions.Request) void {
    w.menu_actions[0] = request;
    w.menu_action_count = 1;
    t.frame();
    t.frame();
}
fn step(t: *ui.Tester) void {
    nano.runFor(0.02);
    t.frame();
}
fn allText(session: *Session, gpa: std.mem.Allocator) ![]u8 {
    if (vt.lt_vt_select_all(session.vt) != 0) return error.SidebarNoOutput;
    defer vt.lt_vt_clear_selection(session.vt);
    var bytes: [65536]u8 = undefined;
    var len: usize = 0;
    if (vt.lt_vt_copy(session.vt, &bytes, bytes.len, &len) != 0) return error.SidebarCopyFailed;
    return gpa.dupe(u8, bytes[0..len]);
}
fn waitText(session: *Session, t: *ui.Tester, needle: []const u8) !void {
    for (0..240) |_| {
        step(t);
        const text = allText(session, session.gpa) catch |err| switch (err) {
            error.SidebarNoOutput => continue,
            else => return err,
        };
        defer session.gpa.free(text);
        if (std.mem.indexOf(u8, text, needle) != null) return;
        if (session.fatal or session.eof) return error.SidebarPtyExitedEarly;
    }
    return error.SidebarPtyTimeout;
}
fn applyMode(w: anytype, t: *ui.Tester, mode: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(w.gpa);
    defer arena.deinit();
    var next = w.host.cfg;
    next.workspace_navigation = mode;
    var transaction = try @import("config_transaction.zig").Transaction(@TypeOf(w)).prepare(w, &arena, next);
    defer transaction.deinit();
    std.debug.print("SIDEBAR_MODE_DIAGNOSTIC window={d} before={s} after={s} navigation_only={any} query=\"{s}\" total={d} current={d}\n", .{ w.id, @tagName(w.cfg.workspace_navigation), @tagName(next.workspace_navigation), transaction.navigation_only, w.query.text(), w.total, w.search_info.current });
    transaction.commit(&t.ctx);
    t.frame();
}
const Identity = struct { id: u64, pid: c_int };
const Saved = struct {
    layout: Layout,
    sessions: [16]Identity = undefined,
    count: usize = 0,
    total: usize,
    current: usize,
    query: [128]u8 = undefined,
    query_len: usize,
    paste_target: ?u64,
    fn capture(w: anytype) !Saved {
        var result: Saved = .{ .layout = try w.layout.clone(), .total = w.total, .current = w.search_info.current, .query_len = w.query.len, .paste_target = w.paste_session };
        if (w.query.len > result.query.len) return error.SidebarFixtureQueryLimit;
        @memcpy(result.query[0..result.query_len], w.query.text());
        for (w.sessions) |entry| if (entry) |session| {
            result.sessions[result.count] = .{ .id = session.id, .pid = session.pid };
            result.count += 1;
        };
        return result;
    }
    fn same(self: *const Saved, w: anytype) bool {
        const same_layout = self.layout.same(w.layout);
        const same_total = self.total == w.total;
        const same_current = self.current == w.search_info.current;
        const same_query = std.mem.eql(u8, self.query[0..self.query_len], w.query.text());
        const same_paste = self.paste_target == w.paste_session;
        if (!same_layout or !same_total or !same_current or !same_query or !same_paste) {
            std.debug.print("SIDEBAR_SAVED_DIAGNOSTIC window={d} layout={any} total={any}({d}->{d}) current={any}({d}->{d}) query={any}(\"{s}\"->\"{s}\") paste={any}({any}->{any})\n", .{ w.id, same_layout, same_total, self.total, w.total, same_current, self.current, w.search_info.current, same_query, self.query[0..self.query_len], w.query.text(), same_paste, self.paste_target, w.paste_session });
            return false;
        }
        var count: usize = 0;
        for (w.sessions) |entry| if (entry) |session| {
            var found = false;
            for (self.sessions[0..self.count]) |identity| if (identity.id == session.id and identity.pid == session.pid) {
                found = true;
                break;
            };
            if (!found or session.fatal or session.eof) {
                std.debug.print("SIDEBAR_SESSION_DIAGNOSTIC window={d} id={d} pid={d} found={any} fatal={any} eof={any}\n", .{ w.id, session.id, session.pid, found, session.fatal, session.eof });
                return false;
            }
            count += 1;
        };
        if (count != self.count) std.debug.print("SIDEBAR_SESSION_COUNT_DIAGNOSTIC window={d} before={d} after={d}\n", .{ w.id, self.count, count });
        return count == self.count;
    }
};

pub fn run(s: anytype) !void {
    const Host = @typeInfo(@TypeOf(s.host)).pointer.child;
    const Window = @typeInfo(@TypeOf(s)).pointer.child;
    var arena = std.heap.ArenaAllocator.init(s.gpa);
    defer arena.deinit();
    const profiles = [_]Profile{.{}};
    const cfg: Config = .{ .shell = "/bin/sh", .shell_integration = .none, .profiles = &profiles, .command = control_command, .copy_on_select = .none, .confirm_close = .always, .clear_default_keybinds = true, .tab_bar = .always };
    var host: Host = .{ .gpa = s.gpa, .arena = arena.allocator(), .app = s.app, .cfg = cfg, .state_path = "/dev/null", .read_path = "/dev/null", .command_override = raw_command, .override_profile = profiles[0].name, .demo = true, .hold = true };
    host.services.init(&host);
    defer {
        host.deinit();
        nano.runFor(0.025);
    }
    const first = try host.create(false);
    first.window_focused = true;
    const receiver = first.active().?;
    const receiver_id = receiver.id;
    const receiver_pid = receiver.pid;
    const first_tab = first.layout.tabs[0].id;
    host.command_override = control_command;
    first.command_override = control_command;
    try first.add(.horizontal);
    first.layout.nodes[first.layout.roots[0]].ratio = 0.31;
    first.focusPane(0);
    try first.layout.rename(first_tab, "Alpha 世界 workspace");
    try first.add(.tab);
    const other_tab = first.layout.tabs[first.layout.active_tab].id;
    try first.layout.rename(other_tab, "Beta workspace");
    first.activateTab(first.layout.tabIndex(first_tab).?);
    const second = try host.create(false);
    second.window_focused = true;
    try second.add(.vertical);
    second.layout.nodes[second.layout.roots[0]].ratio = 0.64;
    var a: ui.Tester = undefined;
    try a.init(s.gpa, .init(first, Window.view), .{ .width = 960, .height = 620, .theme = @import("appearance.zig").theme(cfg) });
    defer a.deinit();
    var b: ui.Tester = undefined;
    try b.init(s.gpa, .init(second, Window.view), .{ .width = 880, .height = 560, .theme = @import("appearance.zig").theme(cfg) });
    defer b.deinit();
    // No native key-window bookkeeping exists for these in-memory surfaces.
    first.window_focused = true;
    second.window_focused = true;
    host.active_id = first.id;
    try waitText(receiver, &a, "__SIDEBAR_READY__");
    try vt.feed(receiver.vt, "\x1b[2J\x1b[HKEEP alpha 中\r\nKEEP beta\r\nKEEP gamma\r\n");
    try vt.feed(second.active().?.vt, "\x1b[2J\x1b[HKEEP second\r\nKEEP window\r\n");
    action(first, &a, .{ .action = .search });
    a.typeText("KEEP");
    action(second, &b, .{ .action = .search });
    b.typeText("KEEP");
    for (0..5) |_| {
        a.frame();
        b.frame();
    }
    vt.lt_vt_select(receiver.vt, 0, 0, 0);
    vt.lt_vt_select(receiver.vt, 3, 0, 1);
    vt.lt_vt_select(second.active().?.vt, 0, 0, 0);
    vt.lt_vt_select(second.active().?.vt, 3, 0, 1);
    first.paste_session = receiver_id; // pending private async source identity
    try check(first.total == 3 and second.total == 2 and vt.lt_vt_has_selection(receiver.vt), "two-window fixture starts with real split VTs, search results and selection");
    a.textOps(&.{.{ .set_marked = .{ .text = "侧", .sel_start = "侧".len, .sel_len = 0 } }});
    // Composition edits the query itself; preserve the live marked query,
    // rather than comparing against the earlier unmarked search baseline.
    for (0..5) |_| a.frame();
    var first_saved = try Saved.capture(first);
    defer first_saved.layout.deinit();
    var second_saved = try Saved.capture(second);
    defer second_saved.layout.deinit();
    const query_focus = a.ctx.focus;
    for (0..3) |_| {
        try applyMode(first, &a, .sidebar);
        b.frame();
        const first_same = first_saved.same(first);
        const second_same = second_saved.same(second);
        try check(first.cfg.workspace_navigation == .sidebar and second.cfg.workspace_navigation == .sidebar and first_same and second_same, "shared config transaction switches both windows to sidebar preserving IDs PIDs pane trees ratios search and pending paste target");
        try check(vt.lt_vt_has_selection(receiver.vt) and vt.lt_vt_has_selection(second.active().?.vt), "navigation-only transaction and required VT resize preserve both terminal selections");
        const marked = if (a.ctx.focused_text) |field| field.marked != null else false;
        try check(marked and a.ctx.focus == query_focus, "navigation-only switch preserves actual search-field IME composition and focus");
        try applyMode(first, &a, .top);
        b.frame();
        try check(first.cfg.workspace_navigation == .top and second.cfg.workspace_navigation == .top and first_saved.same(first) and second_saved.same(second), "returning to top navigation preserves both windows rather than activating or replacing workspaces");
    }
    a.textOps(&.{.unmark});
    first.paste_session = null;
    try applyMode(first, &a, .sidebar);
    b.frame();
    try @import("sidebar_geometry_ui_check.zig").run(first, &a);
    try a.screenshot(".cache/test-logs/sidebar-light.png");
    action(first, &a, .{ .action = .end_search });
    action(second, &b, .{ .action = .end_search });
    try interactions(first, &a, receiver, first_tab, other_tab);
    // Admit terminal input only after every sidebar/IME/modal event has run.
    if (first.layout.tabIndex(first_tab)) |index| first.activateTab(index) else return error.SidebarReceiverTabLost;
    first.focusPane(0);
    first.sidebar.focused = false;
    first.window_focused = true;
    a.ctx.focus = 0;
    a.frame();
    try check(receiver.id == receiver_id and receiver.pid == receiver_pid and !receiver.fatal and !receiver.eof, "all sidebar interactions retain the original raw input receiver and child PID");
    a.key(.tab);
    a.typeText("中Z");
    try waitText(receiver, &a, "__SIDEBAR_DONE__");
    const output = try allText(receiver, s.gpa);
    defer s.gpa.free(output);
    const start = (std.mem.indexOf(u8, output, "__SIDEBAR_RESULT__") orelse return error.SidebarMissingRawResult) + "__SIDEBAR_RESULT__".len;
    const end = std.mem.indexOfPos(u8, output, start, "__SIDEBAR_DONE__") orelse return error.SidebarMissingRawResult;
    var tokens = std.mem.tokenizeAny(u8, output[start..end], " \r\n\t");
    var bytes: [16]u8 = undefined;
    var count: usize = 0;
    while (tokens.next()) |token| {
        if (count == bytes.len or token.len != 2) return error.SidebarInvalidRawResult;
        bytes[count] = try std.fmt.parseInt(u8, token, 16);
        count += 1;
    }
    try check(std.mem.eql(u8, bytes[0..count], "\t中Z"), "real raw PTY receives exactly final terminal Tab and UTF8 with no leaked sidebar IME modal or navigation input");
    first.cfg.background = 0x161616;
    first.cfg.foreground = 0xeeeeee;
    a.theme = ui.Theme.dark_theme;
    for (first.sessions) |entry| if (entry) |session| first.configureSession(session);
    a.frame();
    try a.screenshot(".cache/test-logs/sidebar-dark.png");
}

fn interactions(w: anytype, t: *ui.Tester, receiver: *Session, first_tab: u64, other_tab: u64) !void {
    const sidebar = @import("navigation/sidebar.zig");
    try vt.feed(receiver.vt, "\x1b[2J\x1b[HFIRST_COLUMN_SAMPLE");
    t.frame();
    const first_cell = t.findGridCell("F") orelse return error.SidebarMissingFirstCell;
    t.drag(first_cell.x + first_cell.w * 0.1, first_cell.y + first_cell.h / 2, first_cell.x + first_cell.w * 2.5, first_cell.y + first_cell.h / 2);
    action(w, t, .{ .action = .copy });
    try check(first_cell.x >= w.navigation_rects.content.x and std.mem.eql(u8, t.clipboard.items, "FIR"), "actual terminal first-column selection uses sidebar-shifted cell coordinates and private clipboard");
    var row = w.sidebar.rowRect(w.layout.tabIndex(first_tab).?, w.navigation_rects.navigation);
    t.click(row.x + 20, row.y + 15);
    try check(w.sidebar.focused and w.layout.tabs[w.layout.active_tab].id == first_tab, "clicking current sidebar workspace gives navigation focus without activating another pane");
    var focused_tabs: usize = 0;
    var focused_terminals: usize = 0;
    if (w.ax.adapter) |*adapter| for (adapter.snapshot.nodes[0..adapter.snapshot.count]) |node| {
        if (node.state & @import("accessibility.zig").State.focused == 0) continue;
        focused_tabs += @intFromBool(node.role == .tab);
        focused_terminals += @intFromBool(node.role == .terminal);
    };
    try check(focused_tabs == 1 and focused_terminals == 0, "postframe AX focus belongs to exactly the selected sidebar row rather than terminal or every header button");
    t.typeText("SIDEBAR_MUST_NOT_REACH_PTY");
    t.textOps(&.{.{ .set_marked = .{ .text = "侧栏", .sel_start = "侧栏".len, .sel_len = 0 } }});
    t.textOps(&.{.unmark});
    try check(w.sidebar.focused and w.views[w.layout.active_pane].preedit.items.len == 0, "sidebar text and IME operations stay in navigation without creating terminal preedit");
    t.key(.escape);
    for (0..3) |_| step(t);
    try check(!w.sidebar.focused and !receiver.eof, "Escape exits navigation focus and consumes its key before raw PTY input");
    const active = w.layout.tabs[w.layout.active_tab].id;
    const first_index = w.layout.tabIndex(first_tab).?;
    const other_index = w.layout.tabIndex(other_tab).?;
    const from = w.sidebar.rowRect(first_index, w.navigation_rects.navigation);
    const to = w.sidebar.rowRect(other_index, w.navigation_rects.navigation);
    t.drag(from.x + 20, from.y + 20, to.x + 20, to.y + 25);
    try check(w.layout.tabIndex(first_tab).? == other_index and w.layout.tabs[w.layout.active_tab].id == active and receiver.pid > 0, "actual row drag commits one stable-ID reorder while retaining active workspace identity");
    var ordered = try w.layout.clone();
    defer ordered.deinit();
    row = w.sidebar.rowRect(w.layout.tabIndex(first_tab).?, w.navigation_rects.navigation);
    t.drag(row.x + 20, row.y + 15, w.navigation_rects.content.x + 40, row.y + 15);
    try check(w.sidebar.dragging == null and ordered.same(w.layout), "dragging outside sidebar cancels without moving a row or starting terminal selection");
    const width = w.sidebar.width;
    const columns = receiver.cols;
    var band = w.navigation_rects.resize;
    t.drag(band.x + 2, 260, band.x + 72, 260);
    try check(w.sidebar.width > width + 50 and @abs(w.navigation_rects.content.x - w.navigation_rects.navigation.w) < 0.1 and receiver.cols < columns and receiver.pid > 0, "real resize-band drag changes preferred sidebar width content rectangle and actual VT columns together");
    const resized = w.sidebar.width;
    band = w.navigation_rects.resize;
    t.moveTo(band.x + 2, 260);
    t.ctx.pointerDown();
    t.frame();
    t.ctx.input.mouse.x += 30;
    t.frame();
    t.key(.escape);
    t.ctx.pointerUp();
    t.frame();
    try check(w.sidebar.resizing == null and @abs(w.sidebar.width - resized) < 0.1, "Escape cancels an in-progress resize and restores its original preferred width");
    band = w.navigation_rects.resize;
    t.moveTo(band.x + 2, 260);
    t.ctx.pointerDown();
    t.frame();
    t.ctx.input.mouse.x += 25;
    t.frame();
    w.window_focused = false;
    t.frame();
    t.ctx.pointerUp();
    t.frame();
    w.window_focused = true;
    t.frame();
    try check(w.sidebar.resizing == null and w.sidebar.dragging == null and !w.sidebar.focused and @abs(w.sidebar.width - resized) < 0.1, "window blur cancels resize and keyboard ownership while restoring user width");
    row = w.sidebar.rowRect(w.layout.tabIndex(first_tab).?, w.navigation_rects.navigation);
    t.moveTo(row.x + 20, row.y + 18);
    t.ctx.pointerDown();
    t.frame();
    try applyMode(w, t, .top);
    t.ctx.pointerUp();
    t.frame();
    try check(w.sidebar.dragging == null and w.sidebar.resizing == null and ordered.same(w.layout), "mode switch cancels captured sidebar drag coordinates without committing stale order");
    try applyMode(w, t, .sidebar);
    const collapse = sidebar.controlRect(w.navigation_rects.navigation, .collapse);
    t.click(collapse.x + 8, collapse.y + 8);
    try check(w.sidebar.collapsed and w.navigation_rects.compact != null and @abs(w.sidebar.width - resized) < 0.1, "collapse preserves user width and gives terminal space while retaining compact entry");
    const compact_row = w.sidebar.rowRect(w.layout.tabIndex(other_tab).?, w.navigation_rects.navigation);
    t.click(compact_row.x + 12, compact_row.y + 12);
    try check(w.layout.tabs[w.layout.active_tab].id == other_tab and !w.sidebar.focused, "compact numbered row switches workspace and returns terminal keyboard focus");
    try t.screenshot(".cache/test-logs/navigation-compact-paper.png");
    const expand = try axNode(w, .sidebar_toggle, 0);
    if (!w.ax.adapter.?.enqueue(expand, .press)) return error.SidebarAxEnqueueRejected;
    t.frame();
    try check(!w.sidebar.collapsed and w.navigation_rects.compact == null and @abs(w.navigation_rects.navigation.w - resized) < 0.1, "compact AX Press expands the actual sidebar through the common action route");
    t.resize(360, 300);
    try check(w.navigation_rects.compact != null and !w.sidebar.collapsed and @abs(w.sidebar.width - resized) < 0.1 and w.navigation_rects.content.w >= 240, "narrow window auto-compacts without replacing the user collapsed preference or width");
    t.resize(960, 620);
    try check(w.navigation_rects.compact == null and @abs(w.navigation_rects.navigation.w - resized) < 0.1, "widening restores preferred expanded width after temporary compact layout");
    row = w.sidebar.rowRect(w.layout.tabIndex(first_tab).?, w.navigation_rects.navigation);
    const pin = sidebar.rowActionRect(row, .pin);
    t.click(pin.x + 8, pin.y + 8);
    try check(w.layout.tabs[w.layout.tabIndex(first_tab).?].pinned and w.layout.tabs[w.layout.active_tab].id == first_tab and t.hasText("PINNED"), "row pin button updates shared tab metadata with a visible noncolor pinned section");
    const pin_row = w.sidebar.rowRect(w.layout.tabIndex(other_tab).?, w.navigation_rects.navigation);
    t.moveTo(pin_row.x + 20, pin_row.y + 12);
    const pin_other = try axNode(w, .tab_pin, other_tab);
    if (!w.ax.adapter.?.enqueue(pin_other, .press)) return error.SidebarAxEnqueueRejected;
    w.activateTab(w.layout.tabIndex(first_tab).?);
    t.frame();
    try check(w.layout.tabs[w.layout.tabIndex(other_tab).?].pinned and w.layout.tabs[w.layout.active_tab].id == other_tab, "queued AX pin resolves its captured workspace ID after an active-row change");
    const other_session = w.active().?.id;
    const close_other = try axNode(w, .tab_close, other_tab);
    if (!w.ax.adapter.?.enqueue(close_other, .press)) return error.SidebarAxEnqueueRejected;
    w.activateTab(w.layout.tabIndex(first_tab).?);
    t.frame();
    try check(w.confirmation.open and w.close_pending.contains(other_session) and !w.close_pending.contains(receiver.id), "queued AX close opens normal confirmation for captured workspace rather than current workspace");
    const tab_count = w.layout.tab_count;
    t.key(.escape);
    t.frame();
    try check(!w.confirmation.open and w.layout.tab_count == tab_count and w.layout.tabIndex(other_tab) != null and !receiver.eof, "canceling sidebar close retains tab IDs processes and pane trees");
    row = w.sidebar.rowRect(w.layout.tabIndex(first_tab).?, w.navigation_rects.navigation);
    t.doubleClick(row.x + 20, row.y + 18);
    try check(w.rename_dialog.open and w.rename_id == first_tab, "sidebar double-click reuses the existing stable-target rename dialog");
    t.textOps(&.{.{ .set_marked = .{ .text = "重", .sel_start = "重".len, .sel_len = 0 } }});
    _ = t.shortcut(.{ .key = ui.Shortcut.tab });
    const marked = if (t.ctx.focused_text) |field| field.marked != null else false;
    try check(marked and w.rename_dialog.open and !receiver.eof, "sidebar rename keeps Chinese composition in the modal while navigation Tab is suppressed");
    t.textOps(&.{ .unmark, .{ .command = .select_all }, .{ .insert = "Workspace 重命名" } });
    t.key(.enter);
    t.frame();
    try check(!w.rename_dialog.open and std.mem.eql(u8, w.layout.tabs[w.layout.tabIndex(first_tab).?].name(), "Workspace 重命名"), "IME-safe rename commits once to the captured tab and updates sidebar snapshot");
    const control_session = w.sessions[1].?;
    try vt.feed(control_session.vt, "\x07\x1b]9;4;1;37\x1b\\");
    control_session.refresh();
    t.frame();
    const summary = w.sidebar.snapshot.rows[w.layout.tabIndex(first_tab).?];
    try check(summary.panes == 2 and summary.bells >= 1 and summary.progress_count >= 1 and summary.progress == 37, "sidebar aggregates real BEL and OSC progress from a nonfocused split rather than current pane alone");
    const other_row = w.sidebar.rowRect(w.layout.tabIndex(other_tab).?, w.navigation_rects.navigation);
    t.click(other_row.x + 20, other_row.y + 18);
    row = w.sidebar.rowRect(w.layout.tabIndex(first_tab).?, w.navigation_rects.navigation);
    t.click(row.x + 20, row.y + 18);
    try check(w.sidebar.snapshot.rows[w.layout.tabIndex(first_tab).?].unread_bells == 0, "selecting workspace acknowledges existing bell counters across its entire split tree");
    const new_control = sidebar.controlRect(w.navigation_rects.navigation, .new);
    const before_new = w.layout.tab_count;
    t.click(new_control.x + 8, new_control.y + 8);
    try check(w.layout.tab_count == before_new + 1 and w.layout.tabs[w.layout.active_tab].id != first_tab and w.layout.tabIndex(first_tab) != null, "sidebar New Workspace uses normal tab creation and shared limits");
    while (w.host.paneCount() < 16) try w.add(.tab);
    t.frame();
    const panes = w.host.paneCount();
    const full_tab_count = w.layout.tab_count;
    t.click(new_control.x + 8, new_control.y + 8);
    try check(w.layout.tab_count == full_tab_count + 1 and full_tab_count > 8 and w.host.paneCount() == panes + 1, "sidebar creates the seventeenth PTY without a fixed workspace ceiling");
    w.close(w.layout.active_pane);
    t.frame();
    try check(w.host.paneCount() == panes, "closing the extra workspace releases only its PTY");
    w.sidebar.focused = true;
    t.key(.end);
    try check(w.sidebar.scroll > 0 and w.layout.active_tab == w.layout.tab_count - 1, "keyboard End selects and reveals the last overflow workspace");
    t.key(.home);
    if (w.layout.active_tab != 0 or w.sidebar.scroll != 0) std.debug.print("SIDEBAR_HOME_DIAGNOSTIC active={d} selected={d} scroll={d} first_row_offset={d} focused={any}\n", .{ w.layout.active_tab, w.sidebar.selected, w.sidebar.scroll, w.sidebar.rowOffset(0), w.sidebar.focused });
    try check(w.layout.active_tab == 0 and w.sidebar.scroll == 0, "keyboard Home restores first workspace and scroll position");
    row = w.sidebar.rowRect(0, w.navigation_rects.navigation);
    t.drag(row.x + 20, row.y + 16, row.x + 20, w.navigation_rects.navigation.h - 50);
    try check(w.layout.tabs[0].pinned and w.layout.tabs[1].pinned and receiver.pid > 0, "drag across pinned and unpinned sections cannot silently unpin or cross the stable partition");
    t.ctx.input.mouse_button = 2;
    row = w.sidebar.rowRect(w.layout.tabIndex(first_tab).?, w.navigation_rects.navigation);
    t.click(row.x + 20, row.y + 18);
    t.ctx.input.mouse_button = 1;
    try check(w.context_menu.open and w.context_menu.target == first_tab, "sidebar right-click opens existing context menu for exact workspace ID");
    t.key(.escape);
    t.frame();
    try check(!w.context_menu.open and !receiver.eof, "context dismissal consumes Escape without sending it to the terminal");
    action(w, t, .{ .action = .toggle_sidebar });
    const persistence = @import("workspace_layout.zig");
    const records = [_]persistence.Record{.{ .id = w.id, .layout = w.layout, .navigation = .{ .width = w.sidebar.width, .collapsed = w.sidebar.collapsed } }};
    const document: persistence.Document = .{ .active = w.id, .next_window_id = w.host.next_window_id, .windows = &records };
    const serialized = try std.json.Stringify.valueAlloc(w.gpa, document, .{});
    defer w.gpa.free(serialized);
    var restored_arena = std.heap.ArenaAllocator.init(w.gpa);
    defer restored_arena.deinit();
    const restored = try persistence.decode(restored_arena.allocator(), serialized, w.cfg.profiles.len);
    try check(restored.windows.len == 1 and restored.windows[0].navigation.collapsed and @abs(restored.windows[0].navigation.width - resized) < 0.1 and restored.windows[0].layout.same(w.layout), "real window display width collapsed preference pin state and tab topology survive versioned layout JSON roundtrip");
    action(w, t, .{ .action = .toggle_sidebar });
}

fn axNode(w: anytype, comptime intent: @import("application_ax_lifecycle.zig").Intent, tab: u64) !u64 {
    const adapter = if (w.ax.adapter) |*value| value else return error.SidebarMissingAccessibility;
    for (w.ax.routes[0..w.ax.route_count]) |route| if (route.intent == intent) {
        for (adapter.routes[0..adapter.route_count]) |target| if (target.node == route.id and target.target.tab == tab) return route.id;
    };
    return error.SidebarMissingAccessibilityControl;
}
