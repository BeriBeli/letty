//! Real upstream OSC 52 parsing and host delivery through Tester's clipboard.
//! Only owned hidden-test sessions/config are used; no system clipboard access.
const std = @import("std");
const ui = @import("nanoui").ui;
const vt = @import("vt.zig");
const config = @import("config.zig");
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI OSC52 {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.Osc52UiCheck;
}
fn send(gpa: std.mem.Allocator, terminal: *vt.Vt, text: []const u8) !void {
    const encoded = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(text.len));
    defer gpa.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, text);
    const command = try std.fmt.allocPrint(gpa, "\x1b]52;c;{s}\x07", .{encoded});
    defer gpa.free(command);
    try vt.feed(terminal, command);
}
pub fn run(s: anytype) !void {
    const W = @TypeOf(s.*);
    const h = s.host;
    const old_active = h.active_id;
    defer if (h.find(old_active) != null) {
        h.active_id = old_active;
    };
    const w = try h.create(false);
    defer h.retire(w);
    w.hold = true;
    w.cfg.kitty_graphics = false;
    w.cfg.copy_on_select = .none;
    w.cfg.confirm_close = .never;
    const first = w.active().?;
    const first_slot = w.layout.active_pane;
    const pid = first.pid;
    w.cfg.clipboard_write = .deny;
    w.configureSession(first);
    var t: ui.Tester = undefined;
    try t.init(s.gpa, .init(w, W.view), .{ .width = 640, .height = 400, .scale = 1, .theme = @import("appearance.zig").theme(w.cfg) });
    defer t.deinit();
    try send(s.gpa, first.vt, "denied");
    t.frame();
    try check(t.clipboard.items.len == 0 and !w.confirmation.open and w.osc52_pending == null, "default deny never writes or prompts");

    w.cfg.clipboard_write = .ask;
    w.configureSession(first);
    try send(s.gpa, first.vt, "hello 中文");
    try check(t.clipboard.items.len == 0 and w.osc52_pending == null, "native callback queues bytes without touching host clipboard");
    t.frame();
    try check(w.confirmation.open and w.confirmation.kind == .osc52_write and w.osc52_pending.?.target == first.id and std.mem.eql(u8, w.osc52_pending.?.request.bytes, "hello 中文"), "after feed owns exact Unicode and stable source target");
    t.key(.enter);
    t.frame();
    try check(w.osc52_pending == null and !w.confirmation.open and t.clipboard.items.len == 0, "default Enter cancels confirmation without write");

    try send(s.gpa, first.vt, "approved 中文");
    t.frame();
    w.confirmation.primary_selected = true;
    t.key(.enter);
    t.frame();
    try check(std.mem.eql(u8, t.clipboard.items, "approved 中文") and w.osc52_pending == null and first.pid == pid, "explicit confirmation writes fake clipboard and preserves PTY");

    try send(s.gpa, first.vt, "revoked");
    t.frame();
    w.cfg.clipboard_write = .deny;
    w.configureSession(first);
    t.frame();
    try check(w.osc52_pending == null and !w.confirmation.open and std.mem.eql(u8, t.clipboard.items, "approved 中文"), "policy reload revokes an outstanding host confirmation");

    w.cfg.clipboard_write = .allow;
    w.configureSession(first);
    try send(s.gpa, first.vt, "first bounded request");
    try send(s.gpa, first.vt, "second must not replace it");
    t.frame();
    try check(std.mem.eql(u8, t.clipboard.items, "first bounded request") and !w.confirmation.open, "allow is explicit and busy queue preserves the first request");
    try vt.feed(first.vt, "\x1b]52;c;%%%\x07");
    t.frame();
    try check(std.mem.eql(u8, t.clipboard.items, "first bounded request") and !vt.lt_vt_failed(first.vt), "invalid base64 is ignored without partial write or terminal failure");
    try send(s.gpa, first.vt, "bad\x00text");
    t.frame();
    try check(std.mem.eql(u8, t.clipboard.items, "first bounded request") and !vt.lt_vt_failed(first.vt), "decoded NUL is refused before native text APIs");
    try send(s.gpa, first.vt, "");
    t.frame();
    try check(t.clipboard.items.len == 0, "explicit empty write clears clipboard through normal host path");

    w.cfg.clipboard_write = .ask;
    w.configureSession(first);
    try w.add(.tab);
    const second = w.active().?;
    const second_pid = second.pid;
    w.configureSession(second);
    try send(s.gpa, first.vt, "background source");
    t.frame();
    try check(w.osc52_pending != null and w.osc52_pending.?.target == first.id and w.active().? == second, "background source prompt does not retarget or activate another terminal");
    w.close(first_slot);
    t.frame();
    try check(w.osc52_pending == null and !w.confirmation.open and t.clipboard.items.len == 0 and second.pid == second_pid, "source closure cancels instead of writing on another session");

    try send(s.gpa, second.vt, "superseded prompt");
    t.frame();
    w.confirmation.show(&t.ctx, .diagnostics, "Other prompt", "No clipboard write", "Close");
    t.frame();
    try check(w.osc52_pending == null and w.confirmation.kind == .diagnostics and t.clipboard.items.len == 0, "another prompt safely retires pending clipboard bytes");
    w.confirmation.dismiss(&t.ctx);
    t.frame();

    try send(s.gpa, second.vt, "stale same-kind payload");
    t.frame();
    const previous_generation = w.osc52_pending.?.generation;
    w.confirmation.show(&t.ctx, .osc52_write, "Replacement prompt", "New consent cannot approve old bytes", "Write Clipboard");
    try check(w.confirmation.generation != previous_generation, "replacement prompt receives a fresh consent generation");
    t.frame();
    try check(w.osc52_pending == null and !w.confirmation.open and t.clipboard.items.len == 0, "same-kind replacement revokes old pending write instead of inheriting consent");
    try send(s.gpa, second.vt, "late callback payload");
    t.frame();
    const late_generation = w.osc52_pending.?.generation;
    @import("application_osc52.zig").finish(w, &t.ctx, true, late_generation -% 1);
    try check(w.osc52_pending == null and t.clipboard.items.len == 0, "late confirmation generation cannot authorize clipboard write");
    w.confirmation.dismiss(&t.ctx);
    t.frame();
    w.cfg.clipboard_write = .allow;
    w.configureSession(second);
    try send(s.gpa, second.vt, "\xff");
    t.frame();
    try check(t.clipboard.items.len == 0 and !vt.lt_vt_failed(second.vt), "decoded invalid UTF8 is refused without a partial clipboard write");
    try vt.feed(second.vt, "\x1b]52;c;?\x07");
    t.frame();
    try check(t.clipboard.items.len == 0 and !w.confirmation.open and w.osc52_pending == null and !vt.lt_vt_failed(second.vt), "synchronous read query returns no host clipboard data or asynchronous prompt");

    var arena = std.heap.ArenaAllocator.init(s.gpa);
    defer arena.deinit();
    if (config.parseText(arena.allocator(), "clipboard-read=allow\n")) |_| {
        try check(false, "unsupported synchronous clipboard reads reject configuration explicitly");
    } else |err| try check(err == error.UnsupportedSynchronousClipboardRead, "unsupported synchronous clipboard reads reject configuration explicitly");
}
