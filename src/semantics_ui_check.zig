//! Real local-shell semantics and focus routing, with isolated startup files.
const std = @import("std");
const builtin = @import("builtin");
const nano = @import("nanoui");
const ui = nano.ui;
const vt_api = @import("vt.zig");
const c = @import("platform_ffi.zig");
const cfg = @import("config.zig");
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
extern "c" fn unsetenv([*:0]const u8) c_int;
extern "c" fn unlink([*:0]const u8) c_int;
extern "c" fn rmdir([*:0]const u8) c_int;
extern "c" fn lt_mkdirs([*:0]const u8) c_int;
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.SemanticsUiCheck;
}
fn action(s: anytype, t: *ui.Tester, a: @import("actions.zig").Action) void {
    s.menu_actions[0] = .{ .action = a };
    s.menu_action_count = 1;
    t.frame();
}
fn drain(t: *ui.Tester) void {
    for (0..12) |_| {
        nano.runFor(0.025);
        t.frame();
    }
}
const Focus = struct {
    gained: usize = 0,
    lost: usize = 0,
    last: u64 = 0,
    fn receive(data: *anyopaque, id: u64, bytes: []const u8) void {
        const f: *Focus = @ptrCast(@alignCast(data));
        f.last = id;
        if (std.mem.eql(u8, bytes, "\x1b[I")) f.gained += 1;
        if (std.mem.eql(u8, bytes, "\x1b[O")) f.lost += 1;
    }
};
pub fn run(s: anytype, t: *ui.Tester, view: ui.View) !void {
    s.cfg.confirm_close = .never;
    if (s.layout.tab_count > 1) action(s, t, .close_other_tabs);
    const template = try s.gpa.dupeSentinel(u8, ".cache/test-logs/shell-XXXXXX", 0);
    defer s.gpa.free(template);
    const dir = mkdtemp(template) orelse return error.TempDirectory;
    var absolute: [4096]u8 = undefined;
    if (c.lt_absolute_path(dir, &absolute, absolute.len) != 0) return error.TempDirectory;
    const home = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&absolute)), 0);
    const home_z = try s.gpa.dupeSentinel(u8, home, 0);
    defer s.gpa.free(home_z);
    const child = try std.fmt.allocPrintSentinel(s.gpa, "{s}/a b", .{home}, 0);
    defer s.gpa.free(child);
    _ = lt_mkdirs(child);
    defer {
        _ = rmdir(child);
        _ = rmdir(dir);
    }
    const rc = try std.fmt.allocPrintSentinel(s.gpa, "{s}/{s}", .{ home, if (builtin.os.tag == .macos) ".zshrc" else ".bashrc" }, 0);
    defer s.gpa.free(rc);
    defer _ = unlink(rc);
    const contents = if (builtin.os.tag == .macos)
        "HISTFILE=/dev/null\nPROMPT='LETTY_TEST> '\nprecmd() { printf 'USER_HOOK_OK\\n'; }\n"
    else
        "HISTFILE=/dev/null\nPS1='LETTY_TEST> '\nPROMPT_COMMAND=\"printf 'USER_HOOK_OK\\\\n'\"\ntrap ':' DEBUG\n";
    try check(c.lt_write_atomic(rc, contents, contents.len) == 0, "prepare isolated shell startup file");
    const old_home = try s.gpa.dupeSentinel(u8, std.mem.span(c.lt_env("HOME")), 0);
    defer s.gpa.free(old_home);
    const old_zdot = try s.gpa.dupeSentinel(u8, std.mem.span(c.lt_env("ZDOTDIR")), 0);
    defer s.gpa.free(old_zdot);
    _ = setenv("HOME", home_z, 1);
    _ = setenv("ZDOTDIR", home_z, 1);
    defer {
        _ = setenv("HOME", old_home, 1);
        if (old_zdot.len > 0) _ = setenv("ZDOTDIR", old_zdot, 1) else _ = unsetenv("ZDOTDIR");
    }
    const old = s.cfg;
    const old_command = s.command_override;
    const old_cwd = s.cwd_override;
    defer {
        s.cfg = old;
        s.command_override = old_command;
        s.cwd_override = old_cwd;
    }
    var profiles = [_]cfg.Profile{.{}};
    s.cfg.profiles = &profiles;
    s.profile = 0;
    s.cfg.shell = if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/bash";
    s.cfg.command = "";
    s.cfg.working_directory = home;
    s.cfg.shell_integration = .detect;
    s.cfg.confirm_close = .never;
    s.command_override = null;
    s.cwd_override = null;
    s.active().?.cwd.set("");
    try @import("directory_ui_check.zig").run(s, t, home, child);
    action(s, t, .tab);
    const shell = s.active().?;
    drain(t);
    if (!(shell.integrated and shell.events.prompts > 0 and shell.idle())) {
        std.debug.print("Shell startup integrated={any} prompts={d} idle={any} status={any} eof={any}\n", .{ shell.integrated, shell.events.prompts, shell.idle(), shell.status, shell.eof });
        var cursor: vt_api.Cursor = .{};
        if (vt_api.lt_vt_frame(shell.vt, &cursor) == 0) {
            defer vt_api.lt_vt_frame_end(shell.vt);
            var cell: vt_api.Cell = undefined;
            while (vt_api.lt_vt_next(shell.vt, &cell)) if (cell.len > 0) std.debug.print("{s}", .{cell.text.?[0..cell.len]});
            std.debug.print("\n", .{});
        }
    }
    try check(shell.integrated and shell.events.prompts > 0 and shell.idle(), "injected local shell reaches a reliable idle prompt");
    try @import("prompt_clear_ui_check.zig").run(s, t, shell);
    try check(std.mem.eql(u8, shell.cwd.text(), home), "explicit working directory reaches the integrated shell through OSC 7");
    _ = vt_api.lt_vt_search(shell.vt, "USER_HOOK_OK", 12);
    var found: usize = 0;
    while (vt_api.lt_vt_search_tick(shell.vt, &found) > 0) {}
    vt_api.lt_vt_search_close(shell.vt);
    try check(found > 0, "existing user prompt hook remains active after shell integration");
    t.typeText("cd 'a b'");
    t.key(.enter);
    drain(t);
    try check(std.mem.eql(u8, shell.cwd.text(), child), "cd reports percent-decoded local directory containing a space");
    action(s, t, .horizontal);
    drain(t);
    const inherited = s.active().?;
    try check(inherited.integrated and std.mem.eql(u8, inherited.cwd.text(), child) and inherited.pid != shell.pid, "new split inherits active CWD through a fresh PTY");
    s.cfg.split_inherit_working_directory = false;
    action(s, t, .vertical);
    drain(t);
    try check(std.mem.eql(u8, s.active().?.cwd.text(), home), "disabled split directory inheritance uses configured initial directory");
    action(s, t, .close);
    s.cfg.split_inherit_working_directory = true;
    // Return to the source with a different directory before testing new tabs.
    for (s.sessions, 0..) |opt, at| if (opt == inherited) s.focusPane(@intCast(at));
    s.cfg.tab_inherit_working_directory = false;
    action(s, t, .tab);
    drain(t);
    try check(std.mem.eql(u8, s.active().?.cwd.text(), home), "disabled tab directory inheritance uses configured initial directory");
    action(s, t, .close);
    s.cfg.tab_inherit_working_directory = true;
    s.cwd_override = home;
    action(s, t, .tab);
    drain(t);
    try check(std.mem.eql(u8, s.active().?.cwd.text(), child), "new tab inherits source directory ahead of CLI initial directory");
    action(s, t, .close);
    s.cwd_override = null;
    for (s.sessions, 0..) |opt, at| if (opt == inherited) s.focusPane(@intCast(at));
    {
        const h = s.host;
        const old_host_cfg = h.cfg;
        const old_host_command = h.command_override;
        const old_host_cwd = h.cwd_override;
        const old_host_active = h.active_id;
        defer {
            h.cfg = old_host_cfg;
            h.command_override = old_host_command;
            h.cwd_override = old_host_cwd;
            h.active_id = old_host_active;
        }
        h.cfg = s.cfg;
        h.command_override = null;
        h.cwd_override = null;
        h.active_id = s.id;
        const inherited_window = try h.create(false);
        drain(t);
        try check(std.mem.eql(u8, inherited_window.active().?.cwd.text(), child), "new window inherits source session directory");
        h.closeWindow(inherited_window);
        drain(t);
        h.active_id = s.id;
        h.cfg.window_inherit_working_directory = false;
        const initial_window = try h.create(false);
        drain(t);
        try check(std.mem.eql(u8, initial_window.active().?.cwd.text(), home), "disabled window directory inheritance uses configured initial directory");
        h.closeWindow(initial_window);
        drain(t);
    }
    // Hidden windows have no OS focus callback; restore the simulated source.
    s.window_focused = true;
    s.syncFocus();
    // Explicit profile CWD has priority over inherited CWD.
    profiles[0].cwd = home;
    action(s, t, .tab);
    drain(t);
    const explicit = s.active().?;
    try check(std.mem.eql(u8, explicit.cwd.text(), home), "explicit launch-profile CWD overrides inheritance");
    profiles[0].cwd = "";
    // Run a real task, leave the tab, then observe its completion marker.
    t.typeText("sleep 0.3; false");
    t.key(.enter);
    try check(!explicit.idle(), "submitted command immediately removes idle-close exemption");
    action(s, t, .previous_tab);
    for (0..3) |_| drain(t);
    try check(explicit.attention == .failed and explicit.idle(), "background command failure sets tab attention then returns to idle");
    const remote = "\x1b]7;file://remote.invalid/private/tmp\x07";
    vt_api.lt_vt_feed(explicit.vt, remote, remote.len);
    explicit.refresh();
    try check(explicit.cwd.text().len == 0, "remote working-directory report clears local inheritance");
    var focus: Focus = .{};
    shell.focus_sink = .{ .ctx = &focus, .call = Focus.receive };
    inherited.focus_sink = .{ .ctx = &focus, .call = Focus.receive };
    defer {
        shell.focus_sink = null;
        inherited.focus_sink = null;
    }
    const on = "\x1b[?1004h";
    const off = "\x1b[?1004l";
    vt_api.lt_vt_feed(shell.vt, on, on.len);
    vt_api.lt_vt_feed(inherited.vt, on, on.len);
    s.window_focused = true;
    s.syncFocus();
    const gains = focus.gained;
    s.syncFocus();
    s.syncFocus();
    try check(gains == 1 and focus.gained == gains, "focus gained goes only to active pane and repeated frames deduplicate it");
    action(s, t, .previous_pane);
    try check(focus.gained == gains + 1 and focus.lost == 1 and focus.last == shell.id, "pane switch pairs lost/gained reports with stable session IDs");
    action(s, t, .palette);
    try check(focus.lost == 2, "command palette takes terminal focus without leaking text");
    t.key(.escape);
    try check(focus.gained == gains + 2, "dismissing palette restores terminal focus once");
    const before_search_lost = focus.lost;
    const before_search_gained = focus.gained;
    action(s, t, .search);
    t.frame();
    try check(focus.lost == before_search_lost + 1 and focus.gained == before_search_gained, "search field holds terminal focus lost after autofocus is consumed");
    t.key(.escape);
    try check(focus.gained == before_search_gained + 1, "closing search restores terminal focus exactly once");
    const window = try s.app.newWindow(.{ .title = "Hidden focus check", .visible = false, .width = 480, .height = 240, .content = .{ .view = view }, .on_focus_changed = .{ .ctx = s, .func = @TypeOf(s.*).windowFocusChanged } });
    defer window.close();
    window.setFocused(true);
    window.setFocused(false);
    try check(!s.window_focused and focus.lost == before_search_lost + 2, "window focus callback reports loss and clears terminal input focus");
    window.setFocused(true);
    vt_api.lt_vt_feed(shell.vt, off, off.len);
    vt_api.lt_vt_feed(inherited.vt, off, off.len);
    s.syncFocus();
    const no_events = focus.gained + focus.lost;
    window.setFocused(false);
    window.setFocused(true);
    s.syncFocus();
    try check(focus.gained + focus.lost == no_events, "mode 1004 off suppresses all pane/window focus reports");
    s.cfg.shell_integration = .none;
    action(s, t, .tab);
    drain(t);
    try check(!s.active().?.integrated and s.active().?.events.prompts == 0, "shell-integration none leaves ordinary shell startup functional");
    s.cfg.confirm_close = .prompt;
    action(s, t, .close);
    try check(s.confirmation.open, "uninstrumented idle-looking shell retains conservative close confirmation");
    t.key(.escape);
    s.cfg.confirm_close = .never;
    action(s, t, .close_tab);
    const idle_id = s.active().?.id;
    try check(s.active().?.idle(), "trusted integrated prompt is idle before close");
    s.cfg.confirm_close = .always;
    action(s, t, .close);
    try check(s.confirmation.open, "always close policy also confirms at a reliable idle prompt");
    t.key(.escape);
    s.cfg.confirm_close = .prompt;
    action(s, t, .close);
    var remains = false;
    for (s.sessions) |opt| if (opt) |session| {
        if (session.id == idle_id) remains = true;
    };
    try check(!remains and !s.confirmation.open, "automatic close policy exempts only trusted idle prompt");
}
