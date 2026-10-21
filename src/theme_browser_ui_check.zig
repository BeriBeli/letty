//! Pending M10 acceptance, not a record of passing tests. Uses real temporary
//! files, native metadata IO, real Session PTYs and offscreen Tester layout.
//! Root must install M10 wiring and link tools/fixtures/config_edit_native.c.
//! No user configuration, environment mutation, clipboard or OS input.
const std = @import("std");
const builtin = @import("builtin");
const nano = @import("nanoui");
const ui = nano.ui;
const config = @import("config.zig");
const edit = @import("config_edit.zig");
const host = @import("application_theme_browser.zig");
const appearance = @import("appearance.zig");
const vt = @import("vt.zig");
const c = @import("platform_ffi.zig");
const semantic = @import("ui_semantics.zig");
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn lt_mkdirs([*:0]const u8) c_int;
extern "c" fn lt_config_fixture_write([*:0]const u8, [*]const u8, usize, c_uint) c_int;
extern "c" fn lt_config_fixture_xattr([*:0]const u8, [*:0]const u8) c_int;
extern "c" fn lt_config_fixture_acl([*:0]const u8) c_int;
extern "c" fn lt_config_fixture_acl_count([*:0]const u8) c_int;
const source = "# M10 root: preserve CRLF/comments\r\nshell=/bin/sh\r\nshell-integration=none\r\ncopy-on-select=none\r\nfont-size=15\r\nfont-feature=ss01=9\r\ntheme = light:themes/day,dark:themes/night\r\n# keep theme comment\r\n";
const day_text = "background=#eeeedd\nfont-feature=ss01=1,calt=0\nfont-ligatures=true\n";
const night_text = "background=#122334\nfont-feature=ss01=2,calt=1\nfont-ligatures=false\n";
const blue_text = "background=#203050\nforeground=#ddeeff\nfont-feature=ss01=3,calt=1\nfont-ligatures=false\n";
const red_text = "background=#502030\nforeground=#ffeedd\nfont-feature=ss01=4,calt=0\nfont-ligatures=true\n";
var checks: usize = 0;
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.ThemeBrowserUiCheck;
    checks += 1;
}
/// Exercise the same borrowed transaction + checked native root save boundary
/// as Settings, without opening a real editor or driving the user's desktop.
fn saveNavigation(w: anytype, t: *ui.Tester, root: []const u8, home: []const u8, sidebar: bool) !void {
    const document = @import("settings/document.zig");
    var before = try edit.Native.capture(w.gpa, root);
    defer before.deinit();
    const replacement = try document.append(w.gpa, before.bytes, &.{
        .{ .key = "workspace-navigation", .value = if (sidebar) "sidebar" else "top" },
        .{ .key = "tab-bar", .value = if (sidebar) "never" else "always" },
        .{ .key = "sidebar-show-git", .value = if (sidebar) "true" else "false" },
        .{ .key = "sidebar-show-ports", .value = if (sidebar) "true" else "false" },
    });
    defer w.gpa.free(replacement);
    var diagnostic: config.Diagnostic = .{};
    var candidate = try document.Candidate.load(w.gpa, before.path, replacement, home, &diagnostic);
    var owned = true;
    defer if (owned) candidate.deinit();
    var transaction = try @import("config_transaction.zig").Transaction(@TypeOf(w)).prepareBorrowed(w, candidate.cfg);
    defer transaction.deinit();
    if (!transaction.navigation_only) return error.ExpectedNavigationOnlyTransaction;
    _ = try edit.Native.save(w.gpa, before, candidate.replacement);
    transaction.adoptArena(candidate.arena);
    owned = false;
    transaction.commit(&t.ctx);
    t.frame();
}
fn navigationSaved(cfg: config.Config, sidebar: bool) bool {
    return cfg.workspace_navigation == (if (sidebar) config.WorkspaceNavigation.sidebar else config.WorkspaceNavigation.top) and
        cfg.tab_bar == (if (sidebar) config.TabBar.never else config.TabBar.always) and cfg.sidebar_show_git == sidebar and cfg.sidebar_show_ports == sidebar;
}
fn path(a: std.mem.Allocator, dir: []const u8, leaf: []const u8) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, leaf }, 0);
}
fn write(filename: [:0]const u8, bytes: []const u8) !void {
    if (lt_config_fixture_write(filename, bytes.ptr, bytes.len, 0o640) != 0) return error.FixtureWrite;
}
fn sameFile(a: std.mem.Allocator, filename: []const u8, expected: edit.Snapshot) !bool {
    var found = try edit.Native.capture(a, filename);
    defer found.deinit();
    return expected.matches(found);
}
fn open(w: anytype, t: *ui.Tester, dir: []const u8, bundled: []const u8) !void {
    host.open(w, &t.ctx, .{ .user_theme_directory = dir, .bundled_theme_directory = bundled, .home = dir });
    t.frame();
    t.frame();
    if (!w.theme_browser.open) return error.BrowserDidNotOpen;
}
fn search(w: anytype, t: *ui.Tester, name: []const u8) void {
    w.theme_browser.keyboard = .query;
    w.theme_browser.focus_query = true;
    t.frame();
    t.textOps(&.{ .{ .command = .select_all }, .{ .insert = name } });
    t.frame();
}
fn choose(w: anytype, t: *ui.Tester, name: []const u8) void {
    search(w, t, name);
    t.key(.enter);
    t.frame();
}
fn cancel(t: *ui.Tester) void {
    t.key(.escape);
    t.frame();
}
fn press(t: *ui.Tester, text: []const u8) !void {
    try t.clickText(text);
    t.frame();
}
fn reload(w: anytype, t: *ui.Tester) void {
    w.menu_actions[0] = .{ .action = .reload };
    w.menu_action_count = 1;
    t.frame();
}
fn rectFor(t: *ui.Tester, id: u64) !ui.Rect {
    for (t.ctx.nodes.items) |node| if (node.id == id) return node.rect;
    return error.FinalLayoutNodeMissing;
}
fn contains(outer: ui.Rect, inner: ui.Rect) bool {
    return inner.w > 0 and inner.h > 0 and inner.x >= outer.x - 0.5 and inner.y >= outer.y - 0.5 and
        inner.x + inner.w <= outer.x + outer.w + 0.5 and inner.y + inner.h <= outer.y + outer.h + 0.5;
}
fn visiblyLaidOut(t: *ui.Tester, id: u64) bool {
    const nodes = t.ctx.nodes.items;
    for (nodes) |node| if (node.id == id) {
        var clip: ui.Rect = .{ .w = t.size.w, .h = t.size.h };
        var parent = node.parent;
        while (parent != std.math.maxInt(u32)) {
            if (parent >= nodes.len) return false;
            if (nodes[parent].style.clip) clip = clip.intersect(nodes[parent].rect);
            parent = nodes[parent].parent;
        }
        return contains(clip, node.rect);
    };
    return false;
}
fn finalButtons(w: anytype, t: *ui.Tester) !void {
    t.frame();
    const g = w.theme_browser.geometry;
    const dialog = try rectFor(t, g.dialog_node);
    const screen: ui.Rect = .{ .w = t.size.w, .h = t.size.h };
    try check(t.size.h == 240 and contains(screen, dialog) and visiblyLaidOut(t, g.query_node) and
        visiblyLaidOut(t, g.cancel_node) and visiblyLaidOut(t, g.apply_node) and visiblyLaidOut(t, g.save_node), "240px theme dialog query and all three controls are fully inside final layout and clipping");
    std.debug.print("M10 LAYOUT h={d} dialog={any} cancel={any} apply={any} save={any}\n", .{ t.size.h, dialog, try rectFor(t, g.cancel_node), try rectFor(t, g.apply_node), try rectFor(t, g.save_node) });
}
fn tabs(t: *ui.Tester, count: usize) void {
    for (0..count) |_| t.key(.tab);
}
fn themeAxNode(w: anytype, control: semantic.Control, ordinal: u32) !u64 {
    for (w.ax.routes[0..w.ax.route_count]) |route| {
        if (route.modal.surface == .theme and route.modal.control == control and route.modal.ordinal == ordinal) return route.id;
    }
    return error.ThemeAxControlMissing;
}
fn themeAxPress(w: anytype, id: u64) !void {
    const adapter = if (w.ax.adapter) |*value| value else return error.ThemeAxAdapterMissing;
    if (adapter.native != null) return error.ThemeAxUnexpectedNativeAttach;
    if (!adapter.enqueue(id, .press)) return error.ThemeAxEnqueueRejected;
}
fn axSelectionChecks(w: anytype, t: *ui.Tester, a: std.mem.Allocator, root: []const u8, themes: []const u8, bundled: []const u8) !void {
    var before = try edit.Native.capture(a, root);
    defer before.deinit();
    const original_background = w.cfg.background;
    const original_applied = w.theme_applied.?.cfg.theme.ptr;
    const pid = w.active().?.pid;
    try open(w, t, themes, bundled);
    search(w, t, "z-extra");
    if (w.theme_browser.geometry.row_count < 2) return error.ThemeAxVisibleRowsMissing;
    const row = w.theme_browser.geometry.rows[1];
    if (w.theme_browser.filtered[w.theme_browser.selected] == row.catalog_index) return error.ThemeAxExpectedDifferentRow;
    const row_id = try themeAxNode(w, .command, @intCast(row.catalog_index));
    try themeAxPress(w, row_id);
    try check(w.ax.adapter.?.native == null and w.ax.adapter.?.request_count == 1 and w.theme_pending == .none and w.theme_browser.controller.candidate == null and w.cfg.background == original_background, "theme AX enqueue stores an owned stable row ID without synchronous selection preview or native attachment");
    t.frame();
    try check(w.theme_browser.filtered[w.theme_browser.selected] == row.catalog_index and w.theme_pending == .preview and w.theme_pending.preview == row.catalog_index and w.theme_browser.controller.candidate == null, "non-current visible AX row selects the matching filtered index and defers preview past the dispatch frame");
    t.frame();
    try check(w.theme_browser.preview_index == row.catalog_index and w.theme_browser.canApply() and w.theme_pending == .none and try sameFile(a, root, before), "deferred AX row preview enables matching Apply Save and leaves root bytes and metadata intact");

    // Queue while the published row is genuinely present, then change the
    // search before dispatch. The previous snapshot still owns the queued ID;
    // the host must reject its no-longer-current filter rather than load it.
    const obsolete = w.theme_browser.geometry.rows[0];
    const obsolete_id = try themeAxNode(w, .command, @intCast(obsolete.catalog_index));
    const candidate = w.theme_browser.controller.candidate.?.cfg.theme.ptr;
    const preview = w.theme_browser.preview_index;
    try themeAxPress(w, obsolete_id);
    w.theme_browser.query.set("Blue");
    w.theme_browser.focus_query = true;
    w.ax.last_error = null;
    t.frame();
    const stale_rejected = if (w.ax.last_error) |err| err == error.AccessibilityStaleSurface else false;
    try check(stale_rejected and w.ax.adapter.?.request_count == 0 and w.theme_pending == .none and w.theme_browser.preview_index == preview and w.theme_browser.controller.candidate.?.cfg.theme.ptr == candidate and !w.theme_browser.canApply(), "queued AX row is rejected when its filter changes before dispatch without replacing the valid preview");
    try check(!w.ax.adapter.?.enqueue(obsolete_id, .press) and try sameFile(a, root, before), "republished filtered theme tree refuses the retired row ID and leaves the root unchanged");
    cancel(t);

    try open(w, t, themes, bundled);
    search(w, t, "z-extra");
    const selected = w.theme_browser.geometry.rows[1];
    try themeAxPress(w, try themeAxNode(w, .command, @intCast(selected.catalog_index)));
    t.frame();
    t.frame();
    if (!w.theme_browser.canApply()) return error.ThemeAxExpectedPreview;
    const preserved = w.theme_browser.controller.candidate.?.cfg.theme.ptr;
    const different = w.theme_browser.geometry.rows[0];
    try themeAxPress(w, try themeAxNode(w, .cancel, 0));
    try themeAxPress(w, try themeAxNode(w, .command, @intCast(different.catalog_index)));
    try themeAxPress(w, try themeAxNode(w, .accept, 0));
    try themeAxPress(w, try themeAxNode(w, .accept, 1));
    try check(w.ax.adapter.?.request_count == 4 and w.theme_pending == .none and w.theme_browser.open, "Cancel row Apply Save enqueue into one real adapter batch without executing inside callbacks");
    t.frame();
    try check(w.theme_browser.open and w.theme_pending == .cancel and w.theme_browser.filtered[w.theme_browser.selected] == selected.catalog_index and w.theme_browser.controller.candidate.?.cfg.theme.ptr == preserved and try sameFile(a, root, before), "AX Cancel wins over later row Apply Save in the same batch before deferred execution");
    t.frame();
    try check(!w.theme_browser.open and w.theme_pending == .none and w.cfg.background == original_background and w.theme_applied.?.cfg.theme.ptr == original_applied and w.active().?.pid == pid and try sameFile(a, root, before), "deferred batch Cancel restores the original owner without applying saving or restarting the PTY");
}
pub fn run(s: anytype) !void {
    checks = 0;
    try check(s.app.flags.hidden, "theme browser fixture requires hidden application and owned offscreen views");
    var storage = std.heap.ArenaAllocator.init(s.gpa);
    defer storage.deinit();
    const a = storage.allocator();
    const template = try a.dupeSentinel(u8, ".cache/test-logs/theme-browser-XXXXXX", 0);
    const temp = mkdtemp(template) orelse return error.TempDirectory;
    defer _ = std.c.rmdir(temp);
    var absolute: [4096]u8 = undefined;
    if (c.lt_absolute_path(temp, &absolute, absolute.len) != 0) return error.TempDirectory;
    const dir = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&absolute)), 0);
    const themes = try path(a, dir, "themes");
    const bundle = try path(a, dir, "bundle");
    if (lt_mkdirs(themes) != 0 or lt_mkdirs(bundle) != 0) return error.FixtureDirectory;
    defer {
        _ = std.c.rmdir(themes);
        _ = std.c.rmdir(bundle);
    }
    const root = try path(a, dir, "config");
    const day = try path(a, themes, "day");
    const night = try path(a, themes, "night");
    const blue = try path(a, themes, "Blue");
    const red = try path(a, themes, "Red");
    const bad = try path(a, themes, "Bad");
    const missing = try path(a, themes, "Missing");
    const bundled = try path(a, bundle, "Bundled");
    const json_root = try path(a, dir, "config.json");
    const missing_root = try path(a, dir, "missing-config");
    defer {
        for ([_][:0]const u8{ root, day, night, blue, red, bad, missing, bundled, json_root, missing_root }) |filename| _ = std.c.unlink(filename);
    }
    var extras: [14][:0]const u8 = undefined;
    var extra_count: usize = 0;
    defer {
        for (extras[0..extra_count]) |filename| _ = std.c.unlink(filename);
    }
    for (&extras, 0..) |*filename, i| {
        filename.* = try path(a, themes, try std.fmt.allocPrint(a, "z-extra-{d:0>2}", .{i}));
        extra_count += 1;
        try write(filename.*, blue_text);
    }
    try write(root, source);
    try write(day, day_text);
    try write(night, night_text);
    try write(blue, blue_text);
    try write(red, red_text);
    try write(bad, "# invalid theme\nbackground=broken\n");
    try write(missing, blue_text);
    try write(bundled, red_text);
    if (lt_config_fixture_xattr(root, "M10-owned-xattr-中") != 0 or lt_config_fixture_acl(root) != 0) return error.FixtureMetadataUnsupported;
    try check(lt_config_fixture_acl_count(root) > 0, "theme fixture installs real nonempty ACL and native extended attribute");
    var original = try edit.Native.capture(a, root);
    defer original.deinit();
    var cfg_arena = std.heap.ArenaAllocator.init(s.gpa);
    var transferred = false;
    defer if (!transferred) cfg_arena.deinit();
    const cfg = try config.loadDetailed(cfg_arena.allocator(), root, null);
    // Host's delayed collection tickets must outlive its stack/temporary files;
    // Host.deinit nulls their host pointer. Config/candidate ownership remains
    // independent, but these tiny tickets use the parent process-lifetime arena.
    var h: @TypeOf(s.host.*) = .{ .gpa = s.gpa, .arena = s.arena, .app = s.app, .cfg = cfg, .config_arena = cfg_arena, .state_path = "", .read_path = "", .demo = true, .hold = true, .command_override = "exec /bin/sh", .override_profile = "Local", .explicit_config = root };
    transferred = true;
    defer h.deinit();
    defer if (builtin.os.tag == .macos) s.macMenu() catch {};
    const first = try h.create(false);
    first.retain();
    defer first.release();
    var t: ui.Tester = undefined;
    try t.init(s.gpa, .init(first, @TypeOf(s.*).view), .{ .width = 640, .height = 500, .theme = appearance.theme(first.cfg) });
    defer t.deinit();
    const second = try h.create(false);
    second.retain();
    defer second.release();
    var other: ui.Tester = undefined;
    try other.init(s.gpa, .init(second, @TypeOf(s.*).view), .{ .width = 640, .height = 500, .theme = appearance.theme(second.cfg) });
    defer other.deinit();
    const pid_a = first.active().?.pid;
    const pid_b = second.active().?.pid;
    const id_a = first.active().?.id;
    first.cfg.font_size = 23;
    second.cfg.font_size = 29;
    const base_size = first.base_font_size;
    const refs = first.refs;
    h.active_id = second.id; // Every tested operation must still target first.
    try open(first, &t, themes, bundle);
    const wheel_rect = first.theme_browser.geometry.dialog;
    t.scroll(wheel_rect.x + 30, wheel_rect.y + 70, -24);
    t.ctx.input.scroll_started = true;
    t.scroll(wheel_rect.x + 30, wheel_rect.y + 70, 0);
    t.scroll(wheel_rect.x + 30, wheel_rect.y + 70, -9);
    try check(first.theme_browser.selected == 0 and first.theme_browser.controller.candidate == null, "zero-delta gesture start clears the theme list fractional row without previewing");
    try check(first.refs == refs + 1 and first.theme_original != null and first.theme_browser.catalog.?.entries.len > 12 and first.theme_browser.geometry.row_count <= 12, "real catalog and modal lease are bounded while fixed source window is retained");
    t.textOps(&.{.{ .set_marked = .{ .text = "Blue", .sel_start = 4, .sel_len = 0 } }});
    t.key(.enter);
    t.frame();
    try check(first.theme_browser.open and first.theme_browser.controller.candidate == null and try sameFile(a, root, original), "marked-text Enter does not preview apply save or dismiss the theme dialog");
    t.textOps(&.{.unmark});
    choose(first, &t, "Blue");
    try check(first.cfg.background == 0x203050 and second.cfg.background == 0xeeeedd and first.cfg.font_size == 23 and first.active().?.pid == pid_a and second.active().?.pid == pid_b and try sameFile(a, root, original), "preview targets source window despite different active window and does not write root or restart PTYs");
    if (std.c.unlink(day) != 0 or std.c.unlink(night) != 0) return error.FixtureUnlink;
    h.setAppearance(true);
    t.frame();
    other.frame();
    cancel(&t);
    try check(first.cfg.background == 0x122334 and second.cfg.background == 0x122334 and first.cfg.font_size == 23 and first.base_font_size == base_size and first.refs == refs and first.theme_original == null, "cancel restores cached conditional dark baseline after original theme files are removed and releases lease");
    try check(first.cfg.font_features.get("ss01".*) == 9 and first.cfg.font_features.get("calt".*) == 1 and !first.cfg.font_ligatures and (try first.cfg.effectiveFontFeatures()).get("calt".*) == 0, "cached conditional features retain root override and force-off policy without rereading missing files");
    const rev = vt.lt_vt_revision(first.active().?.vt);
    h.setAppearance(true);
    try check(vt.lt_vt_revision(first.active().?.vt) == rev, "duplicate appearance while theme dialog is closed has no extra VT effects");
    h.setAppearance(false);
    try write(day, day_text);
    try write(night, night_text);
    try open(first, &t, themes, bundle);
    choose(first, &t, "Blue");
    try press(&t, "Apply");
    try check(!first.theme_browser.open and first.theme_applied != null and first.cfg.background == 0x203050 and second.cfg.background == 0xeeeedd and h.cfg.background == 0xeeeedd and try sameFile(a, root, original), "Apply transfers owned theme to target window only and leaves file and shared root config unchanged");
    const applied_ptr = first.theme_applied.?.cfg.theme.ptr;
    try open(first, &t, themes, bundle);
    choose(first, &t, "Red");
    try check(first.theme_applied.?.cfg.theme.ptr == applied_ptr and first.theme_original.?.background == 0x203050, "previous applied owner stays alive while replacement preview borrows a different candidate");
    cancel(&t);
    try check(first.cfg.background == 0x203050 and first.theme_applied.?.cfg.theme.ptr == applied_ptr and first.refs == refs, "cancel replacement preview returns to valid old applied owner without resetting zoom");
    try open(first, &t, themes, bundle);
    choose(first, &t, "Blue");
    choose(first, &t, "Bad");
    try check(first.cfg.background == 0x203050 and !first.theme_browser.canApply() and first.theme_browser.controller.candidate != null and std.mem.eql(u8, first.theme_browser.notice.text(), "InvalidColor") and first.theme_browser.diagnostic.line == 2 and std.mem.endsWith(u8, first.theme_browser.diagnostic.path[0..first.theme_browser.diagnostic.path_len], "/Bad"), "invalid real theme preserves last valid preview and disables mismatched Apply with source line diagnostic");
    if (std.c.unlink(missing) != 0) return error.FixtureUnlink;
    choose(first, &t, "Missing");
    try check(!first.theme_browser.canApply() and std.mem.eql(u8, first.theme_browser.notice.text(), "ConfigNotFound") and first.cfg.background == 0x203050 and try sameFile(a, root, original), "catalog entry removed before preview fails required read without discarding working theme or file");
    cancel(&t);
    try open(first, &t, themes, bundle);
    choose(first, &t, "Red");
    const external = source ++ "# external edit\r\n";
    try write(root, external);
    try press(&t, "Save");
    var concurrent = try edit.Native.capture(a, root);
    defer concurrent.deinit();
    try check(first.theme_browser.open and std.mem.eql(u8, first.theme_browser.notice.text(), "ConcurrentChange") and std.mem.eql(u8, concurrent.bytes, external) and first.theme_applied.?.cfg.theme.ptr == applied_ptr, "UI checked Save rejects concurrent root content and retains old owner plus external bytes");
    cancel(&t);
    try open(first, &t, themes, bundle);
    choose(first, &t, "Red");
    if (lt_config_fixture_xattr(root, "M10-external-metadata") != 0) return error.FixtureMetadata;
    try press(&t, "Save");
    var metadata = try edit.Native.capture(a, root);
    defer metadata.deinit();
    try check(first.theme_browser.open and std.mem.eql(u8, first.theme_browser.notice.text(), "ConcurrentChange") and std.mem.eql(u8, metadata.bytes, external) and !std.mem.eql(u8, &metadata.metadata_sha256, &concurrent.metadata_sha256), "UI checked Save rejects concurrent native metadata change before replacement");
    cancel(&t);
    t.resize(480, 240);
    try open(first, &t, themes, bundle);
    choose(first, &t, "Red");
    try finalButtons(first, &t);
    try t.screenshot(".cache/test-logs/m10-theme-browser-240.png");
    tabs(&t, 1);
    try check(first.theme_browser.keyboard == .cancel, "240px keyboard Tab reaches Cancel without pointer or OS input");
    t.key(.enter);
    t.frame();
    try check(!first.theme_browser.open and first.cfg.background == 0x203050, "240px keyboard Cancel restores previous applied theme");
    try open(first, &t, themes, bundle);
    choose(first, &t, "Red");
    tabs(&t, 2);
    try check(first.theme_browser.keyboard == .apply, "240px keyboard Tab reaches Apply");
    t.key(.enter);
    t.frame();
    try check(!first.theme_browser.open and first.cfg.background == 0x502030 and try sameFile(a, root, metadata), "240px keyboard Apply replaces owner without writing root or changing metadata");
    try open(first, &t, themes, bundle);
    choose(first, &t, "Blue");
    var before_save = try edit.Native.capture(a, root);
    defer before_save.deinit();
    const selected = first.theme_browser.controller.selected.?;
    const selector = try a.dupe(u8, first.theme_browser.catalog.?.entries[selected].selector);
    const expected = try edit.replaceTheme(a, before_save.bytes, selector);
    tabs(&t, 3);
    try check(first.theme_browser.keyboard == .save, "240px keyboard Tab reaches explicit Save");
    t.key(.enter);
    t.frame();
    var saved = try edit.Native.capture(a, root);
    defer saved.deinit();
    try check(!first.theme_browser.open and first.cfg.background == 0x203050 and second.cfg.background == 0xeeeedd and first.cfg.font_size == 23 and first.base_font_size == base_size and std.mem.eql(u8, saved.bytes, expected) and saved.identity.inode != before_save.identity.inode, "240px keyboard Save performs exact surgical atomic replacement and applies only source window while preserving zoom");
    try check((saved.identity.mode & 0o7777) == (before_save.identity.mode & 0o7777) and saved.identity.uid == before_save.identity.uid and saved.identity.gid == before_save.identity.gid and std.mem.eql(u8, &saved.metadata_sha256, &before_save.metadata_sha256) and lt_config_fixture_acl_count(root) > 0, "UI native Save preserves mode owner group real xattrs and nonempty ACL");
    // Virtual rows are checked using actual final geometry, not count guesses.
    try open(first, &t, themes, bundle);
    search(first, &t, "z-extra");
    for (0..4) |_| {
        t.key(.down);
        t.frame();
    }
    try check(first.theme_browser.first > 0 and first.theme_browser.geometry.row_count <= 2 and first.theme_browser.filtered_count == extras.len, "minimum-height real search list scrolls virtually within bounded visible rows");
    cancel(&t);
    t.resize(640, 500);
    try axSelectionChecks(first, &t, a, root, themes, bundle);
    try open(first, &t, themes, bundle);
    choose(first, &t, "Red");
    try open(second, &other, themes, bundle);
    choose(second, &other, "Blue");
    try write(root, "font-size=not-a-number\ntheme=paper\n");
    reload(first, &t);
    other.frame();
    try check(first.confirmation.open and !first.theme_browser.open and second.theme_browser.open and first.theme_applied != null and first.cfg.background == 0x203050 and second.cfg.background == 0x203050 and h.cfg.forAppearance(false).background == 0xeeeedd and std.mem.endsWith(u8, first.cfg.theme, "/Blue"), "failed real reload preserves original root arena and old applied owner while other window preview remains valid");
    t.key(.escape);
    t.frame();
    try write(root, "shell=/bin/sh\nshell-integration=none\ncopy-on-select=none\nfont-size=18\ntheme=paper\n");
    reload(first, &t);
    other.frame();
    try check(!first.theme_browser.open and !second.theme_browser.open and first.theme_original == null and second.theme_original == null and first.theme_applied == null and second.theme_applied == null and first.cfg.font_size == 18 and second.cfg.font_size == 18 and first.active().?.pid == pid_a and second.active().?.pid == pid_b, "real shared-root reload cancels both previews before arena free and releases old applied owners after cfg rebind");
    // A navigation-only settings commit may run while another window keeps
    // a theme preview lease. Cancel/re-preview/Apply must not restore its old
    // navigation snapshot over the just-saved shared values.
    try open(first, &t, themes, bundle);
    choose(first, &t, "Blue");
    const navigation_lease = first.theme_browser.lease.?;
    try saveNavigation(first, &t, root, dir, true);
    try check(first.theme_browser.open and first.theme_browser.lease.?.token == navigation_lease.token and navigationSaved(first.theme_original.?, true) and navigationSaved(first.cfg, true) and navigationSaved(second.cfg, true) and navigationSaved(h.cfg, true), "navigation settings save updates the live theme lease base without cancelling its preview");
    cancel(&t);
    var navigation_arena = std.heap.ArenaAllocator.init(s.gpa);
    defer navigation_arena.deinit();
    const disk_navigation = try config.loadDetailed(navigation_arena.allocator(), root, null);
    try check(!first.theme_browser.open and first.cfg.theme.len == 5 and std.mem.eql(u8, first.cfg.theme, "paper") and navigationSaved(first.cfg, true) and navigationSaved(disk_navigation, true) and first.active().?.pid == pid_a and second.active().?.pid == pid_b, "theme Cancel preserves all saved navigation values and existing processes");
    try open(first, &t, themes, bundle);
    choose(first, &t, "Blue");
    try saveNavigation(first, &t, root, dir, false);
    choose(first, &t, "Red");
    try check(first.theme_browser.open and first.cfg.background == 0x502030 and navigationSaved(first.cfg, false) and navigationSaved(first.theme_original.?, false) and navigationSaved(second.cfg, false) and navigationSaved(h.cfg, false), "re-preview after another navigation save uses the newly committed base rather than the captured old settings");
    try press(&t, "Apply");
    try check(!first.theme_browser.open and first.cfg.background == 0x502030 and navigationSaved(first.cfg, false) and first.active().?.pid == pid_a and second.active().?.pid == pid_b, "theme Apply retains navigation-only settings saved while the browser was open");
    first.explicit_config = missing_root;
    host.open(first, &t.ctx, .{ .user_theme_directory = themes, .bundled_theme_directory = bundle, .home = dir });
    t.frame();
    try check(!first.theme_browser.open and first.confirmation.open and first.confirmation.kind == .create_config and !config.exists(missing_root), "missing root follows existing create/open confirmation without implicitly creating a file");
    t.key(.escape);
    t.frame();
    first.explicit_config = root;
    const json_text = "{\"theme\":\"paper\",\"font_size\":18}";
    try write(json_root, json_text);
    var json_before = try edit.Native.capture(a, json_root);
    defer json_before.deinit();
    first.explicit_config = json_root;
    host.open(first, &t.ctx, .{ .user_theme_directory = themes, .bundled_theme_directory = bundle, .home = dir });
    t.frame();
    try check(!first.theme_browser.open and first.theme_original == null and first.confirmation.open and std.mem.eql(u8, first.config_diagnostic.reason[0..first.config_diagnostic.reason_len], "UnsupportedJsonRoot") and try sameFile(a, json_root, json_before), "JSON root reports explicit unsupported diagnostic and is never converted or modified");
    t.key(.escape);
    t.frame();
    first.explicit_config = root;
    try open(second, &other, themes, bundle);
    choose(second, &other, "Blue");
    try press(&other, "Apply");
    try open(second, &other, themes, bundle);
    choose(second, &other, "Red");
    h.closeWindow(second);
    nano.runFor(0.04);
    try check(second.retired and second.shutting_down and !second.theme_browser.open and second.theme_original == null and second.theme_applied == null and h.count() == 1 and first.active().?.id == id_a and first.active().?.pid == pid_a, "source-window teardown cancels preview and frees its old owner while retained closed state and other PTY stay valid");
    var closed_file = try edit.Native.capture(a, root);
    defer closed_file.deinit();
    second.theme_pending = .save;
    host.process(second, &other.ctx);
    try check(second.theme_pending == .none and try sameFile(a, root, closed_file) and first.active().?.pid == pid_a and t.clipboard.items.len == 0 and other.clipboard.items.len == 0, "late Save to retired source is discarded with no file write surviving-window effect or clipboard use");
    std.debug.print("PASS M10 THEME BROWSER {d} checks; real IO and Tester layout\n", .{checks});
}
