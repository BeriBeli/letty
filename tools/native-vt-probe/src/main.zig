const std = @import("std");
const builtin = @import("builtin");
const state = @import("state.zig");
const vt = state.vt;
const Probe = state.Probe;
var checks: usize = 0;
fn check(ok: bool, name: []const u8) !void {
    if (!ok) {
        std.debug.print("FAIL: {s}\n", .{name});
        return error.ProbeCheckFailed;
    }
    checks += 1;
    std.debug.print("PASS: {s}\n", .{name});
}
fn exact(probe: *Probe, expected: []const u8) !bool {
    const value = try probe.text();
    defer probe.allocator.free(value);
    const trimmed = std.mem.trimEnd(u8, value, "\n");
    if (!std.mem.eql(u8, trimmed, expected)) std.debug.print("text expected={any}, actual={any}\n", .{ expected, trimmed });
    return std.mem.eql(u8, trimmed, expected);
}
pub fn main(init: std.process.Init) !void {
    var dpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = dpa.allocator();
    {
        const probe = try Probe.create(init.io, allocator, 80, 24, true);
        defer probe.destroy(null);
        try check(probe.stream.handler.terminal == &probe.terminal and probe.stream.handler.effects.write_pty != null, "stable owner and explicitly installed effects");
        try probe.feed("Hello, native Zig!");
        try check(try exact(probe, "Hello, native Zig!"), "ASCII text and cursor");
        try probe.feed("\x1bc\x1b[1;31mR\x1b[0m");
        const entry = probe.terminal.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        const page = entry.node.page();
        const style = page.styles.get(page.memory, entry.cell.style_id);
        try check(style.flags.bold and style.fg_color == .palette and style.fg_color.palette == 1 and try exact(probe, "R"), "ANSI foreground and bold persist on written cell");
        try check(probe.terminal.screens.active.cursor.style.default(), "SGR reset restores current style");
        try probe.feed("\x1bc中");
        const head = probe.terminal.screens.active.pages.getCell(.{ .active = .{ .x = 0 } }).?.cell;
        const tail = probe.terminal.screens.active.pages.getCell(.{ .active = .{ .x = 1 } }).?.cell;
        try check(head.wide == .wide and tail.wide == .spacer_tail and probe.terminal.screens.active.cursor.x == 2 and try exact(probe, "中"), "CJK leading and tail cells retain two columns");
        try probe.feed("\x1bcé");
        const combined = probe.terminal.screens.active.pages.getCell(.{ .active = .{ .x = 0 } }).?.cell;
        try check(combined.content_tag == .codepoint_grapheme and probe.terminal.screens.active.cursor.x == 1 and try exact(probe, "é"), "combining accent remains one VT cell");
        try probe.feed("\x1bc");
        for ("中é😀") |byte| try probe.feed(&.{byte});
        try check(probe.terminal.screens.active.cursor.x == 5 and try exact(probe, "中é😀"), "every-byte UTF8 feed retains CJK combining and emoji");
        try probe.feed("\x1bcPRIMARY\x1b[?1049h\x1b[HALT");
        try check(probe.terminal.screens.active_key == .alternate and try exact(probe, "ALT"), "alternate screen isolates text");
        try probe.feed("\x1b[?1049l");
        try check(probe.terminal.screens.active_key == .primary and try exact(probe, "PRIMARY"), "alternate exit restores primary content");
        try probe.feed("\x1bc\x1b[2;3H\x1b[6n");
        try check(probe.reply_calls == 1 and std.mem.eql(u8, probe.response(), "\x1b[2;3R"), "DSR emits exact cursor response once");
        try probe.feed("");
        try probe.feed("x");
        try check(probe.reply_calls == 1, "ordinary or empty feed never replays DSR reply");
        probe.resetReplies();
        try probe.feed("\x1b]2;Native probe title\x1b\\");
        try check(probe.title_changes == 1 and std.mem.eql(u8, probe.title[0..probe.title_len], "Native probe title"), "title effect copies borrowed title");
        try probe.feed("\x1b]7;file://localhost/tmp/native-vt\x1b\\");
        try check(probe.pwd_changes == 1 and std.mem.eql(u8, probe.pwd[0..probe.pwd_len], "file://localhost/tmp/native-vt"), "PWD effect copies raw authority URI");
        try probe.feed("\x07");
        try check(probe.bells == 1, "BEL invokes host effect once without system interaction");
        try probe.feed("\x1b]133;A\x1b\\\x1b]133;B\x1b\\\x1b]133;C;cmdline_url=echo%20hi\x1b\\\x1b]133;D;7\x1b\\");
        const expected = [_]vt.SemanticPrompt.Kind{ .prompt_start, .input_start, .output_start, .command_end };
        try check(probe.semantic_count == expected.len and std.mem.eql(vt.SemanticPrompt.Kind, &expected, probe.semantic_kinds[0..probe.semantic_count]) and probe.exit_code == 7 and std.mem.eql(u8, probe.command[0..probe.command_len], "echo hi"), "semantic prompt steps command and exit code copied");
        const progress_before = probe.progress_changes;
        try probe.feed("\x1b]9;4;1;42\x1b\\");
        try check(probe.progress_changes == progress_before + 1 and probe.progress_state == .set and probe.progress == 42, "progress effect reports exact state and percentage");
        try inputChecks(probe);
        probe.resetReplies();
        try probe.feed("\x1b[18t");
        try check(probe.reply_calls == 1 and std.mem.eql(u8, probe.response(), "\x1b[8;24;80t"), "geometry effect answers XTWINOPS once");
        try check(!probe.stream.handler.semantic_failure and !probe.callback_overflow, "no swallowed terminal semantic or callback failures");
        probe.resetReplies();
        probe.reply_limit = 2;
        try std.testing.expectError(error.CallbackCapacityExceeded, probe.feed("\x1b[6n"));
        try check(probe.reply_len == 0 and probe.reply_overflow, "reply budget reports backpressure without partial bytes");
    }
    try resizeChecks(init.io, allocator);
    try fragmentedChecks(init.io, allocator);
    {
        const readonly = try Probe.create(init.io, allocator, 12, 4, false);
        defer readonly.destroy(null);
        try readonly.feed("\x1b[6n\x07\x1b]2;state only\x07");
        try check(readonly.reply_calls == 0 and readonly.bells == 0 and readonly.title_changes == 0 and readonly.terminal.getTitle() != null, "readonly stream is explicitly insufficient for host effects");
    }
    var report: state.Teardown = .{};
    const temporary = try Probe.create(init.io, allocator, 12, 4, true);
    temporary.destroy(&report);
    try check(std.mem.eql(u8, report.stages[0..report.len], "st"), "stream is destroyed before terminal and owner");
    try check(dpa.deinit() == .ok, "all isolated native objects freed without allocator leaks");
    std.debug.print("{{\"suite\":\"native-vt-probe\",\"backend\":\"zig\",\"ghostty\":\"5064b3265e500d55f5f44ff48ca59b8685543bb8\",\"zig\":\"0.17.0\",\"simd\":false,\"checks\":{d},\"status\":\"pass\",\"arch\":\"{s}\",\"os\":\"{s}\",\"io\":\"std.process.Init.io\"}}\n", .{ checks, @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) });
}

