//! Real vi PTY acceptance through the in-process Tester. Startup files,
//! editor history and the edited file are isolated from the user's account.
const std = @import("std");
const nano = @import("nanoui");
const ui = nano.ui;
const vt = @import("vt.zig");
const c = @import("platform_ffi.zig");
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn unlink([*:0]const u8) c_int;
extern "c" fn rmdir([*:0]const u8) c_int;
extern "c" fn lt_mkdirs([*:0]const u8) c_int;
extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
extern "c" fn unsetenv([*:0]const u8) c_int;

fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.TuiUiCheck;
}
fn action(s: anytype, t: *ui.Tester, a: @import("actions.zig").Action) void {
    s.menu_actions[0] = .{ .action = a };
    s.menu_action_count = 1;
    t.frame();
}
fn closeOwned(s: anytype, id: u64) void {
    for (s.sessions, 0..) |opt, slot| if (opt) |session| if (session.id == id) {
        s.close(@intCast(slot));
        return;
    };
}
fn containsSession(s: anytype, id: u64) bool {
    for (s.sessions) |opt| if (opt) |session| if (session.id == id) return true;
    return false;
}
fn alternate(session: anytype) bool {
    var scroll: vt.Scroll = .{};
    vt.lt_vt_scroll_info(session.vt, &scroll);
    return scroll.alternate;
}
fn visibleContains(session: anytype, needle: []const u8) bool {
    if (vt.lt_vt_select_all(session.vt) != 0) return false;
    defer vt.lt_vt_clear_selection(session.vt);
    var buffer: [65536]u8 = undefined;
    var len: usize = 0;
    if (vt.lt_vt_copy(session.vt, &buffer, buffer.len, &len) != 0 or len > buffer.len) return false;
    return std.mem.indexOf(u8, buffer[0..len], needle) != null;
}

/// A single quoted shell argument, including repository paths containing
/// spaces or apostrophes. The command never interpolates terminal input.
fn quoted(a: std.mem.Allocator, path: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    try result.append(a, '\'');
    for (path) |byte| {
        if (byte == '\'') try result.appendSlice(a, "'\\''") else try result.append(a, byte);
    }
    try result.append(a, '\'');
    return result.toOwnedSlice(a);
}

