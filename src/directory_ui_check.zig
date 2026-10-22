//! Real uninstrumented csh in semantics_ui_check's private HOME and PTY.
const std = @import("std");
const nano = @import("nanoui");
const ui = nano.ui;
const c = @import("platform_ffi.zig");
const vt = @import("vt.zig");
extern "c" fn access([*:0]const u8, c_int) c_int;
extern "c" fn unlink([*:0]const u8) c_int;
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI CSH {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.DirectoryUiCheck;
}
fn action(s: anytype, t: *ui.Tester, value: @import("actions.zig").Action) void {
    s.menu_actions[0] = .{ .action = value };
    s.menu_action_count = 1;
    t.frame();
}
fn wait(s: anytype, t: *ui.Tester, path: []const u8) bool {
    for (0..160) |_| {
        nano.runFor(0.025);
        t.frame();
        if (std.mem.eql(u8, s.cwd.text(), path)) return true;
        if (s.eof or s.fatal or s.status != null) break;
    }
    std.debug.print("CSH directory expected={s} actual={s} status={any}\n", .{ path, s.cwd.text(), s.status });
    return false;
}
pub fn run(s: anytype, t: *ui.Tester, home: []const u8, child: []const u8) !void {
    const executable: [:0]const u8 = for ([_][:0]const u8{ "/bin/csh", "/bin/tcsh", "/usr/bin/tcsh" }) |candidate| {
        if (access(candidate, 1) == 0) break candidate;
    } else {
        std.debug.print("SKIP UI CSH no csh/tcsh installed\n", .{});
        return;
    };
    const rc = try std.fmt.allocPrintSentinel(s.gpa, "{s}/.cshrc", .{home}, 0);
    defer s.gpa.free(rc);
    defer _ = unlink(rc);
    const contents = "set history=0\nset savehist=0\nset histfile=/dev/null\nset prompt='LETTY_CSH> '\n";
    try check(c.lt_write_atomic(rc, contents, contents.len) == 0, "prepare private startup without title hooks");
    const old_shell = s.cfg.shell;
    const old_tab = s.layout.tabs[s.layout.active_tab].id;
    defer {
        s.cfg.shell = old_shell;
        if (s.layout.tabIndex(old_tab)) |index| s.layout.activate(index);
        t.frame();
    }
    s.cfg.shell = executable;
    action(s, t, .tab);
    const session = s.active().?;
    const tab_id = s.layout.tabs[s.layout.active_tab].id;
    defer if (s.layout.tabIndex(tab_id)) |index| {
        s.layout.activate(index);
        action(s, t, .close_tab);
    };
    try check(wait(session, t, home) and std.mem.eql(u8, s.tabLabel(s.layout.active_tab), "~"), "default tab title shows HOME without shell hooks");
    try check(!session.integrated and session.events.pwd == 0 and !session.idle(), "directory discovery does not grant trusted-idle semantics");
    try check(session.send("cd 'a b'\n") and wait(session, t, child) and std.mem.eql(u8, s.tabLabel(s.layout.active_tab), child), "cd updates the real tab title including spaces");
    try s.layout.rename(tab_id, "Pinned shell");
    try check(session.send("cd ..\n") and wait(session, t, home) and std.mem.eql(u8, s.tabLabel(s.layout.active_tab), "Pinned shell"), "manual tab name survives directory changes");
    try s.layout.rename(tab_id, "");
    try check(std.mem.eql(u8, s.tabLabel(s.layout.active_tab), "~"), "clearing manual name resumes the current directory");
    const job = try std.fmt.allocPrint(s.gpa, "{s} -f -c 'cd /; echo JOB_READY; sleep 0.5'\n", .{executable});
    defer s.gpa.free(job);
    try check(session.send(job), "launch foreground csh job in a different directory");
    for (0..12) |_| {
        nano.runFor(0.025);
        t.frame();
    }
    try check(std.mem.eql(u8, session.cwd.text(), home), "foreground csh job directory does not replace the owning shell directory");
    for (0..20) |_| {
        nano.runFor(0.025);
        t.frame();
    }
    try check(session.directory.delay == null, "idle csh has no directory polling timer");
    const remote = "\x1b]7;file://remote.invalid/private/tmp\x07";
    vt.lt_vt_feed(session.vt, remote, remote.len);
    session.refresh();
    try check(session.send("cd 'a b'\n"), "produce output after a remote OSC7 report");
    for (0..16) |_| {
        nano.runFor(0.025);
        t.frame();
    }
    try check(session.cwd.len == 0 and session.directory.owner == null, "remote OSC7 disables local fallback and directory inheritance");
}
