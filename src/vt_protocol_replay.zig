//! Native public-facade query regression against fixed golden records.
//! No upstream imports, OSC parser, OS clipboard, permission or GUI side effect.
//! PROTOCOL JSON describes values only. legacy_size_callback marks the five
//! historical C callback gaps; every native response is checked in full.
const std = @import("std");
const vt = @import("vt.zig");
const st = "\x1b\\";
const Case = struct {
    name: []const u8,
    setup: []const u8 = "",
    query: []const u8,
    expected: []const u8,
    calls: usize = 1,
    /// Historical provenance: the archived C bridge did not install SIZE.
    /// This metadata never changes native expected bytes or callback counts.
    legacy_size_callback: bool = false,
    resize: bool = false,
};
const cases = [_]Case{
    .{ .name = "DA-primary", .query = "\x1b[c", .expected = "\x1b[?62;22c" },
    .{ .name = "DA-secondary", .query = "\x1b[>c", .expected = "\x1b[>1;0;0c" },
    .{ .name = "DA-tertiary", .query = "\x1b[=c", .expected = "\x1bP!|00000000" ++ st },
    .{ .name = "DSR-operating-status", .query = "\x1b[5n", .expected = "\x1b[0n" },
    .{ .name = "DSR-ANSI-cursor", .query = "\x1b[6n", .expected = "\x1b[2;3R" },
    .{ .name = "DSR-private-cursor-page", .query = "\x1b[?6n", .expected = "\x1b[?2;3;1R" },
    .{ .name = "DSR-origin-relative", .setup = "\x1b[2;5r\x1b[?6h\x1b[2;3H", .query = "\x1b[6n", .expected = "\x1b[2;3R" },
    .{ .name = "DSR-private-origin-relative", .setup = "\x1b[2;5r\x1b[?6h\x1b[2;3H", .query = "\x1b[?6n", .expected = "\x1b[?2;3;1R" },
    .{ .name = "DECRQM-wrap-default", .query = "\x1b[?7$p", .expected = "\x1b[?7;1$y" },
    .{ .name = "DECRQM-wrap-disabled", .setup = "\x1b[?7l", .query = "\x1b[?7$p", .expected = "\x1b[?7;2$y" },
    .{ .name = "DECRQM-insert-default", .query = "\x1b[4$p", .expected = "\x1b[4;2$y" },
    .{ .name = "DECRQM-insert-set", .setup = "\x1b[4h", .query = "\x1b[4$p", .expected = "\x1b[4;1$y" },
    .{ .name = "DECRQM-unknown", .query = "\x1b[?9999$p", .expected = "\x1b[?9999;0$y" },
    .{ .name = "DECRQM-large-no-alias", .query = "\x1b[?32775$p", .expected = "\x1b[?32775;0$y" },
    .{ .name = "DECRQM-permanently-reset", .query = "\x1b[?117$p", .expected = "\x1b[?117;4$y" },
    .{ .name = "DECRQM-Kitty-paste-without-clipboard", .query = "\x1b[?5522$p", .expected = "\x1b[?5522;0$y" },
    .{ .name = "Kitty-keyboard-default", .query = "\x1b[?u", .expected = "\x1b[?0u" },
    .{ .name = "Kitty-keyboard-flags", .setup = "\x1b[>5u", .query = "\x1b[?u", .expected = "\x1b[?5u" },
    .{ .name = "Kitty-keyboard-push-query-pop", .query = "\x1b[?u\x1b[>5u\x1b[?u\x1b[<u\x1b[?u", .expected = "\x1b[?0u\x1b[?5u\x1b[?0u", .calls = 3 },
    .{ .name = "Kitty-graphics-default-disabled", .query = "\x1b_Ga=q,f=24,s=1,v=1,i=99;/wAA" ++ st, .expected = "", .calls = 0 },
    .{ .name = "size-text-area-pixels", .query = "\x1b[14t", .expected = "\x1b[4;108;160t", .legacy_size_callback = true },
    .{ .name = "size-cell-pixels", .query = "\x1b[16t", .expected = "\x1b[6;18;8t", .legacy_size_callback = true },
    .{ .name = "size-text-area-cells", .query = "\x1b[18t", .expected = "\x1b[8;6;20t", .legacy_size_callback = true },
    .{ .name = "size-screen-cells", .query = "\x1b[19t", .expected = "\x1b[9;6;20t", .legacy_size_callback = true },
    .{ .name = "size-mode2048-enable", .query = "\x1b[?2048h", .expected = "\x1b[48;6;20;108;160t", .legacy_size_callback = true },
    // Handler.resize reports its explicit, updated dimensions in-band.
    .{ .name = "size-mode2048-resize", .setup = "\x1b[?2048h", .query = "", .resize = true, .expected = "\x1b[48;7;17;133;153t" },
    .{ .name = "XTVERSION-default-library-identity", .query = "\x1b[>0q", .expected = "\x1bP>|libghostty" ++ st },
    .{ .name = "ENQ-without-host-answer", .query = "\x05", .expected = "", .calls = 0 },
    .{ .name = "DSR-color-scheme-without-host-policy", .query = "\x1b[?996n", .expected = "", .calls = 0 },
    .{ .name = "DSR-default-visibility", .query = "\x1b[?998n", .expected = "\x1b[?999;1n" },
    .{ .name = "title-report-default-denied", .query = "\x1b[21t", .expected = "", .calls = 0 },
    .{ .name = "OSC10-foreground-ST", .query = "\x1b]10;?" ++ st, .expected = "\x1b]10;rgb:1212/3434/5656" ++ st },
    .{ .name = "OSC11-background-BEL", .query = "\x1b]11;?\x07", .expected = "\x1b]11;rgb:f0f0/e0e0/d0d0\x07" },
    .{ .name = "OSC12-cursor-ST", .query = "\x1b]12;?" ++ st, .expected = "\x1b]12;rgb:abab/cdcd/efef" ++ st },
    .{ .name = "OSC10-bundled-dynamic-colors", .query = "\x1b]10;?;?;?\x07", .expected = "\x1b]10;rgb:1212/3434/5656\x07\x1b]11;rgb:f0f0/e0e0/d0d0\x07\x1b]12;rgb:abab/cdcd/efef\x07" },
    .{ .name = "OSC4-palette-color", .query = "\x1b]4;1;?" ++ st, .expected = "\x1b]4;1;rgb:2222/3333/4444" ++ st },
    .{ .name = "OSC4-bundled-palette-colors", .query = "\x1b]4;0;?;1;?" ++ st, .expected = "\x1b]4;0;rgb:0101/0202/0303" ++ st ++ "\x1b]4;1;rgb:2222/3333/4444" ++ st },
    .{ .name = "OSC11-set-then-query", .setup = "\x1b]11;#203040" ++ st, .query = "\x1b]11;?" ++ st, .expected = "\x1b]11;rgb:2020/3030/4040" ++ st },
    .{ .name = "OSC11-reset-host-default", .setup = "\x1b]11;#203040" ++ st ++ "\x1b]111" ++ st, .query = "\x1b]11;?" ++ st, .expected = "\x1b]11;rgb:f0f0/e0e0/d0d0" ++ st },
    .{ .name = "OSC4-set-and-query-one-packet", .query = "\x1b]4;1;#203040;1;?" ++ st, .expected = "\x1b]4;1;rgb:2020/3030/4040" ++ st },
    .{ .name = "OSC4-reset-host-default", .setup = "\x1b]4;1;#203040" ++ st ++ "\x1b]104;1" ++ st, .query = "\x1b]4;1;?" ++ st, .expected = "\x1b]4;1;rgb:2222/3333/4444" ++ st },
    .{ .name = "DECRQSS-default-SGR", .query = "\x1bP$qm" ++ st, .expected = "\x1bP1$r0m" ++ st },
    .{ .name = "DECRQSS-bold-SGR", .setup = "\x1b[1m", .query = "\x1bP$qm" ++ st, .expected = "\x1bP1$r0;1m" ++ st },
    .{ .name = "DECRQSS-curly-underline", .setup = "\x1b[4:3m", .query = "\x1bP$qm" ++ st, .expected = "\x1bP1$r0;4:3m" ++ st },
    .{ .name = "DECRQSS-cursor-style", .setup = "\x1b[4 q", .query = "\x1bP$q q" ++ st, .expected = "\x1bP1$r4 q" ++ st },
    .{ .name = "DECRQSS-scrolling-margins", .setup = "\x1b[2;5r", .query = "\x1bP$qr" ++ st, .expected = "\x1bP1$r2;5r" ++ st },
    .{ .name = "DECRQSS-unknown-string", .query = "\x1bP$qz" ++ st, .expected = "\x1bP0$r" ++ st },
    // With no clipboard host callback, OSC52 is silently ignored; do not call
    // this an asynchronous prompt or fabricate an empty clipboard response.
    .{ .name = "OSC52-read-standard-denied", .query = "\x1b]52;c;?" ++ st, .expected = "", .calls = 0 },
    .{ .name = "OSC52-read-primary-denied", .query = "\x1b]52;p;?\x07", .expected = "", .calls = 0 },
    .{ .name = "OSC52-write-denied", .query = "\x1b]52;c;TmV2ZXIgc2VudCB0byBPUyBjbGlwYm9hcmQ=" ++ st, .expected = "", .calls = 0 },
    .{ .name = "OSC52-clear-denied", .query = "\x1b]52;c;" ++ st, .expected = "", .calls = 0 },
    .{ .name = "OSC52-invalid-base64-denied", .query = "\x1b]52;c;!!!" ++ st, .expected = "", .calls = 0 },
    .{ .name = "Kitty-clipboard-read-explicit-denial", .query = "\x1b]5522;type=read:id=fixture;dGV4dC9wbGFpbg==" ++ st, .expected = "\x1b]5522;type=read:status=EPERM:id=fixture" ++ st },
    .{ .name = "Kitty-clipboard-write-host-unavailable", .query = "\x1b]5522;type=write:id=fixture" ++ st, .expected = "\x1b]5522;type=write:status=ENOSYS:id=fixture" ++ st },
    .{ .name = "Kitty-clipboard-bad-read-payload", .query = "\x1b]5522;type=read;!!!" ++ st, .expected = "", .calls = 0 },
    .{ .name = "XTGETTCAP-terminal-name-unconfigured", .query = "\x1bP+q544E" ++ st, .expected = "", .calls = 0 },
};
const Replies = struct {
    bytes: [8192]u8 = undefined,
    lengths: [32]usize = undefined,
    len: usize = 0,
    calls: usize = 0,
    overflow: bool = false,
    fn receive(context: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void {
        const self: *Replies = @ptrCast(@alignCast(context.?));
        if (self.calls == self.lengths.len or len > self.bytes.len - self.len) {
            self.overflow = true;
            return;
        }
        @memcpy(self.bytes[self.len..][0..len], bytes[0..len]);
        self.lengths[self.calls] = len;
        self.len += len;
        self.calls += 1;
    }
    fn clear(self: *Replies) void {
        self.len = 0;
        self.calls = 0;
        self.overflow = false;
    }
};
const event_seed = "\x07\x1b]2;Protocol title" ++ st ++ "\x1b]7;file://localhost/protocol" ++ st ++
    "\x1b]133;A" ++ st ++ "\x1b]133;B" ++ st ++ "\x1b]133;C" ++ st ++ "\x1b]133;D;3" ++ st ++ "\x1b]133;A" ++ st ++ "\x1b]9;4;1;37" ++ st ++ "\x1b[2;3H";
fn create(gpa: std.mem.Allocator, io: std.Io, replies: *Replies, case: Case) !*vt.Vt {
    const value = try vt.create(gpa, io, 20, 6, 1000, 2 * 1024 * 1024, Replies.receive, replies);
    errdefer vt.destroy(value);
    vt.lt_vt_colors(value, 0x123456, 0xf0e0d0);
    var palette: [16]u32 = @splat(0x010203);
    palette[1] = 0x223344;
    vt.lt_vt_palette(value, &palette, 0xabcdef);
    if (vt.lt_vt_resize(value, 20, 6, 8, 18) != 0) return error.ProtocolInitialResize;
    try vt.feed(value, event_seed);
    var events: vt.Events = .{};
    vt.lt_vt_events(value, &events);
    if (events.bells != 1 or events.pwd != 1 or events.prompts != 2 or events.starts != 1 or events.ends != 1 or events.exit_code != 3 or !events.has_exit or !events.at_prompt or events.progress_state != 1 or events.progress != 37) return error.ProtocolHostEffectsMissing;
    try vt.feed(value, case.setup);
    replies.clear();
    return value;
}
fn apply(value: *vt.Vt, replies: *Replies, case: Case, cut: ?usize) !void {
    if (cut) |position| {
        try vt.feed(value, case.query[0..position]);
        try vt.feed(value, case.query[position..]);
    } else try vt.feed(value, case.query);
    if (case.resize and vt.lt_vt_resize(value, 17, 7, 9, 19) != 0) return error.ProtocolInBandResize;
    if (replies.overflow) return error.ProtocolReplyOverflow;
    const expected = case.expected;
    const calls = case.calls;
    if (!std.mem.eql(u8, replies.bytes[0..replies.len], expected) or replies.calls != calls) {
        std.debug.print("FAIL PROTOCOL {s}: expected bytes={any}, calls={d}; actual bytes={any}, calls={d}\n", .{ case.name, expected, calls, replies.bytes[0..replies.len], replies.calls });
        return error.ProtocolResponseMismatch;
    }
    // A later empty feed must never replay a completed query response.
    const before = replies.calls;
    try vt.feed(value, "");
    if (replies.calls != before) return error.ProtocolRepeatedReply;
}
fn capture(gpa: std.mem.Allocator, value: *vt.Vt, replies: *const Replies, case: Case) ![]u8 {
    var events: vt.Events = .{};
    vt.lt_vt_events(value, &events);
    var cursor: vt.Cursor = .{};
    if (vt.lt_vt_frame(value, &cursor) != 0) return error.ProtocolFrame;
    vt.lt_vt_frame_end(value);
    var title: [1024]u8 = undefined;
    const title_len = vt.lt_vt_title(value, &title, title.len);
    var pwd: [4096]u8 = undefined;
    const pwd_len = vt.lt_vt_pwd(value, &pwd, pwd.len);
    return std.json.Stringify.valueAlloc(gpa, .{
        .fixture = case.name,
        .legacy_size_callback = case.legacy_size_callback,
        .reply_bytes = replies.bytes[0..replies.len],
        .reply_calls = replies.calls,
        .reply_lengths = replies.lengths[0..replies.calls],
        .cursor = .{ .x = cursor.x, .y = cursor.y },
        .events = events,
        .title = title[0..title_len],
        .pwd = pwd[0..pwd_len],
        .focus_reporting = vt.lt_vt_focus_enabled(value),
        .bracketed_paste = vt.lt_vt_bracketed(value),
    }, .{});
}
pub fn run(gpa: std.mem.Allocator, io: std.Io) !usize {
    if (!vt.capabilities.basic or !vt.capabilities.frame or !vt.capabilities.events or !vt.capabilities.input) return error.ProtocolFacadeCapabilityMissing;
    var splits: usize = 0;
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const scratch = arena.allocator();
        var replies: Replies = .{};
        const value = try create(gpa, io, &replies, case);
        defer vt.destroy(value);
        var before: vt.Events = .{};
        vt.lt_vt_events(value, &before);
        try apply(value, &replies, case, null);
        var after: vt.Events = .{};
        vt.lt_vt_events(value, &after);
        if (!std.meta.eql(before, after)) return error.ProtocolQueryMutatedHostEvents;
        const baseline = try capture(scratch, value, &replies, case);
        std.debug.print("PROTOCOL {s}\n", .{baseline});
        for (0..case.query.len + 1) |cut| {
            var other_replies: Replies = .{};
            const other = try create(gpa, io, &other_replies, case);
            defer vt.destroy(other);
            try apply(other, &other_replies, case, cut);
            const current = try capture(scratch, other, &other_replies, case);
            if (!std.mem.eql(u8, baseline, current)) return error.ProtocolFragmentedMismatch;
            splits += 1;
        }
    }
    // Keep this accepted summary schema; the five gaps describe archived C
    // provenance only. All 56 native responses and 596 split checks are strict.
    std.debug.print("Protocol query fixtures: {d}; byte-split checks: {d}; known size-callback gaps: 5\n", .{ cases.len, splits });
    return cases.len;
}
pub fn main(init: std.process.Init) !void {
    const count = try run(init.gpa, init.io);
    std.debug.print("All {d} public-facade protocol query fixtures passed.\n", .{count});
}
