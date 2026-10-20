//! Real hidden windows, stable cross-window ownership and atomic reload.
const std = @import("std");
const nano = @import("nanoui");
const ui = nano.ui;
const c = @import("platform_ffi.zig");
const config = @import("config.zig");
const Request = @import("actions.zig").Request;
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn unlink([*:0]const u8) c_int;
extern "c" fn rmdir([*:0]const u8) c_int;
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.MultiwindowUiCheck;
}
fn action(s: anytype, t: *ui.Tester, request: Request) void {
    s.menu_actions[0] = request;
    s.menu_action_count = 1;
    t.frame();
}
fn settle() void {
    nano.runFor(0.04);
}
pub fn run(s: anytype, t: *ui.Tester) !void {
    const h = s.host;
    const a = s.active().?;
    const a_id = a.id;
    const a_pid = a.pid;
    const b = try h.create(true);
    b.retain();
    defer b.release();
    var second: ui.Tester = undefined;
    try second.init(s.gpa, .init(b, @TypeOf(s.*).view), .{ .width = 800, .height = 500, .theme = t.theme });
    defer second.deinit();
    b.window_focused = true;
    second.frame();
    const b_session = b.active().?;
    try check(h.count() == 2 and b.id != s.id and b_session.id != a_id and b_session.pid != a_pid, "two hidden windows own globally distinct window/session identities and PTYs");
    h.active_id = b.id;
    h.queue(.{ .action = .font_up });
    second.frame();
    try check(b.cfg.font_size != s.cfg.font_size and s.active().?.pid == a_pid, "application menu queue targets active window while font zoom remains local");
    b.cfg.confirm_close = .always;
    action(b, &second, .{ .action = .quit });
    try check(b.confirmation.open and b.close_pending.count == h.paneCount() and b.close_pending.contains(a_id), "Quit captures all windows in one confirmation transaction");
    second.key(.escape);
    try check(h.count() == 2 and s.active().?.pid == a_pid and b_session.pid == b.active().?.pid, "cancelling application Quit preserves both windows and their processes");
    // Cross the former window ceiling using owned hidden fixtures.
    var extra: [10]u64 = undefined;
    for (&extra) |*id| {
        const w = try h.create(false);
        id.* = w.id;
    }
    try check(h.count() == 12 and h.paneCount() >= 12, "application registry grows beyond eight windows with distinct PTYs");
    try reload(s, t, b, &second);
    for (extra) |id| h.closeWindow(h.find(id).?);
    settle();
    try check(h.count() == 2, "closing auxiliary windows leaves the other windows registered");
    // Fill total PTYs across both windows, not a 16-PTY allowance per window.
    while (h.paneCount() < 24) try b.add(.horizontal);
    try b.layout.validate(b.cfg.profiles.len);
    try check(h.paneCount() == 24 and b.active() != null, "application grows beyond sixteen PTYs and split nodes remain valid");
    var original_layout = try b.layout.clone();
    defer original_layout.deinit();
    const real_allocator = b.gpa;
    var failure = std.testing.FailingAllocator.init(real_allocator, .{ .fail_index = 0 });
    b.gpa = failure.allocator();
    const failed_add = b.add(.horizontal);
    b.gpa = real_allocator;
    try std.testing.expectError(error.OutOfMemory, failed_add);
    try check(h.paneCount() == 24 and original_layout.same(b.layout), "allocation failure leaves all PTYs and split topology intact");
    b.cfg.confirm_close = .always;
    action(b, &second, .{ .action = .quit });
    try check(b.confirmation.open and b.close_pending.count == 24 and b.close_pending.contains(b.active().?.id), "Quit confirmation captures every real PTY beyond the former sixteen-session limit");
    second.key(.escape);
    try check(h.paneCount() == 24, "cancelling large Quit keeps every captured PTY alive");
    // An async callback may outlive the native window; retain state until it returns.
    const late_target = b.active().?.id;
    b.paste_session = late_target;
    b.cfg.confirm_close = .always;
    action(b, &second, .{ .action = .close_window });
    try check(b.confirmation.open and b.close_pending.count < h.paneCount(), "Close Window confirmation includes only that window's captured sessions");
    second.key(.escape);
    h.closeWindow(b);
    settle();
    @import("clipboard.zig").deliver(b, late_target, "LATE_RESPONSE");
    try check(b.retired and b.shutting_down and b.paste_delivery == null and h.count() == 1 and a.pid == a_pid, "late clipboard delivery to retired window is dropped without touching surviving PTY");
    h.active_id = s.id;
    s.window_focused = true;
    t.frame();
    try check(!s.closing and s.active().?.id == a_id, "closing B keeps window A usable with its original session identity");
}
fn reload(s: anytype, t: *ui.Tester, b: anytype, second: *ui.Tester) !void {
    const name = try s.gpa.dupeSentinel(u8, ".cache/test-logs/windows-XXXXXX", 0);
    defer s.gpa.free(name);
    const dir = mkdtemp(name) orelse return error.TempDirectory;
    defer _ = rmdir(dir);
    const path = try std.fmt.allocPrintSentinel(s.gpa, "{s}/config", .{std.mem.span(dir)}, 0);
    defer s.gpa.free(path);
    defer _ = unlink(path);
    const layout_path = try std.fmt.allocPrintSentinel(s.gpa, "{s}/workspace.json", .{std.mem.span(dir)}, 0);
    defer s.gpa.free(layout_path);
    defer _ = unlink(layout_path);
    const old_path = s.explicit_config;
    s.explicit_config = path;
    defer s.explicit_config = old_path;
    const first = s.active().?;
    const other = b.active().?;
    const first_pid = first.pid;
    const other_pid = other.pid;
    const text = "shell = /bin/sh\ncopy-on-select = none\nfont-size = 15\nbackground = #162636\n";
    try check(c.lt_write_atomic(path, text, text.len) == 0, "prepare multi-window configuration transaction");
    const prior_profiles = b.cfg.profiles;
    var incompatible = [_]config.Profile{.{ .name = "Removed Profile" }};
    b.cfg.profiles = &incompatible;
    const old_color = s.cfg.background;
    const other_color = b.cfg.background;
    action(s, t, .{ .action = .reload });
    try check(s.cfg.background == old_color and b.cfg.background == other_color and !s.confirmation.open, "profile mismatch rejects reload atomically in every window");
    b.cfg.profiles = prior_profiles;
    action(s, t, .{ .action = .reload });
    second.frame();
    try check(s.cfg.background == 0x162636 and b.cfg.background == 0x162636 and first.pid == first_pid and other.pid == other_pid, "successful shared reload applies every window and preserves all PIDs");
    const h = s.host;
    const old_state = h.state_path;
    const old_demo = h.demo;
    h.state_path = layout_path;
    h.demo = false;
    h.save();
    h.demo = old_demo;
    h.state_path = old_state;
    var arena = std.heap.ArenaAllocator.init(s.gpa);
    defer arena.deinit();
    const bytes = (try config.read(arena.allocator(), layout_path, 512 * 1024)) orelse return error.LayoutMissing;
    const document = try @import("workspace_layout.zig").decode(arena.allocator(), bytes, s.cfg.profiles.len);
    try check(document.windows.len == h.count() and document.next_window_id > document.windows[1].id, "persistence records every window beyond the old eight-window limit");
    var restored: @TypeOf(h.*) = .{ .gpa = s.gpa, .arena = arena.allocator(), .app = s.app, .cfg = h.cfg, .state_path = layout_path, .read_path = layout_path, .demo = true, .hold = true, .command_override = h.command_override, .override_profile = h.override_profile };
    defer restored.deinit();
    try check(try restored.restore(), "serialized multi-window workspace restores real independent PTYs");
    const restored_first = restored.active().?.active().?;
    try check(restored.count() == h.count() and restored_first.pid != first_pid and restored_first.pid != other_pid, "workspace restart restores topology with fresh processes instead of reusing handles");
    const lock = try std.fmt.allocPrintSentinel(s.gpa, "{s}/writer.lock", .{std.mem.span(dir)}, 0);
    defer s.gpa.free(lock);
    defer _ = unlink(lock);
    const fd = c.lt_state_lock(lock);
    defer c.lt_close(fd);
    const conflict = c.lt_state_lock(lock);
    defer c.lt_close(conflict);
    try check(fd >= 0 and conflict < 0, "layout writer lock rejects a competing process-style writer");
}