fn inputChecks(probe: *Probe) !void {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try vt.input.encodeKey(&writer, .{ .key = .arrow_up }, .fromTerminal(&probe.terminal));
    try check(std.mem.eql(u8, writer.buffered(), "\x1b[A"), "normal arrow encoding uses terminal modes");
    try probe.feed("\x1b[?1h");
    writer = .fixed(&buffer);
    try vt.input.encodeKey(&writer, .{ .key = .arrow_up }, .fromTerminal(&probe.terminal));
    try check(std.mem.eql(u8, writer.buffered(), "\x1bOA"), "application arrow mode changes key encoding");
    writer = .fixed(&buffer);
    try vt.input.encodeKey(&writer, .{ .key = .key_a, .utf8 = "a", .unshifted_codepoint = 'a', .mods = .{ .ctrl = true } }, .fromTerminal(&probe.terminal));
    try check(std.mem.eql(u8, writer.buffered(), "\x01"), "Ctrl+A encodes exact control byte");
    try probe.feed("\x1b[>1u");
    writer = .fixed(&buffer);
    try vt.input.encodeKey(&writer, .{ .key = .key_a, .utf8 = "a", .unshifted_codepoint = 'a', .mods = .{ .ctrl = true } }, .fromTerminal(&probe.terminal));
    try check(std.mem.eql(u8, writer.buffered(), "\x1b[97;5u"), "Kitty negotiation changes modified key encoding");
    var plain = "left\nright".*;
    const fragments = vt.input.encodePaste(@as([]u8, &plain), .fromTerminal(&probe.terminal));
    try check(std.mem.eql(u8, fragments[1], "left\rright") and fragments[0].len == 0 and fragments[2].len == 0, "plain paste transforms newline by current mode");
    try probe.feed("\x1b[?2004h");
    var bracketed = "left\nright".*;
    const framed = vt.input.encodePaste(@as([]u8, &bracketed), .fromTerminal(&probe.terminal));
    try check(std.mem.eql(u8, framed[0], "\x1b[200~") and std.mem.eql(u8, framed[1], "left\nright") and std.mem.eql(u8, framed[2], "\x1b[201~"), "bracketed paste framing and payload preserve mode semantics");
    writer = .fixed(&buffer);
    try probe.focus(.gained, &writer);
    try check(writer.buffered().len == 0, "focus reports suppressed while mode1004 disabled");
    try probe.feed("\x1b[?1004h");
    try probe.focus(.gained, &writer);
    try probe.focus(.lost, &writer);
    try check(std.mem.eql(u8, writer.buffered(), "\x1b[I\x1b[O"), "focus mode1004 emits exact gained and lost bytes");
}

