//! Bounded, local-only theme catalog and owned preview candidates for nanoui.
//! No Window/Host mutations are hidden here. Preview applies only visual fields;
//! Apply transfers candidate ownership to the host; Save is a separate checked
//! disk operation. Restore a previewing window BEFORE cancelling/deinitializing
//! its candidate, and keep an applied candidate alive while a Config borrows it.
const std = @import("std");
const config = @import("config.zig");
const edit = @import("config_edit.zig");
pub const Origin = enum { builtin, bundled, user };
pub const Root = struct { directory: []const u8, origin: Origin, optional: bool = true };
pub const Entry = struct {
    name: []const u8,
    /// Physical absolute path for files, built-in selector otherwise.
    selector: []const u8,
    origin: Origin,
};
pub const Limits = struct { roots: usize = 8, entries: usize = 512, scanned: usize = 2048, name_bytes: usize = 256 * 1024 };
pub const ScanResult = struct { scanned: usize, truncated: bool = false };
pub const Visitor = struct { context: *anyopaque, visit: *const fn (*anyopaque, []const u8) anyerror!void };
pub const Reader = struct {
    context: *anyopaque,
    canonicalize: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!?[]const u8,
    scan: *const fn (*anyopaque, std.mem.Allocator, []const u8, usize, Visitor) anyerror!ScanResult,
};
const Collector = struct {
    a: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    directory: []const u8 = "",
    origin: Origin = .user,
    limits: Limits,
    bytes: usize = 0,
    fn visit(raw: *anyopaque, name: []const u8) !void {
        const self: *Collector = @ptrCast(@alignCast(raw));
        if (name.len == 0 or name.len > 255 or !std.unicode.utf8ValidateSlice(name) or std.mem.indexOfAny(u8, name, "/\x00\r\n\"") != null) return;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return;
        if (self.entries.items.len >= self.limits.entries) return error.CatalogLimit;
        const cost = self.directory.len + 1 + name.len * 2;
        if (cost > self.limits.name_bytes -| self.bytes) return error.CatalogLimit;
        for (self.entries.items) |entry| if (std.mem.eql(u8, std.fs.path.basename(entry.selector), name) and
            std.mem.eql(u8, std.fs.path.dirname(entry.selector) orelse "", self.directory)) return;
        const selector = try std.fs.path.join(self.a, &.{ self.directory, name });
        try self.entries.append(self.a, .{ .name = try self.a.dupe(u8, name), .selector = selector, .origin = self.origin });
        self.bytes += cost;
    }
};
pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,
    scanned: usize,
    truncated: bool,
    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn scan(gpa: std.mem.Allocator, roots: []const Root, reader: Reader, limits: Limits) !Catalog {
        if (roots.len > limits.roots or limits.roots > 8 or limits.entries == 0 or limits.entries > 4096 or limits.scanned > 65536 or limits.name_bytes > 4 * 1024 * 1024) return error.InvalidCatalogLimits;
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var collector: Collector = .{ .a = a, .limits = limits };
        try collector.entries.append(a, .{ .name = "Letty", .selector = "letty", .origin = .builtin });
        if (limits.entries > 1) try collector.entries.append(a, .{ .name = "Paper", .selector = "paper", .origin = .builtin });
        var total: usize = 0;
        var truncated = limits.entries == 1;
        for (roots) |root| {
            if (total >= limits.scanned) {
                truncated = true;
                break;
            }
            const directory = (try reader.canonicalize(reader.context, a, root.directory)) orelse {
                if (root.optional) continue;
                return error.ThemeDirectoryNotFound;
            };
            if (directory.len > 4095 or !std.fs.path.isAbsolute(directory) or !std.unicode.utf8ValidateSlice(directory)) return error.InvalidThemeDirectory;
            collector.directory = directory;
            collector.origin = root.origin;
            const result = reader.scan(reader.context, a, directory, limits.scanned - total, .{ .context = &collector, .visit = Collector.visit }) catch |err| switch (err) {
                error.CatalogLimit => {
                    truncated = true;
                    break;
                },
                else => return err,
            };
            if (result.scanned > limits.scanned - total) return error.InvalidScannerResult;
            total += result.scanned;
            truncated = truncated or result.truncated;
            if (result.truncated) break;
        }
        std.mem.sort(Entry, collector.entries.items, {}, struct {
            fn less(_: void, left: Entry, right: Entry) bool {
                const order = std.ascii.orderIgnoreCase(left.name, right.name);
                if (order != .eq) return order == .lt;
                return std.mem.order(u8, left.selector, right.selector) == .lt;
            }
        }.less);
        return .{ .arena = arena, .entries = try collector.entries.toOwnedSlice(a), .scanned = total, .truncated = truncated };
    }
    /// Writes matching catalog indices into caller-owned bounded storage.
    pub fn filter(self: *const Catalog, query: []const u8, output: []usize) !usize {
        if (query.len > 256 or !std.unicode.utf8ValidateSlice(query)) return error.InvalidThemeQuery;
        var count: usize = 0;
        for (self.entries, 0..) |entry, index| if (query.len == 0 or std.ascii.findIgnoreCase(entry.name, query) != null) {
            if (count == output.len) return error.ResultBufferTooSmall;
            output[count] = index;
            count += 1;
        };
        return count;
    }
};
extern "c" fn lt_config_theme_scan([*:0]const u8, usize, *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) c_int, ?*anyopaque, *usize, *c_int) c_int;
var native_context: u8 = 0;
pub fn nativeReader() Reader {
    return .{ .context = &native_context, .canonicalize = nativeCanonicalize, .scan = nativeScan };
}
fn nativeCanonicalize(_: *anyopaque, a: std.mem.Allocator, path: []const u8) !?[]const u8 {
    if (path.len == 0 or path.len > 4095 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidThemeDirectory;
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    var buffer: [4096]u8 = undefined;
    const physical = std.c.realpath(z, &buffer) orelse return switch (std.c.errno(@as(c_int, -1))) {
        .NOENT, .NOTDIR => null,
        .ACCES, .PERM => error.AccessDenied,
        else => error.ThemeScanIo,
    };
    return try a.dupe(u8, std.mem.span(physical));
}
fn nativeScan(_: *anyopaque, a: std.mem.Allocator, directory: []const u8, limit: usize, visitor: Visitor) !ScanResult {
    const Adapter = struct {
        visitor: Visitor,
        failure: ?anyerror = null,
        fn receive(raw: ?*anyopaque, name: [*]const u8, len: usize) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.visitor.visit(self.visitor.context, name[0..len]) catch |err| {
                self.failure = err;
                return -1;
            };
            return 0;
        }
    };
    var adapter: Adapter = .{ .visitor = visitor };
    const z = try a.dupeSentinel(u8, directory, 0);
    defer a.free(z);
    var count: usize = 0;
    var truncated: c_int = 0;
    const result = lt_config_theme_scan(z, limit, Adapter.receive, &adapter, &count, &truncated);
    if (adapter.failure) |err| {
        if (err == error.CatalogLimit) return .{ .scanned = count, .truncated = true };
        return err;
    }
    if (result != 0) return switch (std.c.errno(@as(c_int, -1))) {
        .ACCES, .PERM => error.AccessDenied,
        else => error.ThemeScanIo,
    };
    return .{ .scanned = count, .truncated = truncated != 0 };
}

