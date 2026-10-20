//! Isolated real PTYs: admission is all-or-none, then byte queues flush.
const std = @import("std");
const nano = @import("nanoui");
const config = @import("config.zig");
const keys = @import("keybindings.zig");
const vt = @import("vt.zig");
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.BroadcastUiCheck;
}
fn matches(session: anytype, text: []const u8) usize {
    _ = vt.lt_vt_search(session.vt, text.ptr, text.len);
    var total: usize = 0;
    while (vt.lt_vt_search_tick(session.vt, &total) > 0) {}
    vt.lt_vt_search_close(session.vt);
    return total;
}
fn awaitText(session: anytype, text: []const u8) bool {
    for (0..150) |_| {
        nano.runFor(0.01);
        if (matches(session, text) > 0) return true;
    }
    return false;
}
fn exactBytes(session: anytype, expected: []const u8) bool {
    if (vt.lt_vt_select_all(session.vt) != 0) return false;
    defer vt.lt_vt_clear_selection(session.vt);
    var text: [8192]u8 = undefined;
    var used: usize = 0;
    if (vt.lt_vt_copy(session.vt, &text, text.len, &used) != 0) return false;
    const ready = "BCAST_READY";
    const start = (std.mem.indexOf(u8, text[0..used], ready) orelse return false) + ready.len;
    const end = std.mem.indexOfPos(u8, text[0..used], start, "BCAST_DONE") orelse return false;
    var bytes: [32]u8 = undefined;
    var len: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, text[start..end], " \r\n\t");
    while (tokens.next()) |token| {
        if (token.len != 2 or len == bytes.len) return false;
        bytes[len] = std.fmt.parseInt(u8, token, 16) catch return false;
        len += 1;
    }
    if (!std.mem.eql(u8, expected, bytes[0..len])) {
        std.debug.print("Broadcast actual OD payload: {s}\n", .{text[start..end]});
        return false;
    }
    return true;
}
pub fn run(original: anytype, tester: *nano.ui.Tester) !void {
    const H = @TypeOf(original.host.*);
    const W = @TypeOf(original.*);
    var cfg: config.Config = .{};
    cfg.shell = "/bin/sh";
    cfg.shell_integration = .none;
    cfg.confirm_close = .never;
    const bindings = [_]keys.Binding{try keys.parse("all:ctrl+x=text:中\\\\\\x1b\\x00A")};
    cfg.keybinds = &bindings;
    cfg.clear_default_keybinds = true;
    var host: H = .{
        .gpa = original.gpa,
        .arena = original.arena,
        .app = original.app,
        .cfg = cfg,
        .state_path = "",
        .read_path = "",
        .demo = true,
        .hold = true,
        .override_profile = cfg.profiles[0].name,
        .command_override = "stty raw -echo; printf BCAST_READY; od -An -tx1 -N 7; printf BCAST_DONE; sleep 2",
    };
    defer host.deinit();
    const a = try host.create(false);
    const b = try host.create(false);
    host.command_override = "printf SKIPPED_EXIT; exit";
    const dead = try host.create(false);
    a.window_focused = true;
    var t: nano.ui.Tester = undefined;
    try t.init(original.gpa, .init(a, W.view), .{ .width = 800, .height = 500, .theme = tester.theme });
    defer t.deinit();
    const first = a.active().?;
    const second = b.active().?;
    const ended = dead.active().?;
    const first_id = first.id;
    const second_id = second.id;
    try check(awaitText(first, "BCAST_READY") and awaitText(second, "BCAST_READY"), "all:text fixtures have two real raw-mode PTYs ready");
    for (0..150) |_| {
        if (ended.eof) break;
        nano.runFor(0.01);
    }
    try check(ended.eof and first_id != second_id, "broadcast snapshots distinct stable IDs and excludes exited PTYs");
    const saved_queue = second.tx;
    // A single synchronous frame cannot pump I/O between preflight and commit.
    second.tx.len = second.tx.bytes.len - 65536;
    const busy_len = second.tx.len;
    _ = t.shortcut(.{ .key = 'x', .ctrl = true });
    try check(first.tx.len == 0 and second.tx.len == busy_len and std.mem.indexOf(u8, a.status, "no bytes admitted") != null, "busy second target rejects broadcast before admitting bytes to either target");
    second.tx = saved_queue;
    nano.runFor(0.03);
    try check(matches(first, "BCAST_DONE") == 0 and matches(second, "BCAST_DONE") == 0, "rejected all:text sends no partial input through the first real PTY");
    _ = t.shortcut(.{ .key = 'x', .ctrl = true });
    try check(awaitText(first, "BCAST_DONE") and awaitText(second, "BCAST_DONE"), "admitted all:text completes both raw-mode PTY receivers");
    try check(exactBytes(first, "中\\\x1b\x00A") and exactBytes(second, "中\\\x1b\x00A"), "broadcast delivers Unicode backslash ESC NUL bytes exactly once to both PTYs");
    try check(first.id == first_id and second.id == second_id and ended.tx.len == 0, "broadcast preserves target identities and never writes to the exited target");
    try flags(original, tester);
}
fn flags(original: anytype, tester: *nano.ui.Tester) !void {
    const H = @TypeOf(original.host.*);
    const bindings = [_]keys.Binding{
        try keys.parse("unconsumed:ctrl+q=text:F"),
        try keys.parse("performable:ctrl+b=copy_to_clipboard"),
    };
    var cfg: config.Config = .{};
    cfg.shell = "/bin/sh";
    cfg.shell_integration = .none;
    cfg.keybinds = &bindings;
    cfg.clear_default_keybinds = true;
    var host: H = .{
        .gpa = original.gpa,
        .arena = original.arena,
        .app = original.app,
        .cfg = cfg,
        .state_path = "",
        .read_path = "",
        .demo = true,
        .hold = true,
        .override_profile = cfg.profiles[0].name,
        .command_override = "stty raw -echo; printf BCAST_READY; od -An -tx1 -N 3; printf BCAST_DONE; sleep 2",
    };
    defer host.deinit();
    const window = try host.create(false);
    window.window_focused = true;
    var t: nano.ui.Tester = undefined;
    try t.init(original.gpa, .init(window, @TypeOf(original.*).view), .{ .width = 800, .height = 500, .theme = tester.theme });
    defer t.deinit();
    const session = window.active().?;
    if (!awaitText(session, "BCAST_READY")) return error.FlagsFixtureNotReady;
    _ = t.shortcut(.{ .key = 'q', .ctrl = true });
    _ = t.shortcut(.{ .key = 'b', .ctrl = true });
    try check(awaitText(session, "BCAST_DONE") and exactBytes(session, "F\x11\x02"), "unconsumed runs its text then forwards the chord once; unavailable performable forwards normally");
    if (vt.lt_vt_select_all(session.vt) != 0) return error.FlagsSelection;
    const taken = t.shortcut(.{ .key = 'b', .ctrl = true });
    try check(taken and std.mem.indexOf(u8, t.clipboard.items, "BCAST_READY") != null, "available performable copy consumes the binding and writes only the Tester's fake clipboard");
}