pub fn run(s: anytype, t: *ui.Tester) !void {
    try check(lt_mkdirs(".cache/test-logs") == 0, "prepare isolated vi PTY files");
    const template = try s.gpa.dupeSentinel(u8, ".cache/test-logs/vi-XXXXXX", 0);
    defer s.gpa.free(template);
    const dir = mkdtemp(template) orelse return error.TempDirectory;
    defer _ = rmdir(dir);
    var absolute: [4096]u8 = undefined;
    if (c.lt_absolute_path(dir, &absolute, absolute.len) != 0) return error.TempDirectory;
    const home = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&absolute)), 0);
    const home_z = try s.gpa.dupeSentinel(u8, home, 0);
    defer s.gpa.free(home_z);
    const file = try std.fmt.allocPrintSentinel(s.gpa, "{s}/fixture.txt", .{home}, 0);
    defer s.gpa.free(file);
    defer _ = unlink(file);
    const argument = try quoted(s.gpa, file);
    defer s.gpa.free(argument);
    // NONE skips user/system vimrc, -i NONE disables viminfo, -n disables
    // swap. Explicit UTF-8 avoids depending on the test host's locale.
    const command = try std.fmt.allocPrint(s.gpa, "exec /usr/bin/vi -u NONE -i NONE -n -N -X --cmd 'set encoding=utf-8 fileencoding=utf-8 nobackup nowritebackup nomore' -- {s}", .{argument});
    defer s.gpa.free(command);

    const Snapshot = struct { id: u64, pid: c_int };
    var originals: [16]Snapshot = undefined;
    var original_count: usize = 0;
    for (s.host.windows) |opt| if (opt) |window| {
        for (window.sessions) |entry| if (entry) |session| {
            if (original_count == originals.len) return error.PaneLimit;
            originals[original_count] = .{ .id = session.id, .pid = session.pid };
            original_count += 1;
        };
    };
    const original_tabs = s.layout.tab_count;
    const original_tab = s.layout.tabs[s.layout.active_tab].id;
    const original_pane = s.layout.active_pane;
    const old_cfg = s.cfg;
    const old_profile = s.profile;
    const old_override_profile = s.override_profile;
    const old_command = s.command_override;
    const old_cwd = s.cwd_override;
    const old_hold = s.hold;
    defer {
        s.cfg = old_cfg;
        s.profile = old_profile;
        s.override_profile = old_override_profile;
        s.command_override = old_command;
        s.cwd_override = old_cwd;
        s.hold = old_hold;
        if (s.layout.tabIndex(original_tab)) |index| {
            s.layout.activate(index);
            s.layout.focus(original_pane);
        }
    }
    // Preserve all profile indices already referenced by other tabs. Only
    // the next spawn receives the command/CWD override for this profile.
    s.override_profile = old_cfg.profiles[old_profile].name;
    s.cfg.shell = "/bin/sh";
    s.cfg.shell_integration = .none;
    s.cfg.confirm_close = .never;
    s.command_override = command;
    s.cwd_override = home;
    // Keep the exited editor's VT available for the primary-screen assertion.
    s.hold = true;
    var owned_id: ?u64 = null;
    defer if (owned_id) |id| closeOwned(s, id);
    const old_home = if (getenv("HOME")) |value| try s.gpa.dupeSentinel(u8, std.mem.span(value), 0) else null;
    defer if (old_home) |value| s.gpa.free(value);
    {
        // forkpty inherits this temporary HOME; restore the parent before
        // polling any children. Even the command shell has no user profile.
        if (setenv("HOME", home_z, 1) != 0) return error.SetEnvironment;
        defer {
            if (old_home) |value| _ = setenv("HOME", value, 1) else _ = unsetenv("HOME");
        }
        action(s, t, .tab);
    }
    const editor = s.active() orelse return error.EditorNotCreated;
    var is_original = false;
    for (originals[0..original_count]) |snapshot| if (snapshot.id == editor.id) {
        is_original = true;
    };
    if (!is_original) owned_id = editor.id;
    try check(!is_original and s.layout.tab_count == original_tabs + 1 and s.host.paneCount() == original_count + 1, "vi launches in one dedicated tab with a fresh real PTY");
    for (0..240) |_| {
        nano.runFor(0.025);
        t.frame();
        if (editor.fatal or editor.status != null or editor.eof or alternate(editor)) break;
    }
    try check(!editor.fatal and !editor.eof and editor.status == null and alternate(editor), "real vi enters the alternate screen without user vimrc or history");
    const payload = "LETTY_VI_ASCII 中e\xcc\x81";
    t.typeText("i");
    t.typeText(payload);
    var visible = false;
    for (0..160) |_| {
        nano.runFor(0.025);
        t.frame();
        if (editor.fatal or editor.eof) break;
        if (visibleContains(editor, payload)) {
            visible = true;
            break;
        }
    }
    try check(visible and alternate(editor), "vi renders committed ASCII, CJK and combining input through the live PTY");
    t.key(.escape);
    t.typeText(":wq");
    t.key(.enter);
    for (0..240) |_| {
        nano.runFor(0.025);
        t.frame();
        if (editor.fatal or editor.status != null and editor.eof) break;
    }
    try check(!editor.fatal and editor.status != null and editor.status.? == 0 and editor.eof, "vi saves and exits normally after Escape and :wq");
    try check(!alternate(editor), "vi restores the primary screen before its PTY closes");
    const fd = c.lt_open(file);
    if (fd < 0) return error.EditorFileMissing;
    {
        defer c.lt_close(fd);
        const expected = payload ++ "\n";
        var written: [4096]u8 = undefined;
        const length = c.lt_length(fd);
        const count = c.lt_pread(fd, &written, written.len, 0);
        try check(length == expected.len and count == expected.len and std.mem.eql(u8, written[0..expected.len], expected), "vi writes the exact UTF-8 file including CJK, combining bytes and final newline");
    }
    const editor_id = editor.id;
    action(s, t, .close_tab);
    try check(!containsSession(s, editor_id) and s.layout.tab_count == original_tabs and s.host.paneCount() == original_count, "closing the vi tab releases its session and restores the PTY budget");
    owned_id = null;
    var unchanged = true;
    for (originals[0..original_count]) |snapshot| {
        var found = false;
        for (s.host.windows) |opt| if (opt) |window| {
            for (window.sessions) |entry| if (entry) |session| if (session.id == snapshot.id) {
                found = session.pid == snapshot.pid;
            };
        };
        unchanged = unchanged and found;
    }
    try check(unchanged, "vi creation, Unicode editing, exit and close preserve every other original PTY PID");
}
