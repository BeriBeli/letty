//! Local PTY ownership. No daemon, socket, terminal mirror or remote attachment.
const std = @import("std");
const platform = @import("platform.zig");
const c = platform.c;
const Terminal = @import("terminal.zig").Terminal;
const shell = @import("shell.zig");
extern "c" fn _NSGetEnviron() *[*:null]?[*:0]u8;
pub const Pty = struct {
    a: std.mem.Allocator,
    id: u64,
    fd: c_int,
    pid: c_int,
    terminal: *Terminal,
    directory: []const u8,
    shell_path: []const u8,
    explicit_command: bool = false,
    exit_code: ?i32 = null,
    eof: bool = false,
    closing: bool = false,
    parsing: bool = false,
    pub fn create(a: std.mem.Allocator, io: std.Io, id: u64, directory: []const u8, shell_path: []const u8, args: []const []const u8, history: usize) !*Pty {
        return createWithEnv(a, io, id, directory, shell_path, args, history, &.{}, true);
    }
    pub fn createWithEnv(a: std.mem.Allocator, io: std.Io, id: u64, directory: []const u8, shell_path: []const u8, args: []const []const u8, history: usize, environment: []const []const u8, login_shell: bool) !*Pty {
        if (id == 0 or !std.fs.path.isAbsolute(directory) or std.mem.indexOfScalar(u8, directory, 0) != null) return error.InvalidLaunch;
        const self = try a.create(Pty);
        errdefer a.destroy(self);
        const owned_dir = try a.dupe(u8, directory);
        errdefer a.free(owned_dir);
        const owned_shell = try a.dupe(u8, shell_path);
        errdefer a.free(owned_shell);
        const vt = try Terminal.create(a, io, 80, 24, history);
        errdefer vt.destroy();
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const ta = arena.allocator();
        const dir_z = try ta.dupeSentinel(u8, directory, 0);
        const shell_z = try ta.dupeSentinel(u8, shell_path, 0);
        const identity = try std.fmt.allocPrintSentinel(ta, "{d}", .{id}, 0);
        // Prepare every allocation before fork: the child only changes cwd and execs.
        var values: std.StringHashMap([]const u8) = .init(ta);
        const inherited = if (@import("builtin").os.tag == .macos) _NSGetEnviron().* else std.c.environ;
        var i: usize = 0;
        var env_bytes: usize = 0;
        while (inherited[i]) |entry| : (i += 1) {
            const raw = std.mem.span(entry);
            env_bytes += raw.len;
            if (env_bytes > 4 * 1024 * 1024) return error.EnvironmentLimit;
            const at = std.mem.indexOfScalar(u8, raw, '=') orelse continue;
            try values.put(try ta.dupe(u8, raw[0..at]), try ta.dupe(u8, raw[at + 1 ..]));
        }
        try values.put("TERM", "xterm-256color");
        try values.put("COLORTERM", "truecolor");
        try values.put("TERM_PROGRAM", "letty");
        for (environment) |entry| {
            const at = std.mem.indexOfScalar(u8, entry, '=') orelse return error.InvalidEnvironment;
            if (at == 0 or std.mem.indexOfScalar(u8, entry, 0) != null) return error.InvalidEnvironment;
            try values.put(entry[0..at], entry[at + 1 ..]);
        }
        try values.put("LETTY_PANE", identity);
        var environment_z: std.ArrayList(?[*:0]const u8) = .empty;
        var iterator = values.iterator();
        while (iterator.next()) |entry| try environment_z.append(ta, (try std.fmt.allocPrintSentinel(ta, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* }, 0)).ptr);
        try environment_z.append(ta, null);
        const login = try std.fmt.allocPrintSentinel(ta, "-{s}", .{std.fs.path.basename(shell_path)}, 0);
        const script = if (args.len > 0) try ta.dupeSentinel(u8, try shell.command(ta, shell_path, args), 0) else null;
        const argv: [6:null]?[*:0]const u8 = if (script) |s| .{ shell_z.ptr, if (login_shell) "-l" else "-i", "-i", "-c", s.ptr, null } else .{ if (login_shell) login.ptr else shell_z.ptr, null, null, null, null, null };
        const ws: c.winsize = .{ .row = 24, .col = 80, .xpixel = 640, .ypixel = 432 };
        var fd: c_int = -1;
        const pid = c.forkpty(&fd, null, null, &ws);
        if (pid < 0) return error.SpawnPty;
        if (pid == 0) {
            if (c.chdir(dir_z.ptr) != 0) c._exit(126);
            _ = std.c.execve(shell_z.ptr, &argv, @ptrCast(environment_z.items.ptr));
            c._exit(127);
        }
        errdefer {
            _ = c.kill(pid, c.SIGKILL);
            var status: c_int = 0;
            _ = c.waitpid(pid, &status, 0);
            _ = c.close(fd);
        }
        try platform.cloexec(fd);
        try platform.nonblock(fd);
        self.* = .{ .a = a, .id = id, .fd = fd, .pid = pid, .terminal = vt, .directory = owned_dir, .shell_path = owned_shell, .explicit_command = args.len > 0 };
        return self;
    }
    pub fn destroy(self: *Pty) void {
        self.closing = true;
        // Close the master before waiting: Darwin can hold an exiting slave
        // in tty drain until the master is released.
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
        if (self.pid > 0) {
            _ = c.kill(-self.pid, c.SIGKILL);
            _ = c.kill(self.pid, c.SIGKILL);
            var status: c_int = 0;
            while (c.waitpid(self.pid, &status, 0) < 0 and platform.errNo() == c.EINTR) {}
        }
        self.terminal.destroy();
        self.a.free(self.directory);
        self.a.free(self.shell_path);
        self.a.destroy(self);
    }
    pub fn resize(self: *Pty, cols: u16, rows: u16, cell_width: u16, cell_height: u16) !void {
        if (self.closing) return;
        if (self.terminal.terminal.cols == cols and self.terminal.terminal.rows == rows and self.terminal.terminal.width_px == @as(u32, cols) * cell_width and self.terminal.terminal.height_px == @as(u32, rows) * cell_height) return;
        if (cols < 2 or rows < 2 or cols > 1000 or rows > 1000 or cell_width == 0 or cell_height == 0) return error.InvalidSize;
        try self.terminal.stream.handler.resize(.{ .cols = cols, .rows = rows, .cell_size_px = .{ .width = cell_width, .height = cell_height } });
        var ws: c.winsize = .{ .row = rows, .col = cols, .xpixel = @intCast(@min(@as(u32, cols) * cell_width, 65535)), .ypixel = @intCast(@min(@as(u32, rows) * cell_height, 65535)) };
        self.terminal.revision +%= 1;
        if (!self.eof and c.ioctl(self.fd, c.TIOCSWINSZ, @intFromPtr(&ws)) != 0) return error.ResizePty;
    }
    pub fn read(self: *Pty) !bool {
        if (self.closing or self.eof or self.parsing) return false;
        self.parsing = true;
        defer self.parsing = false;
        var buf: [4096]u8 = undefined;
        var budget: usize = 65536;
        var changed = false;
        while (budget > 0) {
            const n = c.read(self.fd, &buf, @min(buf.len, budget));
            if (n < 0) {
                const err = platform.errNo();
                if (err == c.EINTR) continue;
                if (err == c.EAGAIN) break;
                // Linux PTYs report EIO after the last slave is closed.
                if (err == 5) {
                    self.eof = true;
                    break;
                }
                return error.ReadPty;
            }
            if (n == 0) {
                self.eof = true;
                break;
            }
            changed = true;
            budget -= @intCast(n);
            try self.terminal.feed(buf[0..@intCast(n)]);
        }
        return changed;
    }
    pub fn flush(self: *Pty) !bool {
        if (self.fd < 0 or self.eof or self.closing) return false;
        const vt = self.terminal;
        var budget: usize = 65536;
        while (vt.tx_at < vt.tx.items.len and budget > 0) {
            const bytes = vt.tx.items[vt.tx_at..];
            const n = c.write(self.fd, bytes.ptr, @min(bytes.len, budget));
            if (n < 0) {
                const err = platform.errNo();
                if (err == c.EINTR) continue;
                if (err == c.EAGAIN) return true;
                return error.WritePty;
            }
            if (n == 0) return true;
            vt.tx_at += @intCast(n);
            budget -= @intCast(n);
        }
        if (vt.tx_at == vt.tx.items.len) {
            vt.tx.clearRetainingCapacity();
            vt.tx_at = 0;
            return false;
        }
        return true;
    }
    pub fn send(self: *Pty, bytes: []const u8) !bool {
        if (self.eof or self.closing or self.exit_code != null) return error.PaneExited;
        try self.terminal.enqueue(bytes, false);
        self.terminal.records.dismiss(self.a);
        return self.flush();
    }
    pub fn reap(self: *Pty) bool {
        if (self.pid <= 0) return false;
        var status: c_int = 0;
        if (c.waitpid(self.pid, &status, c.WNOHANG) != self.pid) return false;
        self.pid = 0;
        self.exit_code = if (status & 0x7f == 0) (status >> 8) & 255 else 128 + (status & 0x7f);
        return true;
    }
    pub fn busy(self: *Pty) bool {
        return self.pid > 0 and c.tcgetpgrp(self.fd) > 0 and c.tcgetpgrp(self.fd) != self.pid;
    }
};
