//! Ask the OS default application to open a local path or an approved URI.
const std = @import("std");
const nano = @import("nanoui");
pub fn open(value: []const u8, is_uri: bool) !void {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidLink;
    if (comptime @import("builtin").os.tag == .macos) {
        const ok = if (is_uri) nano.shell.openUrl(value) else nano.shell.openPath(value);
        if (!ok) return error.OpenExternal;
    } else {
        if (api == null) try init();
        const a = std.heap.c_allocator;
        const z = try a.dupeSentinel(u8, value, 0);
        defer a.free(z);
        const uri = if (is_uri) z.ptr else api.?.filename(z.ptr, null, null) orelse return error.InvalidLink;
        defer if (!is_uri) api.?.free(@constCast(uri));
        if (api.?.launch(uri, null, null) == 0) return error.OpenExternal;
    }
}
const Api = struct { lib: std.DynLib, launch: *const fn ([*:0]const u8, ?*anyopaque, ?*anyopaque) callconv(.c) c_int, filename: *const fn ([*:0]const u8, ?[*:0]const u8, ?*anyopaque) callconv(.c) ?[*:0]u8, free: *const fn (?*anyopaque) callconv(.c) void };
var api: ?Api = null;
fn init() !void {
    var lib = try std.DynLib.open("libgio-2.0.so.0");
    errdefer lib.close();
    api = .{ .lib = lib, .launch = lib.lookup(@FieldType(Api, "launch"), "g_app_info_launch_default_for_uri") orelse return error.OpenSymbol, .filename = lib.lookup(@FieldType(Api, "filename"), "g_filename_to_uri") orelse return error.OpenSymbol, .free = lib.lookup(@FieldType(Api, "free"), "g_free") orelse return error.OpenSymbol };
}
