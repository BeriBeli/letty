//! Run from the application's hidden UI-check process. Real owned Settings
//! window + two owned PTYs; never user's windows, config, or system clipboard.
const std = @import("std");
const builtin = @import("builtin");
const nano = @import("nanoui");
const ui = nano.ui;
const config = @import("../config.zig");
const edit = @import("../config_edit.zig");
const vt = @import("../vt.zig");
const application = @import("../application_settings.zig");
const keys = @import("../keybindings.zig");
extern "c" fn lt_millis() u64;
extern "c" fn usleep(c_uint) c_int;
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn lt_config_fixture_write([*:0]const u8, [*]const u8, usize, c_uint) c_int;
var checks: usize = 0;
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI Settings {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.SettingsApplicationCheck;
    checks += 1;
}
fn settle(settings: anytype) void {
    for (0..20) |_| {
        if (!settings.scheduled) break;
        nano.runFor(0.005);
    }
}
fn press(t: *ui.Tester, settings: anytype, label: []const u8) !void {
    try t.clickText(label);
    settle(settings);
    if (settings.window != null) t.frame();
}
pub fn run(s: anytype) !void {
    checks = 0;
    try check(s.app.flags.hidden, "requires hidden application");
    var storage: std.heap.ArenaAllocator = .init(s.gpa);
    defer storage.deinit();
    const a = storage.allocator();
    const template = try a.dupeSentinel(u8, "/tmp/letty-settings-app-XXXXXX", 0);
    const directory = mkdtemp(template) orelse return error.FixtureDirectory;
    defer _ = std.c.rmdir(directory);
    const root = try std.fmt.allocPrintSentinel(a, "{s}/config", .{std.mem.span(directory)}, 0);
    defer _ = std.c.unlink(root);
    const source = "# Settings application fixture\nshell=/bin/sh\nshell-integration=none\ncopy-on-select=none\nconfirm-close-surface=false\nfont-size=14\nworkspace-navigation=top\ntab-bar=never\n";
    if (lt_config_fixture_write(root, source, source.len, 0o640) != 0) return error.FixtureWrite;
    var baseline: std.heap.ArenaAllocator = .init(s.gpa);
    const cfg = config.loadDetailed(baseline.allocator(), root, null) catch |err| {
        baseline.deinit();
        return err;
    };
    // Match current main: CLI overrides remain separate from parsed profiles,
    // so saving only navigation preserves the actual terminal interaction state.
    const Host = @TypeOf(s.host.*);
    const Window = @TypeOf(s.*);
    var h: Host = .{ .gpa = s.gpa, .arena = s.arena, .app = s.app, .cfg = cfg, .config_arena = baseline, .state_path = "", .read_path = "", .explicit_config = root, .command_override = "exec /bin/sh", .override_profile = "Local", .demo = true, .hold = true };
    defer {
        h.deinit();
        nano.runFor(0.02);
    }
    defer if (builtin.os.tag == .macos) s.macMenu() catch {};
    const first = try h.create(false);
    const second = try h.create(false);
    first.retain();
    defer first.release();
    second.retain();
    defer second.release();
    h.active_id = first.id;
    first.window_focused = true;
    var terminal: ui.Tester = undefined;
    try terminal.init(s.gpa, .init(first, Window.view), .{ .width = 900, .height = 640, .theme = @import("../appearance.zig").theme(first.cfg) });
    defer terminal.deinit();
    const first_session = first.active().?;
    const second_session = second.active().?;
    const pid_a = first_session.pid;
    const pid_b = second_session.pid;
    const id_a = first_session.id;
    const id_b = second_session.id;
    const terminal_count = h.count();
    const pane_count = h.paneCount();
    h.queue(.{ .action = .open_settings });
    const native = h.settings.window orelse return error.SettingsDidNotOpen;
    try check(h.count() == terminal_count and h.paneCount() == pane_count, "menu action opens separate window with no PTY or terminal slot");
    h.queue(.{ .action = .open_settings });
    try check(h.settings.window == native, "repeat open retains one Settings window");
    const surface = native.surface orelse {
        std.debug.print("SKIP UI Settings native save flow: headless backend has no native surface; run hidden GTK acceptance with DISPLAY.\n", .{});
        return;
    };
    // A hidden GTK surface has not received size-allocate/draw events yet.
    // Render the real Settings view with its native frame theme first.
    var t: ui.Tester = undefined;
    try t.init(s.gpa, surface.view, .{ .width = 900, .height = 720, .theme = surface.theme_override.? });
    defer t.deinit();
    h.settings.form.category = .terminal;
    t.frame();
    t.frame();
    const rendered_mono = t.ctx.theme.mono_font;
    const frame_mono = surface.theme_override.?.mono_font;
    const stable_font = if (rendered_mono) |rendered| (if (frame_mono) |frame| std.mem.eql(u8, rendered, frame) else false) else frame_mono == null;
    try check(stable_font and surface.theme_override.?.font == null, "system UI font and verified preview family remain stable across redraws");
    try t.screenshot("/tmp/letty-settings-application-light.png");
    const Field = @import("schema.zig").Field;
    const font_face = t.ctx.rects.get(h.settings.form.controls[@backingInt(Field.font)]).?;
    t.click(font_face.x + 20, font_face.y + font_face.h / 2);
    try check(h.settings.form.choice_open == .font, "font face opens a floating Letty picker without expanding its settings row");
    t.typeText("Maple");
    try check(std.mem.eql(u8, h.settings.form.popup_query.text(), "Maple") and h.settings.model.?.dirtyCount() == 0, "floating font picker owns search input without editing the configuration");
    try t.screenshot("/tmp/letty-settings-font-picker.png");
    t.key(.escape);
    try check(h.settings.form.choice_open == null and !h.settings.form.confirm_discard, "Escape closes the picker before requesting Settings close");
    h.settings.form.query.set("shell-integration");
    t.frame();
    const cursor_face = t.ctx.rects.get(h.settings.form.controls[@backingInt(Field.integration)]).?;
    t.click(cursor_face.x + 20, cursor_face.y + cursor_face.h / 2);
    try check(h.settings.form.choice_open == .integration and t.hasText("none"), "choice face opens its actual floating options");
    t.key(.down);
    t.key(.enter);
    try check(h.settings.form.choice_open == null and std.mem.eql(u8, h.settings.model.?.value(.integration).input.text(), "none"), "popup Down and Enter commit the selected shell-integration choice once");
    h.settings.model.?.value(.integration).input.set(h.settings.model.?.value(.integration).original);
    h.settings.form.query.clear();
    h.settings.form.popup_query.clear();
    t.ctx.focus = 0;
    t.frame();
    h.settings.form.category = .appearance;
    t.frame();
    try t.screenshot("/tmp/letty-settings-appearance.png");
    h.settings.form.category = .terminal;
    t.frame();
    const ax = @import("../accessibility.zig");
    var font_node: u64 = 0;
    var category_node: u64 = 0;
    for (h.settings.ax.adapter.?.snapshot.nodes[0..h.settings.ax.adapter.?.snapshot.count]) |node| {
        const snapshot = &h.settings.ax.adapter.?.snapshot;
        if (std.mem.eql(u8, snapshot.label(node), "Font size")) font_node = node.id;
        if (std.mem.eql(u8, snapshot.label(node), "Terminal")) category_node = node.id;
    }
    try check(font_node != 0 and category_node != 0 and h.settings.ax.adapter.?.snapshot.find(font_node).?.role == .button, "Settings publishes labeled configuration controls and category actions");
    if (!h.settings.ax.adapter.?.enqueue(category_node, .press)) return error.SettingsAxQueue;
    h.settings.form.confirm_discard = true;
    t.frame();
    try check(h.settings.form.category == .terminal and h.settings.ax.adapter.?.snapshot.count == 4 and h.settings.ax.adapter.?.snapshot.nodes[0].state & ax.State.modal != 0, "stale category action cannot escape draft confirmation and modal tree contains only its controls");
    try press(&t, &h.settings, "Keep editing");
    var preview_before = try edit.Native.capture(s.gpa, root);
    defer preview_before.deinit();
    h.settings.model.?.value(.font_size).input.set("16");
    t.frame();
    nano.runFor(0.18);
    t.frame();
    var preview_after = try edit.Native.capture(s.gpa, root);
    defer preview_after.deinit();
    try check(h.settings.preview != null and h.settings.preview.?.cfg.font_size == 16 and first.cfg.font_size == 14 and preview_before.matches(preview_after), "automatic preview updates after editing without writing disk or applying terminal settings");
    h.settings.model.?.value(.font_size).input.set("-");
    t.frame();
    nano.runFor(0.18);
    t.frame();
    try check(h.settings.preview.?.cfg.font_size == 16 and h.settings.model.?.notice.len == 0 and h.settings.model.?.last_error_field == null, "incomplete numeric edit keeps last valid preview without a validation notice");
    h.settings.model.?.value(.font_size).input.set("14");
    t.frame();
    nano.runFor(0.18);
    t.frame();
    try check(h.settings.preview.?.cfg.font_size == 14 and h.settings.model.?.dirtyCount() == 0, "reverting a draft restores the automatic preview");

    first.confirmation.open = true;
    first.status = "Finish or cancel the current prompt first";
    first.status_feedback.update(first, &terminal.ctx);
    try check(first.status.len > 0, "modal prerequisite notice remains while its prompt is open");
    first.confirmation.open = false;
    first.status_feedback.update(first, &terminal.ctx);
    try check(first.status.len == 0, "modal prerequisite notice clears when the prompt closes");
    first.status = "Settings saved and applied";
    first.status_feedback.update(first, &terminal.ctx);
    second.status = "Settings saved and applied";
    second.status_feedback.update(second, &terminal.ctx);
    second.status = "Persistent fixture error";
    second.status_feedback.update(second, &terminal.ctx);
    const deadline = lt_millis() + 4100;
    while (lt_millis() < deadline) {
        nano.runFor(0.01);
        _ = usleep(1000);
    }
    try check(first.status.len == 0 and std.mem.eql(u8, second.status, "Persistent fixture error"), "success timer expires but a replacement persistent error survives the old deadline");
    second.status = "";

    nano.runFor(0.025);
    try vt.feed(first_session.vt, "\x1b[2J\x1b[HCLI KEEP\r\n");
    first.search_open = true;
    first.query.set("CLI KEEP");
    vt.lt_vt_select(first_session.vt, 0, 0, 0);
    vt.lt_vt_select(first_session.vt, 3, 0, 1);
    h.settings.model.?.value(.navigation).input.set("sidebar");
    h.settings.model.?.value(.sidebar_git).input.set("true");
    h.settings.model.?.value(.sidebar_ports).input.set("true");
    t.frame();
    try press(&t, &h.settings, "Save and apply");
    try check(first.cfg.workspace_navigation == .sidebar and first.search_open and std.mem.eql(u8, first.query.text(), "CLI KEEP") and vt.lt_vt_has_selection(first_session.vt), "first navigation save with CLI profile override preserves search and selection");
    h.settings.model.?.value(.navigation).input.set("top");
    t.frame();
    try press(&t, &h.settings, "Save and apply");
    try check(first.cfg.workspace_navigation == .top and first.search_open and first_session.pid == pid_a and second_session.pid == pid_b, "CLI override survives navigation roundtrip without restarting either PTY");
    try check(first.cfg.sidebar_show_git and second.cfg.sidebar_show_git and first.cfg.sidebar_show_ports and second.cfg.sidebar_show_ports, "real provider controls persist and publish to both application windows");
    first.search_open = false;
    var original = try edit.Native.capture(s.gpa, root);
    defer original.deinit();
    h.settings.model.?.value(.font_size).input.set("999");
    t.frame();
    try press(&t, &h.settings, "Save and apply");
    var rejected = try edit.Native.capture(s.gpa, root);
    defer rejected.deinit();
    try check(original.matches(rejected) and first.cfg.font_size == 14 and second.cfg.font_size == 14 and h.settings.unsaved(), "UI save validation failure keeps both runtimes file and draft");
    h.settings.model.?.value(.font_size).input.set("18");
    t.frame();
    try press(&t, &h.settings, "Save and apply");
    try check(first.cfg.font_size == 18 and second.cfg.font_size == 18 and h.settings.model.?.dirtyCount() == 0, "actual Save button publishes to both application windows");
    try check(first_session.pid == pid_a and second_session.pid == pid_b and first_session.id == id_a and second_session.id == id_b, "font save preserves original PTY PIDs and stable session IDs");
    try vt.feed(first_session.vt, "\x1b[2J\x1b[HKEEP first\r\nKEEP second\r\n");
    try vt.feed(second_session.vt, "\x1b[2J\x1b[HKEEP other\r\n");
    first.search_open = true;
    second.search_open = true;
    first.query.set("KEEP");
    second.query.set("KEEP");
    vt.lt_vt_select(first_session.vt, 0, 0, 0);
    vt.lt_vt_select(first_session.vt, 3, 0, 1);
    const active_pane = first.layout.active_pane;
    const active_tab = first.layout.tabs[first.layout.active_tab].id;
    h.settings.model.?.value(.navigation).input.set("sidebar");
    t.frame();
    try press(&t, &h.settings, "Save and apply");
    try check(first.cfg.workspace_navigation == .sidebar and second.cfg.workspace_navigation == .sidebar and first.cfg.tab_bar == .never, "Settings persists sidebar in all windows independent of tab-bar=never");
    try check(first.search_open and second.search_open and std.mem.eql(u8, first.query.text(), "KEEP") and std.mem.eql(u8, second.query.text(), "KEEP") and vt.lt_vt_has_selection(first_session.vt) and first.layout.active_pane == active_pane and first.layout.tabs[first.layout.active_tab].id == active_tab, "navigation save keeps search selection and active identities");
    try check(first_session.pid == pid_a and second_session.pid == pid_b, "navigation save keeps original PIDs");
    t.theme = ui.Theme.dark_theme;
    t.size = .{ .w = 480, .h = 360 };
    t.frame();
    try t.screenshot("/tmp/letty-settings-application-sidebar-dark.png");
    h.settings.model.?.value(.font_size).input.set("22");
    try check(!h.settings.guardQuit() and !h.quitting and h.paneCount() == pane_count, "unsaved Settings guard rejects Quit before any terminal is destroyed");
    t.frame();
    try press(&t, &h.settings, "Keep editing");
    try press(&t, &h.settings, "Cancel");
    t.frame();
    try press(&t, &h.settings, "Discard and close");
    try check(h.settings.window == null and h.count() == terminal_count and first.cfg.font_size == 18, "discard closes only Settings and retains working config and terminals");
    first.search_open = false;
    second.search_open = false;
    first.window_focused = true;
    _ = terminal.shortcut(.{ .key = ',', .cmd = builtin.os.tag == .macos, .ctrl = builtin.os.tag != .macos });
    terminal.frame();
    try check(h.settings.window != null and h.settings.model.?.baseline.font_size == 18 and h.settings.model.?.baseline.workspace_navigation == .sidebar, "default platform shortcut reopens saved configuration");
    h.settings.deinit();
    // The owner remains a stable embedded value; open reinitializes it.
    const ignored = try keys.parse(if (builtin.os.tag == .macos) "super+comma=ignore" else "ctrl+comma=ignore");
    first.cfg.keybinds = &.{ignored};
    _ = terminal.shortcut(.{ .key = ',', .cmd = builtin.os.tag == .macos, .ctrl = builtin.os.tag != .macos });
    terminal.frame();
    try check(h.settings.window == null, "user ignore binding suppresses the default Settings shortcut");
    const custom = try keys.parse("ctrl+alt+s=open_settings");
    first.cfg.keybinds = &.{custom};
    _ = terminal.shortcut(.{ .key = 's', .ctrl = true, .alt = true });
    terminal.frame();
    try check(h.settings.window != null and h.paneCount() == pane_count and first_session.pid == pid_a and second_session.pid == pid_b, "custom binding opens Settings without sending bytes or starting PTYs");
    first.cfg.keybinds = h.cfg.keybinds;
    std.debug.print("Settings application acceptance: {d} checks passed\n", .{checks});
}
