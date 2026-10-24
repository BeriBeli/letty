//! Latest-only Markdown preparation over an owned in-memory draft. Disk writes
//! are never part of this job. Four active jobs bound CPU/image work.
const std = @import("std");
const Prepared = @import("panel.zig").Prepared;
const a = std.heap.page_allocator;
var active: std.atomic.Value(usize) = .init(0);
pub const Job = struct {
    refs: std.atomic.Value(usize) = .init(1),
    done: std.atomic.Value(bool) = .init(false),
    pipe: [2]c_int,
    epoch: u64,
    revision: u64,
    kind: @import("loader.zig").Kind,
    path: []u8,
    source: []u8,
    result: ?Prepared = null,
    failure: ?anyerror = null,
    pub fn create(path: []const u8, source: []const u8, kind: @import("loader.zig").Kind, epoch: u64, revision: u64) !*Job {
        if (source.len > 2 * 1024 * 1024) return error.DraftLimit;
        if (active.fetchAdd(1, .acq_rel) >= 4) {
            _ = active.fetchSub(1, .acq_rel);
            return error.DraftWorkersBusy;
        }
        errdefer _ = active.fetchSub(1, .acq_rel);
        const owned_path = try a.dupe(u8, path);
        errdefer a.free(owned_path);
        const owned_source = try a.dupe(u8, source);
        errdefer a.free(owned_source);
        var pipe: [2]c_int = undefined;
        if (std.c.pipe(&pipe) != 0) return error.DraftNotification;
        errdefer for (pipe) |fd| {
            _ = std.c.close(fd);
        };
        for (pipe) |fd| if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) return error.DraftNotification;
        const self = try a.create(Job);
        self.* = .{ .pipe = pipe, .epoch = epoch, .revision = revision, .kind = kind, .path = owned_path, .source = owned_source };
        return self;
    }
    pub fn launch(self: *Job) !void {
        _ = self.refs.fetchAdd(1, .monotonic);
        var thread: std.c.pthread_t = undefined;
        if (std.c.pthread_create(&thread, null, run, self) != .SUCCESS) {
            self.release();
            return error.DraftWorker;
        }
        _ = std.c.pthread_detach(thread);
    }
    fn run(raw: ?*anyopaque) callconv(.c) ?*anyopaque {
        const self: *Job = @ptrCast(@alignCast(raw.?));
        self.result = Prepared.initWithPath(a, self.kind, self.source, self.path) catch |err| blk: {
            self.failure = err;
            break :blk null;
        };
        self.done.store(true, .release);
        const byte = [_]u8{1};
        while (std.c.write(self.pipe[1], &byte, 1) < 0) if (std.c.errno(@as(c_int, -1)) != .INTR) break;
        self.release();
        return null;
    }
    pub fn release(self: *Job) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        _ = active.fetchSub(1, .acq_rel);
        for (self.pipe) |fd| _ = std.c.close(fd);
        if (self.result) |*prepared| prepared.deinit();
        a.free(self.path);
        a.free(self.source);
        a.destroy(self);
    }
};
