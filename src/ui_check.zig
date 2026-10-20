//! End-to-end UI checks use nanoui's in-process Tester, never the real desktop.
const std = @import("std");
const mac = @import("builtin").os.tag == .macos;
const nano = @import("nanoui");
const vt_api = @import("vt.zig");
const c = @import("platform_ffi.zig");
const ui = nano.ui;
fn check(ok: bool, name: []const u8) !void {
    if (!ok) {
        std.debug.print("FAIL UI {s}\n", .{name});
        return error.UiCheck;
    }
    std.debug.print("PASS UI {s}\n", .{name});
}
pub fn run(s: anytype, view: ui.View, theme: ui.Theme) !void {
    s.window_focused = true;
    s.cfg.confirm_close = .never;
    s.cfg.copy_on_select = .none;
    var t: ui.Tester = undefined;
    try t.init(s.gpa, view, .{ .width = 1000, .height = 680, .theme = theme });
    defer t.deinit();
    t.frame();
    var single_new = false;
    for (s.ax.routes[0..s.ax.route_count]) |route| if (route.intent == .new_tab) {
        if (t.ctx.rects.get(route.widget)) |r| single_new = r.x >= 0 and r.x + r.w <= t.size.w;
    };
    try check(s.layout.tab_count == 1 and single_new and s.navigation_rects.navigation.h == @import("navigation/geometry.zig").top_height, "single-tab auto navigation retains a visible New Tab control");
    try t.screenshot(".cache/test-logs/navigation-top-one-paper.png");
    // A burst of native menu actions must all survive until the next frame.
    s.menu_actions[0] = .{ .action = .tab };
    s.menu_actions[1] = .{ .action = .horizontal };
    s.menu_actions[2] = .{ .action = .vertical };
    s.menu_action_count = 3;
    t.frame();
    var count: usize = 0;
    for (s.sessions) |session| if (session != null) {
        count += 1;
    };
    try check(s.layout.tab_count == 2 and count == 4, "rapid menu actions preserve 2 tabs / 4 PTYs");
    const root = s.layout.roots[s.layout.active_tab];
    t.drag(s.navigation_rects.content.x + s.navigation_rects.content.w / 2, 300, 650, 300);
    try check(s.layout.nodes[root].ratio > 0.6 and s.layout.nodes[root].ratio < 0.7, "divider drags across the 7pt target");
    _ = t.shortcut(.{ .key = 'f', .cmd = mac, .ctrl = !mac, .shift = !mac });
    t.typeText("Ready");
    try check(s.search_open and std.mem.eql(u8, s.query.text(), "Ready"), "find opens with keyboard focus");
    for (0..60) |_| {
        nano.runFor(0.05);
        t.frame();
        if (s.total > 0) break;
    }
    try check(s.total > 0, "floating search reaches live PTY output");
    t.key(.escape);
    try check(!s.search_open, "Escape closes search and restores terminal input");
    const p = s.sessions[s.layout.active_pane].?;
    t.typeText("printf 'UI_%s_OK\\n' INPUT");
    t.key(.enter);
    for (0..4) |_| {
        nano.runFor(0.05);
        t.frame();
    }
    _ = vt_api.lt_vt_search(p.vt, "UI_INPUT_OK", 11);
    var total: usize = 0;
    while (vt_api.lt_vt_search_tick(p.vt, &total) > 0) {}
    try check(total > 0, "typing after search reaches the shell");
    const closing_tab = s.layout.tabs[s.layout.active_tab].id;
    const close_rect = find_close: for (s.ax.routes[0..s.ax.route_count]) |route| {
        if (route.intent == .tab_close) for (s.ax.adapter.?.routes[0..s.ax.adapter.?.route_count]) |target| {
            if (target.node == route.id and target.target.tab == closing_tab) break :find_close t.ctx.rects.get(route.widget) orelse return error.MissingTabClose;
        };
    } else return error.MissingTabClose;
    t.click(close_rect.x + close_rect.w / 2, close_rect.y + close_rect.h / 2);
    try check(s.layout.tab_count == 1 and s.layout.nodes[s.layout.roots[0]].kind == .pane, "close tab removes its splits and preserves the other tab");
    t.resize(480, 300);
    try check(s.sessions[s.layout.active_pane].?.cols > 20, "small window resizes the PTY grid");
    try palette(s, &t);
    try @import("palette_native_ui_check.zig").run(s, view);
    try customization(s, &t);
    try @import("layout_ui_check.zig").run(s, &t);
    try @import("navigation_ui_check.zig").run(s, &t);
    try @import("lifecycle_ui_check.zig").run(s, &t, view);
    try @import("clipboard_ui_check.zig").run(s, &t);
    try @import("semantics_ui_check.zig").run(s, &t, view);
    try @import("title_ui_check.zig").run(s, &t);
    try @import("tui_ui_check.zig").run(s, &t);
    try @import("multiwindow_ui_check.zig").run(s, &t);
    try @import("binding_ui_check.zig").run(s, &t);
    try @import("broadcast_ui_check.zig").run(s, &t);
    try @import("config_combination_ui_check.zig").run(s, &t);
    try @import("terminal_render_ui_check.zig").run(s);
    try @import("font_render_ui_check.zig").run(s);
    try @import("cpu_damage_ui_check.zig").run(s);
    try @import("window_frame_ui_check.zig").run(s);
    try @import("feature_checks.zig").run(s, .M9);
    try @import("feature_checks.zig").run(s, .M10);
    try @import("feature_checks.zig").run(s, .M11);
    try @import("feature_checks.zig").run(s, .SIDEBAR);
    try @import("feature_checks.zig").run(s, .SETTINGS);
    try @import("feature_checks.zig").run(s, .PREVIEW);
    std.debug.print("All UI checks passed.\n", .{});
}

extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn unlink([*:0]const u8) c_int;
extern "c" fn rmdir([*:0]const u8) c_int;
extern "c" fn lt_mkdirs([*:0]const u8) c_int;
fn customization(s: anytype, t: *ui.Tester) !void {
    try check(lt_mkdirs(".cache/test-logs") == 0, "prepare isolated config tests");
    const template = try s.gpa.dupeSentinel(u8, ".cache/test-logs/config-XXXXXX", 0);
    defer s.gpa.free(template);
    const dir = mkdtemp(template) orelse return error.TempDirectory;
    defer _ = rmdir(dir);
    const file = try std.fmt.allocPrintSentinel(s.gpa, "{s}/config", .{std.mem.span(dir)}, 0);
    defer s.gpa.free(file);
    defer _ = unlink(file);
    const theme_file = try std.fmt.allocPrintSentinel(s.gpa, "{s}/Night", .{std.mem.span(dir)}, 0);
    defer s.gpa.free(theme_file);
    defer _ = unlink(theme_file);
    const theme_data = "background = #101820\nforeground = #eaeaea\npalette = 1=#ff5555\n";
    try check(c.lt_write_atomic(theme_file, theme_data, theme_data.len) == 0, "write independent external theme");
    const text = "copy-on-select = none\nbackground = #222831\ntheme = ./Night\nfont-size = 18\nwindow-padding-x = 12,18\nwindow-padding-y = 10,15\ncursor-style = bar\ntab-bar = always\nkeybind = ctrl+shift+k=new_tab\nkeybind = super+q=ignore\nkeybind = ctrl+shift+j=toggle_command_palette\nkeybind = ctrl+shift+l=increase_font_size:2\n";
    try check(c.lt_write_atomic(file, text, text.len) == 0, "write common customization");
    const old_path = s.explicit_config;
    s.explicit_config = file;
    defer s.explicit_config = old_path;
    const session = s.sessions[s.layout.active_pane].?;
    const id = session.id;
    const pid = session.pid;
    s.menu_actions[0] = .{ .action = .reload };
    s.menu_action_count = 1;
    t.frame();
    try check(s.cfg.font_size == 18 and s.cfg.background == 0x222831 and s.cfg.foreground == 0xeaeaea and s.cfg.palette[1] == 0xff5555 and t.ctx.theme.dark, "theme file, explicit override and dark chrome reload together");
    try t.screenshot(".cache/test-logs/customization-dark.png");
    try check(s.cfg.padding_x[0] == 12 and s.cfg.padding_x[1] == 18 and s.cfg.padding_y[1] == 15, "asymmetric padding reaches terminal geometry");
    try check(session.id == id and session.pid == pid and s.sessions[s.layout.active_pane] == session, "reload preserves running PTY identity");
    var cursor: vt_api.Cursor = .{};
    try check(vt_api.lt_vt_frame(session.vt, &cursor) == 0, "read reconfigured VT cursor");
    vt_api.lt_vt_frame_end(session.vt);
    try check(cursor.style == 0, "configured cursor style reaches libghostty-vt");
    const keys = @import("keybindings.zig");
    try check(keys.accelerator(s.cfg.keybinds, s.cfg.clear_default_keybinds, .quit).len == 0, "disabled shortcut is also removed from native menu");
    _ = t.shortcut(.{ .key = 'k', .ctrl = true, .shift = true });
    try check(s.layout.tab_count == 2, "custom keybind creates a real terminal session");
    _ = t.shortcut(.{ .key = 'j', .ctrl = true, .shift = true });
    try check(s.palette.open, "configured toggle_command_palette binding opens nanoui overlay");
    t.typeText("reload");
    try t.screenshot(".cache/test-logs/command-palette-dark.png");
    t.key(.enter);
    t.frame();
    try check(!s.palette.open and s.cfg.font_size == 18 and session.pid == pid, "palette reload action preserves running PTY");
    _ = t.shortcut(.{ .key = 'l', .ctrl = true, .shift = true });
    try check(s.cfg.font_size == 20, "configured shortcut retains amount through common dispatcher");
    s.cfg.font_size = 18;
    const invalid = "font-size = -1\n";
    try check(c.lt_write_atomic(file, invalid, invalid.len) == 0, "write invalid test config");
    s.menu_actions[0] = .{ .action = .reload };
    s.menu_action_count = 1;
    t.frame();
    try check(s.cfg.font_size == 18 and session.pid == pid and s.layout.tab_count == 2, "invalid reload retains working settings and sessions");
    try check(s.confirmation.open and s.config_diagnostic.line == 1, "invalid config shows a modal diagnostic with exact line");
    t.key(.escape);
    const reset = "copy-on-select = none\ntheme = paper\nfont-size = 19\n";
    try check(c.lt_write_atomic(file, reset, reset.len) == 0, "replace test config");
    s.menu_actions[0] = .{ .action = .reload };
    s.menu_action_count = 1;
    t.frame();
    try check(s.cfg.font_size == 19 and s.cfg.background == 0xfcfbf9 and !t.ctx.theme.dark and session.pid == pid, "second reload safely replaces prior config and font caches");
}

