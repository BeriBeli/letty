//! Isolated native files + offscreen nanoui. Never touches a real config/PTY.
const std = @import("std");
const nano = @import("nanoui");
const ui = nano.ui;
const Model = @import("model.zig").Model;
const schema = @import("schema.zig");
const Form = @import("form.zig").Form;
const doc = @import("document.zig");
const adapter = @import("adapter.zig");
const edit = @import("../config_edit.zig");
const config = @import("../config.zig");
const appearance = @import("../appearance.zig");
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn lt_config_fixture_write([*:0]const u8, [*]const u8, usize, c_uint) c_int;
extern "c" fn lt_config_fixture_xattr([*:0]const u8, [*:0]const u8) c_int;
extern "c" fn lt_config_fixture_acl([*:0]const u8) c_int;
extern "c" fn lt_config_fixture_acl_count([*:0]const u8) c_int;
extern "c" fn lt_config_fixture_metadata_fault([*:0]const u8, c_int) c_int;
extern "c" fn lt_config_fixture_metadata_read(c_int, [*]u8, usize, *usize) callconv(.c) c_int;
extern "c" fn symlink([*:0]const u8, [*:0]const u8) c_int;
var count: usize = 0;
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} settings {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.SettingsCheckFailed;
    count += 1;
}
fn write(path: [:0]const u8, bytes: []const u8) !void {
    if (lt_config_fixture_write(path, bytes.ptr, bytes.len, 0o640) != 0) return error.FixtureWrite;
}
const Fake = struct {
    prepared: usize = 0,
    aborted: usize = 0,
    committed: usize = 0,
    reject: bool = false,
    config: ?doc.Candidate = null,
    change_during_prepare: ?[:0]const u8 = null,
    fn host(self: *Fake) adapter.Host {
        return .{ .context = self, .prepare = prepare, .abort = abort, .commit = commit, .open_config = openConfig };
    }
    fn prepare(raw: *anyopaque, candidate: *const doc.Candidate) !*anyopaque {
        const self: *Fake = @ptrCast(@alignCast(raw));
        _ = candidate;
        if (self.reject) return error.ProfileInUse;
        self.prepared += 1;
        if (self.change_during_prepare) |path| try write(path, "# changed during prepare\nfont-size=16\n");
        return raw;
    }
    fn abort(raw: *anyopaque, _: *anyopaque) void {
        const self: *Fake = @ptrCast(@alignCast(raw));
        self.aborted += 1;
    }
    fn commit(raw: *anyopaque, _: *anyopaque, candidate: doc.Candidate) void {
        const self: *Fake = @ptrCast(@alignCast(raw));
        if (self.config) |*old| old.deinit();
        self.config = candidate;
        self.committed += 1;
    }
    fn openConfig(_: *anyopaque) !void {}
};
const View = struct {
    model: *Model,
    catalog: ?*const @import("../theme_browser.zig").Catalog = null,
    form: Form = .{},
    intent: @import("form.zig").Intent = .none,
    preview_requests: usize = 0,
    fn draw(self: *View, ctx: *ui.Context) void {
        self.intent = self.form.draw(ctx, self.model, null, self.catalog);
        if (self.intent == .preview) self.preview_requests += 1;
    }
};
pub fn run(init: std.process.Init) !void {
    _ = init;
    const a = std.heap.page_allocator;
    var dir_buf = "/tmp/letty-settings-XXXXXX\x00".*;
    const dir = std.mem.span(mkdtemp(@ptrCast(&dir_buf)) orelse return error.FixtureDirectory);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/config", .{dir}, 0);
    defer a.free(path);
    defer _ = std.c.rmdir(@ptrCast(dir.ptr));
    defer _ = std.c.unlink(path);
    const include = try std.fmt.allocPrintSentinel(a, "{s}/common", .{dir}, 0);
    defer a.free(include);
    defer _ = std.c.unlink(include);
    const source = "# comment: 保留\r\nfont-size = 13\r\nfont-size = 15\r\nconfig-file = common\r\n";
    try write(include, "font-size=17\nwindow-padding-x=8,12\n");
    try write(path, source);
    var fake: Fake = .{};
    defer if (fake.config) |*owned| owned.deinit();
    {
        var m = try Model.init(a, path, dir);
        defer m.deinit();
        try check(m.baseline.font_size == 17, "include effective value");
        try check(m.dirtyCount() == 0 and try m.save(fake.host()) == null, "unchanged does not prepare/save");
        var initial = try edit.Native.capture(a, path);
        defer initial.deinit();
        m.value(.font_size).input.set("20");
        var next = try m.candidate();
        defer next.deinit();
        try check(next.cfg.font_size == 20 and std.mem.startsWith(u8, next.replacement, source), "append root override after includes preserves duplicate keys/comments/CRLF");
        try check(std.mem.indexOf(u8, next.replacement, "font-size = \"20\"\r\n") != null, "uses root newline convention");
        var found = try edit.Native.capture(a, path);
        defer found.deinit();
        try check(initial.matches(found), "preview is zero writes");
        fake.reject = true;
        const failed = m.save(fake.host()) catch |err| blk: {
            try check(err == error.ProfileInUse, "host preflight rejection");
            break :blk null;
        };
        _ = failed;
        var after_reject = try edit.Native.capture(a, path);
        defer after_reject.deinit();
        try check(initial.matches(after_reject) and m.dirtyCount() == 1 and fake.committed == 0, "failed apply preserves file/runtime/draft");
        fake.reject = false;
        _ = try m.save(fake.host());
        try check(fake.committed == 1 and fake.config.?.cfg.font_size == 20, "checked save commits prepared candidate");
    }
    {
        var m = try Model.init(a, path, dir);
        defer m.deinit();
        try check(m.baseline.font_size == 20 and m.dirtyCount() == 0, "reopen reads saved values");
        m.value(.font_size).input.set("999");
        const invalid = m.candidate() catch |err| blk: {
            try check(err == error.InvalidFontSize and m.last_error_field == .font_size, "range error locates field");
            break :blk null;
        };
        if (invalid) |candidate| {
            var owned = candidate;
            owned.deinit();
            return error.ExpectedRejection;
        }
        m.value(.font_size).input.set("22");
        try write(include, "font-size=19\n");
        const conflict = m.save(fake.host()) catch |err| blk: {
            try check(err == error.IncludedSourceChanged and m.dirtyCount() == 1, "included external change retains draft");
            break :blk null;
        };
        _ = conflict;
    }
    {
        var m = try Model.init(a, path, dir);
        defer m.deinit();
        m.value(.font_size).input.set("23");
        try write(path, "# externally modified\nfont-size=16\n");
        _ = m.save(fake.host()) catch |err| blk: {
            try check(err == error.ConcurrentChange, "root external change is not overwritten");
            break :blk null;
        };
    }
    try write(path, "font-size=14\n");
    {
        var m = try Model.init(a, path, dir);
        defer m.deinit();
        const default = if (@import("builtin").os.tag == .macos) "super+t=new_tab" else "ctrl+shift+t=new_tab";
        m.addBinding(default, false) catch |err| try check(err == error.ShortcutConflict, "shortcut collision requires explicit replacement");
        try m.addBinding(default, true);
        try m.addBinding("ctrl+b>t=new_tab", false);
        var next = try m.candidate();
        defer next.deinit();
        try check(next.cfg.keybinds.len == 2, "advanced sequence survives binding form");
        try m.editBinding("ctrl+b>t", "ctrl+alt+y=new_tab", false);
        var moved = try m.candidate();
        defer moved.deinit();
        try check(moved.cfg.keybinds.len == 4 and moved.cfg.keybinds[3].action == .unbind, "editing shortcut retires its old trigger atomically");
        try m.editBinding("ctrl+alt+y", "control+alt+y=new_window", false);
        var alias_edit = try m.candidate();
        defer alias_edit.deinit();
        try check(alias_edit.cfg.keybinds[alias_edit.cfg.keybinds.len - 1].action == .new_window, "equivalent trigger spelling edits in place without unbinding the new shortcut");
        const edit_count = m.binding_edits.items.len;
        m.editBinding("ctrl+alt+y", default, false) catch |err| try check(err == error.ShortcutConflict and m.binding_edits.items.len == edit_count, "conflicting edit preserves old shortcut and draft");
        while (m.binding_edits.items.len < 63) try m.addBinding("ctrl+alt+y=new_tab", true);
        m.editBinding("ctrl+alt+y", "ctrl+alt+z=new_tab", true) catch |err| try check(err == error.TooManyKeybindings and m.binding_edits.items.len == 63, "capacity failure rolls back the entire shortcut move");
        try m.reset(.font_size);
        try check(!m.value(.font_size).dirty(), "reset uses Config default");
    }
    // The first save creates a file without requiring xattr support. Reopening
    // must display its actual values even when later metadata inspection fails.
    _ = std.c.unlink(path);
    {
        var missing = try Model.init(a, path, dir);
        defer missing.deinit();
        missing.value(.font_size).input.set("21");
        _ = try missing.save(fake.host());
        for ([_]anyerror{ error.MetadataUnsupported, error.MetadataAccessDenied, error.MetadataIo }, 1..) |expected, kind| {
            if (lt_config_fixture_metadata_fault(path, @intCast(kind)) != 0) return error.FixtureMetadata;
            var m = try Model.initWithMetadataReader(a, path, dir, lt_config_fixture_metadata_read);
            defer m.deinit();
            try check(m.read_only and m.metadata_unavailable and m.baseline.font_size == 21 and m.root.?.metadata_error.? == expected, "metadata failure reopens committed settings with actual values and a specific read-only diagnostic");
            try check(std.mem.indexOf(u8, m.notice.text(), @errorName(expected)) != null and std.mem.indexOf(u8, m.notice.text(), path) != null, "metadata diagnostic names the error and affected source");
            const prepared = fake.prepared;
            m.value(.font_size).input.set("22");
            try std.testing.expectError(error.ReadOnlySetting, m.save(fake.host()));
            try std.testing.expectError(expected, edit.Native.save(a, m.root.?, "font-size=22\n"));
            try check(fake.prepared == prepared and !m.root.?.matches(m.root.?), "incomplete metadata cannot authorize a transaction or direct file replacement");
            var view: View = .{ .model = &m };
            var tester: ui.Tester = undefined;
            try tester.init(a, .init(&view, View.draw), .{ .width = 800, .height = 600 });
            defer tester.deinit();
            tester.frame();
            try check(tester.containsText("File attributes unavailable") and tester.containsText("Open Config"), "metadata recovery UI renders with external-editor access");
        }
        var reopened = try Model.init(a, path, dir);
        defer reopened.deinit();
        try check(!reopened.read_only and reopened.baseline.font_size == 21, "metadata recovery leaves saved bytes untouched and restores editing after inspection succeeds");
    }
    try write(path, source);
    try write(include, "font-size=17\nwindow-padding-x=8,12\n");
    if (lt_config_fixture_metadata_fault(include, 1) != 0) return error.FixtureMetadata;
    {
        var m = try Model.initWithMetadataReader(a, path, dir, lt_config_fixture_metadata_read);
        defer m.deinit();
        try check(m.read_only and m.metadata_unavailable and m.baseline.font_size == 17 and std.mem.indexOf(u8, m.notice.text(), include) != null, "included-file metadata failure retains inherited values and identifies the included source");
    }
    try write(path, "{\"font_size\":18,\"profiles\":[{\"name\":\"Local\"}]}\n");
    {
        var m = try Model.init(a, path, dir);
        defer m.deinit();
        try check(m.json and m.read_only and m.baseline.font_size == 18, "JSON correctly loaded and explicitly read only");
        m.value(.font_size).input.set("19");
        _ = m.candidate() catch |err| blk: {
            try check(err == error.UnsupportedJsonRoot, "never writes INI over JSON");
            break :blk null;
        };
    }
    try write(path, "font-size=broken\n");
    {
        var m = try Model.init(a, path, dir);
        defer m.deinit();
        try check(m.read_only and m.diagnostic.reason_len > 0, "invalid config opens diagnostics without mutation");
    }
    _ = std.c.unlink(path);
    {
        var m = try Model.init(a, path, dir);
        defer m.deinit();
        try check(m.root == null and m.baseline.font_size == 14, "missing default file uses schema defaults");
        m.value(.font_size).input.set("21");
        _ = try m.save(fake.host());
        try check(fake.config.?.cfg.font_size == 21, "first save exclusively creates config");
        _ = doc.create(a, path, "font-size=30\n") catch |err| blk: {
            try check(err == error.ConcurrentChange, "creation race refuses replacement");
            break :blk null;
        };
    }
    try uiChecks(a, path, dir);
    try extraChecks(a, path, dir, &fake);
    // Include window code in compilation without opening native/user windows.
    std.testing.refAllDecls(@import("window.zig").Settings);
    var font_catalog = try @import("fonts.zig").Catalog.scan(a);
    defer font_catalog.deinit();
    try check(!font_catalog.contains("Letty deliberately missing font 123456789"), "font availability rejects missing family");
    std.debug.print("Settings acceptance: {d} checks passed\n", .{count});
}
fn extraChecks(a: std.mem.Allocator, path: [:0]const u8, dir: []const u8, fake: *Fake) !void {
    try write(path, "# keep\nfont-size=14\ntab-bar=never\nworkspace-navigation=top\n");
    {
        var m = try Model.init(a, path, dir);
        defer m.deinit();
        var before = try edit.Native.capture(a, path);
        defer before.deinit();
        m.value(.navigation).input.set("sidebar");
        m.value(.sidebar_git).input.set("true");
        m.value(.sidebar_ports).input.set("true");
        var candidate = try m.candidate();
        defer candidate.deinit();
        try check(candidate.cfg.workspace_navigation == .sidebar and candidate.cfg.tab_bar == .never and candidate.cfg.sidebar_show_git and candidate.cfg.sidebar_show_ports, "sidebar selection preserves top tab visibility policy");
        var after = try edit.Native.capture(a, path);
        defer after.deinit();
        try check(before.matches(after), "navigation draft preview/cancel has zero writes");
        _ = try m.save(fake.host());
    }
    {
        var m = try Model.init(a, path, dir);
        defer m.deinit();
        try check(m.baseline.workspace_navigation == .sidebar, "navigation survives reopen");
        try m.reset(.navigation);
        try check(std.mem.eql(u8, m.value(.navigation).input.text(), "top") and m.value(.navigation).dirty(), "navigation reset is a pending default change");
        m.value(.navigation).input.set("wrong");
        _ = m.candidate() catch |err| blk: {
            try check(err == error.InvalidWorkspaceNavigation and m.last_error_field == .navigation, "invalid navigation rejected at its field");
            break :blk null;
        };
    }
    try write(path, "font-size=14\n");
    {
        var m = try Model.init(a, path, dir);
        defer m.deinit();
        m.value(.font_size).input.set("22");
        const commits = fake.committed;
        const aborts = fake.aborted;
        fake.change_during_prepare = path;
        defer fake.change_during_prepare = null;
        _ = m.save(fake.host()) catch |err| blk: {
            try check(err == error.ConcurrentChange, "post-prepare conflict rejects save");
            break :blk null;
        };
        try check(fake.aborted == aborts + 1 and fake.committed == commits and m.dirtyCount() == 1, "post-prepare failure releases reservation and keeps draft/runtime");
    }
    try write(path, "font-size=14\n");
    const alias = try std.fmt.allocPrintSentinel(a, "{s}/alias", .{dir}, 0);
    defer a.free(alias);
    defer _ = std.c.unlink(alias);
    if (symlink(path, alias) != 0) return error.FixtureSymlink;
    {
        var m = try Model.init(a, alias, dir);
        defer m.deinit();
        m.value(.font_size).input.set("19");
        _ = try m.save(fake.host());
        var physical = try edit.Native.capture(a, path);
        defer physical.deinit();
        var linked = try edit.Native.capture(a, alias);
        defer linked.deinit();
        try check(physical.matches(linked) and !std.mem.eql(u8, linked.path, alias), "save follows physical root and preserves symbolic link");
    }
    try write(path, "font-size=14\n");
    if (lt_config_fixture_xattr(path, "settings-preserve") != 0 or lt_config_fixture_acl(path) != 0) return error.FixtureMetadata;
    {
        var m = try Model.init(a, path, dir);
        defer m.deinit();
        const metadata = m.root.?.metadata_sha256;
        const mode = m.root.?.identity.mode;
        m.value(.font_size).input.set("20");
        _ = try m.save(fake.host());
        var after = try edit.Native.capture(a, path);
        defer after.deinit();
        try check(std.mem.eql(u8, &metadata, &after.metadata_sha256) and mode == after.identity.mode and lt_config_fixture_acl_count(path) > 0, "settings saves preserve ACL/xattr/mode through config_edit");
    }
    const binding_text = @import("bindings.zig");
    const keys = @import("../keybindings.zig");
    for (keys.defaults) |binding| {
        const action = binding_text.request(binding.request()) orelse return error.UnrepresentableDefaultAction;
        const trigger = try binding_text.trigger(a, binding);
        defer a.free(trigger);
        const spec = try std.fmt.allocPrint(a, "{s}={s}", .{ trigger, action });
        defer a.free(spec);
        const roundtrip = try keys.parse(spec);
        if (!keys.sameTrigger(&binding, &roundtrip) or !roundtrip.request().same(binding.request())) return error.BindingRoundtrip;
    }
    try check(true, "all supported default bindings roundtrip through recorder serializer");
    const equal = try binding_text.chord(a, .{ .key = '=', .ctrl = true });
    defer a.free(equal);
    try check(std.mem.indexOfScalar(u8, equal, '=') == null, "recorded equal key cannot corrupt binding separator");
    const long_command_len = @as(ui.TextBuffer, .{}).buf.len + 1;
    const long_command = try a.alloc(u8, long_command_len);
    defer a.free(long_command);
    @memset(long_command, 'x');
    const long_source = try std.fmt.allocPrint(a, "command={s}\n", .{long_command});
    defer a.free(long_source);
    try write(path, long_source);
    {
        var m = try Model.init(a, path, dir);
        defer m.deinit();
        try check(m.value(.command).locked and !m.value(.command).dirty() and m.value(.command).text().len == long_command_len, "long existing values remain intact and unchanged beyond form capacity");
        try m.reset(.command);
        var candidate = try m.candidate();
        defer candidate.deinit();
        try check(candidate.cfg.command.len == 0 and std.mem.startsWith(u8, candidate.replacement, long_source), "explicit default reset can replace a locked long value without losing original text");
        m.value(.command).input.set("printf \"%s\" hello");
        var quoted = try m.candidate();
        defer quoted.deinit();
        try check(std.mem.eql(u8, quoted.cfg.command, "printf \"%s\" hello"), "quoted startup commands roundtrip through the actual text grammar");
    }
    const theme_path = try std.fmt.allocPrintSentinel(a, "{s}/new-theme", .{dir}, 0);
    defer a.free(theme_path);
    defer _ = std.c.unlink(theme_path);
    const dark_path = try std.fmt.allocPrintSentinel(a, "{s}/dark-theme", .{dir}, 0);
    defer a.free(dark_path);
    defer _ = std.c.unlink(dark_path);
    try write(theme_path, "font-ligatures=true\n");
    try write(dark_path, "font-ligatures=false\n");
    try write(path, "theme=light:./new-theme,dark:./dark-theme\n");
    {
        var m = try Model.init(a, path, dir);
        defer m.deinit();
        m.syncAppearance(true);
        try check(std.mem.eql(u8, m.value(.ligatures).input.text(), "false") and m.dirtyCount() == 0, "active dark theme supplies inherited ligature value without an edit");
        m.value(.ligatures).input.set("true");
        var next = try m.candidate();
        defer next.deinit();
        try check(next.cfg.forAppearance(true).font_ligatures and next.cfg.forAppearance(false).font_ligatures, "enabling inherited dark ligatures creates a real explicit root override");
        m.syncAppearance(false);
        try check(m.value(.ligatures).dirty() and std.mem.eql(u8, m.value(.ligatures).input.text(), "true"), "appearance event preserves an existing ligature draft");
    }
    try write(path, "font-size=14\n");
    try write(theme_path, "background=#203040\n");
    {
        var m = try Model.init(a, path, dir);
        defer m.deinit();
        m.value(.theme).input.set("./new-theme");
        const commits = fake.committed;
        fake.change_during_prepare = theme_path;
        defer fake.change_during_prepare = null;
        _ = m.save(fake.host()) catch |err| blk: {
            try check(err == error.IncludedSourceChanged and fake.committed == commits and m.dirtyCount() == 1, "newly selected theme frozen bytes are rechecked after preflight");
            break :blk null;
        };
    }
    const optional = try std.fmt.allocPrintSentinel(a, "{s}/optional", .{dir}, 0);
    defer a.free(optional);
    defer _ = std.c.unlink(optional);
    try write(path, "config-file=?optional\nfont-size=14\n");
    {
        var m = try Model.init(a, path, dir);
        defer m.deinit();
        m.value(.font_size).input.set("18");
        try write(optional, "font-size=19\n");
        _ = m.save(fake.host()) catch |err| blk: {
            try check(err == error.IncludedSourceChanged, "appearing optional include is an external conflict");
            break :blk null;
        };
    }
    const second_include = try std.fmt.allocPrintSentinel(a, "{s}/second-include", .{dir}, 0);
    defer a.free(second_include);
    defer _ = std.c.unlink(second_include);
    try write(optional, "font-size=16\n");
    try write(second_include, "font-size=16\n");
    _ = std.c.unlink(alias);
    if (symlink(optional, alias) != 0) return error.FixtureSymlink;
    try write(path, "config-file=alias\n");
    {
        var m = try Model.init(a, path, dir);
        defer m.deinit();
        m.value(.font_size).input.set("18");
        _ = std.c.unlink(alias);
        if (symlink(second_include, alias) != 0) return error.FixtureSymlink;
        _ = m.save(fake.host()) catch |err| blk: {
            try check(err == error.IncludedSourceChanged, "retargeting an include symlink rejects stale draft even with identical values");
            break :blk null;
        };
    }
}
fn uiChecks(a: std.mem.Allocator, _: []const u8, dir: []const u8) !void {
    const fixture_path = try std.fmt.allocPrintSentinel(a, "{s}/visual-config", .{dir}, 0);
    defer a.free(fixture_path);
    defer _ = std.c.unlink(fixture_path);
    try write(fixture_path, "font-family=Maple Mono Normal NL NF CN\nfont-size=14\ntheme=paper\nwindow-padding-x=8\nwindow-padding-y=8\nworkspace-navigation=sidebar\n");
    var m = try Model.init(a, fixture_path, dir);
    defer m.deinit();
    var view: View = .{ .model = &m };
    var t: ui.Tester = undefined;
    var missing_font = m.baseline;
    missing_font.font = "Letty deliberately missing font 123456789";
    const safe_theme = @import("window.zig").systemTheme(missing_font);
    try check(safe_theme.font == null and safe_theme.mono_font == null, "settings chrome never depends on configured terminal font");
    try t.init(a, .init(&view, View.draw), .{ .width = 1100, .height = 760, .theme = safe_theme });
    defer t.deinit();
    try t.screenshot("/tmp/letty-settings-initial.png");
    for (schema.categories, 0..) |label, index| {
        const id = for (view.form.ax.notes[0..view.form.ax.count]) |note| {
            if (std.mem.eql(u8, note.label, label)) break note.widget;
        } else return error.MissingCategory;
        const rect = t.ctx.rects.get(id).?;
        t.moveTo(rect.x + rect.w / 2, rect.y + rect.h / 2);
        t.ctx.pointerDown();
        t.frame();
        try check(t.ctx.focus == id, "category pointer press focuses the pressed row");
        t.ctx.pointerUp();
        t.frame();
        t.frame();
        try check(t.ctx.focus == id and @backingInt(view.form.category) == index, "category click keeps focus and selection on the same row");
    }
    try t.clickText("Terminal");
    t.key(.enter);
    try check(view.form.category == .startup, "Enter after a category click keeps the clicked page");
    _ = t.shortcut(.{ .key = '\t' });
    t.key(.enter);
    try check(view.form.category == .keyboard, "Tab then Enter activates the next category");
    _ = t.shortcut(.{ .key = '\t', .shift = true });
    t.key(.enter);
    try check(view.form.category == .startup, "Shift Tab then Enter returns to the previous category");
    for ([_]schema.Category{ .startup, .keyboard, .clipboard, .advanced }, [_][]const u8{ "terminal", "keyboard", "clipboard", "advanced" }) |category, name| {
        view.form.category = category;
        t.frame();
        t.frame();
        const capture = try std.fmt.allocPrint(a, "/tmp/letty-settings-pages-{s}.png", .{name});
        defer a.free(capture);
        try t.screenshot(capture);
        try check(!t.containsText("Preview only"), "non-appearance page has no unrelated preview");
    }
    view.form.category = .keyboard;
    t.frame();
    t.frame();
    const scroll = &view.form.scroll_area;
    const viewport = scroll.viewport;
    t.scroll(viewport.x + 60, viewport.y + 80, -180);
    try check(scroll.offset > 0 and scroll.alpha > 0, "settings wheel scroll moves content and reveals overlay thumb");
    const wheel_offset = scroll.offset;
    t.advance(1.5);
    try check(scroll.alpha == 0 and scroll.offset == wheel_offset, "idle thumb fades away without moving content");
    t.moveTo(viewport.x + viewport.w - 4, viewport.y + 50);
    try check(scroll.alpha > 0, "moving near the edge reveals the scrollbar");
    const thumb = scroll.thumb(scroll.offset);
    t.moveTo(thumb.x + 2, thumb.y + thumb.h / 2);
    t.ctx.pointerDown();
    t.frame();
    t.moveTo(thumb.x + 2, thumb.y + thumb.h / 2 + 100);
    t.ctx.pointerUp();
    t.frame();
    try check(scroll.offset > wheel_offset and !scroll.dragging, "overlay scrollbar drag changes offset and releases capture");
    try t.clickText("Terminal");
    t.frame();
    try check(scroll.offset == 0 and t.hasText("Startup"), "category change resets scroll to the beginning");
    view.form.category = .appearance;
    t.frame();
    t.frame();
    try check(t.hasText("Font") and t.containsText("Preview only"), "categorized form with contained preview");
    try check(t.containsText("system monospace"), "missing/unverified font has explicit system fallback");
    const before_size = try a.dupe(u8, m.value(.font_size).input.text());
    defer a.free(before_size);
    for (view.form.ax.notes[0..view.form.ax.count]) |note| if (std.mem.eql(u8, note.label, "Increase Font size")) {
        const r = t.ctx.rects.get(note.widget).?;
        t.click(r.x + r.w / 2, r.y + r.h / 2);
        break;
    };
    try check(view.preview_requests == 1, "appearance edit requests automatic preview");
    try check(std.mem.eql(u8, m.value(.font_size).input.text(), "15"), "font stepper increments draft without saving");
    for (view.form.ax.notes[0..view.form.ax.count]) |note| if (std.mem.eql(u8, note.label, "Decrease Font size")) {
        const r = t.ctx.rects.get(note.widget).?;
        t.click(r.x + r.w / 2, r.y + r.h / 2);
        break;
    };
    try check(std.mem.eql(u8, before_size, m.value(.font_size).input.text()) and m.dirtyCount() == 0, "font stepper returns to clean draft");
    m.last_error_field = .theme;
    m.value(.font_size).input.set("-");
    const invalid_preview = m.previewCandidate() catch null;
    try check(invalid_preview == null and m.last_error_field == .theme, "incomplete auto-preview preserves save diagnostics and rejects invalid values");
    m.last_error_field = null;
    m.value(.font_size).input.set(before_size);

    var toggled = false;
    for (view.form.ax.notes[0..view.form.ax.count]) |note| if (std.mem.eql(u8, note.label, "Dark preview")) {
        const r = t.ctx.rects.get(note.widget).?;
        t.click(r.x + r.w / 2, r.y + r.h / 2);
        toggled = true;
        break;
    };
    try check(toggled and view.form.dark_preview and m.dirtyCount() == 0, "single appearance icon toggles preview without changing configuration");
    view.form.dark_preview = false;
    try t.clickText("Dark theme…");
    try check(t.hasText("Dark theme"), "dark theme disclosure keeps advanced field accessible");
    try t.clickText("Dark theme…");
    view.form.focus_query = true;
    t.frame();
    t.textOps(&.{.{ .insert = "font-size" }});
    try check(t.hasText("Font size") and !t.hasText("Horizontal padding"), "config key search filters fields");
    t.textOps(&.{ .{ .command = .select_all }, .{ .insert = "" } });
    view.form.query.clear();
    t.frame();
    _ = t.shortcut(.{ .key = '\t' });
    try check(t.ctx.focus != view.form.query_id, "Tab changes keyboard focus");
    view.form.focus_query = true;
    t.frame();
    t.textOps(&.{.{ .set_marked = .{ .text = "字", .sel_start = 3, .sel_len = 0 } }});
    t.key(.escape);
    try check(view.intent == .none and !view.form.confirm_discard, "IME composition Escape does not close settings");
    t.textOps(&.{.unmark});
    view.form.query.clear();
    view.form.composing = false;
    m.value(.font_size).input.set("24");
    t.key(.escape);
    try check(view.form.confirm_discard and view.intent == .none, "Escape prompts for unsaved draft");
    try t.clickText("Keep editing");
    try check(!view.form.confirm_discard and m.dirtyCount() == 1, "continue editing preserves draft");
    try t.screenshot("/tmp/letty-settings-light.png");
    t.theme = ui.Theme.dark_theme;
    t.size = .{ .w = 480, .h = 360 };
    t.frame();
    try check(t.findText("Save and apply") != null, "narrow dark footer exists");
    if (t.ctx.rects.get(view.form.save_id)) |r| try check(r.x >= 0 and r.y >= 0 and r.x + r.w <= 480.5 and r.y + r.h <= 360.5, "narrow save button fully inside window") else return error.MissingSaveButton;
    try t.screenshot("/tmp/letty-settings-dark-narrow.png");
    view.form.confirm_discard = false;
    view.form.query.set("workspace-navigation");
    t.frame();
    try check(t.hasText("Workspace navigation"), "navigation searchable by config key");
    view.form.query.clear();
    m.value(.navigation).input.set("sidebar");
    view.form.dark_preview = true;
    t.frame();
    try check(t.containsText("> Workspace 1") and t.containsText("Available with top tabs"), "sidebar draft previews layout and explains disabled top policy");
    try t.screenshot("/tmp/letty-settings-sidebar-narrow.png");
    try t.clickText("Keyboard");
    view.form.recording = true;
    _ = t.shortcut(.{ .key = '=', .ctrl = true });
    try check(!view.form.recording and std.mem.eql(u8, view.form.chord.text(), "ctrl+equal"), "shortcut recorder consumes equal key safely");
    view.form.query.set("new_tab");
    t.frame();
    try check(t.hasText("New Tab"), "action search works with canonical names");
    view.form.query.clear();
    t.frame();
    try check(!t.hasText("Reload from disk") and !t.hasText("Update preview") and !t.hasText("Light"), "settings has no manual reload or preview-update controls");
    view.form.confirm_discard = false;
    view.form.category = .advanced;
    view.form.applied_values[@backingInt(schema.Field.font_size)] = "99";
    view.form.command_override.set("exec /bin/sh");
    view.form.advanced_applied = true;
    view.form.advanced_overrides = true;
    t.frame();
    try check(t.containsText("font-size: applied 99; file") and t.hasText("Applied values when this window opened"), "Advanced distinguishes applied snapshot from file values");
    try check(t.hasText("--command=exec /bin/sh"), "Advanced explains active command-line overrides");
    var catalog = try @import("../theme_browser.zig").Catalog.scan(a, &.{}, @import("../theme_browser.zig").nativeReader(), .{});
    defer catalog.deinit();
    view.catalog = &catalog;
    view.form.category = .appearance;
    view.form.show_themes = true;
    view.form.theme_query.set("deliberately missing theme 123456789");
    t.frame();
    try check(t.hasText("No matching local themes."), "embedded theme browser filters local catalog");
    view.form.theme_query.clear();
    t.frame();
    try check(t.hasText("Paper (builtin)"), "theme choices identify their actual origin");
}
