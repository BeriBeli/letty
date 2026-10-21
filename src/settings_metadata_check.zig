//! Private-file regressions for the real writer on filesystems without xattrs.
const std = @import("std");
const nano = @import("nanoui");
const ui = nano.ui;
const Model = @import("settings/model.zig").Model;
const Settings = @import("settings/window.zig").Settings;
const doc = @import("settings/document.zig");
const adapter = @import("settings/adapter.zig");
const edit = @import("config_edit.zig");
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn lt_config_no_xattr_fixture([*:0]const u8, c_int) c_int;
extern "c" fn lt_config_fixture_write([*:0]const u8, [*]const u8, usize, c_uint) c_int;
extern "c" fn lt_config_fixture_acl([*:0]const u8) c_int;
extern "c" fn lt_config_fixture_acl_count([*:0]const u8) c_int;
const Host = struct {
    commits: usize = 0,
    fn callbacks(self: *@This()) adapter.Host {
        return .{ .context = self, .prepare = prepare, .abort = abort, .commit = commit, .open_config = open };
    }
    fn prepare(raw: *anyopaque, _: *const doc.Candidate) !*anyopaque {
        return raw;
    }
    fn abort(_: *anyopaque, _: *anyopaque) void {}
    fn commit(raw: *anyopaque, _: *anyopaque, value: doc.Candidate) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.commits += 1;
        var owned = value;
        owned.deinit();
    }
    fn open(_: *anyopaque) !void {}
};
fn fault(directory: [:0]const u8, kind: c_int) !void {
    if (lt_config_no_xattr_fixture(directory, kind) != 0) return error.FixtureFault;
}
fn write(path: [:0]const u8, bytes: []const u8) !void {
    if (lt_config_fixture_write(path, bytes.ptr, bytes.len, 0o600) != 0) return error.FixtureWrite;
}
fn check(ok: bool, label: []const u8) !void {
    if (!ok) return error.SettingsMetadataCheck;
    std.debug.print("PASS settings metadata {s}\n", .{label});
}
fn save(t: *ui.Tester, settings: *Settings) !void {
    t.frame();
    try t.clickText("Save and apply");
    for (0..40) |_| {
        if (!settings.scheduled) break;
        nano.runFor(0.005);
    }
    t.frame();
    try check(!settings.scheduled and !settings.saved and !settings.model.?.read_only and settings.model.?.dirtyCount() == 0, "Save button refreshes an editable clean draft");
}
pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    var template = "/tmp/letty-no-xattr-XXXXXX\x00".*;
    const dir: [:0]const u8 = std.mem.span(mkdtemp(@ptrCast(&template)) orelse return error.FixtureDirectory);
    defer _ = std.c.rmdir(dir);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/config", .{dir}, 0);
    defer a.free(path);
    defer _ = std.c.unlink(path);
    const include = try std.fmt.allocPrintSentinel(a, "{s}/common", .{dir}, 0);
    defer a.free(include);
    defer _ = std.c.unlink(include);
    try fault(dir, 1);
    const app = try nano.App.create(init, .{ .name = "Letty metadata regression" });
    defer app.destroy();
    app.flags.hidden = true;
    var host: Host = .{};
    var settings: Settings = .{};
    defer {
        settings.deinit();
        nano.runFor(0.02);
    }
    try settings.open(a, app, host.callbacks(), .{ .path = path, .home = dir });
    const surface = settings.window.?.surface orelse return error.NativeSurfaceRequired;
    var t: ui.Tester = undefined;
    try t.init(a, surface.view, .{ .width = 1100, .height = 760, .theme = surface.theme_override.? });
    defer t.deinit();
    for ([_][]const u8{ "18", "20", "22" }, [_]f32{ 18, 20, 22 }) |text, expected| {
        settings.model.?.value(.font_size).input.set(text);
        try save(&t, &settings);
        try check(settings.model.?.baseline.font_size == expected, "first create and repeated atomic saves reload the actual value");
    }
    try check(host.commits == 3, "three successful saves publish exactly three runtime configurations");
    settings.deinit();
    try settings.open(a, app, host.callbacks(), .{ .path = path, .home = dir });
    try check(!settings.model.?.read_only and settings.model.?.baseline.font_size == 22, "closing and reopening retains saved values and editing");
    settings.deinit();
    try write(include, "font-size=17\n");
    try write(path, "# retained comment\nconfig-file=common\n");
    {
        var model = try Model.init(a, path, dir);
        defer model.deinit();
        try check(!model.read_only and model.baseline.font_size == 17, "included NFS configuration stays editable");
        model.value(.font_size).input.set("19");
        _ = try model.save(host.callbacks());
        var reopened = try Model.init(a, path, dir);
        defer reopened.deinit();
        try check(reopened.baseline.font_size == 19 and std.mem.startsWith(u8, reopened.root.?.bytes, "# retained comment\n"), "save preserves comments and overrides included values");
        reopened.value(.font_size).input.set("20");
        try write(include, "font-size=21\n");
        try std.testing.expectError(error.IncludedSourceChanged, reopened.save(host.callbacks()));
        try check(true, "changed include rejects save");
    }
    try write(path, "font-size=19\n");
    {
        var before = try edit.Native.capture(a, path);
        defer before.deinit();
        try fault(dir, 6);
        var changed = try edit.Native.capture(a, path);
        defer changed.deinit();
        try check(!before.matches(changed), "unsupported and supported-empty metadata snapshots differ");
        try std.testing.expectError(error.ConcurrentChange, edit.Native.save(a, before, "font-size=20\n"));
        try fault(dir, 7);
        try std.testing.expectError(error.MetadataAccessDenied, edit.Native.save(a, before, "font-size=20\n"));
        try fault(dir, 9);
        try std.testing.expectError(error.ConcurrentChange, edit.Native.save(a, before, "font-size=20\n"));
        try fault(dir, 1);
        var after = try edit.Native.capture(a, path);
        defer after.deinit();
        try check(before.matches(after), "replacement attribute failure leaves original bytes and inode untouched");
    }
    for ([_]anyerror{ error.MetadataAccessDenied, error.MetadataIo, error.MetadataTooLarge, error.MetadataUnsupported }, 2..) |expected, kind| {
        try fault(dir, @intCast(kind));
        var model = try Model.init(a, path, dir);
        defer model.deinit();
        try check(model.read_only and model.root.?.metadata_error.? == expected and model.baseline.font_size == 19, "real errors remain diagnostic read-only views");
        model.value(.font_size).input.set("20");
        try std.testing.expectError(error.ReadOnlySetting, model.save(host.callbacks()));
    }
    try fault(dir, 8);
    try std.testing.expectError(error.MetadataUnsupported, edit.Native.capture(a, path));
    try check(true, "unsupported individual attribute reads are never accepted as an empty list");
    if (@import("builtin").os.tag == .linux) {
        try fault(dir, 10);
        try std.testing.expectError(error.MetadataAccessDenied, edit.Native.capture(a, path));
        try check(true, "ACL probe access errors are not hidden by unsupported enumeration");
    }
    try fault(dir, 0);
    if (lt_config_fixture_acl(path) != 0) return error.FixtureAcl;
    try fault(dir, 1);
    {
        var before = try edit.Native.capture(a, path);
        defer before.deinit();
        _ = try edit.Native.save(a, before, "font-size=23\n");
        var after = try edit.Native.capture(a, path);
        defer after.deinit();
        try check(std.mem.eql(u8, &before.metadata_sha256, &after.metadata_sha256) and lt_config_fixture_acl_count(path) > 0, "nonempty native ACL survives unsupported xattr enumeration");
        try check(before.identity.mode == after.identity.mode and before.identity.uid == after.identity.uid and before.identity.gid == after.identity.gid, "mode owner and group survive replacement");
    }
    std.debug.print("All settings metadata regressions passed; only owned files and hidden windows used.\n", .{});
}
