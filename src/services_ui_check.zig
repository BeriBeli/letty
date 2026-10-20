//! M11 hidden real-WindowState/Tester acceptance. This file is deliberately
//! driven through the real combined candidate. No native AX/global
//! registration, visible window, system clipboard or user shell config.
const std = @import("std");
const nano = @import("nanoui");
const ui = nano.ui;
const vt = @import("vt.zig");
const Config = @import("config.zig").Config;
const Profile = @import("config.zig").Profile;
const actions = @import("actions.zig");
const bridge = @import("application_accessibility.zig");
const ax = bridge.ax;
const semantic = @import("ui_semantics.zig");
const Session = @import("session.zig").Session;
const Text = @import("fixed_text.zig").Text;
const control_command = "exec /bin/sh -c 'printf \"M11_CONTROL_READY\\r\\n\"; sleep 30'";
const raw_command = "exec /bin/sh -c 'stty raw -echo || exit 90; printf \"\\r\\n__M11_READY__\\r\\n\"; output=$(od -An -tx1 -N 5); result=$?; printf \"\\r\\n__M11_RESULT__%s__M11_DONE__\\r\\n\" \"$output\"; exit \"$result\"'";
const Original = struct { window: u64, session: u64, pid: c_int };

fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.ServicesUiCheck;
}
fn require(ok: bool) !void {
    if (!ok) return error.ServicesUiInvariant;
}
fn frame(t: *ui.Tester) void {
    t.frame();
}
fn step(t: *ui.Tester) void {
    nano.runFor(0.025);
    t.frame();
}
fn action(w: anytype, t: *ui.Tester, request: actions.Request) void {
    w.menu_actions[0] = request;
    w.menu_action_count = 1;
    t.frame();
    t.frame();
}
fn modalNode(w: anytype, control: semantic.Control, ordinal: u32) !u64 {
    for (w.ax.routes[0..w.ax.route_count]) |route| if (route.modal.surface != .none and route.modal.control == control and route.modal.ordinal == ordinal) return route.id;
    return error.ServicesMissingControl;
}
fn commandNode(w: anytype, command: actions.Action) !u64 {
    for (w.ax.routes[0..w.ax.route_count]) |route| if (route.modal.command) |value| if (value.action == command and (command != .font_up or value.request().amount() == 1)) return route.id;
    return error.ServicesMissingCommand;
}
fn terminalNode(w: anytype, session: u64) !u64 {
    const adapter = if (w.ax.adapter) |*value| value else return error.ServicesMissingAdapter;
    for (adapter.routes[0..adapter.route_count]) |route| if (route.target.session == session) {
        const node = adapter.snapshot.find(route.node) orelse continue;
        if (node.role == .terminal) return node.id;
    };
    return error.ServicesMissingTerminal;
}
fn widget(t: *ui.Tester, id: u64) !ui.Rect {
    for (t.ctx.nodes.items) |node| if (node.id == id) return node.rect;
    return error.ServicesMissingWidget;
}
fn same(a: ax.Bounds, b: ui.Rect) bool {
    return @abs(a.x - b.x) < 0.05 and @abs(a.y - b.y) < 0.05 and @abs(a.width - b.w) < 0.05 and @abs(a.height - b.h) < 0.05;
}
fn enqueue(w: anytype, id: u64, kind: ax.Action) !void {
    const adapter = if (w.ax.adapter) |*value| value else return error.ServicesMissingAdapter;
    try require(adapter.enqueue(id, kind));
}
fn geometry(w: anytype, t: *ui.Tester) !usize {
    const adapter = if (w.ax.adapter) |*value| value else return error.ServicesMissingAdapter;
    var count: usize = 0;
    for (w.ax.routes[0..w.ax.route_count]) |route| if (route.modal.surface != .none) {
        const node = adapter.snapshot.find(route.id) orelse return error.ServicesMissingRecord;
        const rect = try widget(t, route.widget);
        try require(same(node.bounds, rect)); // cards fit fully in this scene
        try require(rect.w > 0 and rect.h > 0 and rect.x >= 0 and rect.y >= 0 and rect.x + rect.w <= t.size.w + 0.05 and rect.y + rect.h <= t.size.h + 0.05);
        count += 1;
    };
    return count;
}
fn text(session: *Session, a: std.mem.Allocator) ![]u8 {
    if (vt.lt_vt_select_all(session.vt) != 0) return error.ServicesNoOutput;
    defer vt.lt_vt_clear_selection(session.vt);
    var buf: [65536]u8 = undefined;
    var len: usize = 0;
    if (vt.lt_vt_copy(session.vt, &buf, buf.len, &len) != 0) return error.ServicesCopyOutput;
    return a.dupe(u8, buf[0..len]);
}
fn waitText(session: *Session, t: *ui.Tester, needle: []const u8) !void {
    for (0..240) |_| {
        step(t);
        if (session.fatal) return error.ServicesPtyFailed;
        const output = text(session, session.gpa) catch |err| switch (err) {
            error.ServicesNoOutput => continue,
            else => return err,
        };
        defer session.gpa.free(output);
        if (std.mem.indexOf(u8, output, needle) != null) return;
        if (session.eof) return error.ServicesPtyExitedEarly;
    }
    return error.ServicesPtyTimeout;
}
fn showClose(w: anytype, t: *ui.Tester, session: *Session) void {
    const refs = [_]@import("close_request.zig").Ref{.{ .id = session.id, .tab = w.layout.tabs[w.layout.active_tab].id }};
    w.close_pending = @import("close_request.zig").Pending.capture(.pane, refs[0].tab, session.id, &refs) catch @panic("close fixture allocation");
    w.confirmation.show(&t.ctx, .close_sessions, "AX Close Fixture", "Close only this isolated fixture? 世界", "Close Fixture");
    t.frame();
}
fn dismiss(w: anytype, t: *ui.Tester) void {
    w.confirmation.dismiss(&t.ctx);
    w.close_pending.deinit();
    w.rename_dialog.dismiss(&t.ctx);
    w.rename_id = null;
    w.palette.dismiss(&t.ctx);
    w.context_menu.dismiss(&t.ctx);
    w.search_open = false;
    w.clearSearch();
    t.ctx.focus = 0;
    t.ctx.input = .{};
    t.frame();
}