const visual_fields = .{ "theme", "foreground", "background", "cursor", "explicit_cursor", "explicit_selection_fg", "explicit_selection_bg", "selection_foreground", "selection_background", "palette", "ui_panel", "ui_border", "ui_accent", "split_divider_color", "font_features", "font_ligatures", "theme_branches" };
pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    cfg: config.Config,
    replacement: []const u8,
    /// Pure file-backed validation: reader redirects only the captured physical
    /// root to edited owned bytes; included files and selected theme use reader.
    pub fn prepare(gpa: std.mem.Allocator, snapshot: edit.Snapshot, entry: Entry, reader: config.includes.Reader, diagnostic: ?*config.Diagnostic) !Candidate {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const replacement = try edit.replaceTheme(a, snapshot.bytes, entry.selector);
        const Redirect = struct {
            base: config.includes.Reader,
            path: []const u8,
            replacement: []const u8,
            fn canonical(raw: *anyopaque, alloc: std.mem.Allocator, name: []const u8) !?[]const u8 {
                const self: *@This() = @ptrCast(@alignCast(raw));
                if (std.mem.eql(u8, name, self.path)) return try alloc.dupe(u8, self.path);
                return self.base.canonicalize(self.base.context, alloc, name);
            }
            fn read(raw: *anyopaque, alloc: std.mem.Allocator, name: []const u8, limit: usize) !?[]const u8 {
                const self: *@This() = @ptrCast(@alignCast(raw));
                if (std.mem.eql(u8, name, self.path)) {
                    if (self.replacement.len > limit) return error.FileSize;
                    return try alloc.dupe(u8, self.replacement);
                }
                return self.base.read(self.base.context, alloc, name, limit);
            }
        };
        var redirect: Redirect = .{ .base = reader, .path = snapshot.path, .replacement = replacement };
        const cfg = try config.loadWithReaderDetailed(a, .{ .context = &redirect, .canonicalize = Redirect.canonical, .read = Redirect.read, .home = reader.home }, snapshot.path, .{}, diagnostic);
        if (!std.mem.eql(u8, cfg.forAppearance(false).theme, entry.selector) or !std.mem.eql(u8, cfg.forAppearance(true).theme, entry.selector)) return error.ThemeOverriddenByInclude;
        return .{ .arena = arena, .cfg = cfg, .replacement = replacement };
    }
    /// Returned strings/colors borrow this candidate; preserve temporary zoom
    /// and every non-theme window setting. No Host/session effects occur here.
    pub fn preview(self: *const Candidate, current: config.Config, dark: bool) config.Config {
        var result = current;
        const selected = self.cfg.forAppearance(dark);
        inline for (visual_fields) |field| @field(result, field) = @field(selected, field);
        return result;
    }
    pub fn save(self: *const Candidate, a: std.mem.Allocator, original: edit.Snapshot) !edit.SaveResult {
        return edit.Native.save(a, original, self.replacement);
    }
    pub fn deinit(self: *Candidate) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub const Phase = enum { browsing, preview, applied, saved, cancelled };
