//! Surgical root-text theme edits and checked POSIX replacement. No UI/global IO.
//! Snapshot paths are physical, bytes are owned, and Native opens regular files
//! nonblocking. Before rename, save checks inode/mode/timestamps AND exact bytes.
//! flock coordinates cooperating writers; POSIX has no compare-and-rename API,
//! so an uncooperative writer can still race the final comparison and rename.
//! All reported errors precede rename. A successful rename with failed directory
//! fsync returns directory_synced=false, never a misleading "unchanged" error.
const std = @import("std");
pub const max_bytes = 64 * 1024;
pub const max_theme_name = 4095;
pub const Digest = [32]u8;
pub const max_metadata_bytes = 256 * 1024;
pub fn digest(bytes: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}
fn checkName(name: []const u8) !void {
    if (name.len == 0 or name.len > max_theme_name or !std.unicode.utf8ValidateSlice(name)) return error.InvalidThemeName;
    for (name) |ch| if (ch == 0 or ch == '\r' or ch == '\n' or ch == '"') return error.InvalidThemeName;
}
/// Change only the last root `theme` value. Other bytes, including comments,
/// unknown keys, indentation, trailing whitespace and CRLF, remain byte exact.
/// With no theme directive, append one. JSON is explicitly unsupported.
pub fn replaceTheme(a: std.mem.Allocator, source: []const u8, selected: []const u8) ![]u8 {
    try checkName(selected);
    if (source.len > max_bytes) return error.FileSize;
    if (!std.unicode.utf8ValidateSlice(source) or std.mem.indexOfScalar(u8, source, 0) != null) return error.InvalidConfigText;
    const trimmed = std.mem.trimStart(u8, source, " \t\r\n");
    if (trimmed.len != 0 and (trimmed[0] == '{' or trimmed[0] == '[')) return error.UnsupportedJsonRoot;
    var last: ?struct { start: usize, end: usize } = null;
    var begin: usize = 0;
    var newline: []const u8 = "\n";
    var saw_newline = false;
    while (begin < source.len) {
        const end = if (std.mem.indexOfScalarPos(u8, source, begin, '\n')) |i| i else source.len;
        if (end < source.len and !saw_newline) {
            newline = if (end > begin and source[end - 1] == '\r') "\r\n" else "\n";
            saw_newline = true;
        }
        const line_end = if (end > begin and source[end - 1] == '\r') end - 1 else end;
        const line = source[begin..line_end];
        if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            if (std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), "theme")) {
                var start = begin + eq + 1;
                while (start < line_end and (source[start] == ' ' or source[start] == '\t')) : (start += 1) {}
                var value_end = line_end;
                var quoted = false;
                for (source[start..line_end], start..) |ch, i| {
                    if (ch == '"') quoted = !quoted;
                    if (!quoted and ch == '#' and (i == start or source[i - 1] == ' ' or source[i - 1] == '\t')) {
                        value_end = i;
                        break;
                    }
                }
                while (value_end > start and (source[value_end - 1] == ' ' or source[value_end - 1] == '\t')) : (value_end -= 1) {}
                last = .{ .start = start, .end = value_end };
            }
        }
        if (end == source.len) break;
        begin = end + 1;
    }
    if (last) |span| {
        if (source.len - (span.end - span.start) + selected.len + 2 > max_bytes) return error.FileSize;
        return std.fmt.allocPrint(a, "{s}\"{s}\"{s}", .{ source[0..span.start], selected, source[span.end..] });
    }
    const separator = if (source.len > 0 and source[source.len - 1] != '\n') newline else "";
    if (source.len + separator.len + selected.len + 10 + newline.len > max_bytes) return error.FileSize;
    return std.fmt.allocPrint(a, "{s}{s}theme = \"{s}\"{s}", .{ source, separator, selected, newline });
}

