//! Hidden Tester + real PTY acceptance for M7. No desktop input or clipboard.
const std = @import("std");
const nano = @import("nanoui");
const ui = nano.ui;
const keys = @import("keybindings.zig");
const actions = @import("actions.zig");
const vt = @import("vt.zig");
const c = @import("platform_ffi.zig");
const Session = @import("session.zig").Session;
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn unlink([*:0]const u8) c_int;
extern "c" fn rmdir([*:0]const u8) c_int;
extern "c" fn lt_mkdirs([*:0]const u8) c_int;
extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
extern "c" fn unsetenv([*:0]const u8) c_int;
const Original = struct { id: u64, pid: c_int };
const ready = "__M7_RAW_READY__";
const done = "__M7_RAW_DONE__";
const control_command = "exec /bin/sh -c 'printf \"M7_CONTROL_READY\\r\\n\"; sleep 30'";

fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.BindingUiCheck;
}
fn action(s: anytype, t: *ui.Tester, request: actions.Request) void {
    s.menu_actions[0] = request;
    s.menu_action_count = 1;
    t.frame();
}
fn step(t: *ui.Tester) void {
    nano.runFor(0.025);
    t.frame();
}
fn prefix(s: anytype, t: *ui.Tester) !void {
    try check(t.shortcut(.{ .key = 'b', .ctrl = true }) and s.binding_state.active(), "sequence prefix is consumed and retained by its window");
}
fn quiet(s: anytype, t: *ui.Tester) !void {
    for (0..160) |_| {
        step(t);
        if (!s.binding_timer_pending) return;
    }
    return error.BindingTimerTimeout;
}
fn cancelled(s: anytype, t: *ui.Tester, font: f32, label: []const u8) !void {
    try check(!s.binding_state.active(), label);
    try quiet(s, t);
    try check(s.cfg.font_size == font, "cancelled prefix cannot dispatch its fallback from a late timer");
}
fn originalContains(originals: []const Original, id: u64) bool {
    for (originals) |entry| if (entry.id == id) return true;
    return false;
}
fn closeNew(s: anytype, originals: []const Original) void {
    for (s.sessions, 0..) |entry, slot| if (entry) |session| {
        if (!originalContains(originals, session.id)) s.close(@intCast(slot));
    };
}
fn body(session: *Session, a: std.mem.Allocator) ![]u8 {
    if (vt.lt_vt_select_all(session.vt) != 0) return error.BindingNoTerminalText;
    defer vt.lt_vt_clear_selection(session.vt);
    var buffer: [65536]u8 = undefined;
    var len: usize = 0;
    if (vt.lt_vt_copy(session.vt, &buffer, buffer.len, &len) != 0 or len > buffer.len) return error.BindingCopy;
    return a.dupe(u8, buffer[0..len]);
}
fn waitText(session: *Session, t: *ui.Tester, needle: []const u8) !void {
    for (0..240) |_| {
        step(t);
        if (session.fatal) return error.BindingPtyFailed;
        const text = body(session, session.gpa) catch |err| switch (err) {
            error.BindingNoTerminalText => continue,
            else => return err,
        };
        defer session.gpa.free(text);
        if (std.mem.indexOf(u8, text, needle) != null) return;
        if (session.eof) return error.BindingPtyExitedBeforeMarker;
    }
    return error.BindingPtyMarkerTimeout;
}
fn receiver(s: anytype, t: *ui.Tester, count: usize) !*Session {
    const command = try std.fmt.allocPrint(s.gpa, "exec /bin/sh -c 'stty raw -echo || exit 90; printf \"\\r\\n{s}\\r\\n\"; od -An -tx1 -N {d}; result=$?; printf \"\\r\\n{s}\\r\\n\"; exit \"$result\"'", .{ ready, count, done });
    defer s.gpa.free(command);
    const old = s.command_override;
    s.command_override = command;
    defer s.command_override = old;
    const tabs = s.layout.tab_count;
    action(s, t, .{ .action = .tab });
    if (s.layout.tab_count != tabs + 1) return error.BindingReceiverNotCreated;
    const session = s.active() orelse return error.BindingReceiverNotCreated;
    try waitText(session, t, ready);
    try check(!session.eof and !session.fatal, "raw od receiver signals READY only after disabling echo and canonical processing");
    return session;
}
fn received(session: *Session, t: *ui.Tester, expected: []const u8) !void {
    try waitText(session, t, done);
    for (0..160) |_| {
        if (session.status != null and session.eof) break;
        step(t);
    }
    try check(!session.fatal and session.eof and session.status != null and session.status.? == 0, "isolated raw od child consumes its exact byte count and exits normally");
    const text = try body(session, session.gpa);
    defer session.gpa.free(text);
    const start = (std.mem.indexOf(u8, text, ready) orelse return error.BindingMissingReady) + ready.len;
    const end = std.mem.indexOfPos(u8, text, start, done) orelse return error.BindingMissingDone;
    var tokens = std.mem.tokenizeAny(u8, text[start..end], " \t\r\n");
    var bytes: [64]u8 = undefined;
    var len: usize = 0;
    while (tokens.next()) |token| {
        if (token.len != 2 or len == bytes.len) return error.BindingInvalidOdOutput;
        bytes[len] = try std.fmt.parseInt(u8, token, 16);
        len += 1;
    }
    try check(std.mem.eql(u8, expected, bytes[0..len]), "real PTY receiver reports the exact ordered bytes without prefix replay or duplication");
}

