//! Detached bounded jobs own every byte; completion wakes the UI through a pipe.
const std = @import("std");
const Editor = @import("editor.zig").Editor;
const disk = @import("../../config_edit.zig");
const a = std.heap.page_allocator;
var active: std.atomic.Value(usize) = .init(0);
pub const Job = struct {
    refs: std.atomic.Value(usize) = .init(1),
    done: std.atomic.Value(bool) = .init(false),
    pipe: [2]c_int,
    path: []u8,
    editor: ?*Editor,
    output: ?[]u8 = null,
    saved: ?disk.Snapshot = null,
    baseline: ?[]u8 = null,
    saving: bool,
    failure: ?anyerror = null,
    directory_synced: bool = true,
    pub fn create(path: []const u8, editor: ?*Editor) !*Job {
        if (active.fetchAdd(1, .acq_rel) >= 4) {
            _ = active.fetchSub(1, .acq_rel);
            return error.EditorBusy;
        }
        errdefer _ = active.fetchSub(1, .acq_rel);
        const owned = try a.dupe(u8, path);
        errdefer a.free(owned);
        const output = if (editor) |e| try e.encoded() else null;
        errdefer if (output) |bytes| a.free(bytes);
        const baseline = if (editor) |e| try a.dupe(u8, e.buffer.text) else null;
        errdefer if (baseline) |bytes| a.free(bytes);
        var pipe: [2]c_int = undefined;
        if (std.c.pipe(&pipe) != 0) return error.EditorNotification;
        errdefer {
            _ = std.c.close(pipe[0]);
            _ = std.c.close(pipe[1]);
        }
        for (pipe) |fd| if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) return error.EditorNotification;
        const job = try a.create(Job);
        errdefer a.destroy(job);
        job.* = .{ .pipe = pipe, .path = owned, .editor = editor, .output = output, .baseline = baseline, .saving = editor != null };
        if (editor) |e| e.retain();
        errdefer if (editor) |e| e.release();
        return job;
    }
    pub fn launch(self: *Job) !void {
        _ = self.refs.fetchAdd(1, .monotonic);
        var thread: std.c.pthread_t = undefined;
        if (std.c.pthread_create(&thread, null, run, self) != .SUCCESS) {
            self.release();
            return error.EditorWorker;
        }
        _ = std.c.pthread_detach(thread);
    }
    pub fn start(path: []const u8, editor: ?*Editor) !*Job {
        const job = try create(path, editor);
        errdefer job.release();
        try job.launch();
        return job;
    }
    fn work(self: *Job) !void {
        if (self.saving) {
            // Resolve the original requested path again, detecting parent changes.
            var latest = try disk.Native.captureWithLimit(a, self.path, @import("editor.zig").limit);
            defer latest.deinit();
            if (!self.editor.?.original.matches(latest)) return error.ConcurrentChange;
            const result = try disk.Native.save(a, self.editor.?.original, self.output.?);
            self.directory_synced = result.directory_synced;
            var saved = try disk.Native.captureWithLimit(a, self.path, @import("editor.zig").limit);
            errdefer saved.deinit();
            if (!std.mem.eql(u8, saved.bytes, self.output.?)) return error.SavedButFileChangedAgain;
            self.saved = saved;
        } else self.editor = try Editor.capture(self.path);
    }
    fn run(raw: ?*anyopaque) callconv(.c) ?*anyopaque {
        const self: *Job = @ptrCast(@alignCast(raw.?));
        self.work() catch |err| {
            self.failure = err;
        };
        self.done.store(true, .release);
        const byte = [_]u8{1};
        while (std.c.write(self.pipe[1], &byte, 1) < 0) {
            if (std.c.errno(@as(c_int, -1)) != .INTR) break;
        }
        self.release();
        return null;
    }
    pub fn release(self: *Job) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        _ = active.fetchSub(1, .acq_rel);
        _ = std.c.close(self.pipe[0]);
        _ = std.c.close(self.pipe[1]);
        if (self.editor) |e| e.release();
        if (self.output) |bytes| a.free(bytes);
        if (self.saved) |*snapshot| snapshot.deinit();
        if (self.baseline) |bytes| a.free(bytes);
        a.free(self.path);
        a.destroy(self);
    }
};
