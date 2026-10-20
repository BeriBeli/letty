//! Lossless root text edits. Native replacement remains config_edit's writer.
const std = @import("std");
const config = @import("../config.zig");
const edit = @import("../config_edit.zig");
pub const Change = struct { key: []const u8, value: []const u8 };
pub fn encodeValue(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, value, "\r\n\x00") != null or !std.unicode.utf8ValidateSlice(value)) return error.InvalidSettingText;
    const unquote = @import("../config_value.zig").unquote;
    const quoted = try std.fmt.allocPrint(a, "\"{s}\"", .{value});
    if (std.mem.eql(u8, unquote(quoted), value)) return quoted;
    a.free(quoted);
    if (std.mem.eql(u8, unquote(value), value)) return a.dupe(u8, value);
    return error.UnrepresentableSettingText;
}
pub fn isJson(bytes: []const u8) bool {
    const text = std.mem.trimStart(u8, bytes, " \r\n\t");
    return text.len > 0 and (text[0] == '{' or text[0] == '[');
}
pub fn append(a: std.mem.Allocator, source: []const u8, changes: []const Change) ![]const u8 {
    if (isJson(source)) return error.UnsupportedJsonRoot;
    if (changes.len == 0) return a.dupe(u8, source);
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    const newline: []const u8 = if (std.mem.indexOf(u8, source, "\r\n") != null) "\r\n" else "\n";
    try w.writeAll(source);
    if (source.len > 0 and source[source.len - 1] != '\n') try w.writeAll(newline);
    try w.print("# Letty settings: local overrides{s}", .{newline});
    for (changes) |change| {
        if (change.key.len == 0 or std.mem.indexOfAny(u8, change.key, "=\r\n\x00\"") != null or
            std.mem.indexOfAny(u8, change.value, "\r\n\x00") != null or !std.unicode.utf8ValidateSlice(change.value)) return error.InvalidSettingText;
        // The shared parser preserves escapes rather than decoding them. Pick
        // only an encoding that roundtrips exactly; never invent JSON escaping.
        const encoded = try encodeValue(a, change.value);
        defer a.free(encoded);
        try w.print("{s} = {s}{s}", .{ change.key, encoded, newline });
    }
    if (out.written().len > edit.max_bytes) return error.FileSize;
    return out.toOwnedSlice();
}
pub const Redirect = struct {
    base: config.includes.Reader,
    path: []const u8,
    bytes: []const u8,
    pub fn reader(self: *Redirect) config.includes.Reader {
        return .{ .context = self, .canonicalize = canonical, .read = read, .home = self.base.home };
    }
    fn canonical(raw: *anyopaque, a: std.mem.Allocator, path: []const u8) !?[]const u8 {
        const self: *Redirect = @ptrCast(@alignCast(raw));
        if (std.mem.eql(u8, path, self.path)) return try a.dupe(u8, path);
        return self.base.canonicalize(self.base.context, a, path);
    }
    fn read(raw: *anyopaque, a: std.mem.Allocator, path: []const u8, limit: usize) !?[]const u8 {
        const self: *Redirect = @ptrCast(@alignCast(raw));
        if (std.mem.eql(u8, path, self.path)) {
            if (self.bytes.len > limit) return error.FileSize;
            return try a.dupe(u8, self.bytes);
        }
        return self.base.read(self.base.context, a, path, limit);
    }
};
pub const Dependency = struct { path: []const u8, snapshot: ?edit.Snapshot };
/// Captures the exact bytes the parser sees, including missing optional files.
/// All snapshots use the caller's arena; no ownership escapes its lifetime.
pub const FrozenReader = struct {
    a: std.mem.Allocator,
    base: config.includes.Reader,
    dependencies: std.ArrayList(Dependency) = .empty,
    pub fn reader(self: *FrozenReader) config.includes.Reader {
        return .{ .context = self, .canonicalize = canonical, .read = read, .home = self.base.home };
    }
    fn canonical(raw: *anyopaque, a: std.mem.Allocator, path: []const u8) !?[]const u8 {
        const self: *FrozenReader = @ptrCast(@alignCast(raw));
        const dependency = try self.remember(path);
        return if (dependency.snapshot) |snapshot| try a.dupe(u8, snapshot.path) else null;
    }
    fn remember(self: *FrozenReader, path: []const u8) !*const Dependency {
        for (self.dependencies.items) |*dependency| if (std.mem.eql(u8, dependency.path, path)) return dependency;
        const snapshot = edit.Native.capture(self.a, path) catch |err| if (err == error.ConfigNotFound) null else return err;
        try self.dependencies.append(self.a, .{ .path = try self.a.dupe(u8, path), .snapshot = snapshot });
        return &self.dependencies.items[self.dependencies.items.len - 1];
    }
    fn read(raw: *anyopaque, a: std.mem.Allocator, path: []const u8, limit: usize) !?[]const u8 {
        const self: *FrozenReader = @ptrCast(@alignCast(raw));
        // Loader reads canonical paths; retain each logical include path too,
        // so a retargeted include symlink fails the later conflict check.
        const dependency = blk: {
            for (self.dependencies.items) |*prior| if (prior.snapshot) |snapshot| {
                if (std.mem.eql(u8, snapshot.path, path)) break :blk prior;
            };
            break :blk try self.remember(path);
        };
        const snapshot = dependency.snapshot orelse return null;
        if (snapshot.bytes.len > limit) return error.ConfigFileSize;
        return try a.dupe(u8, snapshot.bytes);
    }
};
pub fn checkDependencies(gpa: std.mem.Allocator, dependencies: []const Dependency) !void {
    for (dependencies) |dependency| {
        var current = edit.Native.capture(gpa, dependency.path) catch |err| if (err == error.ConfigNotFound) null else return err;
        defer if (current) |*snapshot| snapshot.deinit();
        if (dependency.snapshot) |original| {
            if (current == null or !original.matches(current.?)) return error.IncludedSourceChanged;
        } else if (current != null) return error.IncludedSourceChanged;
    }
}
pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    cfg: config.Config,
    replacement: []const u8,
    dependencies: []const Dependency,
    pub fn load(gpa: std.mem.Allocator, path: []const u8, bytes: []const u8, home: []const u8, diagnostic: *config.Diagnostic) !Candidate {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const owned = try a.dupe(u8, bytes);
        var frozen: FrozenReader = .{ .a = a, .base = config.includes.nativeReader(home) };
        var redirect: Redirect = .{ .base = frozen.reader(), .path = path, .bytes = owned };
        const cfg = try config.loadWithReaderDetailed(a, redirect.reader(), path, .{}, diagnostic);
        return .{ .arena = arena, .cfg = cfg, .replacement = owned, .dependencies = frozen.dependencies.items };
    }
    pub fn deinit(self: *Candidate) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// New-file counterpart to Native.save: publish an already synced tempfile with
