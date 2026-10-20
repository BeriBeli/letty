//! Real-shell prompt clear acceptance inside semantics_ui_check's isolated
//! shell and in-process Tester. No desktop keys or system clipboard are used.
const std = @import("std");
const builtin = @import("builtin");
const nano = @import("nanoui");
const ui = nano.ui;
const vt = @import("vt.zig");

fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.PromptClearUiCheck;
}
fn drain(t: *ui.Tester) void {
    for (0..10) |_| {
        nano.runFor(0.025);
        t.frame();
    }
}
fn waitCommand(t: *ui.Tester, shell: anytype, previous_ends: u64) !void {
    for (0..160) |_| {
        nano.runFor(0.025);
        t.frame();
        if (shell.fatal or shell.eof) return error.PromptClearShellExited;
        if (shell.events.ends > previous_ends and shell.idle()) return;
    }
    return error.PromptClearShellTimeout;
}
fn terminalText(a: std.mem.Allocator, shell: anytype, keep_selection: bool) ![]u8 {
    if (vt.lt_vt_select_all(shell.vt) != 0) return error.PromptClearNoText;
    defer if (!keep_selection) vt.lt_vt_clear_selection(shell.vt);
    var buffer: [65536]u8 = undefined;
    var len: usize = 0;
    if (vt.lt_vt_copy(shell.vt, &buffer, buffer.len, &len) != 0 or len > buffer.len) return error.PromptClearCopy;
    return a.dupe(u8, buffer[0..len]);
}

/// Exhaust the TX capacity without putting any fabricated bytes in a live PTY
/// queue. Temporarily use a zero-capacity, empty view of its existing allocation.
/// No event loop/frame runs until the original ring is restored. Even an
/// incorrect flush has no bytes to send, rather than leaking uninitialized or
/// dummy queue contents into the shell. This hits the same free()<reserve+1
/// admission check as a full ring while retaining the real session and fd.
fn rejectedTx(a: std.mem.Allocator, shell: anytype) !void {
    try check(shell.tx.len == 0 and !shell.fatal and !shell.eof, "prompt clear TX rejection starts with a drained live shell");
    const before = try terminalText(a, shell, true);
    defer a.free(before);
    const revision = vt.lt_vt_revision(shell.vt);
    const selected = vt.lt_vt_has_selection(shell.vt);
    const saved = shell.tx;
    const write_watch = shell.write_watch;
    shell.tx = .{ .bytes = saved.bytes[0..0], .head = 0, .len = 0 };
    const rejected = blk: {
        defer shell.tx = saved;
        break :blk if (shell.clearScreen()) |_| false else |_| true;
    };
    // No synthetic payload is ever consumed/flushed. The complete original
    // ring metadata and backing allocation are restored before any assertion.
    try check(rejected and shell.tx.len == saved.len and shell.tx.head == saved.head and shell.write_watch == write_watch and !shell.fatal, "exhausted TX refuses prompt clear and restores the queue without writing fake bytes");
    try check(vt.lt_vt_revision(shell.vt) == revision and vt.lt_vt_has_selection(shell.vt) == selected, "TX refusal leaves VT revision and ordinary selection unchanged");
    var buffer: [65536]u8 = undefined;
    var len: usize = 0;
    try check(vt.lt_vt_copy(shell.vt, &buffer, buffer.len, &len) == 0 and len <= buffer.len and std.mem.eql(u8, buffer[0..len], before), "TX refusal preserves the exact selected terminal text");
    vt.lt_vt_clear_selection(shell.vt);
}

fn clearAction(s: anytype, t: *ui.Tester) !void {
    if (builtin.os.tag == .macos) {
        try check(t.shortcut(.{ .key = 'k', .cmd = true }), "Cmd+K dispatches prompt-preserving clear through the application");
    } else {
        s.menu_actions[0] = .{ .action = .clear_screen };
        s.menu_action_count = 1;
        t.frame();
    }
}
fn executeEdited(s: anytype, t: *ui.Tester, shell: anytype, command: []const u8, expected: []const u8, reflow: bool) !void {
    const pid = shell.pid;
    const ends = shell.events.ends;
    t.typeText(command);
    drain(t);
    // Four left movements cross the closing quote and the ASCII XYZ suffix,
    // putting the editing point immediately before X, not at end-of-line.
    for (0..4) |_| t.key(.left);
    drain(t);
    const original_size = t.size;
    defer if (reflow) t.resize(original_size.w, original_size.h);
    if (reflow) {
        const original_cols = shell.cols;
        t.resize(if (original_size.w > 500) 420 else 780, original_size.h);
        drain(t);
        try check(shell.cols != original_cols, "live CJK and combining command is reflowed by a real PTY resize");
    }
    const mode = vt.lt_vt_bracketed(shell.vt);
    try clearAction(s, t);
    drain(t);
    try check(shell.pid == pid and !shell.fatal and !shell.eof and shell.events.ends == ends and vt.lt_vt_bracketed(shell.vt) == mode, "prompt clear keeps the process, editing transaction and terminal mode intact");
    t.typeText("_");
    // Ctrl+E is bound to end-of-line by the explicit isolated emacs keymap.
    if (!shell.send("\x05")) return error.PromptClearSend;
    t.key(.enter);
    try waitCommand(t, shell, ends);
    const body = try terminalText(s.gpa, shell, false);
    defer s.gpa.free(body);
    // The input command contains a printf %s template, not the expected full
    // line. Therefore echoed input cannot satisfy this execution assertion.
    try check(std.mem.indexOf(u8, body, expected) != null, if (reflow)
        "CJK, combining and wrapped input execute with the exact mid-buffer insertion after clear"
    else
        "unexecuted shell input keeps its editing cursor and executes the exact mid-buffer insertion after Cmd+K");
}

pub fn run(s: anytype, t: *ui.Tester, shell: anytype) !void {
    // C remains the strict legacy-C comparison. Its lack of a native higher
    // level operation is an explicit capability, never fake successful clear.
    if (comptime vt.prompt_clear_supported) try runNative(s, t, shell);
}
fn runNative(s: anytype, t: *ui.Tester, shell: anytype) !void {
    try check(s.active().? == shell and shell.integrated and shell.idle(), "prompt clear uses the existing isolated active shell at a trusted prompt");
    drain(t);
    // Startup files belong to semantics_ui_check's temporary HOME. Explicitly
    // choose predictable editing bindings; no user shell configuration changes.
    const ends = shell.events.ends;
    if (!shell.send("if [ -n \"$ZSH_VERSION\" ]; then bindkey -e; else set -o emacs; fi\r")) return error.PromptClearSend;
    try waitCommand(t, shell, ends);
    try rejectedTx(s.gpa, shell);
    try executeEdited(s, t, shell, "printf '__LETTY_PC_A__:%s\\n' 'abcXYZ'", "__LETTY_PC_A__:abc_XYZ", false);

    const padding: [160]u8 = @splat('r');
    const command = try std.fmt.allocPrint(s.gpa, "printf '__LETTY_PC_U__:%s\\n' '{s}中e\xcc\x81XYZ'", .{padding});
    defer s.gpa.free(command);
    const expected = try std.fmt.allocPrint(s.gpa, "__LETTY_PC_U__:{s}中e\xcc\x81_XYZ", .{padding});
    defer s.gpa.free(expected);
    try executeEdited(s, t, shell, command, expected, true);
    drain(t);
    try check(shell.tx.len == 0 and shell.idle() and !shell.fatal and !shell.eof, "prompt clear shell checks finish idle with a drained real TX queue");
}
