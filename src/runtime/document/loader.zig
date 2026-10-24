//! Owned native-worker bridge. No UI/config pointers cross this boundary.
const std = @import("std");
pub const max_path = 4095;
pub const max_text_bytes = 2 * 1024 * 1024;
pub const max_image_bytes = 8 * 1024 * 1024;
pub const max_lines = 50000;
pub const Kind = enum(c_int) { text = 0, markdown, image, unsupported };
pub const Status = enum(c_int) { closed = 0, loading, ready, missing, permission, too_large, unsupported, invalid_utf8, not_regular, symlink, watch_error, io_error, cancelled, invalid_image };
pub const Hooks = extern struct {
    context: ?*anyopaque = null,
    prepare: ?*const fn (?*anyopaque, [*:0]const u8, [*]const u8, usize, c_int, *?*anyopaque) callconv(.c) c_int = null,
    release: ?*const fn (?*anyopaque, *anyopaque) callconv(.c) void = null,
};
pub const Prepared = struct {
    value: *anyopaque,
    hooks: Hooks,
    pub fn deinit(self: Prepared) void {
        if (self.hooks.release) |release| release(self.hooks.context, self.value);
    }
};
const Raw = extern struct {
    generation: u64,
    status: c_int,
    kind: c_int,
    changed: u32,
    watch_available: u32,
    width: u32,
    height: u32,
    length: usize,
    lines: usize,
    allocation: usize,
    bytes: ?[*]u8,
    prepared: ?*anyopaque,
    hooks: Hooks,
};
const Context = opaque {};
extern "c" fn lt_preview_create_with_hooks([*:0]const u8, u64, *const Hooks) ?*Context;
extern "c" fn lt_preview_fd(*const Context) c_int;
extern "c" fn lt_preview_refresh(*Context, u64) c_int;
extern "c" fn lt_preview_drain(*Context, *Raw) c_int;
extern "c" fn lt_preview_result_free(*Raw) void;
extern "c" fn lt_preview_destroy(*Context) void;
extern "c" fn lt_preview_read_resource([*:0]const u8, [*:0]const u8, *Raw) c_int;
pub const Result = struct {
    raw: Raw,
    pub fn deinit(self: *Result) void {
        lt_preview_result_free(&self.raw);
    }
    pub fn takePrepared(self: *Result) ?Prepared {
        const value = self.raw.prepared orelse return null;
        self.raw.prepared = null;
        return .{ .value = value, .hooks = self.raw.hooks };
    }
};
pub const Loader = struct {
    handle: *Context,
    pub fn init(path: []const u8, generation: u64, hooks: Hooks) !Loader {
        try validatePath(path);
        var owned: [max_path + 1:0]u8 = @splat(0);
        @memcpy(owned[0..path.len], path);
        return .{ .handle = lt_preview_create_with_hooks(&owned, generation, &hooks) orelse return error.PreviewLoaderUnavailable };
    }
    pub fn fd(self: *const Loader) c_int {
        return lt_preview_fd(self.handle);
    }
    pub fn refresh(self: *Loader, generation: u64) !void {
        if (lt_preview_refresh(self.handle, generation) != 0) return error.PreviewRefreshFailed;
    }
    pub fn drain(self: *Loader) !?Result {
        var raw: Raw = undefined;
        return switch (lt_preview_drain(self.handle, &raw)) {
            0 => null,
            1 => .{ .raw = raw },
            else => error.PreviewDrainFailed,
        };
    }
    pub fn deinit(self: *Loader) void {
        lt_preview_destroy(self.handle);
        self.* = undefined;
    }
};
pub fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path.len > max_path or path[0] != '/' or path[path.len - 1] == '/' or !std.unicode.utf8ValidateSlice(path)) return error.InvalidPreviewPath;
    for (path) |byte| if (byte < 32 or byte == 127) return error.InvalidPreviewPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidPreviewPath;
}
/// Only call from a background prepare hook. Returned bytes use gpa; the C
/// scratch allocation is released before returning. Never watches resources.
pub fn readResource(gpa: std.mem.Allocator, document_path: []const u8, relative_ref: []const u8) ![]u8 {
    try validatePath(document_path);
    if (relative_ref.len == 0 or relative_ref.len > max_path or std.mem.indexOfScalar(u8, relative_ref, 0) != null) return error.InvalidPreviewResource;
    var path: [max_path + 1:0]u8 = @splat(0);
    var reference: [max_path + 1:0]u8 = @splat(0);
    @memcpy(path[0..document_path.len], document_path);
    @memcpy(reference[0..relative_ref.len], relative_ref);
    var result: Result = undefined;
    if (lt_preview_read_resource(&path, &reference, &result.raw) != 0) return error.PreviewResourceUnavailable;
    defer result.deinit();
    if (result.raw.status != @backingInt(Status.ready) or result.raw.kind != @backingInt(Kind.image)) return switch (std.enums.fromInt(Status, result.raw.status) orelse .io_error) {
        .permission => error.PreviewResourcePermission,
        .too_large => error.PreviewResourceTooLarge,
        .missing => error.PreviewResourceMissing,
        .symlink => error.PreviewResourceSymlink,
        else => error.PreviewResourceUnsupported,
    };
    const pointer = result.raw.bytes orelse return error.PreviewResourceUnavailable;
    return gpa.dupe(u8, pointer[0..result.raw.length]);
}
test "preview paths reject remote controls traversal and malformed Unicode" {
    for ([_][]const u8{ "", "file:///tmp/a", "https://example.invalid/a", "/a\x00b", "/a\nb", "/a/../b", "/a/./b", "/a/", "/\xff" }) |path| try std.testing.expectError(error.InvalidPreviewPath, validatePath(path));
    try validatePath("/private/tmp/中文 file:12.md");
}
