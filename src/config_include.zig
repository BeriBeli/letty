//! Bounded, transactional text-config expansion. All returned text belongs to Document.
//! Reader.canonicalize must resolve symlinks and return an absolute physical path;
//! null means ENOENT/ENOTDIR only. Other I/O errors must remain errors. read has the
//! same missing-file contract and must enforce its supplied byte limit before allocating.
//! Both callbacks must allocate returned slices with the supplied allocator (or
//! return immutable process-lifetime storage); no transient borrowed buffers.
const std = @import("std");

pub const Limits = struct {
    depth: usize = 16,
    file_bytes: usize = 64 * 1024,
    total_bytes: usize = 1024 * 1024,
    files: usize = 256,
    entries: usize = 8192,
};
pub const Reader = struct {
    context: *anyopaque,
    canonicalize: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!?[]const u8,
    read: *const fn (*anyopaque, std.mem.Allocator, []const u8, usize) anyerror!?[]const u8,
    home: []const u8 = "",
};
// Reuses Letty's old-kernel file helpers, while preserving errno so an optional
// include never hides EACCES/EIO. The in-memory Reader remains usable standalone.
extern "c" fn lt_config_open([*:0]const u8) c_int;
extern "c" fn lt_length(c_int) i64;
extern "c" fn lt_pread(c_int, [*]u8, usize, u64) isize;
extern "c" fn lt_close(c_int) void;
var native_context: u8 = 0;
pub fn nativeReader(home: []const u8) Reader {
    return .{ .context = &native_context, .canonicalize = nativeCanonicalize, .read = nativeRead, .home = home };
}
fn ioError() anyerror {
    return switch (std.c.errno(@as(c_int, -1))) {
        .ACCES, .PERM => error.AccessDenied,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.PathTooLong,
        else => error.ConfigIo,
    };
}
fn missing() bool {
    return switch (std.c.errno(@as(c_int, -1))) {
        .NOENT, .NOTDIR => true,
        else => false,
    };
}
fn nativeCanonicalize(_: *anyopaque, a: std.mem.Allocator, path: []const u8) !?[]const u8 {
    if (path.len > 4095 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidIncludePath;
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    var buffer: [4096]u8 = undefined;
    const resolved = std.c.realpath(z, &buffer) orelse {
        if (missing()) return null;
        return ioError();
    };
    return try a.dupe(u8, std.mem.span(resolved));
}
fn nativeRead(_: *anyopaque, a: std.mem.Allocator, path: []const u8, limit: usize) !?[]const u8 {
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    const fd = lt_config_open(z);
    if (fd < 0) {
        if (missing()) return null;
        return ioError();
    }
    defer lt_close(fd);
    const size = lt_length(fd);
    if (size < 0) return ioError();
    if (size > limit) return error.FileSize;
    const data = try a.alloc(u8, @intCast(size));
    errdefer a.free(data);
    var at: usize = 0;
    while (at < data.len) {
        const n = lt_pread(fd, data[at..].ptr, data.len - at, at);
        if (n < 0) return ioError();
        if (n == 0) return error.ShortRead;
        at += @intCast(n);
    }
    return data;
}
pub const Frame = struct { path: []const u8, line: usize };
pub const Location = struct {
    path: []const u8,
    line: usize,
    /// Outermost to innermost config-file directives, excluding the current line.
    chain: []const Frame = &.{},
};
pub const Entry = struct { key: []const u8, value: []const u8, raw: []const u8, source: Location };
pub const Source = struct {
    path: []const u8,
    included_from: ?Location,
    optional: bool,
    missing: bool = false,
};
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,
    sources: []const Source,
    /// Compatibility root JSON is deliberately not merged with text includes.
    json: ?[]const u8 = null,
    total_bytes: usize,
    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub const Diagnostic = struct {
    path: [4096]u8 = @splat(0),
    path_len: usize = 0,
    line: usize = 0,
    key: [128]u8 = @splat(0),
    key_len: usize = 0,
    reason: [128]u8 = @splat(0),
    reason_len: usize = 0,
    chain: [16384]u8 = @splat(0),
    chain_len: usize = 0,
    chain_truncated: bool = false,
    pub fn setPath(self: *Diagnostic, path: []const u8) void {
        self.path_len = copy(&self.path, path);
    }
    pub fn fail(self: *Diagnostic, line: usize, key: []const u8, err: anyerror) void {
        self.line = line;
        self.key_len = copy(&self.key, key);
        self.reason_len = copy(&self.reason, @errorName(err));
    }
    pub fn set(self: *Diagnostic, source: Location, key: []const u8, err: anyerror) void {
        self.* = .{};
        self.path_len = copy(&self.path, source.path);
        self.line = source.line;
        self.key_len = copy(&self.key, key);
        self.reason_len = copy(&self.reason, @errorName(err));
        for (source.chain) |frame| {
            var digits: [32]u8 = undefined;
            const suffix = std.fmt.bufPrint(&digits, ":{d}\n", .{frame.line}) catch unreachable;
            self.appendChain(frame.path);
            self.appendChain(suffix);
        }
    }
    fn copy(out: []u8, in: []const u8) usize {
        const n = @min(out.len, in.len);
        @memcpy(out[0..n], in[0..n]);
        return n;
    }
    fn appendChain(self: *Diagnostic, text: []const u8) void {
        const n = copy(self.chain[self.chain_len..], text);
        self.chain_len += n;
        self.chain_truncated = self.chain_truncated or n != text.len;
    }
};

const Loader = struct {
    a: std.mem.Allocator,
    reader: Reader,
    limits: Limits,
    diagnostic: ?*Diagnostic,
    entries: std.ArrayList(Entry) = .empty,
    sources: std.ArrayList(Source) = .empty,
    stack: std.ArrayList([]const u8) = .empty,
    total: usize = 0,
    json: ?[]const u8 = null,

    fn failure(self: *Loader, location: Location, key: []const u8, err: anyerror) anyerror {
        if (self.diagnostic) |d| if (d.reason_len == 0) d.set(location, key, err);
        return err;
    }
    fn includePath(self: *Loader, parent: []const u8, name: []const u8) ![]const u8 {
        if (name.len == 0 or name.len > 4095 or std.mem.indexOfScalar(u8, name, 0) != null or !std.unicode.utf8ValidateSlice(name)) return error.InvalidIncludePath;
        if (std.mem.eql(u8, name, "~") or std.mem.startsWith(u8, name, "~/")) {
            if (self.reader.home.len == 0) return error.HomeMissing;
            return std.fmt.allocPrint(self.a, "{s}{s}", .{ self.reader.home, name[1..] });
        }
        if (std.fs.path.isAbsolute(name)) return self.a.dupe(u8, name);
        // Preserve '..' until the reader resolves symlinks; lexical normalization
        // before realpath changes the meaning of link/../file.
        return std.fs.path.join(self.a, &.{ std.fs.path.dirname(parent) orelse ".", name });
    }
    fn visit(self: *Loader, requested: []const u8, optional: bool, origin: ?Location) anyerror!void {
        const fallback = origin orelse Location{ .path = requested, .line = 0 };
        if (self.stack.items.len >= self.limits.depth) return self.failure(fallback, "config-file", error.IncludeDepth);
        if (self.sources.items.len >= self.limits.files) return self.failure(fallback, "config-file", error.TooManyConfigFiles);
        const canonical = self.reader.canonicalize(self.reader.context, self.a, requested) catch |err| return self.failure(fallback, "config-file", err);
        const path = canonical orelse requested;
        if (canonical != null and (!std.fs.path.isAbsolute(path) or path.len > 4095 or std.mem.indexOfScalar(u8, path, 0) != null)) return self.failure(fallback, "config-file", error.InvalidCanonicalPath);
        self.sources.append(self.a, .{ .path = path, .included_from = origin, .optional = optional, .missing = canonical == null }) catch |err| return self.failure(fallback, "config-file", err);
        if (canonical == null) {
            if (optional) return;
            return self.failure(fallback, "config-file", error.ConfigNotFound);
        }
        for (self.stack.items) |ancestor| if (std.mem.eql(u8, ancestor, path)) return self.failure(fallback, "config-file", error.IncludeCycle);
        var chain: []const Frame = &.{};
        if (origin) |from| {
            const allocated = self.a.alloc(Frame, from.chain.len + 1) catch |err| return self.failure(from, "config-file", err);
            @memcpy(allocated[0..from.chain.len], from.chain);
            allocated[from.chain.len] = .{ .path = from.path, .line = from.line };
            chain = allocated;
        }
        const source = Location{ .path = path, .line = 0, .chain = chain };
        const remaining = self.limits.total_bytes -| self.total;
        const data = (self.reader.read(self.reader.context, self.a, path, @min(self.limits.file_bytes, remaining)) catch |err| {
            const bounded_error = if (err == error.FileSize) (if (remaining < self.limits.file_bytes) error.ConfigTotalSize else error.ConfigFileSize) else err;
            return self.failure(source, "", bounded_error);
        }) orelse {
            self.sources.items[self.sources.items.len - 1].missing = true;
            if (optional) return;
            return self.failure(source, "", error.ConfigNotFound);
        };
        if (data.len > self.limits.file_bytes) return self.failure(source, "", error.ConfigFileSize);
        if (data.len > remaining) return self.failure(source, "", error.ConfigTotalSize);
        self.total += data.len;
        if (std.mem.indexOfScalar(u8, data, 0) != null or !std.unicode.utf8ValidateSlice(data)) return self.failure(source, "", error.InvalidConfigText);
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, data, " \t\r\n"), "{")) {
            if (origin != null) return self.failure(source, "", error.IncludedJsonUnsupported);
            self.json = data;
            return;
        }
        self.stack.append(self.a, path) catch |err| return self.failure(source, "", err);
        defer _ = self.stack.pop();
        var lines = std.mem.splitScalar(u8, data, '\n');
        var line_number: usize = 0;
        while (lines.next()) |raw| {
            line_number += 1;
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const location = Location{ .path = path, .line = line_number, .chain = chain };
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return self.failure(location, "", error.InvalidConfigLine);
            const key = std.mem.trim(u8, line[0..eq], " \t");
            if (key.len == 0) return self.failure(location, "", error.InvalidConfigLine);
            const value = unquote(line[eq + 1 ..]);
            if (std.mem.eql(u8, key, "config-file")) {
                const maybe = std.mem.startsWith(u8, value, "?");
                const child = self.includePath(path, if (maybe) value[1..] else value) catch |err| return self.failure(location, key, err);
                try self.visit(child, maybe, location);
            } else {
                if (self.entries.items.len >= self.limits.entries) return self.failure(location, key, error.TooManyConfigEntries);
                self.entries.append(self.a, .{ .key = key, .value = value, .raw = raw, .source = location }) catch |err| return self.failure(location, key, err);
            }
        }
    }
};
fn unquote(raw: []const u8) []const u8 {
    return @import("config_value.zig").unquote(raw);
}
pub fn load(a: std.mem.Allocator, reader: Reader, path: []const u8, limits: Limits, diagnostic: ?*Diagnostic) !Document {
    if (diagnostic) |d| d.* = .{};
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    var loader = Loader{ .a = arena.allocator(), .reader = reader, .limits = limits, .diagnostic = diagnostic };
    try loader.visit(path, false, null);
    const entries = try loader.entries.toOwnedSlice(loader.a);
    const sources = try loader.sources.toOwnedSlice(loader.a);
    return .{ .arena = arena, .entries = entries, .sources = sources, .json = loader.json, .total_bytes = loader.total };
}

test {
    _ = @import("config_include_test.zig");
}
