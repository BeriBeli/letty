//! Local csh directory fallback, sampled after output, never from draw or idle.
const std = @import("std");
const c = @import("platform_ffi.zig");
const timer = @import("one_shot.zig");
const Session = @import("session.zig").Session;
const titles = @import("terminal_title.zig");
pub const State = struct {
    owner: ?*Session = null,
    session_id: u64 = 0,
    shell_group: c_int = 0,
    delay: ?timer.Handle = null,
    last_read: u64 = 0,

    pub fn configure(self: *State, session: *Session, shell: []const u8, command: []const u8) void {
        self.stop();
        if (!titles.trackLocalDirectory(shell, command)) return;
        self.owner = session;
        self.session_id = session.id;
        self.request();
    }
    fn live(self: *const State) bool {
        const session = self.owner orelse return false;
        return session.id == self.session_id and !session.closing and !session.eof and
            !session.fatal and session.status == null and session.fd >= 0 and session.events.pwd == 0;
    }
    pub fn request(self: *State) void {
        if (!self.live() or self.delay != null) return;
        // Coalesce prompt bursts and bound queries to five per second even
        // during sustained output. A callback never schedules another sample.
        const elapsed = c.lt_millis() -| self.last_read;
        self.delay = timer.start(@max(25, 200 -| elapsed), self, ready) catch null;
    }
    fn ready(raw: ?*anyopaque) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(raw.?));
        const handle = self.delay;
        self.delay = null;
        if (handle) |value| value.fired();
        if (!self.live()) return;
        const session = self.owner.?;
        self.last_read = c.lt_millis();
        const foreground = c.lt_foreground_group(session.fd);
        if (foreground <= 0 or (self.shell_group != 0 and foreground != self.shell_group)) return;
        var name: [256]u8 = @splat(0);
        var path: [4096]u8 = @splat(0);
        const group = c.lt_foreground_process(session.fd, &name, name.len, &path, path.len);
        // A foreground editor, SSH client or other job must not replace the
        // shell directory. Recheck the foreground group before publishing.
        if (group != foreground or group != c.lt_foreground_group(session.fd) or
            !titles.trackLocalDirectory(std.mem.sliceTo(&name, 0), "")) return;
        const decoded = @import("cwd.zig").decode(std.mem.sliceTo(&path, 0)) orelse return;
        const cwd = decoded.path[0..decoded.len];
        self.shell_group = group;
        if (std.mem.eql(u8, cwd, session.cwd.text())) return;
        session.cwd.set(cwd);
        session.feedback_changed = true;
        session.metadata.request();
        session.notify(session.notify_ctx, session.id);
    }
    pub fn stop(self: *State) void {
        if (self.delay) |delay| delay.cancel();
        self.* = .{};
    }
};