/// link(), which cannot replace an existing file. Linux 3.10/glibc 2.17 safe.
/// Every reported failure precedes publication. No ACL existed to preserve.
pub fn create(a: std.mem.Allocator, path: []const u8, bytes: []const u8) !edit.SaveResult {
    if (path.len == 0 or path.len > 4095 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (bytes.len > edit.max_bytes) return error.FileSize;
    const parent = try a.dupeSentinel(u8, std.fs.path.dirname(path) orelse ".", 0);
    defer a.free(parent);
    if (lt_mkdirs(parent) != 0) return error.ConfigCreateFailed;
    const target = try a.dupeSentinel(u8, path, 0);
    defer a.free(target);
    const temporary = try std.fmt.allocPrintSentinel(a, "{s}.settings-XXXXXX", .{path}, 0);
    defer a.free(temporary);
    const fd = mkstemp(temporary);
    if (fd < 0) return error.ConfigCreateFailed;
    defer _ = std.c.unlink(temporary);
    var opened = true;
    defer if (opened) {
        _ = std.c.close(fd);
    };
    if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) return error.ConfigCreateFailed;
    var at: usize = 0;
    while (at < bytes.len) {
        const n = std.c.write(fd, bytes[at..].ptr, bytes.len - at);
        if (n < 0) {
            if (std.c.errno(n) == .INTR) continue;
            return error.ConfigCreateFailed;
        }
        if (n == 0) return error.ShortWrite;
        at += @intCast(n);
    }
    if (std.c.fsync(fd) != 0) return error.ConfigCreateFailed;
    const closed = std.c.close(fd);
    opened = false;
    if (closed != 0) return error.ConfigCreateFailed;
    if (link(temporary, target) != 0) return if (std.c.errno(@as(c_int, -1)) == .EXIST) error.ConcurrentChange else error.ConfigCreateFailed;
    const directory = std.c.open(parent, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (directory < 0) return .{ .directory_synced = false };
    defer _ = std.c.close(directory);
    return .{ .directory_synced = std.c.fsync(directory) == 0 };
}
extern "c" fn mkstemp([*:0]u8) c_int;
extern "c" fn link([*:0]const u8, [*:0]const u8) c_int;
extern "c" fn lt_mkdirs([*:0]const u8) c_int;
