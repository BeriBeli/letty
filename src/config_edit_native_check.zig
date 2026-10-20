//! Real owned-tempfile IO only. No user configs, windows, defaults or clipboard.
const std = @import("std");
const c = std.c;
const edit = @import("config_edit.zig");
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn symlink([*:0]const u8, [*:0]const u8) c_int;
extern "c" fn mkfifo([*:0]const u8, c.mode_t) c_int;
extern "c" fn chmod([*:0]const u8, c.mode_t) c_int;
extern "c" fn lt_config_fixture_write([*:0]const u8, [*]const u8, usize, c_uint) c_int;
extern "c" fn lt_config_fixture_xattr([*:0]const u8, [*:0]const u8) c_int;
extern "c" fn lt_config_fixture_acl([*:0]const u8) c_int;
extern "c" fn lt_config_fixture_acl_variant([*:0]const u8, c_int) c_int;
extern "c" fn lt_config_fixture_acl_count([*:0]const u8) c_int;
extern "c" fn lt_config_edit_metadata(c_int, [*]u8, usize, *usize) c_int;
var checks: usize = 0;
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} CONFIG EDIT NATIVE {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.NativeConfigEditCheck;
    checks += 1;
}
fn write(path: [:0]const u8, bytes: []const u8) !void {
    if (lt_config_fixture_write(path, bytes.ptr, bytes.len, 0o640) != 0) return error.FixtureWrite;
}
fn equalDigest(a: edit.Digest, b: edit.Digest) bool {
    return std.mem.eql(u8, &a, &b);
}
fn unchanged(a: std.mem.Allocator, path: []const u8, expected: edit.Snapshot) !bool {
    var next = try edit.Native.capture(a, path);
    defer next.deinit();
    return expected.matches(next);
}
const SyncFault = struct {
    called: bool = false,
    real_ebadf: bool = false,
    fn run(raw: ?*anyopaque, fd: c_int) bool {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.called = fd >= 0;
        self.real_ebadf = c.fsync(-1) == -1 and std.c.errno(@as(c_int, -1)) == .BADF;
        return false;
    }
};
pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const pattern = try a.dupeSentinel(u8, ".cache/config-edit-native-XXXXXX", 0);
    defer a.free(pattern);
    const folder = mkdtemp(pattern) orelse return error.TempDirectory;
    defer _ = c.rmdir(folder);
    const file = try std.fmt.allocPrintSentinel(a, "{s}/config", .{std.mem.span(folder)}, 0);
    defer a.free(file);
    defer _ = c.unlink(file);
    const alias = try std.fmt.allocPrintSentinel(a, "{s}/alias", .{std.mem.span(folder)}, 0);
    defer a.free(alias);
    defer _ = c.unlink(alias);
    const fifo = try std.fmt.allocPrintSentinel(a, "{s}/fifo", .{std.mem.span(folder)}, 0);
    defer a.free(fifo);
    defer _ = c.unlink(fifo);
    const source = "# keep CRLF\r\nfuture-key=verbatim\r\ntheme = paper\r\n";
    try write(file, source);
    {
        var ordinary = try edit.Native.capture(a, file);
        defer ordinary.deinit();
        _ = try edit.Native.save(a, ordinary, "theme=plain\n");
        var plain = try edit.Native.capture(a, file);
        defer plain.deinit();
        try check(equalDigest(ordinary.metadata_sha256, plain.metadata_sha256) and std.mem.eql(u8, plain.bytes, "theme=plain\n"), "ordinary file without an extended ACL survives atomic replacement with identical metadata");
        try write(file, source);
    }
    if (lt_config_fixture_xattr(file, "owned-xattr-中") != 0 or lt_config_fixture_acl(file) != 0) return error.FixtureMetadataUnsupported;
    try check(lt_config_fixture_acl_count(file) > 0, "fixture installs an actual nonempty native ACL");
    var original = try edit.Native.capture(a, file);
    defer original.deinit();
    const output = try edit.replaceTheme(a, original.bytes, "Night 中");
    defer a.free(output);
    const saved = try edit.Native.save(a, original, output);
    var after = try edit.Native.capture(a, file);
    defer after.deinit();
    try check(std.mem.eql(u8, after.bytes, output) and after.identity.inode != original.identity.inode, "atomic replacement writes exact bytes through a different inode");
    try check((after.identity.mode & 0o7777) == (original.identity.mode & 0o7777) and after.identity.uid == original.identity.uid and after.identity.gid == original.identity.gid, "atomic save preserves mode uid and gid");
    try check(equalDigest(after.metadata_sha256, original.metadata_sha256) and lt_config_fixture_acl_count(file) > 0, "all real extended attributes and ACL survive replacement byte exactly");
    try check(saved.directory_synced, "native parent directory fsync confirms successful save durability");

    try write(file, "theme=external\n");
    try std.testing.expectError(error.ConcurrentChange, edit.Native.save(a, after, output));
    var external = try edit.Native.capture(a, file);
    defer external.deinit();
    try check(std.mem.eql(u8, external.bytes, "theme=external\n"), "concurrent content edit is rejected without overwriting external bytes");
    if (lt_config_fixture_xattr(file, "changed-metadata") != 0) return error.FixtureMetadata;
    try std.testing.expectError(error.ConcurrentChange, edit.Native.save(a, external, output));
    var changed = try edit.Native.capture(a, file);
    defer changed.deinit();
    try check(!equalDigest(external.metadata_sha256, changed.metadata_sha256) and try unchanged(a, file, changed), "concurrent xattr change is rejected and remains untouched");
    if (chmod(file, 0o600) != 0) return error.FixtureMode;
    try std.testing.expectError(error.ConcurrentChange, edit.Native.save(a, changed, output));
    var mode_changed = try edit.Native.capture(a, file);
    defer mode_changed.deinit();
    try check((mode_changed.identity.mode & 0o7777) == 0o600, "concurrent permission change is rejected with its new mode intact");
    if (lt_config_fixture_acl_variant(file, 1) != 0) return error.FixtureMetadata;
    try std.testing.expectError(error.ConcurrentChange, edit.Native.save(a, mode_changed, output));
    var with_acl = try edit.Native.capture(a, file);
    defer with_acl.deinit();
    try check(!equalDigest(mode_changed.metadata_sha256, with_acl.metadata_sha256) and try unchanged(a, file, with_acl), "concurrent ACL permission change is rejected without dropping or altering the new ACL");
    if (symlink(with_acl.path, alias) != 0) return error.FixtureSymlink;
    var via_alias = try edit.Native.capture(a, alias);
    defer via_alias.deinit();
    try check(std.mem.eql(u8, via_alias.path, with_acl.path), "symlink capture binds the physical root target");
    _ = try edit.Native.save(a, via_alias, output);
    var link_text: [4096]u8 = undefined;
    const link_len = c.readlink(alias, &link_text, link_text.len);
    try check(link_len > 0 and std.mem.eql(u8, link_text[0..@intCast(link_len)], via_alias.path), "saving physical root preserves the user's symlink inode and target");
    if (mkfifo(fifo, 0o600) != 0) return error.FixtureFifo;
    try std.testing.expectError(error.NotRegularFile, edit.Native.capture(a, fifo));
    try check(true, "FIFO capture refuses without opening a blocking stream");

    var before_failure = try edit.Native.capture(a, file);
    defer before_failure.deinit();
    const fd = c.open(before_failure.path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true });
    if (fd < 0) return error.FixtureOpen;
    defer _ = c.close(fd);
    var tiny: [1]u8 = undefined;
    var length: usize = 0;
    try check(lt_config_edit_metadata(fd, &tiny, tiny.len, &length) < 0 and std.c.errno(@as(c_int, -1)) == .@"2BIG" and try unchanged(a, file, before_failure), "bounded native metadata refusal happens before any file replacement");
    if (chmod(folder, 0o500) != 0) return error.FixtureMode;
    const failed = edit.Native.save(a, before_failure, "theme=denied\n");
    const restored = chmod(folder, 0o700);
    if (restored != 0) return error.FixtureMode;
    if (failed) |_| return error.ExpectedPermissionFailure else |err| try std.testing.expect(err == error.AccessDenied);
    try check(try unchanged(a, file, before_failure), "actual pre-rename permission failure preserves entire original inode bytes and metadata");
    var fault: SyncFault = .{};
    const committed = try edit.Native.saveWithOptions(a, before_failure, "theme=committed\n", .{ .context = &fault, .sync_directory = SyncFault.run });
    var final = try edit.Native.capture(a, file);
    defer final.deinit();
    try check(!committed.directory_synced and fault.called and fault.real_ebadf and std.mem.eql(u8, final.bytes, "theme=committed\n"), "post-rename sync failure is injected EBADF and reports committed bytes without an unchanged error");
    try check(equalDigest(final.metadata_sha256, before_failure.metadata_sha256), "post-commit durability warning retains exact ACL and xattrs");
    std.debug.print("All {d} native config edit checks passed. No windows or user files; directory-sync failure explicitly injected.\n", .{checks});
}
