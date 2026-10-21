//! End-to-end document editing in an owned hidden application window.
const std = @import("std");
const nano = @import("nanoui");
const application = @import("../application_preview.zig");
extern "c" fn lt_config_fixture_write([*:0]const u8, [*]const u8, usize, c_uint) c_int;
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI Editor {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.EditorApplicationCheck;
}
fn step(t: *nano.ui.Tester) void {
    nano.runFor(0.01);
    t.frame();
}
fn ready(w: anytype, t: *nano.ui.Tester, id: u64) !void {
    for (0..600) |_| {
        step(t);
        const d = w.preview.find(id) orelse return error.EditorDocumentLost;
        if (!d.panel.edit_busy and d.panel.edit_request == .none) return;
    }
    return error.EditorOperationTimeout;
}
pub fn run(w: anytype, t: *nano.ui.Tester, a: std.mem.Allocator, dir: []const u8) !void {
    const original_tab = w.layout.tabs[w.layout.active_tab].id;
    const path = try std.fmt.allocPrintSentinel(a, "{s}/editor-fixture.md", .{dir}, 0);
    defer _ = std.c.unlink(path);
    const source = "# Editor fixture\n";
    if (lt_config_fixture_write(path, source.ptr, source.len, 0o600) != 0) return error.EditorFixtureWrite;
    try application.openWorkspace(w, path);
    const d = w.preview.active(w.layout.tabs[w.layout.active_tab].id).?;
    const id = d.id;
    for (0..600) |_| {
        step(t);
        if (d.panel.prepared != null and d.panel.model.status == .ready) break;
    }
    try @import("ui_check.zig").clickControl(&d.panel, t, .unlock);
    try ready(w, t, id);
    try check(d.panel.editor != null, "footer lock captures disk snapshot and opens editor");
    t.typeText("中文 draft\n");
    try check(d.panel.editor.?.dirty and d.panel.hasUnsaved(), "application routes typed text into owned draft");
    const ax = @import("../accessibility.zig");
    var accessible = false;
    if (w.ax.adapter) |*adapter| for (adapter.snapshot.nodes[0..adapter.snapshot.count]) |node| {
        if (std.mem.eql(u8, adapter.snapshot.label(node), "Document Source Editor")) accessible = node.role == .text_field and node.state & ax.State.read_only == 0;
    };
    try check(accessible, "accessibility exposes editable source field");
    w.preview.close(w, id);
    try check(w.preview.find(id) != null, "document close preserves unsaved draft");
    try check(!@import("../application_preview_edit.zig").guardClose(w, .window) and !@import("../application_preview_edit.zig").guardClose(w, .quit), "window close and Quit reject dirty document");
    t.frame();
    _ = t.shortcut(.{ .key = 's', .cmd = @import("builtin").os.tag == .macos, .ctrl = @import("builtin").os.tag != .macos });
    try ready(w, t, id);
    try check(d.panel.editor == null and !d.panel.hasUnsaved() and d.panel.mode == .rendered, "Cmd/Ctrl+S saves, locks and restores Markdown preview");
    var snapshot = try @import("../config_edit.zig").Native.capture(a, path);
    defer snapshot.deinit();
    try check(std.mem.indexOf(u8, snapshot.bytes, "中文 draft") != null, "saved application draft reaches disk");
    for (0..600) |_| {
        step(t);
        if (d.panel.prepared != null and std.mem.indexOf(u8, d.panel.prepared.?.source.text, "中文 draft") != null) break;
    }
    try @import("ui_check.zig").clickControl(&d.panel, t, .unlock);
    try ready(w, t, id);
    try check(d.panel.editor != null, "saved file can be unlocked again");
    t.typeText("discard me");
    try @import("ui_check.zig").clickControl(&d.panel, t, .discard);
    try ready(w, t, id);
    try check(d.panel.editor == null and !d.panel.hasUnsaved(), "Discard clears draft and releases close protection");
    w.preview.close(w, id);
    w.activateTab(w.layout.tabIndex(original_tab).?);
    t.ctx.focus = 0;
    t.frame();
}
