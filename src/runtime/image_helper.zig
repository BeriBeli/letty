//! Isolated image decoder. The GUI receives only a bounded PNG thumbnail.
const std = @import("std");
const nano = @import("nanoui");
const os = @import("platform.zig");
const Obj = *anyopaque;
pub fn run(a: std.mem.Allocator, path: []const u8) !void {
    if (comptime @import("builtin").os.tag == .linux) {
        const Limit = extern struct { current: usize, maximum: usize };
        const api = struct {
            extern "c" fn setrlimit(c_int, *const Limit) c_int;
        };
        _ = api.setrlimit(9, &.{ .current = 512 * 1024 * 1024, .maximum = 512 * 1024 * 1024 });
    }
    const bytes = try os.readFile(a, path, 64 * 1024 * 1024);
    defer a.free(bytes);
    const pixels = if (comptime @import("builtin").os.tag == .macos) try mac(a, bytes) else try linux(a, bytes);
    defer a.free(pixels.bytes);
    const png = try nano.ui.png.encode(a, pixels);
    defer a.free(png);
    if (png.len > 8 * 1024 * 1024) return error.ImageLimit;
    try os.output(png);
}
fn mac(a: std.mem.Allocator, bytes: []const u8) !nano.ui.gpu.Pixels {
    const objc = nano.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    const data = objc.msg(Obj, objc.class("NSData"), "dataWithBytes:length:", .{ bytes.ptr, bytes.len });
    const source = CGImageSourceCreateWithData(data, null) orelse return error.NotImage;
    defer CFRelease(source);
    const maximum = objc.msg(Obj, objc.class("NSNumber"), "numberWithUnsignedInteger:", .{@as(usize, 1024)});
    const yes = objc.msg(Obj, objc.class("NSNumber"), "numberWithBool:", .{true});
    const opts = objc.msg(Obj, objc.class("NSMutableDictionary"), "dictionary", .{});
    objc.msg(void, opts, "setObject:forKey:", .{ maximum, kCGImageSourceThumbnailMaxPixelSize });
    objc.msg(void, opts, "setObject:forKey:", .{ yes, kCGImageSourceCreateThumbnailFromImageAlways });
    objc.msg(void, opts, "setObject:forKey:", .{ yes, kCGImageSourceCreateThumbnailWithTransform });
    const image = CGImageSourceCreateThumbnailAtIndex(source, 0, opts) orelse return error.NotImage;
    defer CGImageRelease(image);
    const w = CGImageGetWidth(image);
    const h = CGImageGetHeight(image);
    if (w == 0 or h == 0 or w > 1024 or h > 1024) return error.ImageLimit;
    const buffer = try a.alloc(u8, w * h * 4);
    errdefer a.free(buffer);
    @memset(buffer, 0);
    const space = CGColorSpaceCreateDeviceRGB() orelse return error.ImageColor;
    defer CGColorSpaceRelease(space);
    const context = CGBitmapContextCreate(buffer.ptr, w, h, 8, w * 4, space, 2 | (2 << 12)) orelse return error.ImageContext;
    defer CGContextRelease(context);
    CGContextDrawImage(context, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) } }, image);
    return .{ .bytes = buffer, .width = @intCast(w), .height = @intCast(h) };
}
extern "c" fn CGImageSourceCreateWithData(Obj, ?Obj) ?Obj;
extern "c" fn CGImageSourceCreateThumbnailAtIndex(Obj, usize, ?Obj) ?Obj;
extern "c" const kCGImageSourceThumbnailMaxPixelSize: Obj;
extern "c" const kCGImageSourceCreateThumbnailFromImageAlways: Obj;
extern "c" const kCGImageSourceCreateThumbnailWithTransform: Obj;
extern "c" fn CFRelease(Obj) void;
extern "c" fn CGImageRelease(Obj) void;
extern "c" fn CGImageGetWidth(Obj) usize;
extern "c" fn CGImageGetHeight(Obj) usize;
extern "c" fn CGColorSpaceCreateDeviceRGB() ?Obj;
extern "c" fn CGColorSpaceRelease(Obj) void;
extern "c" fn CGBitmapContextCreate([*]u8, usize, usize, usize, usize, Obj, u32) ?Obj;
extern "c" fn CGContextRelease(Obj) void;
extern "c" fn CGContextDrawImage(Obj, extern struct { origin: extern struct { x: f64, y: f64 }, size: extern struct { width: f64, height: f64 } }, Obj) void;
const Pixbuf = struct {
    loader: *const fn () callconv(.c) ?Obj,
    size: *const fn (Obj, c_int, c_int) callconv(.c) void,
    write: *const fn (Obj, [*]const u8, usize, ?*anyopaque) callconv(.c) c_int,
    close: *const fn (Obj, ?*anyopaque) callconv(.c) c_int,
    get: *const fn (Obj) callconv(.c) ?Obj,
    width: *const fn (Obj) callconv(.c) c_int,
    height: *const fn (Obj) callconv(.c) c_int,
    stride: *const fn (Obj) callconv(.c) c_int,
    channels: *const fn (Obj) callconv(.c) c_int,
    pixels: *const fn (Obj) callconv(.c) [*]const u8,
    unref: *const fn (Obj) callconv(.c) void,
    connect: *const fn (Obj, [*:0]const u8, *const anyopaque, ?*anyopaque, ?*anyopaque, c_int) callconv(.c) c_ulong,
};
fn linux(a: std.mem.Allocator, bytes: []const u8) !nano.ui.gpu.Pixels {
    var lib = try std.DynLib.open("libgdk_pixbuf-2.0.so.0");
    defer lib.close();
    var api: Pixbuf = undefined;
    const names = .{ .{ "loader", "gdk_pixbuf_loader_new" }, .{ "size", "gdk_pixbuf_loader_set_size" }, .{ "write", "gdk_pixbuf_loader_write" }, .{ "close", "gdk_pixbuf_loader_close" }, .{ "get", "gdk_pixbuf_loader_get_pixbuf" }, .{ "width", "gdk_pixbuf_get_width" }, .{ "height", "gdk_pixbuf_get_height" }, .{ "stride", "gdk_pixbuf_get_rowstride" }, .{ "channels", "gdk_pixbuf_get_n_channels" }, .{ "pixels", "gdk_pixbuf_get_pixels" }, .{ "unref", "g_object_unref" }, .{ "connect", "g_signal_connect_data" } };
    inline for (names) |entry| @field(api, entry[0]) = lib.lookup(@FieldType(Pixbuf, entry[0]), entry[1]) orelse return error.ImageSymbol;
    const loader = api.loader() orelse return error.ImageLoader;
    defer api.unref(loader);
    const callback = struct {
        fn prepared(value: Obj, w: c_int, h: c_int, raw: ?*anyopaque) callconv(.c) void {
            const p: *Pixbuf = @ptrCast(@alignCast(raw.?));
            if (w <= 0 or h <= 0) return;
            const scale = @min(1.0, @min(1024.0 / @as(f64, @floatFromInt(w)), 1024.0 / @as(f64, @floatFromInt(h))));
            p.size(value, @intFromFloat(@max(1, @as(f64, @floatFromInt(w)) * scale)), @intFromFloat(@max(1, @as(f64, @floatFromInt(h)) * scale)));
        }
    }.prepared;
    _ = api.connect(loader, "size-prepared", @ptrCast(&callback), &api, null, 0);
    if (api.write(loader, bytes.ptr, bytes.len, null) == 0) return error.NotImage;
    if (api.close(loader, null) == 0) return error.NotImage;
    const pix = api.get(loader) orelse return error.NotImage;
    const width = api.width(pix);
    const height = api.height(pix);
    const stride = api.stride(pix);
    const channels = api.channels(pix);
    if (width <= 0 or height <= 0 or width > 1024 or height > 1024 or (channels != 3 and channels != 4) or stride < width * channels) return error.ImageLimit;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const source = api.pixels(pix);
    const out = try a.alloc(u8, w * h * 4);
    errdefer a.free(out);
    for (0..h) |y| for (0..w) |x| {
        const from = y * @as(usize, @intCast(stride)) + x * @as(usize, @intCast(channels));
        const to = (y * w + x) * 4;
        const alpha: u16 = if (channels == 4) source[from + 3] else 255;
        out[to] = @intCast((@as(u16, source[from + 2]) * alpha + 127) / 255);
        out[to + 1] = @intCast((@as(u16, source[from + 1]) * alpha + 127) / 255);
        out[to + 2] = @intCast((@as(u16, source[from]) * alpha + 127) / 255);
        out[to + 3] = @intCast(alpha);
    };
    return .{ .bytes = out, .width = @intCast(width), .height = @intCast(height) };
}