fn resizeChecks(io: std.Io, allocator: std.mem.Allocator) !void {
    const probe = try Probe.create(io, allocator, 6, 4, true);
    defer probe.destroy(null);
    try probe.feed("ABCDEFGHIJKL");
    try check(try exact(probe, "ABCDEF\nGHIJKL"), "narrow viewport wraps at VT columns");
    try probe.stream.handler.resize(.{ .cols = 12, .rows = 4 });
    try check(try exact(probe, "ABCDEFGHIJKL"), "native resize reflows soft wrapped content");
    try std.testing.expectError(error.InvalidValue, probe.stream.handler.resize(.{ .cols = 0, .rows = 4 }));
    try check(probe.terminal.cols == 12, "zero resize rejected without partial mutation");
    try probe.feed("\x1b[?2048h");
    probe.resetReplies();
    try probe.stream.handler.resize(.{ .cols = 40, .rows = 12, .cell_size_px = .{ .width = 9, .height = 18 } });
    try check(probe.reply_calls == 1 and std.mem.eql(u8, probe.response(), "\x1b[48;12;40;216;360t"), "handler resize delivers in-band geometry effect once");
}

fn fragmentedChecks(io: std.Io, allocator: std.mem.Allocator) !void {
    const fixture = "\x1b[1;31m中é😀\x1b[0m\x1b[6n";
    const whole = try Probe.create(io, allocator, 40, 4, true);
    defer whole.destroy(null);
    try whole.feed(fixture);
    const expected = try whole.text();
    defer allocator.free(expected);
    var equivalent = true;
    for (0..fixture.len + 1) |cut| {
        const split = try Probe.create(io, allocator, 40, 4, true);
        defer split.destroy(null);
        try split.feed(fixture[0..cut]);
        try split.feed(fixture[cut..]);
        const value = try split.text();
        defer allocator.free(value);
        equivalent = equivalent and std.mem.eql(u8, expected, value) and split.reply_calls == 1 and std.mem.eql(u8, whole.response(), split.response());
    }
    try check(equivalent, "all UTF8/ANSI/DSR byte split points equal whole-feed output and one reply");
}
