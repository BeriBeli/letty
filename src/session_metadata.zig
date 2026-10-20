//! Event-triggered metadata worker ownership. No work is started by draw().
const std = @import("std");
const builtin = @import("builtin");
const nano = @import("nanoui");
const c = @import("platform_ffi.zig");
const timer = @import("one_shot.zig");
const native = @import("navigation/providers/native.zig");
const Session = @import("session.zig").Session;
extern "c" fn lt_millis() u64;
pub const State = struct {
    owner: ?*Session = null,
    provider: ?native.Provider = null,
    watch: c_uint = 0,
    mac_watch: ?nano.fdwatch.Watch = null,
    delay: ?timer.Handle = null,
    generation: u64 = 0,
    git: bool = false,
    ports: bool = false,
    focused: bool = false,
    pending: bool = false,
    last_start: u64 = 0,
    snapshot: ?native.Snapshot = null,
    last_error: ?anyerror = null,
    completions: usize = 0,
    last_completion: ?struct { generation: u64, git: native.State, ports: native.State } = null,
    pub fn configure(self: *State, session: *Session, git: bool, ports: bool) void {
        if (self.owner != null and self.git == git and self.ports == ports) return;
        self.owner = session;
        self.git = git;
        self.ports = ports;
        if (!git and !ports) {
            self.stop();
            return;
        }
        self.request();
    }
    pub fn setFocus(self: *State, wanted: bool) void {
        const changed = self.focused != wanted;
        self.focused = wanted;
        if (changed and wanted) self.request();
    }
    pub fn request(self: *State) void {
        const session = self.owner orelse return;
        if ((!self.git and !self.ports) or session.closing or session.eof or session.fatal or session.status != null or session.pid <= 0) return;
        self.generation +|= 1;
        self.snapshot = null; // No stale cwd/PID/flag data is displayed.
        self.pending = true;
        if (self.provider) |*provider| provider.cancel();
        self.schedule();
    }
    fn schedule(self: *State) void {
        if (!self.pending or self.delay != null) return;
        const elapsed = lt_millis() -| self.last_start;
        if (elapsed < 200) {
            self.delay = timer.start(200 - elapsed, self, delayed) catch |err| {
                self.last_error = err;
                return;
            };
        } else self.start();
    }
    fn delayed(raw: ?*anyopaque) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(raw.?));
        const handle = self.delay;
        self.delay = null;
        if (handle) |value| value.fired();
        self.start();
    }
    fn start(self: *State) void {
        const session = self.owner orelse return;
        if (!self.pending or session.closing or session.eof or session.fatal or session.status != null) return;
        const git = self.git and session.cwd.len > 0;
        if (!git and !self.ports) {
            self.pending = false;
            return;
        }
        if (self.provider == null) {
            self.provider = native.Provider.init(session.id, session.pid) catch |err| {
                self.last_error = err;
                self.pending = false;
                return;
            };
            const fd = self.provider.?.notificationFd();
            if (builtin.os.tag == .linux) {
                self.watch = c.lt_fd_watch(fd, 1 | 8 | 16, linuxReady, self);
                if (self.watch == 0) {
                    self.provider.?.deinit();
                    self.provider = null;
                    self.last_error = error.ProviderWatchUnavailable;
                    self.pending = false;
                    return;
                }
            } else self.mac_watch = nano.fdwatch.readable(fd, self, ready) catch |err| {
                self.provider.?.deinit();
                self.provider = null;
                self.last_error = err;
                self.pending = false;
                return;
            };
        }
        var path: [4096:0]u8 = @splat(0);
        @memcpy(path[0..session.cwd.len], session.cwd.text());
        const started = self.provider.?.start(.{ .generation = self.generation, .cwd = if (git) path[0..session.cwd.len :0] else null, .git = git, .ports = self.ports }) catch |err| {
            self.last_error = err;
            self.pending = false;
            return;
        };
        if (started) {
            self.last_start = lt_millis();
            self.pending = false;
        }
        // Busy: the existing worker's completion fd resumes the merged request.
    }
    fn linuxReady(_: c_int, _: c_uint, raw: ?*anyopaque) callconv(.c) c_int {
        const self: *State = @ptrCast(@alignCast(raw.?));
        ready(raw);
        return @intFromBool(self.watch != 0);
    }
    fn ready(raw: ?*anyopaque) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(raw.?));
        const session = self.owner orelse return;
        const provider = if (self.provider) |*value| value else return;
        const result = provider.drain() catch |err| {
            self.last_error = err;
            return;
        };
        if (result) |snapshot| {
            self.completions +|= 1;
            self.last_completion = .{ .generation = snapshot.generation, .git = snapshot.git_state, .ports = snapshot.ports_state };
            if (!session.closing and !session.eof and !session.fatal and session.status == null and snapshot.currentFor(session.id, self.generation)) self.snapshot = snapshot;
            self.schedule();
            session.feedback_changed = true;
            session.notify(session.notify_ctx, session.id);
        }
    }
    pub fn stop(self: *State) void {
        if (self.delay) |delay| delay.cancel();
        if (self.watch != 0) c.lt_unwatch(self.watch);
        if (self.mac_watch) |watch| watch.cancel();
        if (self.provider) |*provider| provider.deinit();
        self.* = .{};
    }
};