pub const Identity = struct {
    device: u64,
    inode: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    size: u64,
    mtime_sec: i64,
    mtime_nsec: i64,
    ctime_sec: i64,
    ctime_nsec: i64,
};
pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    limit: usize = max_bytes,
    path: [:0]const u8,
    bytes: []const u8,
    sha256: Digest,
    identity: Identity,
    metadata_sha256: Digest = @splat(0),
    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.path);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
    pub fn matches(self: Snapshot, other: Snapshot) bool {
        return std.mem.eql(u8, self.path, other.path) and std.meta.eql(self.identity, other.identity) and
            std.mem.eql(u8, &self.sha256, &other.sha256) and std.mem.eql(u8, &self.metadata_sha256, &other.metadata_sha256) and std.mem.eql(u8, self.bytes, other.bytes);
    }
};
pub const SaveResult = struct { directory_synced: bool };
/// Directory durability policy seam. It runs only AFTER a successful rename;
/// returning false reports committed-but-not-confirmed-durable, never error.
/// Tests inject a real EBADF fsync here; default always syncs the opened dir.
pub const SaveOptions = struct {
    context: ?*anyopaque = null,
    sync_directory: *const fn (?*anyopaque, c_int) bool = syncDirectory,
};
fn syncDirectory(_: ?*anyopaque, fd: c_int) bool {
    return std.c.fsync(fd) == 0;
}
// POSIX libc calls deliberately avoid Zig 0.17's Linux statx-only Io.Stat;
// fstat/flock/pread/fsync/rename are available on the EL7/glibc2.17 baseline.
const os = std.c;
extern "c" fn mkstemp([*:0]u8) c_int;
const FileInfo = extern struct {
    device: u64,
    inode: u64,
    size: u64,
    mtime_sec: i64,
    mtime_nsec: i64,
    ctime_sec: i64,
    ctime_nsec: i64,
    mode: u32,
    uid: u32,
    gid: u32,
    reserved: u32,
};
comptime {
    std.debug.assert(@sizeOf(FileInfo) == 72);
    std.debug.assert(@offsetOf(FileInfo, "mode") == 56);
}
extern "c" fn lt_config_edit_info(c_int, *FileInfo) c_int;
extern "c" fn lt_config_edit_metadata(c_int, [*]u8, usize, *usize) c_int;
extern "c" fn lt_config_edit_copy_metadata(c_int, c_int) c_int;
fn metadataError() anyerror {
    return switch (std.c.errno(@as(c_int, -1))) {
        .@"2BIG", .RANGE => error.MetadataTooLarge,
        .NOMEM => error.OutOfMemory,
        .AGAIN => error.ConcurrentChange,
        else => error.MetadataUnsupported,
    };
}
fn metadataDigest(a: std.mem.Allocator, fd: c_int) !Digest {
    const buffer = try a.alloc(u8, max_metadata_bytes);
    defer a.free(buffer);
    var length: usize = 0;
    if (lt_config_edit_metadata(fd, buffer.ptr, buffer.len, &length) != 0) return metadataError();
    if (length > buffer.len) return error.MetadataTooLarge;
    return digest(buffer[0..length]);
}
fn ioError() anyerror {
    return switch (std.c.errno(@as(c_int, -1))) {
        .NOENT, .NOTDIR => error.ConfigNotFound,
        .ACCES, .PERM => error.AccessDenied,
        .AGAIN => error.SaveBusy,
        .LOOP => error.SymLinkLoop,
        else => error.ConfigIo,
    };
}
fn identity(fd: c_int, limit: usize) !Identity {
    var info: FileInfo = undefined;
    if (lt_config_edit_info(fd, &info) != 0) return ioError();
    if (info.mode & os.S.IFMT != os.S.IFREG) return error.NotRegularFile;
    if (info.size > limit) return error.FileSize;
    return .{ .device = info.device, .inode = info.inode, .mode = info.mode, .uid = info.uid, .gid = info.gid, .size = info.size, .mtime_sec = info.mtime_sec, .mtime_nsec = info.mtime_nsec, .ctime_sec = info.ctime_sec, .ctime_nsec = info.ctime_nsec };
}
fn open(path: [*:0]const u8) !c_int {
    const fd = os.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true, .NOFOLLOW = true });
    if (fd < 0) return ioError();
    return fd;
}
fn fromFd(a: std.mem.Allocator, filename: [:0]const u8, fd: c_int, limit: usize) !Snapshot {
    const before = try identity(fd, limit);
    const bytes = try a.alloc(u8, @intCast(before.size));
    errdefer a.free(bytes);
    var at: usize = 0;
    while (at < bytes.len) {
        const count = os.pread(fd, bytes[at..].ptr, bytes.len - at, @intCast(at));
        if (count < 0) {
            if (std.c.errno(@as(c_int, -1)) == .INTR) continue;
            return ioError();
        }
        if (count == 0) return error.ConcurrentChange;
        at += @intCast(count);
    }
    var extra: [1]u8 = undefined;
    const tail = os.pread(fd, &extra, 1, @intCast(bytes.len));
    const metadata = try metadataDigest(a, fd);
    if (tail != 0 or !std.meta.eql(before, try identity(fd, limit))) return error.ConcurrentChange;
    const owned_path = try a.dupeSentinel(u8, filename, 0);
    return .{ .allocator = a, .limit = limit, .path = owned_path, .bytes = bytes, .sha256 = digest(bytes), .identity = before, .metadata_sha256 = metadata };
}
pub const Native = struct {
    /// Resolve the root once and always replace that physical file, preserving
    /// a user's symlink to it instead of silently replacing the symlink itself.
    pub fn capture(a: std.mem.Allocator, filename: []const u8) !Snapshot {
        return captureWithLimit(a, filename, max_bytes);
    }
    pub fn captureWithLimit(a: std.mem.Allocator, filename: []const u8, limit: usize) !Snapshot {
        if (filename.len == 0 or filename.len > 4095 or std.mem.indexOfScalar(u8, filename, 0) != null) return error.InvalidPath;
        const z = try a.dupeSentinel(u8, filename, 0);
        defer a.free(z);
        var buffer: [4096]u8 = undefined;
        const physical = os.realpath(z, &buffer) orelse return ioError();
        const physical_slice = std.mem.span(physical);
        const fd = try open(@ptrCast(physical));
        defer _ = os.close(fd);
        return fromFd(a, physical_slice, fd, limit);
    }
    pub fn save(a: std.mem.Allocator, original: Snapshot, output: []const u8) !SaveResult {
        return saveWithOptions(a, original, output, .{});
    }
    pub fn saveWithOptions(a: std.mem.Allocator, original: Snapshot, output: []const u8, options: SaveOptions) !SaveResult {
        if (output.len > original.limit) return error.FileSize;
        const calculated = digest(original.bytes);
        if (!std.mem.eql(u8, &calculated, &original.sha256)) return error.InvalidSnapshot;
        const fd = try open(original.path);
        defer _ = os.close(fd);
        if (os.flock(fd, os.LOCK.EX | os.LOCK.NB) != 0) return ioError();
        var current = try fromFd(a, original.path, fd, original.limit);
        defer current.deinit();
        if (!original.matches(current)) return error.ConcurrentChange;
        const temp = try std.fmt.allocPrintSentinel(a, "{s}.theme-XXXXXX", .{original.path}, 0);
        defer a.free(temp);
        const parent = try a.dupeSentinel(u8, std.fs.path.dirname(original.path) orelse ".", 0);
        defer a.free(parent);
        const temp_fd = mkstemp(temp);
        if (temp_fd < 0) return ioError();
        var temp_open = true;
        defer if (temp_open) {
            _ = os.close(temp_fd);
        };
        var committed = false;
        defer if (!committed) {
            _ = os.unlink(temp);
        };
        if (os.fcntl(temp_fd, os.F.SETFD, @as(c_int, os.FD_CLOEXEC)) < 0) return ioError();
        if (os.fchown(temp_fd, original.identity.uid, original.identity.gid) != 0) return ioError();
        var at: usize = 0;
        while (at < output.len) {
            const count = os.write(temp_fd, output[at..].ptr, output.len - at);
            if (count < 0) {
                if (std.c.errno(@as(c_int, -1)) == .INTR) continue;
                return ioError();
            }
            if (count == 0) return error.ShortWrite;
            at += @intCast(count);
        }
        if (os.fchmod(temp_fd, @intCast(original.identity.mode & 0o7777)) != 0) return ioError();
        if (lt_config_edit_copy_metadata(fd, temp_fd) != 0) return metadataError();
        const copied = try identity(temp_fd, original.limit);
        if ((copied.mode & 0o7777) != (original.identity.mode & 0o7777) or copied.uid != original.identity.uid or copied.gid != original.identity.gid or
            !std.mem.eql(u8, &(try metadataDigest(a, temp_fd)), &original.metadata_sha256)) return error.MetadataNotPreserved;
        if (os.fsync(temp_fd) != 0) return ioError();
        const closed = os.close(temp_fd);
        temp_open = false;
        if (closed != 0) return ioError();
        var latest = try captureWithLimit(a, original.path, original.limit);
        defer latest.deinit();
        if (!original.matches(latest)) return error.ConcurrentChange;
        if (os.rename(temp, original.path) != 0) return ioError();
        committed = true;
        const dir = os.open(parent, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
        if (dir < 0) return .{ .directory_synced = false };
        defer _ = os.close(dir);
        return .{ .directory_synced = options.sync_directory(options.context, dir) };
    }
};

test {
    _ = @import("config_edit_test.zig");
}
