const std = @import("std");
const vcs = @import("vcs.zig");
const jobs = @import("jobs.zig");
const os = @import("platform.zig");
const t = std.testing;
const a = t.allocator;
fn temporary() ![]const u8 {
    var buffer: [128]u8 = undefined;
    const name = try std.fmt.bufPrintSentinel(&buffer, "/tmp/letty-vcs-unit-XXXXXX", .{}, 0);
    const raw = os.c.mkdtemp(name.ptr) orelse return error.FixtureDirectory;
    errdefer _ = os.c.rmdir(raw);
    var canonical: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.c.realpath(raw, &canonical) orelse return error.FixtureDirectory;
    return a.dupe(u8, std.mem.span(path));
}
fn cleanup(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(t.io, path) catch {};
    a.free(path);
}
test "Changes discovers nearest Git and SVN roots and gates comparison capabilities" {
    const root = try temporary();
    defer cleanup(root);
    const svn = try std.fmt.allocPrint(a, "{s}/svn", .{root});
    defer a.free(svn);
    const nested = try std.fmt.allocPrint(a, "{s}/git", .{svn});
    defer a.free(nested);
    const metadata = try std.fmt.allocPrint(a, "{s}/.svn", .{svn});
    defer a.free(metadata);
    try os.mkdirs(a, metadata);
    try os.mkdirs(a, nested);
    const git_marker = try std.fmt.allocPrint(a, "{s}/.git", .{nested});
    defer a.free(git_marker);
    try os.atomicFile(a, git_marker, "gitdir: private-marker\n");
    var state: vcs.State = .{};
    defer state.deinit(a);
    const target: jobs.Target = .{ .window = 1, .workspace = 2, .pane = 3 };
    try state.request(a, target, nested, true);
    try t.expect(state.backend == .git and state.supportsBase(.branch));
    const owner_epoch = state.epoch;
    try state.request(a, target, nested, true);
    try t.expectEqual(owner_epoch, state.epoch);
    var other_target = target;
    other_target.pane += 1;
    try state.request(a, other_target, nested, true);
    try t.expect(state.epoch != owner_epoch);
    try state.setBase(.branch);
    const version = state.patchVersion();
    state.capture_requested = true;
    try state.request(a, target, svn, true);
    try t.expect(state.epoch != owner_epoch);
    try t.expect(state.backend == .svn and state.base() == .head and state.label().len > 0);
    try t.expectError(error.UnsupportedVcsBase, state.setBase(.branch));
    try t.expect(!state.git_state.capture and !state.capture_requested);
    try t.expect(state.patchVersion() != version);
    try state.request(a, target, root, true);
    try t.expect(state.backend == .none and !state.busy() and !state.hasData());
    try t.expectEqualStrings("No Git or SVN working copy", state.message());
}
test "Changes coalesces directory switches until old jobs are reaped and hides old results" {
    const root = try temporary();
    defer cleanup(root);
    const git_marker = try std.fmt.allocPrint(a, "{s}/.git", .{root});
    defer a.free(git_marker);
    try os.atomicFile(a, git_marker, "private marker\n");
    const svn = try std.fmt.allocPrint(a, "{s}/child", .{root});
    defer a.free(svn);
    const metadata = try std.fmt.allocPrint(a, "{s}/.svn", .{svn});
    defer a.free(metadata);
    try os.mkdirs(a, metadata);
    var state: vcs.State = .{};
    defer state.deinit(a);
    try state.request(a, .{ .window = 1, .pane = 2 }, root, true);
    state.git_state.running = true;
    const generation = state.git_state.generation;
    var pool: jobs.Pool = .{ .a = a, .wake_fd = -1 };
    defer pool.deinit();
    var job: jobs.Job = undefined;
    job = .{ .pool = &pool, .target = state.git_state.target, .status = 1, .failure = .cancelled, .output = .{ .job = &job, .limit = 4096 }, .errors = .{ .job = &job, .limit = 4096 } };
    job.target.tag = 1; // Git discovery, owned by the old directory.
    try state.request(a, .{ .window = 1, .pane = 2 }, svn, true);
    try t.expect(state.pending and state.busy() and state.backend == .svn);
    try t.expectEqualStrings("", state.root());
    try t.expectEqualStrings("", state.patch());
    try state.pump(a, &pool);
    try t.expect(state.pending);
    try state.consume(a, &job);
    try state.request(a, .{ .window = 1, .pane = 2 }, svn, true);
    try t.expect(!state.pending and state.svn_state.stage == .open);
    try t.expect(state.git_state.generation == generation and !state.git_state.running);
    try t.expectEqualStrings("", state.message());
}
test "Changes validates current membership and openability for local SVN paths" {
    var state: vcs.State = .{ .backend = .svn };
    defer state.deinit(a);
    state.svn_state.root = try a.dupe(u8, "/tmp/private-wc");
    state.svn_state.data = try vcs.svn.Data.status(a, "<status><target><entry path='file.sv'><wc-status item='modified' props='none'/></entry><entry path='gone'><wc-status item='missing' props='none'/></entry><entry path='vendor'><wc-status item='external' props='none'/></entry></target></status>");
    try t.expectError(error.VcsSelectionMissing, state.select(a, "not-listed"));
    try t.expect(state.canOpen("file.sv") and !state.canOpen("gone") and !state.canOpen("vendor"));
    const path = try state.openPath(a, "file.sv");
    defer a.free(path);
    try t.expectEqualStrings("/tmp/private-wc/file.sv", path);
    try t.expectError(error.VcsSelectionMissing, state.openPath(a, "../outside"));
    state.pending = true;
    try t.expect(state.files().len == 0 and !state.canOpen("file.sv"));
}

test "equal backend counters on distinct pane owners never reuse a diff stamp" {
    const first: vcs.State = .{ .backend = .git, .epoch = 1, .target = .{ .window = 1, .workspace = 2, .pane = 3 } };
    var second = first;
    second.target.pane = 4;
    try std.testing.expect(first.patchVersion() != second.patchVersion());
}