fn windows(s: anytype, t: *ui.Tester) !void {
    const h = s.host;
    h.cfg = s.cfg;
    h.command_override = control_command;
    h.cwd_override = s.cwd_override;
    h.override_profile = s.override_profile;
    h.chosen = s.profile;
    const other = try h.create(false);
    other.retain();
    defer other.release();
    var second: ui.Tester = undefined;
    try second.init(s.gpa, .init(other, @TypeOf(s.*).view), .{ .width = 800, .height = 500, .theme = t.theme });
    defer second.deinit();
    defer if (!other.closing) h.closeWindow(other);
    const first_tabs = s.layout.tab_count;
    const second_tabs = other.layout.tab_count;
    h.activate(s, false);
    s.window_focused = true;
    t.frame();
    try prefix(s, t);
    h.activate(other, false);
    other.window_focused = true;
    second.frame();
    second.typeText("t");
    try check(!s.binding_state.active() and !other.binding_state.active() and
        s.layout.tab_count == first_tabs and other.layout.tab_count == second_tabs, "switching hidden windows cancels the old prefix and never completes it in the other window");
    try prefix(other, &second);
    h.activate(s, false);
    s.window_focused = true;
    t.typeText("t");
    try check(!other.binding_state.active() and !s.binding_state.active() and s.layout.tab_count == first_tabs, "prefix ownership stays isolated in both window-switch directions");
    h.closeWindow(other);
    for (0..160) |_| {
        step(t);
        if (!other.binding_timer_pending and !s.binding_timer_pending) break;
    }
    try check(h.count() == 1 and !other.binding_timer_pending, "closing a window safely drains its retained one-shot binding callback");
    h.activate(s, false);
    s.window_focused = true;
}