pub fn run(s: anytype) !void {
    // The surrounding suite may have many windows. The fixture owns a separate
    // Host registry/arena and never writes any of the surrounding Configs.
    var originals: [16]Original = undefined;
    var count: usize = 0;
    for (s.host.windows) |opt| if (opt) |w| for (w.sessions) |entry| if (entry) |session| {
        try require(count < originals.len);
        originals[count] = .{ .window = w.id, .session = session.id, .pid = session.pid };
        count += 1;
    };
    try isolated(s);
    for (originals[0..count]) |original| {
        const w = s.host.find(original.window) orelse return error.ServicesOriginalWindowChanged;
        var found = false;
        for (w.sessions) |entry| if (entry) |session| if (session.id == original.session and session.pid == original.pid) {
            found = true;
            break;
        };
        try require(found);
    }
    try check(count > 0, "M11 isolated service teardown preserves every original window/session PID");
}
fn isolated(s: anytype) !void {
    const Host = @typeInfo(@TypeOf(s.host)).pointer.child;
    const Window = @typeInfo(@TypeOf(s)).pointer.child;
    var arena = std.heap.ArenaAllocator.init(s.gpa);
    defer arena.deinit();
    const profiles = [_]Profile{.{}};
    const cfg: Config = .{ .shell = "/bin/sh", .shell_integration = .none, .profiles = &profiles, .command = control_command, .copy_on_select = .none, .confirm_close = .always, .clear_default_keybinds = true, .tab_bar = .always };
    var host: Host = .{ .gpa = s.gpa, .arena = arena.allocator(), .app = s.app, .cfg = cfg, .state_path = "/dev/null", .read_path = "/dev/null", .command_override = raw_command, .override_profile = profiles[0].name, .demo = true, .hold = true };
    host.services.init(&host); // stable final Host address, no native start
    defer {
        host.deinit();
        nano.runFor(0.025);
    }
    const w = try host.create(false);
    w.window_focused = true;
    const raw = w.active() orelse return error.ServicesMissingSession;
    const raw_id = raw.id;
    const raw_pid = raw.pid;
    host.command_override = control_command;
    w.command_override = control_command;
    var t: ui.Tester = undefined;
    try t.init(s.gpa, .init(w, Window.view), .{ .width = 900, .height = 620, .theme = @import("appearance.zig").theme(cfg) });
    defer t.deinit();
    try waitText(raw, &t, "__M11_READY__");
    try check(w.window == null and w.ax.adapter != null and w.ax.adapter.?.native == null and w.ax.adapter.?.wake != null and host.services.hotkeys.registry.adapter == null, "M11 real WindowState publishes in-memory AX with no native surface or OS registration");
    try check(w.ax.adapter.?.snapshot.count > 1 and try terminalNode(w, raw_id) != 0, "real postframe callback publishes the visible terminal semantic node");
    try modalChecks(w, &t, raw);
    try keyboardChecks(w, &t, raw);
    try contextChecks(w, &t, raw);
    try navigationChecks(w, &t, raw);
    try visibleChecks(w, &t, raw);
    // Every preceding UI/AX/IME event must have left the raw receiver untouched.
    try check(raw.id == raw_id and raw.pid == raw_pid and !raw.eof and !raw.fatal, "modal/search/IME routes preserve the raw receiver before terminal input is admitted");
    dismiss(w, &t);
    t.key(.tab);
    t.typeText("中Z");
    try waitText(raw, &t, "__M11_DONE__");
    for (0..160) |_| {
        if (raw.eof and raw.status != null) break;
        step(&t);
    }
    const output = try text(raw, s.gpa);
    defer s.gpa.free(output);
    const first = (std.mem.indexOf(u8, output, "__M11_RESULT__") orelse return error.ServicesMissingResult) + "__M11_RESULT__".len;
    const last = std.mem.indexOfPos(u8, output, first, "__M11_DONE__") orelse return error.ServicesMissingResult;
    var tokens = std.mem.tokenizeAny(u8, output[first..last], " \t\r\n");
    var actual: [16]u8 = undefined;
    var len: usize = 0;
    while (tokens.next()) |token| {
        try require(token.len == 2 and len < actual.len);
        actual[len] = try std.fmt.parseInt(u8, token, 16);
        len += 1;
    }
    try check(raw.eof and raw.status != null and raw.status.? == 0 and std.mem.eql(u8, actual[0..len], "\t中Z"), "real raw PTY receives exactly terminal Tab+UTF8 once, with zero leaked modal/IME/search bytes");
    try check(host.count() == 1 and w.ax.adapter.?.native == null and host.services.hotkeys.registry.adapter == null, "service acceptance leaves native AX/global adapters unopened through teardown");
}
fn modalChecks(w: anytype, t: *ui.Tester, raw: *Session) !void {
    showClose(w, t, raw);
    const accept = try modalNode(w, .accept, 0);
    const panel = try modalNode(w, .panel, 0);
    const old = w.ax.adapter.?.snapshot.find(panel).?.bounds;
    try check(try geometry(w, t) >= 4, "message card/body/buttons use actual final postframe bounds");
    t.resize(540, 400);
    const next_panel = try modalNode(w, .panel, 0);
    const moved = w.ax.adapter.?.snapshot.find(next_panel).?.bounds;
    try check(try geometry(w, t) >= 4 and @abs(old.x - moved.x) > 20 and moved.width <= t.size.w, "resized modal records move with final layout instead of retaining prior-frame rectangles");
    const terminal = try terminalNode(w, raw.id);
    try check(!w.ax.adapter.?.enqueue(terminal, .copy), "published modal subtree refuses background terminal AX actions");
    try enqueue(w, accept, .press);
    try check(w.confirmation.open and w.ax.adapter.?.request_count == 1 and w.confirmation.ax_pending == null, "native-like AX enqueue only stores owned IDs and never accepts a prompt synchronously");
    w.close_pending.ids[0] +%= 0x100000; // pending operation changed without reopening
    t.frame();
    try check(w.confirmation.open and w.ax.adapter.?.request_count == 0 and !raw.eof, "pending-operation stamp rejects an old queued accept before deferred execution");
    const stale = try modalNode(w, .accept, 0);
    try enqueue(w, stale, .press);
    const generation = w.confirmation.generation;
    w.confirmation.dismiss(&t.ctx);
    showClose(w, t, raw); // begin must reject the queued previous generation
    const current = try modalNode(w, .accept, 0);
    try check(w.confirmation.open and w.confirmation.generation > generation and current != stale and !raw.eof, "closing and reopening the same prompt assigns new AX IDs and rejects the old queued accept");
    try check(!w.ax.adapter.?.enqueue(stale, .press), "republished modal snapshot cannot enqueue a retired control ID");
    try enqueue(w, try modalNode(w, .cancel, 0), .press);
    try check(w.confirmation.open, "AX Cancel is deferred until the next application frame");
    t.frame();
    try check(!w.confirmation.open and w.close_pending.count == 0 and !raw.eof, "deferred Cancel follows the real dialog transaction without closing the PTY");
    t.resize(900, 620);
    t.frame();
    action(w, t, .{ .action = .palette });
    try check(w.palette.open and try geometry(w, t) >= 3, "command palette publishes actual menu/query/command geometry");
    t.typeText("increase_font_size"); // AX exposes only current virtual rows.
    t.frame();
    const font = w.cfg.font_size;
    try enqueue(w, try commandNode(w, .font_up), .press);
    try check(w.palette.open and w.cfg.font_size == font, "palette native callback queues a typed action without mutating configuration");
    t.frame();
    t.frame();
    try check(!w.palette.open and w.cfg.font_size == font + 1 and !raw.eof, "palette AX command dispatches once through the real typed application action");
}
fn keyboardChecks(w: anytype, t: *ui.Tester, raw: *Session) !void {
    w.confirmation.show(&t.ctx, .diagnostics, "AX Keyboard Fixture", "Controlled copied details 世界", "Unused Open Config");
    t.frame();
    const copy_id = try modalNode(w, .copy, 0);
    try enqueue(w, copy_id, .focus);
    t.frame();
    const before = t.ctx.focus;
    _ = t.shortcut(.{ .key = ui.Shortcut.tab });
    try check(t.ctx.focus != before and w.confirmation.open, "Tab traverses real modal controls before terminal shortcuts");
    _ = t.shortcut(.{ .key = ui.Shortcut.tab, .shift = true });
    try check(t.ctx.focus == before and w.confirmation.open, "Shift-Tab reverses the same modal focus traversal");
    t.key(.enter);
    try check(w.confirmation.open and std.mem.eql(u8, t.clipboard.items, "Controlled copied details 世界"), "Enter on the AX-focused Copy Details button uses the private Tester clipboard");
    try enqueue(w, try modalNode(w, .cancel, 0), .press);
    t.frame();
    const tab = w.layout.tabs[w.layout.active_tab].id;
    action(w, t, .{ .action = .rename_tab });
    try check(w.rename_dialog.open and w.rename_id == tab and try geometry(w, t) == 4, "rename field and buttons expose a real dialog with a stable tab target");
    // Queue while Accept is enabled, then deliver the IME event before its
    // deferred dispatch. Once composing is published, Accept is correctly
    // disabled and cannot accept a new native action at all.
    try enqueue(w, try modalNode(w, .accept, 0), .press);
    t.textOps(&.{.{ .set_marked = .{ .text = "拼", .sel_start = "拼".len, .sel_len = 0 } }});
    const marked = if (t.ctx.focused_text) |field| field.marked != null else false;
    const query = w.rename_dialog.geometry.find(.query, 0) orelse return error.ServicesMissingControl;
    t.frame();
    const composition_error = if (w.ax.last_error) |err| std.mem.eql(u8, @errorName(err), "AccessibilityCompositionActive") else false;
    try check(w.rename_dialog.open and t.ctx.focus == query.widget and w.ax.adapter.?.request_count == 0 and composition_error, "queued AX accept cannot commit or steal focus from active IME composition");
    const still_marked = if (t.ctx.focused_text) |field| field.marked != null else false;
    try check(still_marked and !raw.eof, "rejected AX action preserves owned marked text and live PTY");
    _ = t.shortcut(.{ .key = ui.Shortcut.tab });
    try check(marked and w.rename_dialog.open and t.ctx.focus == query.widget, "active IME composition keeps focus in the field and blocks AX Tab traversal");
    t.textOps(&.{.unmark});
    w.rename_dialog.text.set("AX Owned 中");
    t.frame();
    try enqueue(w, try modalNode(w, .accept, 0), .focus);
    t.frame();
    t.key(.enter);
    t.frame();
    try check(!w.rename_dialog.open and std.mem.eql(u8, w.layout.tabs[w.layout.tabIndex(tab).?].name(), "AX Owned 中"), "Enter accepts the exact live rename target through its real dialog result");
    action(w, t, .{ .action = .search });
    t.typeText("never-send-to-pty");
    const field = t.ctx.focus;
    _ = t.shortcut(.{ .key = ui.Shortcut.tab });
    const button = t.ctx.focus;
    _ = t.shortcut(.{ .key = ui.Shortcut.tab, .shift = true });
    try check(w.search_open and field != 0 and button != field and t.ctx.focus == field, "search Tab cycles its controls and Shift-Tab restores the real query field");
    t.key(.escape);
    t.frame();
    try check(!w.search_open and !raw.eof, "Escape exits search without sending modal traversal or query text to the PTY");
}
fn contextChecks(w: anytype, t: *ui.Tester, raw: *Session) !void {
    const original = w.layout.tabs[w.layout.active_tab].id;
    action(w, t, .{ .action = .tab });
    const other = w.active() orelse return error.ServicesMissingSession;
    const other_id = other.id;
    const other_tab = w.layout.tabs[w.layout.active_tab].id;
    w.activateTab(w.layout.tabIndex(original).?);
    t.ctx.input.mouse = .{ .x = 80, .y = 20 };
    w.openContext(&t.ctx, .tab, original);
    t.frame();
    try check(w.context_menu.open and try geometry(w, t) >= 3, "context menu publishes real visible rows and their captured typed commands");
    const rename = try commandNode(w, .rename_tab);
    try enqueue(w, rename, .press);
    w.activateTab(w.layout.tabIndex(other_tab).?); // callback target cannot follow this
    t.frame();
    t.frame();
    try check(w.rename_dialog.open and w.rename_id == original and w.active().?.id == raw.id and w.sessions[w.layout.active_pane].?.id != other_id, "queued context action resolves its original tab after active-tab switching");
    w.rename_dialog.dismiss(&t.ctx);
    w.rename_id = null;
    t.frame();
    w.activateTab(w.layout.tabIndex(other_tab).?);
    action(w, t, .{ .action = .close_tab });
    // Avoid a real close confirmation in this controlled cleanup only.
    if (w.confirmation.open) {
        w.confirmation.dismiss(&t.ctx);
        w.close_pending.deinit();
        w.cfg.confirm_close = .never;
        action(w, t, .{ .action = .close_tab });
        w.cfg.confirm_close = .always;
    }
    try check(w.layout.tab_count == 1 and w.active().?.id == raw.id and !raw.eof, "closing the context fixture preserves the receiver's original PID and tab");
}
fn navigationChecks(w: anytype, t: *ui.Tester, raw: *Session) !void {
    const adapter = if (w.ax.adapter) |*value| value else return error.ServicesMissingAdapter;
    var roles: usize = 0;
    for ([_]ax.Role{ .tab_group, .tab, .pane }) |role| {
        var found = false;
        for (w.ax.routes[0..w.ax.route_count]) |route| {
            const node = adapter.snapshot.find(route.id) orelse continue;
            if (node.role != role) continue;
            try require(same(node.bounds, try widget(t, route.widget)));
            found = true;
            break;
        }
        if (found) roles += 1;
    }
    try check(roles == 3, "tab group/tab/pane AX nodes retain actual final widget geometry");
    for (0..80) |_| try vt.feed(raw.vt, "AX controlled history row\r\n");
    t.frame();
    var bar: ?u64 = null;
    for (adapter.routes[0..adapter.route_count]) |route| {
        const node = adapter.snapshot.find(route.node) orelse continue;
        if (node.role == .scrollbar and route.target.session == raw.id) {
            bar = node.id;
            break;
        }
    }
    const id = bar orelse return error.ServicesMissingScrollbar;
    var before: vt.Scroll = .{};
    vt.lt_vt_scroll_info(raw.vt, &before);
    try require(before.total > before.len and before.offset > 0);
    try enqueue(w, id, .decrement);
    var queued: vt.Scroll = .{};
    vt.lt_vt_scroll_info(raw.vt, &queued);
    t.frame();
    var earlier: vt.Scroll = .{};
    vt.lt_vt_scroll_info(raw.vt, &earlier);
    try check(queued.offset == before.offset and earlier.offset < before.offset, "scrollbar decrement is deferred and scrolls the captured live VT by a real page");
    try enqueue(w, id, .increment);
    t.frame();
    var restored: vt.Scroll = .{};
    vt.lt_vt_scroll_info(raw.vt, &restored);
    try check(restored.offset == before.offset and !raw.eof, "scrollbar increment restores the same viewport without writing PTY input");
}
fn visibleChecks(w: anytype, t: *ui.Tester, raw: *Session) !void {
    dismiss(w, t);
    try vt.feed(raw.vt, "\x1b[2J\x1b[HA中e\xcc\x81\x1b[8mSECRET\x1b[0mB\x1b[1;4H\x1b[?25h");
    vt.lt_vt_select(raw.vt, 1, 0, 0);
    vt.lt_vt_select(raw.vt, 3, 0, 1);
    t.frame();
    const id = try terminalNode(w, raw.id);
    const adapter = if (w.ax.adapter) |*value| value else return error.ServicesMissingAdapter;
    const node = adapter.snapshot.find(id) orelse return error.ServicesMissingTerminal;
    const value = adapter.snapshot.value(node.*);
    try check(std.mem.startsWith(u8, value, "A中e\xcc\x81") and std.mem.indexOf(u8, value, "SECRET") == null and std.unicode.utf8ValidateSlice(value), "visible terminal AX preserves CJK/combining UTF8 while conceal text is absent");
    try require(node.selection_start <= node.selection_end and node.selection_end <= value.len and node.caret <= value.len);
    const selection = value[node.selection_start..node.selection_end];
    try check(std.mem.eql(u8, selection, "中e\xcc\x81") and node.caret == "A中".len and std.unicode.utf8ValidateSlice(selection), "AX selection and caret byte offsets respect wide CJK and combining-cell boundaries");
    try enqueue(w, id, .copy);
    t.frame();
    try check(std.mem.eql(u8, t.clipboard.items, "中e\xcc\x81"), "terminal AX Copy reuses exact live selection and the private Tester clipboard");
    vt.lt_vt_clear_selection(raw.vt);
    // The OS tree owns bytes after source/frame changes, until a later publish.
    var owned: Text(4096) = .{};
    owned.set(value);
    try vt.feed(raw.vt, "\x1b[2J\x1b[HCHANGED");
    try check(std.mem.eql(u8, adapter.snapshot.value(node.*), owned.text()), "published AX visible text survives a later VT mutation without retaining frame pointers");
    t.frame();
    const updated = adapter.snapshot.find(try terminalNode(w, raw.id)).?;
    try check(std.mem.startsWith(u8, adapter.snapshot.value(updated.*), "CHANGED"), "next postframe transaction replaces the prior owned visible-text snapshot");
    try vt.feed(raw.vt, "\x1b[2J\x1b[HCOPY CURRENT \x1b[8mPRIVATE\x1b[0m visible");
    try enqueue(w, id, .copy);
    t.frame();
    try check(std.mem.startsWith(u8, t.clipboard.items, "COPY CURRENT ") and std.mem.indexOf(u8, t.clipboard.items, "PRIVATE") == null and std.mem.indexOf(u8, t.clipboard.items, "CHANGED") == null and std.mem.indexOf(u8, t.clipboard.items, "AX controlled history") == null and t.clipboard.items.len <= 4096, "terminal AX Copy without selection reads fresh bounded visible text and excludes concealed/history content");
}
