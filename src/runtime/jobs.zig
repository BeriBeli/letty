//! Main-loop child jobs: bounded output/deadlines, owned PIDs and stable targets.
//! No shell command interpolation and no worker can borrow a window/pane pointer.
const std = @import("std");
const os = @import("platform.zig");
const c = os.c;
const Watch = @import("watch.zig").Watch;
extern "c" fn fork() c_int;
extern "c" fn _NSGetEnviron() *[*:null]?[*:0]u8;
pub const Target = struct { window: u64, workspace: u64 = 0, pane: u64 = 0, generation: u64 = 0, domain: enum { vcs, image } = .vcs, tag: u8 = 0 };
pub const Spec = struct { target: Target, executable: []const u8, args: []const []const u8, directory: []const u8, env: []const []const u8 = &.{}, limit: usize = 4 << 20, timeout_ms: u32 = 15000, clean_git_env: bool = false };
pub const Pool = struct {
    a: std.mem.Allocator,
    wake_fd: c_int,
    jobs: std.ArrayList(*Job) = .empty,
    pub const max_active = 4;
    pub fn launch(self: *Pool, spec: Spec) !void {
        if (self.jobs.items.len >= max_active) return error.BackgroundBusy;
        try self.jobs.ensureUnusedCapacity(self.a, 1);
        const job = try Job.create(self, spec);
        self.jobs.appendAssumeCapacity(job);
    }
    pub fn reap(self: *Pool) void {
        for (self.jobs.items) |job| job.reap();
    }
    pub fn take(self: *Pool) ?*Job {
        for (self.jobs.items, 0..) |job, i| if (job.complete()) return self.jobs.orderedRemove(i);
        return null;
    }
    pub fn cancelImage(self: *Pool, window: u64) void {
        for (self.jobs.items) |job| if (job.target.domain == .image and job.target.window == window) job.cancel(.cancelled);
    }
    pub fn cancelPane(self: *Pool, pane: u64) void {
        for (self.jobs.items) |job| if (job.target.pane == pane) job.cancel(.cancelled);
    }
    pub fn deinit(self: *Pool) void {
        for (self.jobs.items) |job| job.destroy();
        self.jobs.deinit(self.a);
    }
};
pub const Job = struct {
    pool: *Pool,
    target: Target,
    pid: c_int = -1,
    status: ?i32 = null,
    failure: ?Failure = null,
    output: Channel,
    errors: Channel,
    deadline: ?*Watch = null,
    reported: bool = false,
    pub const Failure = enum { cancelled, timeout, output_limit, read_failed };
    const Channel = struct {
        job: *Job,
        fd: c_int = -1,
        watch: ?*Watch = null,
        bytes: std.ArrayList(u8) = .empty,
        limit: usize,
        fn stop(self: *Channel) void {
            if (self.watch) |watch| watch.cancel();
            self.watch = null;
            if (self.fd >= 0) _ = c.close(self.fd);
            self.fd = -1;
        }
        fn ready(raw: ?*anyopaque) callconv(.c) void {
            const self: *Channel = @ptrCast(@alignCast(raw.?));
            var budget: usize = 65536;
            var buffer: [8192]u8 = undefined;
            while (budget > 0 and self.fd >= 0) {
                const n = c.read(self.fd, &buffer, @min(buffer.len, budget));
                if (n < 0) {
                    if (os.errNo() == c.EINTR) continue;
                    if (os.errNo() == c.EAGAIN) break;
                    self.job.cancel(.read_failed);
                    break;
                }
                if (n == 0) {
                    self.stop();
                    break;
                }
                const length: usize = @intCast(n);
                if (length > self.limit -| self.bytes.items.len) {
                    self.job.cancel(.output_limit);
                    break;
                }
                self.bytes.appendSlice(self.job.pool.a, buffer[0..length]) catch {
                    self.job.cancel(.output_limit);
                    break;
                };
                budget -= length;
            }
            self.job.report();
        }
    };
    fn create(pool: *Pool, spec: Spec) !*Job {
        if (spec.limit > 8 << 20 or spec.timeout_ms == 0 or spec.timeout_ms > 60000 or spec.args.len > 256 or !std.fs.path.isAbsolute(spec.directory)) return error.InvalidJob;
        const a = pool.a;
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const ta = arena.allocator();
        const executable = try resolve(ta, spec.executable);
        const directory = try ta.dupeSentinel(u8, spec.directory, 0);
        var args: std.ArrayList(?[*:0]const u8) = .empty;
        try args.append(ta, executable.ptr);
        var arg_bytes: usize = 0;
        for (spec.args) |arg| {
            arg_bytes += arg.len;
            if (arg_bytes > 65536 or std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidJob;
            try args.append(ta, (try ta.dupeSentinel(u8, arg, 0)).ptr);
        }
        try args.append(ta, null);
        var environment: std.ArrayList(?[*:0]const u8) = .empty;
        const inherited = if (@import("builtin").os.tag == .macos) _NSGetEnviron().* else std.c.environ;
        var i: usize = 0;
        while (inherited[i]) |entry| : (i += 1) {
            const value = std.mem.span(entry);
            if (spec.clean_git_env and std.mem.startsWith(u8, value, "GIT_")) continue;
            const at = std.mem.indexOfScalar(u8, value, '=') orelse continue;
            var replaced = false;
            for (spec.env) |replacement| if (replacement.len > at and replacement[at] == '=' and std.mem.eql(u8, replacement[0..at], value[0..at])) {
                replaced = true;
                break;
            };
            if (!replaced) try environment.append(ta, entry);
        }
        for (spec.env) |entry| {
            if (std.mem.indexOfScalar(u8, entry, '=') == null or std.mem.indexOfScalar(u8, entry, 0) != null) return error.InvalidJob;
            try environment.append(ta, (try ta.dupeSentinel(u8, entry, 0)).ptr);
        }
        try environment.append(ta, null);
        const self = try a.create(Job);
        self.* = .{ .pool = pool, .target = spec.target, .output = .{ .job = self, .limit = spec.limit }, .errors = .{ .job = self, .limit = 32768 } };
        errdefer self.destroy();
        var output: [2]c_int = .{ -1, -1 };
        var errors: [2]c_int = .{ -1, -1 };
        defer for (output ++ errors) |fd| if (fd >= 0) {
            _ = c.close(fd);
        };
        if (c.pipe(&output) != 0 or c.pipe(&errors) != 0) return error.JobPipe;
        for (output ++ errors) |fd| try os.cloexec(fd);
        const input = c.open("/dev/null", c.O_RDONLY | c.O_CLOEXEC);
        if (input < 0) return error.JobPipe;
        defer _ = c.close(input);
        const pid = fork();
        if (pid < 0) return error.SpawnJob;
        if (pid == 0) {
            // Only async-signal-safe OS calls between fork and exec. All strings,
            // argv and environment storage were prepared on the parent thread.
            _ = std.c.setpgid(0, 0);
            if (c.chdir(directory.ptr) != 0 or std.c.dup2(input, 0) < 0 or std.c.dup2(output[1], 1) < 0 or std.c.dup2(errors[1], 2) < 0) c._exit(126);
            _ = std.c.execve(executable.ptr, @ptrCast(args.items.ptr), @ptrCast(environment.items.ptr));
            c._exit(127);
        }
        self.pid = pid;
        _ = std.c.setpgid(pid, pid);
        _ = c.close(output[1]);
        output[1] = -1;
        _ = c.close(errors[1]);
        errors[1] = -1;
        self.output.fd = output[0];
        output[0] = -1;
        self.errors.fd = errors[0];
        errors[0] = -1;
        try os.nonblock(self.output.fd);
        try os.nonblock(self.errors.fd);
        self.output.watch = try Watch.create(self.output.fd, false, &self.output, Channel.ready);
        self.errors.watch = try Watch.create(self.errors.fd, false, &self.errors, Channel.ready);
        self.deadline = try Watch.timer(spec.timeout_ms, self, expired);
        return self;
    }
    fn expired(raw: ?*anyopaque) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(raw.?));
        if (self.deadline) |watch| watch.cancel();
        self.deadline = null;
        self.cancel(.timeout);
    }
    pub fn cancel(self: *Job, reason: Failure) void {
        self.failure = reason;
        if (self.pid > 0) {
            _ = c.kill(-self.pid, c.SIGKILL);
            _ = c.kill(self.pid, c.SIGKILL);
        }
        self.output.stop();
        self.errors.stop();
        self.reap();
        self.report();
    }
    fn reap(self: *Job) void {
        if (self.pid <= 0) return;
        var status: c_int = 0;
        if (c.waitpid(self.pid, &status, c.WNOHANG) != self.pid) return;
        self.pid = -1;
        self.status = if (status & 0x7f == 0) (status >> 8) & 255 else 128 + (status & 0x7f);
        self.report();
    }
    pub fn complete(self: *const Job) bool {
        return self.status != null and self.output.fd < 0 and self.errors.fd < 0;
    }
    pub fn ok(self: *const Job) bool {
        return self.complete() and self.failure == null and self.status.? == 0;
    }
    fn report(self: *Job) void {
        if (!self.complete() or self.reported) return;
        self.reported = true;
        if (self.deadline) |watch| watch.cancel();
        self.deadline = null;
        const byte = [_]u8{1};
        _ = c.write(self.pool.wake_fd, &byte, 1);
    }
    pub fn destroy(self: *Job) void {
        if (self.deadline) |watch| watch.cancel();
        self.output.stop();
        self.errors.stop();
        if (self.pid > 0) {
            _ = c.kill(-self.pid, c.SIGKILL);
            _ = c.kill(self.pid, c.SIGKILL);
            var status: c_int = 0;
            while (c.waitpid(self.pid, &status, 0) < 0 and os.errNo() == c.EINTR) {}
        }
        self.output.bytes.deinit(self.pool.a);
        self.errors.bytes.deinit(self.pool.a);
        self.pool.a.destroy(self);
    }
};
pub fn resolve(a: std.mem.Allocator, executable: []const u8) ![:0]const u8 {
    if (std.mem.indexOfScalar(u8, executable, 0) != null) return error.InvalidExecutable;
    if (std.fs.path.isAbsolute(executable)) {
        const path = try a.dupeSentinel(u8, executable, 0);
        if (std.c.access(path.ptr, 1) == 0) return path;
        a.free(path);
        return error.ExecutableNotFound;
    }
    if (std.mem.indexOfScalar(u8, executable, '/') != null) return error.InvalidExecutable;
    var paths = std.mem.splitScalar(u8, os.env("PATH") orelse "/usr/bin:/bin", ':');
    while (paths.next()) |directory| {
        if (!std.fs.path.isAbsolute(directory)) continue;
        const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ directory, executable }, 0);
        if (std.c.access(path.ptr, 1) == 0) return path;
        a.free(path);
    }
    return error.ExecutableNotFound;
}