pub const Controller = struct {
    selected: ?usize = null,
    phase: Phase = .browsing,
    candidate: ?Candidate = null,
    pub fn select(self: *Controller, catalog: *const Catalog, index: usize) !Entry {
        if (self.phase == .applied or self.phase == .saved or self.phase == .cancelled) return error.BrowserClosed;
        if (index >= catalog.entries.len) return error.InvalidThemeSelection;
        self.selected = index;
        return catalog.entries[index];
    }
    /// Caller restores the old window visual before replacing an older preview.
    pub fn preview(self: *Controller, candidate: Candidate) !void {
        if (self.phase == .applied or self.phase == .saved or self.phase == .cancelled) return error.BrowserClosed;
        if (self.candidate) |*old| old.deinit();
        self.candidate = candidate;
        self.phase = .preview;
    }
    /// Ownership transfer: host stores the returned candidate for the lifetime
    /// of any Config referencing it. Apply alone never writes root config.
    pub fn apply(self: *Controller) !Candidate {
        const result = self.candidate orelse return error.NoThemePreview;
        self.candidate = null;
        self.phase = .applied;
        return result;
    }
    /// Saving is explicit and does not itself apply colors to a Window/Host.
    pub fn save(self: *Controller, a: std.mem.Allocator, snapshot: edit.Snapshot) !edit.SaveResult {
        const candidate = if (self.candidate) |*value| value else return error.NoThemePreview;
        const result = try candidate.save(a, snapshot);
        self.phase = .saved;
        return result;
    }
    /// Restore the target window's original Config/zoom before calling cancel.
    pub fn cancel(self: *Controller) void {
        self.deinit();
        self.phase = .cancelled;
    }
    pub fn deinit(self: *Controller) void {
        if (self.candidate) |*candidate| candidate.deinit();
        self.candidate = null;
    }
};
test {
    _ = @import("theme_browser_test.zig");
}