fn palette(s: anytype, t: *ui.Tester) !void {
    try check(lt_mkdirs(".cache/test-logs") == 0, "prepare palette snapshots");
    const key: ui.Shortcut = .{ .key = 'p', .cmd = mac, .ctrl = !mac, .shift = true };
    const session = s.sessions[s.layout.active_pane].?;
    const pid = session.pid;
    _ = t.shortcut(key);
    try check(s.palette.open and t.findText("Type a command…") != null, "command palette shortcut opens searchable overlay");
    t.textOps(&.{.{ .set_marked = .{ .text = "New", .sel_start = 3, .sel_len = 0 } }});
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    t.key(.enter);
    try check(s.palette.open and s.palette.selected == 0, "IME composition retains arrows and Enter before palette navigation");
    t.textOps(&.{.unmark});
    t.key(.escape);
    _ = t.shortcut(key);
    t.typeText("NEW TAB");
    try check(std.mem.eql(u8, s.palette.query.text(), "NEW TAB") and t.findText("New Tab") != null and t.findText("Reload Configuration") == null, "palette autofocus filters commands case-insensitively");
    t.key(.enter);
    t.frame();
    try check(!s.palette.open and s.layout.tab_count == 2 and session.pid == pid, "palette Enter creates a real PTY without restarting existing sessions");
    s.menu_actions[0] = .{ .action = .close_tab };
    s.menu_action_count = 1;
    t.frame();
    _ = t.shortcut(key);
    t.typeText("increase_font_size");
    const font_before = s.cfg.font_size;
    const row = t.findText("Font Size: Increase") orelse return error.PaletteRow;
    t.click(row.x + 10, row.y + row.h / 2);
    t.frame();
    try check(!s.palette.open and s.cfg.font_size == font_before + 1, "clicking a palette row executes its command");
    s.cfg.font_size = font_before;
    s.menu_actions[0] = .{ .action = .font_up, .args = .{ .amount = 2 } };
    s.menu_action_count = 1;
    t.frame();
    _ = t.shortcut(key);
    t.typeText("increase by 2");
    t.key(.enter);
    t.frame();
    try check(s.cfg.font_size == font_before + 4, "menu queue and palette preserve typed action amount");
    s.cfg.font_size = font_before;
    _ = t.shortcut(key);
    t.typeText("copy_to_clipboard");
    t.key(.enter);
    try check(s.palette.open and t.findText("Select terminal text first") != null, "unavailable palette action remains disabled with a reason");
    t.key(.escape);
    _ = t.shortcut(key);
    t.scroll(240, 100, 1);
    try check(s.palette.selected == 1, "mouse wheel moves palette selection");
    t.typeText("PALETTE_INPUT_MUST_NOT_LEAK");
    try check(t.findText("No matching commands") != null, "palette displays empty results");
    t.key(.enter);
    try check(s.palette.open and s.layout.tab_count == 1, "Enter with no results does nothing");
    t.textOps(&.{.{ .command = .cancel }});
    try check(!s.palette.open, "native text input cancel dismisses palette");
    for (0..4) |_| {
        nano.runFor(0.05);
        t.frame();
    }
    _ = vt_api.lt_vt_search(session.vt, "PALETTE_INPUT_MUST_NOT_LEAK", "PALETTE_INPUT_MUST_NOT_LEAK".len);
    var total: usize = 0;
    while (vt_api.lt_vt_search_tick(session.vt, &total) > 0) {}
    try check(total == 0, "palette query and Enter never reach the shell");
    vt_api.lt_vt_search_close(session.vt);
    t.resize(1000, 680);
    _ = t.shortcut(key);
    try check(s.palette.query.len == 0, "reopening palette clears prior query");
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    try check(s.palette.selected == 1, "native Down selects next command");
    t.key(.up);
    t.key(.up);
    try check(s.palette.selected > 8 and s.palette.first > 0, "palette keyboard selection wraps and scrolls to the selected row");
    t.key(.escape);
    _ = t.shortcut(key);
    t.typeText("split");
    try t.screenshot(".cache/test-logs/command-palette-paper.png");
    t.key(.escape);
    t.resize(480, 240);
    _ = t.shortcut(key);
    try check(t.findText("↑↓ select    ↵ run").?.y < 240, "palette fits minimum window height");
    // The tab's close button is behind this outside click; it must survive.
    const old_tab_bar = s.cfg.tab_bar;
    s.cfg.tab_bar = .always;
    t.frame();
    t.click(14, 14);
    try check(!s.palette.open and s.layout.tab_count == 1 and session.pid == pid, "outside click dismisses without activating underlying tab close");
    s.cfg.tab_bar = old_tab_bar;
    s.query.clear();
    _ = t.shortcut(key);
    t.typeText("Find");
    t.key(.enter);
    t.frame();
    t.typeText("Ready");
    try check(!s.palette.open and s.search_open and std.mem.eql(u8, s.query.text(), "Ready"), "palette Find hands keyboard focus to terminal search");
    t.key(.escape);
    t.resize(480, 300);
}
