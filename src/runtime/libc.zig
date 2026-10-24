//! Explicit libc declarations for Zig 0.17 (which removed @cImport).
const std = @import("std");
const mac = @import("builtin").os.tag == .macos;
pub const struct_timespec = std.c.timespec;
// glibc before 2.33 exports __fxstat, not an unversioned fstat symbol.
pub const struct_stat = if (mac) std.c.Stat else extern struct {
    dev: u64,
    ino: u64,
    nlink: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    pad: u32,
    rdev: u64,
    size: i64,
    blksize: i64,
    blocks: i64,
    atim: struct_timespec,
    mtim: struct_timespec,
    ctim: struct_timespec,
    reserved: [3]i64,
};
pub const pollfd = std.c.pollfd;
pub const winsize = std.c.winsize;
pub const F_GETFL = 3;
pub const F_SETFL = 4;
pub const F_SETFD = 2;
pub const FD_CLOEXEC = 1;
pub const O_RDONLY = 0;
pub const O_WRONLY = 1;
pub const O_RDWR = 2;
pub const O_NONBLOCK = if (mac) 4 else 0x800;
pub const O_CLOEXEC = if (mac) 0x1000000 else 0x80000;
pub const O_NOFOLLOW = if (mac) 0x100 else 0x20000;
pub const O_CREAT = if (mac) 0x200 else 0x40;
pub const O_APPEND = if (mac) 8 else 0x400;
pub const O_TRUNC = if (mac) 0x400 else 0x200;
pub const S_IFMT = 0o170000;
pub const S_IFREG = 0o100000;
pub const EEXIST = 17;
pub const EINTR = 4;
pub const EAGAIN = if (mac) 35 else 11;
pub const CLOCK_REALTIME: std.c.clockid_t = .REALTIME;
pub const POLLIN = 1;
pub const POLLOUT = 4;
pub const POLLERR = 8;
pub const POLLHUP = 16;
pub const LOCK_EX = 2;
pub const LOCK_NB = 4;
pub const SIGTERM = 15;
pub const SIGHUP = 1;
pub const SIGKILL = 9;
pub const SIGPIPE = 13;
pub const WNOHANG = 1;
pub const TIOCSWINSZ: c_int = if (mac) @bitCast(@as(u32, 0x80087467)) else 0x5414;
pub const fcntl = std.c.fcntl;
pub const getenv = std.c.getenv;
pub const clock_gettime = std.c.clock_gettime;
pub const read = std.c.read;
pub const write = std.c.write;
pub const close = std.c.close;
pub const dlopen = std.c.dlopen;
pub const dlsym = std.c.dlsym;
pub const dlclose = std.c.dlclose;
pub const RTLD_LAZY: std.c.RTLD = .{ .LAZY = true };
pub const mkdir = std.c.mkdir;
pub const fsync = std.c.fsync;
pub const unlink = std.c.unlink;
pub fn fstat(fd: c_int, st: *struct_stat) c_int {
    return if (mac) std.c.fstat(fd, st) else __fxstat(1, fd, st);
}
extern "c" fn __fxstat(c_int, c_int, *struct_stat) c_int;
pub const getuid = std.c.getuid;
pub const getpwuid = std.c.getpwuid;
pub const getcwd = std.c.getcwd;
pub const chmod = std.c.chmod;
pub const waitpid = std.c.waitpid;
pub const ioctl = std.c.ioctl;
pub const chdir = std.c.chdir;
pub const pipe = std.c.pipe;
pub extern "c" fn tcgetpgrp(c_int) c_int;
pub const SIGCHLD = if (mac) 20 else 17;
pub extern "c" fn __error() *c_int;
pub extern "c" fn __errno_location() *c_int;
pub extern "c" fn poll(?[*]pollfd, usize, c_int) c_int;
pub extern "c" fn mkstemp([*:0]u8) c_int;
pub extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
pub const rmdir = std.c.rmdir;
pub extern "c" fn unsetenv([*:0]const u8) c_int;
pub extern "c" fn rename([*:0]const u8, [*:0]const u8) c_int;
pub extern "c" fn forkpty(*c_int, ?[*]u8, ?*anyopaque, ?*const winsize) c_int;
pub extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
pub extern "c" fn _exit(c_int) noreturn;
pub extern "c" fn execv([*:0]const u8, [*:null]const ?[*:0]const u8) c_int;
pub extern "c" fn kill(c_int, c_int) c_int;
pub extern "c" fn open([*:0]const u8, c_int, ...) c_int;
pub extern "c" fn signal(c_int, ?*const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void;
