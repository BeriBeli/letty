//! Worktree-relative regular files, opened through no-follow directory handles.
const std = @import("std");
const os = @import("platform.zig");
const c = os.c;
const A = std.mem.Allocator;
const directory_flag: c_int = if (@import("builtin").os.tag == .macos) 0x100000 else 0x10000;
extern "c" fn openat(c_int, [*:0]const u8, c_int, ...) c_int;
extern "c" fn renameat(c_int, [*:0]const u8, c_int, [*:0]const u8) c_int;
extern "c" fn unlinkat(c_int, [*:0]const u8, c_int) c_int;
extern "c" fn fchmod(c_int, c_uint) c_int;
var serial: u64 = 0;
pub const File = struct {
    parent: c_int = -1,
    name: [:0]const u8,
    bytes: []const u8,
    hash: [32]u8,
    mode: u32,
    pub fn deinit(self: *File, a: A) void {
        if (self.parent >= 0) _ = c.close(self.parent);
        a.free(self.name);
        a.free(self.bytes);
        self.parent = -1;
    }
    pub fn open(a: A, root: []const u8, path: []const u8) !File {
        if (!@import("git.zig").validPath(path) or !std.fs.path.isAbsolute(root)) return error.InvalidReviewPath;
        const z = try a.dupeSentinel(u8, root, 0);
        defer a.free(z);
        var fd = c.open(z, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK | c.O_NOFOLLOW | directory_flag);
        if (fd < 0) return error.OpenReviewRoot;
        errdefer _ = c.close(fd);
        var parts = std.mem.splitScalar(u8, path, '/');
        var name = parts.next() orelse return error.InvalidReviewPath;
        while (parts.next()) |part| {
            if (std.ascii.eqlIgnoreCase(name, ".git") or std.ascii.eqlIgnoreCase(name, ".svn")) return error.InvalidReviewPath;
            const entry = try a.dupeSentinel(u8, name, 0);
            defer a.free(entry);
            const child = openat(fd, entry, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK | c.O_NOFOLLOW | directory_flag);
            if (child < 0) return error.OpenReviewDirectory;
            _ = c.close(fd);
            fd = child;
            name = part;
        }
        if (std.ascii.eqlIgnoreCase(name, ".git") or std.ascii.eqlIgnoreCase(name, ".svn")) return error.InvalidReviewPath;
        const owned = try a.dupeSentinel(u8, name, 0);
        errdefer a.free(owned);
        const snapshot = try read(a, fd, owned);
        return .{ .parent = fd, .name = owned, .bytes = snapshot.bytes, .hash = hash(snapshot.bytes), .mode = snapshot.mode };
    }
    pub fn write(self: *File, a: A, text: []const u8) !void {
        if (text.len > 1024 * 1024 or !std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return error.EditLimit;
        const expected = try read(a, self.parent, self.name);
        defer a.free(expected.bytes);
        if (!std.mem.eql(u8, &self.hash, &hash(expected.bytes))) return error.FileChangedExternallyReloadFirst;
        serial +%= 1;
        var buffer: [96]u8 = undefined;
        const temp = try std.fmt.bufPrintSentinel(&buffer, ".letty-edit-{d}-{d}", .{ std.c.getpid(), serial }, 0);
        const exclusive: c_int = if (@import("builtin").os.tag == .macos) 0x800 else 0x80;
        const fd = openat(self.parent, temp, c.O_WRONLY | c.O_CREAT | c.O_CLOEXEC | c.O_NOFOLLOW | exclusive, @as(c_uint, 0o600));
        if (fd < 0) return error.CreateReviewTemporary;
        defer _ = c.close(fd);
        defer _ = unlinkat(self.parent, temp, 0);
        try os.writeAll(fd, text);
        if (fchmod(fd, expected.mode & 0o777) != 0 or c.fsync(fd) != 0) return error.WriteReviewFile;
        const latest = try read(a, self.parent, self.name);
        defer a.free(latest.bytes);
        if (!std.mem.eql(u8, &self.hash, &hash(latest.bytes))) return error.FileChangedExternallyReloadFirst;
        const copy = try a.dupe(u8, text);
        errdefer a.free(copy);
        if (renameat(self.parent, temp, self.parent, self.name) != 0) return error.WriteReviewFile;
        a.free(self.bytes);
        self.bytes = copy;
        self.hash = hash(text);
        self.mode = expected.mode;
    }
};
fn read(a: A, parent: c_int, name: [:0]const u8) !struct { bytes: []const u8, mode: u32 } {
    const fd = openat(parent, name, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK | c.O_NOFOLLOW);
    if (fd < 0) return error.OpenReviewFile;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or (st.mode & c.S_IFMT) != c.S_IFREG or st.size < 0 or st.size > 1024 * 1024) return error.ReviewFileLimit;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buffer: [8192]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buffer, buffer.len);
        if (n == 0) break;
        if (n < 0) {
            if (os.errNo() == c.EINTR) continue;
            return error.ReadReviewFile;
        }
        if (out.items.len + @as(usize, @intCast(n)) > 1024 * 1024) return error.ReviewFileLimit;
        try out.appendSlice(a, buffer[0..@intCast(n)]);
    }
    return .{ .bytes = try out.toOwnedSlice(a), .mode = st.mode };
}

fn hash(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}
