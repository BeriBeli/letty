//! Private disposable repositories only. No command operates on the checkout.
const std = @import("std");
const nano = @import("nanoui");
const os = @import("platform.zig");
const jobs = @import("jobs.zig");
const git = @import("git.zig");
const A = std.mem.Allocator;
const fixture_env = &[_][]const u8{ "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null", "GIT_AUTHOR_NAME=Letty Fixture", "GIT_AUTHOR_EMAIL=fixture@invalid", "GIT_COMMITTER_NAME=Letty Fixture", "GIT_COMMITTER_EMAIL=fixture@invalid" };
fn check(ok: bool, label: []const u8) !void {
    if (!ok) {
        os.diagnostic("FAIL UI ");
        os.diagnostic(label);
        os.diagnostic("\n");
        return error.GitFixtureFailed;
    }
    try os.output("PASS UI ");
    try os.output(label);
    try os.output("\n");
}
fn drain(fd: c_int) void {
    var bytes: [256]u8 = undefined;
    while (os.c.read(fd, &bytes, bytes.len) > 0) {}
}
fn wait(pool: *jobs.Pool) !*jobs.Job {
    const deadline = os.millis() + 5000;
    while (os.millis() < deadline) {
        pool.reap();
        if (pool.take()) |job| return job;
        nano.runFor(0.01);
    }
    return error.FixtureDeadline;
}
fn command(pool: *jobs.Pool, directory: []const u8, args: []const []const u8) !void {
    try pool.launch(.{ .target = .{ .window = 0 }, .executable = "git", .args = args, .directory = directory, .env = fixture_env, .clean_git_env = true });
    const job = try wait(pool);
    defer job.destroy();
    if (!job.ok()) {
        os.diagnostic(job.errors.bytes.items);
        return error.GitFixtureCommand;
    }
}
pub fn run(a: A, directory: []const u8) !git.State {
    var pipe: [2]c_int = undefined;
    if (os.c.pipe(&pipe) != 0) return error.FixturePipe;
    defer for (pipe) |fd| {
        _ = os.c.close(fd);
    };
    for (pipe) |fd| {
        try os.cloexec(fd);
        try os.nonblock(fd);
    }
    var pool: jobs.Pool = .{ .a = a, .wake_fd = pipe[1] };
    defer pool.deinit();
    for (0..jobs.Pool.max_active) |_| try pool.launch(.{ .target = .{ .window = 0 }, .executable = "/bin/sh", .args = &.{ "-c", "printf OUT; printf ERR >&2" }, .directory = directory });
    const busy = pool.launch(.{ .target = .{ .window = 0 }, .executable = "/bin/sh", .args = &.{ "-c", "exit 99" }, .directory = directory });
    if (busy) |_| return error.JobLimit else |err| if (err != error.BackgroundBusy) return err;
    var captured = true;
    for (0..jobs.Pool.max_active) |_| {
        const job = try wait(&pool);
        defer job.destroy();
        captured = captured and job.ok() and std.mem.eql(u8, job.output.bytes.items, "OUT") and std.mem.eql(u8, job.errors.bytes.items, "ERR");
    }
    try check(captured, "background job slots are bounded and capture owned stdout and stderr");
    try pool.launch(.{ .target = .{ .window = 0 }, .executable = "/bin/sh", .args = &.{ "-c", "sleep 10" }, .directory = directory, .timeout_ms = 50 });
    {
        const job = try wait(&pool);
        defer job.destroy();
        try check(job.failure == .timeout and job.pid <= 0, "job deadlines terminate and reap only their owned process group");
    }
    try pool.launch(.{ .target = .{ .window = 0, .pane = 42 }, .executable = "/bin/sh", .args = &.{ "-c", "sleep 10" }, .directory = directory });
    pool.cancelPane(42);
    {
        const job = try wait(&pool);
        defer job.destroy();
        try check(job.failure == .cancelled and job.pid <= 0, "closing a target cancels its jobs without retaining a pane pointer");
    }
    try pool.launch(.{ .target = .{ .window = 0 }, .executable = "/bin/sh", .args = &.{ "-c", "printf '0123456789012345678901234567890123456789'" }, .directory = directory, .limit = 8 });
    {
        const job = try wait(&pool);
        defer job.destroy();
        try check(job.failure == .output_limit and job.output.bytes.items.len <= 8, "child output limit fails without unbounded buffers");
    }
    drain(pipe[0]);
    const repo = try std.fmt.allocPrint(a, "{s}/private-git-fixture", .{directory});
    defer a.free(repo);
    try os.mkdirs(a, repo);
    try command(&pool, repo, &.{ "-c", "init.defaultBranch=main", "init", "-q" });
    const file = try std.fmt.allocPrint(a, "{s}/tracked.txt", .{repo});
    defer a.free(file);
    try os.atomicFile(a, file, "before\n");
    const old = try std.fmt.allocPrintSentinel(a, "{s}/old name.txt", .{repo}, 0);
    defer a.free(old);
    try os.atomicFile(a, old, "rename fixture\n");
    try command(&pool, repo, &.{ "add", "--all" });
    try command(&pool, repo, &.{ "commit", "-q", "-m", "private fixture" });
    try os.atomicFile(a, file, "staged\n");
    try command(&pool, repo, &.{ "add", "--", "tracked.txt" });
    try os.atomicFile(a, file, "working\n");
    const renamed = try std.fmt.allocPrintSentinel(a, "{s}/new name.txt", .{repo}, 0);
    defer a.free(renamed);
    if (os.c.rename(old.ptr, renamed.ptr) != 0) return error.RenameFixture;
    const untracked = try std.fmt.allocPrint(a, "{s}/untracked 空格.txt", .{repo});
    defer a.free(untracked);
    try os.atomicFile(a, untracked, "one\ntwo\n");
    const binary = try std.fmt.allocPrint(a, "{s}/binary.bin", .{repo});
    defer a.free(binary);
    try os.atomicFile(a, binary, "\x00binary");
    const index = try std.fmt.allocPrint(a, "{s}/.git/index", .{repo});
    defer a.free(index);
    const before = try os.readFile(a, index, 1 << 20);
    defer a.free(before);
    var state: git.State = .{};
    errdefer state.deinit(a);
    try state.request(a, .{ .window = 0 }, repo, true);
    try finish(a, &pool, &state);
    const after = try os.readFile(a, index, 1 << 20);
    defer a.free(after);
    try check(std.mem.eql(u8, before, after) and state.temporary.len == 0, "Git snapshots preserve the real index and remove their private temporary index");
    var rename_ok = false;
    var binary_ok = false;
    var untracked_ok = false;
    for (state.data.?.files.items) |entry| {
        if (std.mem.eql(u8, entry.path, "new name.txt")) rename_ok = std.mem.eql(u8, entry.old_path, "old name.txt");
        if (std.mem.eql(u8, entry.path, "binary.bin")) binary_ok = entry.binary;
        if (std.mem.eql(u8, entry.path, "untracked 空格.txt")) untracked_ok = entry.added == 2;
    }
    try check(rename_ok and binary_ok and untracked_ok, "Git review includes Unicode untracked paths, renames and binary files");
    try state.select(a, "tracked.txt");
    try finish(a, &pool, &state);
    try check(std.mem.indexOf(u8, state.patch, "+working") != null and std.mem.indexOf(u8, state.patch, "+staged") == null, "Git patches compare the current working file rather than the staged version");
    try command(&pool, repo, &.{ "checkout", "-q", "-b", "feature" });
    state.base = .branch;
    try state.request(a, .{ .window = 0 }, repo, true);
    try finish(a, &pool, &state);
    try check(state.revision.len == 40 or state.revision.len == 64, "branch review resolves the native Git merge base");
    state.base = .head;
    return state;
}
fn finish(a: A, pool: *jobs.Pool, state: *git.State) !void {
    const deadline = os.millis() + 15000;
    while (os.millis() < deadline) {
        try state.pump(a, pool);
        pool.reap();
        if (pool.take()) |job| {
            defer job.destroy();
            try state.consume(a, job);
        }
        if (state.stage == .idle and !state.running and !state.dirty and pool.jobs.items.len == 0) {
            if (state.message.len > 0) {
                os.diagnostic(state.message);
                return error.GitFixtureRead;
            }
            return;
        }
        nano.runFor(0.01);
    }
    return error.FixtureDeadline;
}