pub fn run(s: anytype, t: *ui.Tester) !void {
    try check(s.host.count() == 1 and s.window_focused, "M7 acceptance starts in one focused hidden window");
    if (lt_mkdirs(".cache/test-logs") != 0) return error.BindingTempDirectory;
    const template = try s.gpa.dupeSentinel(u8, ".cache/test-logs/bindings-XXXXXX", 0);
    defer s.gpa.free(template);
    const dir = mkdtemp(template) orelse return error.BindingTempDirectory;
    defer _ = rmdir(dir);
    var absolute: [4096]u8 = undefined;
    if (c.lt_absolute_path(dir, &absolute, absolute.len) != 0) return error.BindingTempDirectory;
    const home = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&absolute)), 0);
    const home_z = try s.gpa.dupeSentinel(u8, home, 0);
    defer s.gpa.free(home_z);
    const path = try std.fmt.allocPrintSentinel(s.gpa, "{s}/reload.json", .{home}, 0);
    defer s.gpa.free(path);
    defer _ = unlink(path);
    const old_home = if (getenv("HOME")) |value| try s.gpa.dupeSentinel(u8, std.mem.span(value), 0) else null;
    defer if (old_home) |value| s.gpa.free(value);
    if (setenv("HOME", home_z, 1) != 0) return error.BindingEnvironment;
    defer {
        if (old_home) |value| _ = setenv("HOME", value, 1) else _ = unsetenv("HOME");
    }
    const h = s.host;
    var originals: [16]Original = undefined;
    var count: usize = 0;
    for (s.sessions) |entry| if (entry) |session| {
        originals[count] = .{ .id = session.id, .pid = session.pid };
        count += 1;
    };
    const old_cfg = s.cfg;
    const old_host_cfg = h.cfg;
    const old_command = s.command_override;
    const old_cwd = s.cwd_override;
    const old_override = s.override_profile;
    const old_profile = s.profile;
    const old_hold = s.hold;
    const old_base_font = s.base_font_size;
    const old_explicit = s.explicit_config;
    const old_query = s.query;
    const old_tab = s.layout.tabs[s.layout.active_tab].id;
    const old_pane = s.layout.active_pane;
    const old_size = t.size;
    const host_command = h.command_override;
    const host_cwd = h.cwd_override;
    const host_override = h.override_profile;
    const host_chosen = h.chosen;
    // Keep the previous owner alive across the real successful reload below.
    // Old Config snapshots borrow this storage and must never be restored dead.
    var previous_arena = h.config_arena;
    h.config_arena = null;
    defer {
        @import("input_dispatch.zig").cancel(s, .reload);
        s.search_open = false;
        s.palette.dismiss(&t.ctx);
        s.confirmation.dismiss(&t.ctx);
        s.clearSearch();
        closeNew(s, originals[0..count]);
        if (h.config_arena) |*temporary| temporary.deinit();
        h.config_arena = previous_arena;
        previous_arena = null;
        h.cfg = old_host_cfg;
        h.command_override = host_command;
        h.cwd_override = host_cwd;
        h.override_profile = host_override;
        h.chosen = host_chosen;
        s.cfg = old_cfg;
        s.command_override = old_command;
        s.cwd_override = old_cwd;
        s.override_profile = old_override;
        s.profile = old_profile;
        s.hold = old_hold;
        s.base_font_size = old_base_font;
        s.explicit_config = old_explicit;
        s.query = old_query;
        s.window_focused = true;
        for (s.views) |*view| view.preedit.clearRetainingCapacity();
        if (s.layout.tabIndex(old_tab)) |index| {
            s.layout.activate(index);
            s.layout.focus(old_pane);
        }
        h.active_id = s.id;
        for (s.sessions) |entry| if (entry) |session| s.configureSession(session);
        t.resize(old_size.w, old_size.h);
    }
    s.cfg.confirm_close = .never;
    s.cfg.shell = "/bin/sh";
    s.cfg.shell_integration = .none;
    s.cfg.copy_on_select = .none;
    s.cfg.clear_default_keybinds = true;
    s.cfg.keybind_sequence_timeout = 300;
    s.override_profile = s.cfg.profiles[s.profile].name;
    s.command_override = control_command;
    s.cwd_override = home;
    s.hold = true;
    t.resize(1000, 680);
    action(s, t, .{ .action = .tab });
    const control = s.active() orelse return error.BindingControlMissing;
    if (originalContains(originals[0..count], control.id)) return error.BindingControlMissing;
    try waitText(control, t, "M7_CONTROL_READY");

    const complete = [_]keys.Binding{ try keys.parse("ctrl+b=increase_font_size:1"), try keys.parse("ctrl+b>t=new_tab") };
    s.cfg.keybinds = &complete;
    const font = s.cfg.font_size;
    const tabs = s.layout.tab_count;
    try prefix(s, t);
    try check(s.cfg.font_size == font and s.layout.tab_count == tabs, "ambiguous complete prefix does not fire its action before a continuation");
    t.typeText("t");
    try check(!s.binding_state.active() and s.layout.tab_count == tabs + 1 and s.cfg.font_size == font, "ctrl+b then plain t dispatches exactly one real new-tab action");
    action(s, t, .{ .action = .close_tab });
    try quiet(s, t);
    const delayed = [_]keys.Binding{ try keys.parse("ctrl+b=increase_font_size:1"), try keys.parse("ctrl+b>t>z=increase_font_size:3") };
    s.cfg.keybinds = &delayed;
    try prefix(s, t);
    const deadline = s.binding_state.matcher.deadline_ms;
    nano.runFor(0.05);
    t.typeText("t");
    try check(s.binding_state.active() and s.binding_state.matcher.deadline_ms == deadline and s.cfg.font_size == font, "intermediate chord preserves the first one-shot deadline without dispatching");
    try quiet(s, t);
    try check(s.cfg.font_size == font + 1 and !s.binding_state.active(), "one-shot expiry runs the deferred complete action exactly once");
    for (0..20) |_| step(t);
    try check(s.cfg.font_size == font + 1 and !s.binding_timer_pending, "idle frames after expiry cannot repeat the fallback or keep polling");

    s.cfg.keybinds = &complete;
    const unchanged_font = s.cfg.font_size;
    try prefix(s, t);
    t.key(.escape);
    try cancelled(s, t, unchanged_font, "Escape consumes cancellation without executing the shorter action");
    try prefix(s, t);
    s.window_focused = false;
    s.syncFocus();
    t.frame();
    s.window_focused = true;
    s.syncFocus();
    try cancelled(s, t, unchanged_font, "real window focus routing cancels a pending sequence");
    try prefix(s, t);
    action(s, t, .{ .action = .palette });
    try check(s.palette.open, "command palette opens through the shared dispatcher during a prefix");
    try cancelled(s, t, unchanged_font, "opening an application overlay cancels the pending sequence");
    t.key(.escape);
    try prefix(s, t);
    s.query.clear();
    action(s, t, .{ .action = .search });
    t.typeText("t");
    try check(s.search_open and std.mem.eql(u8, s.query.text(), "t") and s.layout.tab_count == tabs, "search field receives its text before sequence continuation routing");
    try cancelled(s, t, unchanged_font, "search entry cancels the previous terminal prefix");
    t.key(.escape);
    try prefix(s, t);
    t.textOps(&.{.{ .set_marked = .{ .text = "中", .sel_start = 1, .sel_len = 0 } }});
    try check(s.views[s.layout.active_pane].preedit.items.len > 0, "IME marked text reaches the terminal preedit owner");
    try cancelled(s, t, unchanged_font, "IME composition has priority and cancels the shortcut prefix");
    t.textOps(&.{.unmark});
    try windows(s, t);

    const reload_text = try std.json.Stringify.valueAlloc(s.gpa, .{ .shell = "/bin/sh", .shell_integration = "none", .confirm_close = "never", .copy_on_select = "none", .restore_layout = false, .font_size = s.cfg.font_size, .profiles = s.cfg.profiles, .keybinds = &complete, .clear_default_keybinds = true, .keybind_sequence_timeout = 300 }, .{});
    defer s.gpa.free(reload_text);
    if (c.lt_write_atomic(path, reload_text.ptr, reload_text.len) != 0) return error.BindingReloadFile;
    s.explicit_config = path;
    try prefix(s, t);
    action(s, t, .{ .action = .reload });
    try check(h.config_arena != null and !s.confirmation.open, "isolated valid binding configuration is adopted by the real reload transaction");
    try cancelled(s, t, unchanged_font, "successful shared configuration reload cancels pending sequence IDs");

    const before_short = s.cfg.font_size;
    s.cfg.keybind_sequence_timeout = 1000;
    try prefix(s, t);
    @import("input_dispatch.zig").cancel(s, .reload);
    try check(!s.binding_timer_pending and !s.binding_state.active(), "cancelling a long deadline immediately retires its one-shot callback");
    s.cfg.keybind_sequence_timeout = 50;
    try prefix(s, t);
    nano.runFor(0.08);
    t.frame();
    try check(s.cfg.font_size == before_short + 1 and !s.binding_state.active() and !s.binding_timer_pending, "replacement 50ms deadline fires after 80ms without waiting for the cancelled 1000ms timer");
    for (0..8) |_| step(t);
    try check(s.cfg.font_size == before_short + 1, "short replacement deadline dispatches its fallback exactly once");
    s.cfg.keybind_sequence_timeout = 300;

    const expected = "中e\xcc\x81\\\x1b\x00\x1b[31m\x1bc";
    const raw = try receiver(s, t, expected.len);
    {
        var arena = std.heap.ArenaAllocator.init(s.gpa);
        defer arena.deinit();
        const specs = [_][]const u8{ "ctrl+x=text:中e\\u{301}\\\\\\x1b\\x00", "ctrl+y=csi:31m", "ctrl+z=esc:c" };
        for (specs, 0..) |spec, index| {
            const source = try arena.allocator().dupe(u8, spec);
            const binding = try keys.parse(source);
            s.menu_actions[index] = binding.request();
        }
        s.menu_action_count = specs.len;
    }
    // Source arena is already gone when this frame dispatches all three
    // owning requests through the normal application/Session queue path.
    t.frame();
    try received(raw, t, expected);
    action(s, t, .{ .action = .close_tab });
    s.cfg.keybinds = &complete;
    const mismatch = try receiver(s, t, 2);
    const before_mismatch = s.cfg.font_size;
    const mismatch_tabs = s.layout.tab_count;
    try prefix(s, t);
    t.typeText("q");
    t.typeText("Z");
    try received(mismatch, t, "qZ");
    try check(s.cfg.font_size == before_mismatch + 1 and s.layout.tab_count == mismatch_tabs, "unmatched last key executes only its pending fallback and routes the current key once");
    action(s, t, .{ .action = .close_tab });
    try quiet(s, t);
    closeNew(s, originals[0..count]);
    var intact = h.count() == 1 and h.paneCount() == count;
    for (originals[0..count]) |entry| {
        var found = false;
        for (s.sessions) |opt| if (opt) |session| if (session.id == entry.id and session.pid == entry.pid) {
            found = true;
        };
        intact = intact and found;
    }
    try check(intact, "M7 test windows and tabs close without replacing any original PTY PID");
}
