const std = @import("std");
const vt_api = @import("vt.zig");
const c = @import("platform_ffi.zig");
const Queue = @import("queue.zig").Queue;
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const reserve = 64 * 1024;
pub const Session = struct {
    id: u64,
    gpa: std.mem.Allocator,
    vt: *vt_api.Vt,
    fd: c_int = -1,
    pid: c_int = 0,
    shell_group: c_int = 0,
    // Launch identity only. A command override may be a remote/TUI program,
    // so its input grammar must never be inferred from the wrapper shell.
    drop_shell: @import("drop_paths.zig").Shell = .unknown,
    metadata: @import("session_metadata.zig").State = .{},
    cols: u16 = 80,
    rows: u16 = 24,
    cell_w: u32 = 0,
    cell_h: u32 = 0,
    read_watch: c_uint = 0,
    write_watch: c_uint = 0,
    child_watch: c_uint = 0,
    mac_read: ?nanoui.fdwatch.Watch = null,
    mac_child: ?nanoui.fdwatch.Watch = null,
    status: ?c_int = null,
    eof: bool = false,
    closing: bool = false,
    fatal: bool = false,
    tx: Queue,
    notify_ctx: ?*anyopaque,
    notify: *const fn (?*anyopaque, u64) void,
    title: [256]u8 = undefined,
    title_len: usize = 0,
    initial_title: @import("fixed_text.zig").Text(256) = .{},
    events: vt_api.Events = .{},
    cwd: @import("fixed_text.zig").Text(4096) = .{},
    integrated: bool = false,
    /// Explicit commands (including SSH profiles) may print non-local paths.
    explicit_command: bool = false,
    /// Monotonic count of bytes admitted by enqueue (input, mouse and focus
    /// reports); lets checks prove an interaction wrote nothing to the PTY.
    admitted_bytes: u64 = 0,
    command_pending: bool = false,
    command_running: bool = false,
    attention: enum { none, bell, done, failed } = .none,
    feedback_changed: bool = false,
    focus_sent: ?bool = null,
    focus_sink: ?struct { ctx: *anyopaque, call: *const fn (*anyopaque, u64, []const u8) void } = null,

    pub fn create(a: std.mem.Allocator, io: std.Io, id: u64, shell: [:0]const u8, command: [:0]const u8, cwd: [:0]const u8, integrate: bool, lines: usize, bytes: usize, ctx: ?*anyopaque, notify: *const fn (?*anyopaque, u64) void) !*Session {
        const s = try a.create(Session);
        errdefer a.destroy(s);
        s.* = .{ .id = id, .gpa = a, .vt = undefined, .tx = try Queue.init(a, 1024 * 1024 + reserve), .notify_ctx = ctx, .notify = notify };
        s.drop_shell = @import("drop_paths.zig").classifyShell(shell, command);
        s.explicit_command = command.len > 0;
        errdefer s.tx.deinit(a);
        s.vt = try vt_api.create(a, io, 80, 24, lines, bytes, reply, s);
        errdefer vt_api.destroy(s.vt);
        s.fd = c.lt_spawn_integrated(shell, command, cwd, 80, 24, &s.pid, integrate, &s.integrated);
        if (s.fd < 0) return error.PtySpawn;
        s.initial_title.set(if (command.len > 0) command else std.fs.path.basename(shell));
        errdefer {
            if (s.child_watch != 0) c.lt_unwatch(s.child_watch);
            if (s.mac_child) |w| w.cancel();
            c.lt_close(s.fd);
            c.lt_signal(s.pid, 9);
            reap(s.pid);
        }
        if (builtin.os.tag == .linux) {
            s.child_watch = c.lt_child_watch(s.pid, childExited, s);
            if (s.child_watch == 0) return error.ChildWatch;
        } else s.mac_child = try nanoui.fdwatch.exited(s.pid, s, macExited);
        try s.startRead();
        return s;
    }
    fn startRead(s: *Session) !void {
        if (s.eof or s.closing or s.fd < 0) return;
        if (builtin.os.tag == .linux) {
            if (s.read_watch == 0) {
                s.read_watch = c.lt_fd_watch(s.fd, 1 | 8 | 16, readable, s);
                if (s.read_watch == 0) return error.FdWatch;
            }
        } else if (s.mac_read == null) s.mac_read = try nanoui.fdwatch.readable(s.fd, s, macReadable);
    }
    fn pauseRead(s: *Session) void {
        if (s.read_watch != 0) c.lt_unwatch(s.read_watch);
        s.read_watch = 0;
        if (s.mac_read) |w| w.cancel();
        s.mac_read = null;
    }
    fn wake(s: *Session) void {
        s.notify(s.notify_ctx, s.id);
    }
    /// Actual renderer allocation failure follows the same PTY stop/wake path.
    pub fn renderFailed(s: *Session) void {
        s.fail();
    }
    fn fail(s: *Session) void {
        s.fatal = true;
        s.metadata.stop();
        s.pauseRead();
        s.wake();
    }
    fn reply(ctx: ?*anyopaque, data: [*]const u8, n: usize) callconv(.c) void {
        const s: *Session = @ptrCast(@alignCast(ctx.?));
        if (!s.tx.push(data[0..n])) s.fail();
    }
    fn readable(_: c_int, _: c_uint, ctx: ?*anyopaque) callconv(.c) c_int {
        const s: *Session = @ptrCast(@alignCast(ctx.?));
        s.pump();
        return if (s.read_watch != 0) 1 else 0;
    }
    fn macReadable(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Session = @ptrCast(@alignCast(ctx.?));
        s.pump();
    }
    fn macExited(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Session = @ptrCast(@alignCast(ctx.?));
        if (s.mac_child) |w| w.cancel();
        s.mac_child = null;
        var status: c_int = 0;
        if (c.lt_wait(s.pid, &status) == s.pid) s.status = status;
        s.pump();
        s.wake();
    }
    fn writable(_: c_int, _: c_uint, ctx: ?*anyopaque) callconv(.c) c_int {
        const s: *Session = @ptrCast(@alignCast(ctx.?));
        s.flush();
        return if (s.write_watch != 0) 1 else 0;
    }
    fn childExited(_: c_int, status: c_int, ctx: ?*anyopaque) callconv(.c) void {
        const s: *Session = @ptrCast(@alignCast(ctx.?));
        s.child_watch = 0;
        s.status = status;
        s.pump();
        s.wake();
    }
    /// Parse a bounded amount on the GTK thread; unread PTY bytes provide backpressure.
    pub fn pump(s: *Session) void {
        var data: [1024]u8 = undefined;
        var budget: usize = 64 * 1024;
        while (!s.eof and !s.fatal and budget > 0) {
            if (s.tx.free() < reserve) {
                s.pauseRead();
                break;
            }
            // A short read leaves a non-aligned remainder. Never let the next
            // read exceed it, or sustained output can underflow the budget.
            const n = c.lt_read(s.fd, &data, @min(data.len, budget));
            if (n == -2) break;
            if (n <= 0) {
                s.eof = true;
                s.pauseRead();
                if (n < 0) s.fail();
                break;
            }
            vt_api.feed(s.vt, data[0..@intCast(n)]) catch {
                s.fail();
                break;
            };
            budget -= @intCast(n);
        }
        s.flush();
        s.refresh();
        if (builtin.os.tag != .linux and s.status == null) {
            var status: c_int = 0;
            if (c.lt_wait(s.pid, &status) == s.pid) s.status = status;
        }
        if (s.eof or s.fatal or s.status != null) s.metadata.stop();
        s.wake();
    }
    pub fn flush(s: *Session) void {
        if (s.fd < 0) return;
        var budget: usize = 64 * 1024;
        while (s.tx.len > 0 and budget > 0) {
            const b = s.tx.peek();
            const n = c.lt_write(s.fd, b.ptr, @min(b.len, budget));
            if (n == -2) break;
            if (n <= 0) {
                s.tx.consume(s.tx.len);
                s.fail();
                break;
            }
            s.tx.consume(@intCast(n));
            budget -= @intCast(n);
        }
        if (s.tx.len > 0 and s.write_watch == 0 and builtin.os.tag == .linux) {
            s.write_watch = c.lt_fd_watch(s.fd, 4 | 8 | 16, writable, s);
            if (s.write_watch == 0) s.fail();
        } else if (s.tx.len == 0 and s.write_watch != 0) {
            c.lt_unwatch(s.write_watch);
            s.write_watch = 0;
        }
        if (s.tx.free() >= reserve and !s.fatal) s.startRead() catch s.fail();
    }
    /// Snapshot only after vt_write returned; no callback re-entry or history mirror.
    pub fn refresh(s: *Session) void {
        var raw_title: [256]u8 = undefined;
        const raw_len = vt_api.lt_vt_title(s.vt, &raw_title, raw_title.len);
        const title = @import("terminal_title.zig").validPrefix(raw_title[0..raw_len]);
        const title_changed = !std.mem.eql(u8, s.title[0..s.title_len], title);
        @memcpy(s.title[0..title.len], title);
        s.title_len = title.len;
        var next: vt_api.Events = .{};
        vt_api.lt_vt_events(s.vt, &next);
        s.feedback_changed = title_changed or next.pwd != s.events.pwd or next.bells != s.events.bells or next.ends != s.events.ends or next.progress != s.events.progress or next.progress_state != s.events.progress_state;
        if (next.bells != s.events.bells) s.attention = .bell;
        if (next.ends != s.events.ends and (s.command_pending or next.starts != s.events.starts or s.command_running)) s.attention = if (next.has_exit and next.exit_code != 0) .failed else .done;
        if (next.starts != s.events.starts) s.command_running = true;
        if (next.ends != s.events.ends) s.command_running = false;
        if (next.prompts != s.events.prompts) {
            s.command_pending = false;
            // login may remain the watched PID on macOS. Learn the shell's
            // foreground group at its first prompt, then retain it while jobs run.
            if (s.shell_group == 0 and next.at_prompt) {
                const group = c.lt_foreground_group(s.fd);
                if (group > 0) s.shell_group = group;
            }
        }
        if (next.pwd != s.events.pwd) {
            var raw: [4096]u8 = undefined;
            const len = vt_api.lt_vt_pwd(s.vt, &raw, raw.len);
            s.cwd.set("");
            if (@import("cwd.zig").decode(raw[0..len])) |d| {
                if (c.lt_local_directory(&d.host, &d.path)) s.cwd.set(d.path[0..d.len]);
            }
        }
        const metadata_changed = next.pwd != s.events.pwd or next.prompts != s.events.prompts or next.starts != s.events.starts or next.ends != s.events.ends;
        s.events = next;
        if (metadata_changed) s.metadata.request();
    }
    pub fn idle(s: *Session) bool {
        return s.eof or (s.integrated and s.events.at_prompt and s.events.prompts > 0 and !s.command_pending and c.lt_shell_idle(s.fd, s.shell_group));
    }
    /// Focus protocol messages bypass user-input scrolling, selection and busy state.
    pub fn reportFocus(s: *Session, wanted: bool) void {
        if (!vt_api.lt_vt_focus_enabled(s.vt)) {
            s.focus_sent = null;
            return;
        }
        if (s.focus_sent == null and !wanted) {
            s.focus_sent = false;
            return;
        }
        if (s.focus_sent != null and s.focus_sent.? == wanted) return;
        var bytes: [16]u8 = undefined;
        const n = vt_api.lt_vt_focus(s.vt, wanted, &bytes, bytes.len);
        if (s.focus_sink) |sink| sink.call(sink.ctx, s.id, bytes[0..n]) else {
            if (s.eof or s.fatal or !s.tx.push(bytes[0..n])) return;
            s.flush();
        }
        s.focus_sent = wanted;
    }
    pub fn canSend(s: *const Session, length: usize) bool {
        return !s.eof and !s.fatal and length <= s.tx.free() and s.tx.free() - length >= reserve;
    }
    /// Admit bytes without flushing: a broadcast admits every target before
    /// any PTY write. The caller must not yield between preflight and admission.
    pub fn enqueue(s: *Session, bytes: []const u8) bool {
        if (!s.canSend(bytes.len)) return false;
        if (!s.tx.push(bytes)) return false;
        s.admitted_bytes +|= bytes.len;
        if (std.mem.indexOfAny(u8, bytes, "\r\n") != null) s.command_pending = true;
        vt_api.lt_vt_bottom(s.vt);
        vt_api.lt_vt_clear_selection(s.vt);
        return true;
    }
    pub fn send(s: *Session, bytes: []const u8) bool {
        if (!s.enqueue(bytes)) return false;
        s.flush();
        return true;
    }
    pub fn clearScreen(s: *Session) !void {
        // Mutating the VT and queuing FF are one serialized host operation.
        // No callbacks/pump run between this preflight and the one-byte write.
        if (s.eof or s.fatal) return error.SessionUnavailable;
        if (s.tx.free() < reserve + 1) return error.InputQueueBusy;
        const redraw = try vt_api.clearForShell(s.vt);
        if (redraw and !s.send("\x0c")) return error.InputQueueBusy;
    }
    pub fn resize(s: *Session, cols: u16, rows: u16, cw: u32, ch: u32) void {
        if (cols == s.cols and rows == s.rows and cw == s.cell_w and ch == s.cell_h) return;
        const metrics = nanoui.ui.window_metrics;
        const vt_start = metrics.begin();
        const vt_result = vt_api.lt_vt_resize(s.vt, cols, rows, cw, ch);
        metrics.end(.vt_resize, vt_start);
        if (vt_result != 0) {
            s.fail();
            return;
        }
        const pty_start = metrics.begin();
        const pty_result = c.lt_resize(s.fd, cols, rows, cw, ch);
        metrics.end(.pty_resize, pty_start);
        if (pty_result != 0) {
            s.fail();
            return;
        }
        s.cols = cols;
        s.rows = rows;
        s.cell_w = cw;
        s.cell_h = ch;
    }
    /// Cancel watches before freeing callback data. Closing a pane ends its session.
    pub fn destroy(s: *Session) void {
        s.closing = true;
        s.metadata.stop();
        s.pauseRead();
        if (s.write_watch != 0) c.lt_unwatch(s.write_watch);
        if (s.child_watch != 0) c.lt_unwatch(s.child_watch);
        if (s.mac_child) |w| w.cancel();
        if (s.status == null) c.lt_terminate_session(s.fd, s.pid);
        c.lt_close(s.fd);
        s.fd = -1;
        if (s.status == null) {
            // Off the event callbacks, at explicit close: reap synchronously after SIGKILL.
            reap(s.pid);
        }
        vt_api.destroy(s.vt);
        s.tx.deinit(s.gpa);
        s.gpa.destroy(s);
    }
};
extern "c" fn lt_reap(c_int) void;
fn reap(pid: c_int) void {
    lt_reap(pid);
}
