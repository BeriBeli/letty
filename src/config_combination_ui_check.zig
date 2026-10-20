//! Real configuration files and PTYs in an isolated, hidden two-window Host.
//! No user configuration, global environment, shell startup file or clipboard.
const std = @import("std");
const builtin = @import("builtin");
const nano = @import("nanoui");
const ui = nano.ui;
const config = @import("config.zig");
const vt = @import("vt.zig");
const c = @import("platform_ffi.zig");
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn unlink([*:0]const u8) c_int;
extern "c" fn rmdir([*:0]const u8) c_int;
extern "c" fn symlink([*:0]const u8, [*:0]const u8) c_int;
extern "c" fn lt_mkdirs([*:0]const u8) c_int;
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.ConfigCombinationUiCheck;
}
fn path(a: std.mem.Allocator, dir: []const u8, leaf: []const u8) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, leaf }, 0);
}
fn write(name: [:0]const u8, text: []const u8) !void {
    if (c.lt_write_atomic(name, text.ptr, text.len) != 0) return error.FixtureWrite;
}
fn action(s: anytype, t: *ui.Tester) void {
    s.menu_actions[0] = .{ .action = .reload };
    s.menu_action_count = 1;
    t.frame();
}
fn dismiss(s: anytype, t: *ui.Tester) !void {
    if (s.confirmation.open) t.key(.escape);
    if (s.confirmation.open) return error.DiagnosticStillOpen;
}
fn terminalColors(session: anytype, bg: u24, cursor_color: u24) bool {
    var cursor: vt.Cursor = .{};
    if (vt.lt_vt_frame(session.vt, &cursor) != 0) return false;
    defer vt.lt_vt_frame_end(session.vt);
    return cursor.bg == bg and cursor.color == cursor_color;
}
fn unchanged(h: anytype, a: anytype, b: anytype, host_cfg: config.Config, first: config.Config, second: config.Config, first_pid: c_int, second_pid: c_int) bool {
    return std.meta.eql(h.cfg, host_cfg) and std.meta.eql(a.cfg, first) and std.meta.eql(b.cfg, second) and
        a.active().?.pid == first_pid and b.active().?.pid == second_pid and h.count() == 2 and h.paneCount() == 2;
}
fn diagnosed(d: *const config.Diagnostic, filename: []const u8, line: usize, reason: []const u8, chain: []const u8) bool {
    return std.mem.eql(u8, d.path[0..d.path_len], filename) and d.line == line and
        std.mem.eql(u8, d.reason[0..d.reason_len], reason) and std.mem.eql(u8, d.chain[0..d.chain_len], chain) and !d.chain_truncated;
}
pub fn run(s: anytype, t: *ui.Tester) !void {
    try check(s.app.flags.hidden, "configuration combination fixture runs only in hidden application mode");
    var storage = std.heap.ArenaAllocator.init(s.gpa);
    defer storage.deinit();
    const mem = storage.allocator();
    const template = try mem.dupeSentinel(u8, ".cache/test-logs/config-combination-XXXXXX", 0);
    const temp = mkdtemp(template) orelse return error.TempDirectory;
    defer _ = rmdir(temp);
    var absolute: [4096]u8 = undefined;
    if (c.lt_absolute_path(temp, &absolute, absolute.len) != 0) return error.TempDirectory;
    const dir = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&absolute)), 0);
    const child_dir = try path(mem, dir, "child");
    const themes_dir = try path(mem, dir, "child/themes");
    if (lt_mkdirs(themes_dir) != 0) return error.TempDirectory;
    defer {
        _ = rmdir(themes_dir);
        _ = rmdir(child_dir);
    }
    const root = try path(mem, dir, "config");
    const options = try path(mem, dir, "child/options");
    const nested = try path(mem, dir, "child/nested");
    const day = try path(mem, dir, "child/themes/day");
    const night = try path(mem, dir, "child/themes/night");
    const loop = try path(mem, dir, "child/loop");
    defer {
        for ([_][:0]const u8{ root, options, nested, day, night, loop }) |name| _ = unlink(name);
    }
    const root_text = "config-file=child/options\nconfig-file=?not-present\nforeground=#123456\nkeybind=ctrl+k>x=ignore\nfont-feature=ss01=9\n";
    const options_text = "config-file=nested\ntheme=light:themes/day,dark:themes/night\nkeybind-sequence-timeout=175\n";
    try write(root, root_text);
    try write(options, options_text);
    try write(nested, "# nested source\nfont-size=17\n");
    try write(day, "background=#f0eee0\ncursor-color=#aabbcc\nui-accent=#224466\nfont-feature=ss01=1,calt=0\nfont-ligatures=true\n");
    try write(night, "background=#102030\ncursor-color=#ddeeff\nui-accent=#6688aa\nfont-feature=ss01=2,calt=1\nfont-ligatures=false\n");

    // This Host owns all candidate arenas and PTYs; no configuration from the
    // surrounding suite is borrowed or replaced. Restore only the global menu.
    defer {
        if (builtin.os.tag == .macos) s.macMenu() catch {};
    }
    var h: @TypeOf(s.host.*) = .{ .gpa = s.gpa, .arena = mem, .app = s.app, .cfg = .{ .shell = "/bin/sh", .shell_integration = .none }, .state_path = "", .read_path = "", .demo = true, .hold = true, .command_override = "exec /bin/sh", .override_profile = "Local", .explicit_config = root };
    defer h.deinit();
    const a = try h.create(false);
    a.retain();
    defer a.release();
    var first: ui.Tester = undefined;
    try first.init(s.gpa, .init(a, @TypeOf(s.*).view), .{ .width = 800, .height = 500, .theme = t.theme });
    defer first.deinit();
    const b = try h.create(true);
    b.retain();
    defer b.release();
    var second: ui.Tester = undefined;
    try second.init(s.gpa, .init(b, @TypeOf(s.*).view), .{ .width = 800, .height = 500, .theme = t.theme });
    defer second.deinit();
    const first_pid = a.active().?.pid;
    const second_pid = b.active().?.pid;
    const first_id = a.active().?.id;
    const second_id = b.active().?.id;
    try check(h.count() == 2 and first_pid != second_pid and b.window != null, "config fixture owns two isolated windows and independent live PTYs");
    action(a, &first);
    second.frame();
    try check(a.cfg.background == 0xf0eee0 and b.cfg.background == 0xf0eee0 and a.cfg.font_size == 17 and b.cfg.font_size == 17 and
        a.cfg.foreground == 0x123456 and a.cfg.keybind_sequence_timeout == 175 and a.cfg.keybinds.len == 1 and
        std.mem.eql(u8, a.cfg.keybinds[0].accelerator, "Ctrl+k > x") and h.cfg.config_sources.len == 6 and
        a.active().?.pid == first_pid and b.active().?.pid == second_pid, "nested and optional includes plus both themes reload atomically into both live windows");
    const host_cfg = h.cfg;
    const old_a = a.cfg;
    const old_b = b.cfg;
    const chain = try std.fmt.allocPrint(mem, "{s}:1\n{s}:1\n", .{ root, options });
    try write(nested, "# invalid included value\nkeybind-sequence-timeout=49\n");
    action(a, &first);
    try check(unchanged(&h, a, b, host_cfg, old_a, old_b, first_pid, second_pid), "included semantic failure leaves all windows config and PTYs unchanged");
    try check(diagnosed(&a.config_diagnostic, nested, 2, "InvalidSequenceTimeout", chain) and a.confirmation.open, "real include diagnostics preserve canonical source line and complete include chain");
    try dismiss(a, &first);
    try write(nested, "font-size=17\n");
    try write(options, "config-file=required-missing\n");
    action(a, &first);
    try check(unchanged(&h, a, b, host_cfg, old_a, old_b, first_pid, second_pid) and
        std.mem.eql(u8, a.config_diagnostic.reason[0..a.config_diagnostic.reason_len], "ConfigNotFound"), "missing required include rejects reload for every window");
    try dismiss(a, &first);
    try write(options, "config-file=loop\n");
    if (symlink(root, loop) != 0) return error.FixtureSymlink;
    action(a, &first);
    try check(unchanged(&h, a, b, host_cfg, old_a, old_b, first_pid, second_pid) and
        std.mem.eql(u8, a.config_diagnostic.reason[0..a.config_diagnostic.reason_len], "IncludeCycle") and
        std.mem.eql(u8, a.config_diagnostic.path[0..a.config_diagnostic.path_len], options), "physical symlink cycle is rejected without changing either live session");
    try dismiss(a, &first);
    try write(options, "theme=light:themes/day,dark:themes/not-present\n");
    action(a, &first);
    try check(unchanged(&h, a, b, host_cfg, old_a, old_b, first_pid, second_pid) and !h.system_dark and a.confirmation.open, "inactive missing dark theme rejects whole reload while light appearance is active");
    try dismiss(a, &first);
    try write(options, options_text);
    try write(night, "# invalid inactive theme\nbackground=broken\n");
    action(a, &first);
    const theme_chain = try std.fmt.allocPrint(mem, "{s}:1\n{s}:2\n", .{ root, options });
    try check(unchanged(&h, a, b, host_cfg, old_a, old_b, first_pid, second_pid) and
        diagnosed(&a.config_diagnostic, night, 2, "InvalidColor", theme_chain), "invalid inactive dark theme reports its actual file line and defining theme chain");
    try dismiss(a, &first);

    // The already loaded successful snapshot still owns both theme branches.
    // Deleting light and corrupting dark must have no effect on appearance events.
    if (unlink(day) != 0) return error.FixtureUnlink;
    a.cfg.font_size = 23;
    b.cfg.font_size = 29;
    const first_base = a.base_font_size;
    const second_base = b.base_font_size;
    const before_dark_a = vt.lt_vt_revision(a.active().?.vt);
    const before_dark_b = vt.lt_vt_revision(b.active().?.vt);
    h.setAppearance(true);
    try check(h.system_dark and h.cfg.background == 0x102030 and a.cfg.background == 0x102030 and b.cfg.background == 0x102030 and
        (a.cfg.ui_accent orelse 0) == 0x6688aa and (b.cfg.ui_accent orelse 0) == 0x6688aa and a.cfg.font_size == 23 and b.cfg.font_size == 29 and
        a.base_font_size == first_base and b.base_font_size == second_base, "appearance uses cached dark colors in every window after source theme files change and preserves local zoom");
    try check(vt.lt_vt_revision(a.active().?.vt) > before_dark_a and vt.lt_vt_revision(b.active().?.vt) > before_dark_b and
        terminalColors(a.active().?, 0x102030, 0xddeeff) and terminalColors(b.active().?, 0x102030, 0xddeeff), "cached dark appearance reaches both real VT palettes and cursor colors");
    first.frame();
    second.frame();
    try check(a.cfg.font_features.get("ss01".*) == 9 and b.cfg.font_features.get("ss01".*) == 9 and
        a.cfg.font_features.get("calt".*) == 1 and b.cfg.font_features.get("calt".*) == 1 and !a.cfg.font_ligatures and !b.cfg.font_ligatures and
        (try a.cfg.effectiveFontFeatures()).get("calt".*) == 0 and (try b.cfg.effectiveFontFeatures()).get("liga".*) == 0, "cached dark features and final ligature policy survive deleted theme files in both renderers");
    const dark_a = vt.lt_vt_revision(a.active().?.vt);
    const dark_b = vt.lt_vt_revision(b.active().?.vt);
    h.setAppearance(true);
    try check(vt.lt_vt_revision(a.active().?.vt) == dark_a and vt.lt_vt_revision(b.active().?.vt) == dark_b, "duplicate dark appearance event performs no terminal reconfiguration");
    h.setAppearance(false);
    try check(!h.system_dark and a.cfg.background == 0xf0eee0 and b.cfg.background == 0xf0eee0 and
        a.cfg.font_size == 23 and b.cfg.font_size == 29 and terminalColors(a.active().?, 0xf0eee0, 0xaabbcc) and terminalColors(b.active().?, 0xf0eee0, 0xaabbcc), "cached light theme remains available after deletion and preserves both local font sizes");
    first.frame();
    second.frame();
    try check(a.cfg.font_features.get("ss01".*) == 9 and b.cfg.font_features.get("ss01".*) == 9 and
        a.cfg.font_features.get("calt".*) == 0 and b.cfg.font_features.get("calt".*) == 0 and a.cfg.font_ligatures and b.cfg.font_ligatures, "cached light features restore without reopening files or resetting either PTY");
    const light_a = vt.lt_vt_revision(a.active().?.vt);
    const light_b = vt.lt_vt_revision(b.active().?.vt);
    h.setAppearance(false);
    try check(vt.lt_vt_revision(a.active().?.vt) == light_a and vt.lt_vt_revision(b.active().?.vt) == light_b and
        a.active().?.pid == first_pid and b.active().?.pid == second_pid and a.active().?.id == first_id and b.active().?.id == second_id, "duplicate light event has no VT effects and all appearance changes retain PTY identities");
}
