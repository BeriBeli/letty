//! Local file drop adapter, independent of nanoui's view/window callback surface.
const std = @import("std");
const nano = @import("nanoui");
const mac = @import("builtin").os.tag == .macos;
pub const Handler = *const fn (*anyopaque, []const []const u8, nano.ui.Point) bool;
const G = *anyopaque;
pub const Guard = struct {
    a: std.mem.Allocator,
    window: *nano.Window,
    ctx: *anyopaque,
    handler: Handler,
    signal: c_ulong = 0,
    pub fn install(a: std.mem.Allocator, window: *nano.Window, style: *@import("window_style.zig").State, ctx: *anyopaque, handler: Handler) !*Guard {
        const self = try a.create(Guard);
        errdefer a.destroy(self);
        self.* = .{ .a = a, .window = window, .ctx = ctx, .handler = handler };
        if (mac) {
            style.drop_ctx = ctx;
            style.drop_handler = handler;
            style.enableDrop();
        } else if (window.gtkwindow != null) {
            try load();
            const area = window.surface.?.area;
            const target = Entry{ .target = "text/uri-list", .flags = 0, .info = 1 };
            api.?.dest(area, 7, &target, 1, 1);
            self.signal = api.?.connect(area, "drag-data-received", @ptrCast(&received), self, null, 0);
            if (self.signal == 0) return error.FileDropSignal;
        }
        return self;
    }
    pub fn deinit(self: *Guard) void {
        if (!mac and self.signal != 0) if (self.window.surface) |surface| api.?.disconnect(surface.area, self.signal);
        self.a.destroy(self);
    }
};
const Entry = extern struct { target: [*:0]const u8, flags: c_uint, info: c_uint };
const Api = struct { lib: std.DynLib, dest: *const fn (G, c_int, *const Entry, c_int, c_uint) callconv(.c) void, connect: *const fn (G, [*:0]const u8, *const anyopaque, ?G, ?G, c_uint) callconv(.c) c_ulong, disconnect: *const fn (G, c_ulong) callconv(.c) void, uris: *const fn (G) callconv(.c) ?[*:null]?[*:0]u8, free: *const fn ([*:null]?[*:0]u8) callconv(.c) void, finish: *const fn (G, c_int, c_int, u32) callconv(.c) void };
var api: ?Api = null;
fn load() !void {
    if (api != null) return;
    var lib = try std.DynLib.open("libgtk-3.so.0");
    errdefer lib.close();
    var value: Api = undefined;
    value.lib = lib;
    inline for (.{ .{ "dest", "gtk_drag_dest_set" }, .{ "connect", "g_signal_connect_data" }, .{ "disconnect", "g_signal_handler_disconnect" }, .{ "uris", "gtk_selection_data_get_uris" }, .{ "free", "g_strfreev" }, .{ "finish", "gtk_drag_finish" } }) |entry| @field(value, entry[0]) = lib.lookup(@FieldType(Api, entry[0]), entry[1]) orelse return error.FileDropSymbol;
    api = value;
}
fn received(_: G, drag: G, x: c_int, y: c_int, selection: G, _: c_uint, time: u32, raw: ?G) callconv(.c) void {
    const self: *Guard = @ptrCast(@alignCast(raw.?));
    var success = false;
    defer api.?.finish(drag, @intFromBool(success), 0, time);
    const uris = api.?.uris(selection) orelse return;
    defer api.?.free(uris);
    var arena: std.heap.ArenaAllocator = .init(self.a);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    var total: usize = 0;
    while (uris[i]) |raw_uri| : (i += 1) {
        if (i >= 1024) return;
        const uri = std.mem.span(raw_uri);
        if (!std.mem.startsWith(u8, uri, "file://")) continue;
        const path = @import("paths.zig").resolve(a, uri, "/", "/") catch return;
        total += path.len;
        if (total > 1024 * 1024) return;
        files.append(a, path) catch return;
    }
    if (files.items.len > 0) success = self.handler(self.ctx, files.items, .{ .x = @floatFromInt(x), .y = @floatFromInt(y) });
}
