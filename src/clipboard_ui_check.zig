//! M4 transactions and links: test-owned clipboard/opener adapters, no OS side effects.
const std = @import("std");
const builtin = @import("builtin");
const nano = @import("nanoui");
const ui = nano.ui;
const vt_api = @import("vt.zig");
const clip = @import("clipboard.zig");
const Request = @import("actions.zig").Request;
const Probe = struct {
    target: u64 = 0,
    primary: bool = false,
    reads: usize = 0,
    primary_writes: usize = 0,
    opens: usize = 0,
    selection: @import("fixed_text.zig").Text(4096) = .{},
    opened: @import("fixed_text.zig").Text(2048) = .{},
    fn read(data: *anyopaque, target: u64, primary: bool) bool {
        const p: *Probe = @ptrCast(@alignCast(data));
        p.target = target;
        p.primary = primary;
        p.reads += 1;
        return true;
    }
    fn write(data: *anyopaque, text: []const u8) void {
        const p: *Probe = @ptrCast(@alignCast(data));
        p.selection.set(text);
        p.primary_writes += 1;
    }
    fn open(data: *anyopaque, text: []const u8) bool {
        const p: *Probe = @ptrCast(@alignCast(data));
        p.opened.set(text);
        p.opens += 1;
        return true;
    }
};
fn check(ok: bool, title: []const u8) !void {
    std.debug.print("{s} UI {s}\n", .{ if (ok) "PASS" else "FAIL", title });
    if (!ok) return error.ClipboardUiCheck;
}
fn action(s: anytype, t: *ui.Tester, request: Request) void {
    s.menu_actions[0] = request;
    s.menu_action_count = 1;
    t.frame();
}
fn drain(t: *ui.Tester) void {
    for (0..6) |_| {
        nano.runFor(0.05);
        t.frame();
    }
}
fn contains(session: anytype, text: []const u8) bool {
    _ = vt_api.lt_vt_search(session.vt, text.ptr, text.len);
    var total: usize = 0;
    for (0..10000) |_| if (vt_api.lt_vt_search_tick(session.vt, &total) <= 0) break;
    vt_api.lt_vt_search_close(session.vt);
    return total > 0;
}
fn clickText(t: *ui.Tester, text: []const u8) !void {
    const r = t.findText(text) orelse return error.MissingControl;
    t.click(r.x + r.w / 2, r.y + r.h / 2);
    t.frame();
}
fn clickButton(t: *ui.Tester, x: f32, y: f32, button: u8) void {
    t.moveTo(x, y);
    t.ctx.input.mouse_button = button;
    t.ctx.pointerDown();
    t.frame();
    t.ctx.pointerUp();
    t.frame();
    t.ctx.input.mouse_button = 1;
}
pub fn run(s: anytype, t: *ui.Tester) !void {
    t.resize(800, 500);
    s.status = "";
    var probe: Probe = .{};
    s.clipboard_read_override = .{ .ctx = &probe, .call = Probe.read };
    s.primary_write_override = .{ .ctx = &probe, .call = Probe.write };
    s.opener_override = .{ .ctx = &probe, .call = Probe.open };
    defer {
        s.clipboard_read_override = null;
        s.primary_write_override = null;
        s.opener_override = null;
    }
    const target = s.active().?;
    const tab_id = s.layout.tabs[s.layout.active_tab].id;
    action(s, t, .{ .action = .paste });
    action(s, t, .{ .action = .previous_tab });
    const other = s.active().?;
    clip.deliver(s, probe.target, "PASTE_TARGET_A");
    t.frame();
    drain(t);
    try check(contains(target, "PASTE_TARGET_A") and !contains(other, "PASTE_TARGET_A"), "async CLIPBOARD response stays with request-time session after tab switch");
    action(s, t, .{ .action = .goto_tab, .args = .{ .index = s.layout.tabIndex(tab_id).? + 1 } });
    _ = t.shortcut(.{ .key = 'u', .ctrl = true });
    action(s, t, .{ .action = .paste });
    clip.deliver(s, probe.target, "printf 'PASTE_CANCELLED\\n'\n");
    t.frame();
    try check(s.confirmation.open and s.confirmation.kind == .paste, "non-bracketed multiline paste shows a preview before any bytes are sent");
    try t.screenshot(".cache/test-logs/paste-confirmation-paper.png");
    t.key(.escape);
    drain(t);
    try check(s.paste_transaction == null and !contains(target, "PASTE_CANCELLED"), "cancel multiline paste sends no bytes to the target shell");
    action(s, t, .{ .action = .paste });
    clip.deliver(s, probe.target, "printf 'PASTE_%s_OK\\n' ACCEPT\n");
    t.frame();
    try clickText(t, "Paste");
    drain(t);
    try check(contains(target, "PASTE_ACCEPT_OK"), "confirmed multiline paste executes only in its captured terminal");
    action(s, t, .{ .action = .paste });
    const closed_id = probe.target;
    action(s, t, .{ .action = .close });
    action(s, t, .{ .action = .tab });
    clip.deliver(s, closed_id, "MUST_NOT_PASTE_IN_REUSED_SLOT");
    t.frame();
    drain(t);
    try check(s.paste_delivery == null and s.paste_transaction == null and !contains(s.active().?, "MUST_NOT_PASTE_IN_REUSED_SLOT"), "closed async target cannot redirect paste to a reused pane slot");
    // A raw collector proves bracketed pastes without asking an ordinary shell to parse them.
    const old_command = s.command_override;
    s.command_override = "stty -echo -icanon; cat";
    action(s, t, .{ .action = .tab });
    s.command_override = old_command;
    drain(t);
    const collector = s.active().?;
    vt_api.lt_vt_feed(collector.vt, "\x1b[?2004h", 8);
    action(s, t, .{ .action = .paste });
    clip.deliver(s, probe.target, "BRACKETED_SAFE\nSECOND\n");
    t.frame();
    drain(t);
    try check(!s.confirmation.open and s.paste_transaction == null and contains(collector, "BRACKETED_SAFE"), "bracketed-safe policy bypasses confirmation through the same transaction");
    vt_api.lt_vt_feed(collector.vt, "\x1b[?2004l\x1b[2J\x1b[HPRIMARY_SAMPLE", "\x1b[?2004l\x1b[2J\x1b[HPRIMARY_SAMPLE".len);
    t.frame();
    s.cfg.copy_on_select = .primary;
    t.ctx.clipboard.write(t.ctx.clipboard.ctx, "CLIPBOARD_UNCHANGED");
    const first = t.findGridCell("P") orelse return error.MissingCell;
    t.drag(first.x + 1, first.y + 8, first.x + 120, first.y + 8);
    try check(probe.primary_writes > 0 and std.mem.indexOf(u8, probe.selection.text(), "PRIMARY") != null and std.mem.eql(u8, t.clipboard.items, "CLIPBOARD_UNCHANGED"), "copy-on-select writes PRIMARY without altering CLIPBOARD");
    const reads = probe.reads;
    clickButton(t, s.navigation_rects.content.x + 60, 150, 3);
    try check(probe.reads == reads + 1 and probe.primary, "middle click requests PRIMARY with its captured session ID");
    clip.deliver(s, probe.target, "PRIMARY_REPLY");
    t.frame();
    drain(t);
    try check(contains(collector, "PRIMARY_REPLY"), "PRIMARY response follows the common paste transaction");
    s.cfg.copy_on_select = .none;
    t.textOps(&.{.{ .insert = "IME_中文\n" }});
    drain(t);
    try check(!s.confirmation.open and contains(collector, "IME_中文"), "IME commit bypasses clipboard confirmation machinery");
    try links(s, t, &probe, collector);
}
fn links(s: anytype, t: *ui.Tester, probe: *Probe, collector: anytype) !void {
    const url = "https://example.com/path";
    vt_api.lt_vt_feed(collector.vt, "\x1b[2J\x1b[Hhttps://example.com/path", "\x1b[2J\x1b[Hhttps://example.com/path".len);
    t.frame();
    const letter = t.findGridCell(":") orelse return error.MissingCell;
    t.ctx.input.cmd = builtin.os.tag == .macos;
    t.ctx.input.ctrl = builtin.os.tag != .macos;
    t.moveTo(letter.x + 2, letter.y + 8);
    t.frame();
    try check(s.views[s.layout.active_pane].link.visible and t.findText(url) != null, "modifier hover displays a copied, complete URL target");
    try t.screenshot(".cache/test-logs/link-hover-paper.png");
    const opens = probe.opens;
    t.click(letter.x + 2, letter.y + 8);
    t.frame();
    try check(probe.opens == opens + 1 and std.mem.eql(u8, probe.opened.text(), url), "modified click passes the exact HTTP target to an argv/native opener adapter");
    t.ctx.input.cmd = false;
    t.ctx.input.ctrl = false;
    const output = "\x1b[2J\x1b[H\x1b]8;;https://real.example/target\x1b\\display label\x1b]8;;\x1b\\";
    vt_api.lt_vt_feed(collector.vt, output, output.len);
    t.frame();
    const cell = t.findGridCell("d") orelse return error.MissingCell;
    clickButton(t, cell.x + 2, cell.y + 8, 2);
    try check(s.context_menu.open and std.mem.eql(u8, s.context_menu.link.text(), "https://real.example/target"), "OSC 8 context menu retains real URI instead of display text");
    try clickText(t, "Copy Link Target");
    try check(std.mem.eql(u8, t.clipboard.items, "https://real.example/target"), "copy link target writes OSC 8 metadata to the test clipboard");
    const before = probe.opens;
    s.link_target.set("file:///etc/passwd");
    action(s, t, .{ .action = .open_link });
    try check(probe.opens == before, "non-web schemes never reach the opener");
}
