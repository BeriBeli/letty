//! Local clipboard files/images become quoted paths, with bounded owned storage.
const std = @import("std");
const nano = @import("nanoui");
const os = @import("platform.zig");
const mac = @import("builtin").os.tag == .macos;
pub fn freeFiles(a: std.mem.Allocator, files: [][]u8) void {
    for (files) |path| a.free(path);
    a.free(files);
}
pub fn paths(a: std.mem.Allocator, files: []const []const u8, shell: []const u8) ![]const u8 {
    if (files.len > 1024) return error.PasteLimit;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    for (files, 0..) |file, i| {
        if (file.len == 0 or !std.fs.path.isAbsolute(file) or std.mem.indexOfScalar(u8, file, 0) != null) return error.InvalidPastePath;
        const quoted = try @import("shell.zig").quote(a, std.fs.path.basename(shell), file);
        defer a.free(quoted);
        if (out.written().len + quoted.len > 1024 * 1024 - 16) return error.PasteLimit;
        if (i > 0) try out.writer.writeByte(' ');
        try out.writer.writeAll(quoted);
    }
    return out.toOwnedSlice();
}
pub const Store = struct {
    directory: []const u8 = "",
    files: std.ArrayList([]const u8) = .empty,
    bytes: usize = 0,
    pub fn deinit(self: *Store, a: std.mem.Allocator) void {
        for (self.files.items) |file| {
            const z = a.dupeSentinel(u8, file, 0) catch {
                a.free(file);
                continue;
            };
            _ = os.c.unlink(z);
            a.free(z);
            a.free(file);
        }
        self.files.deinit(a);
        if (self.directory.len > 0) {
            const z = a.dupeSentinel(u8, self.directory, 0) catch {
                a.free(self.directory);
                self.* = .{};
                return;
            };
            _ = os.c.rmdir(z);
            a.free(z);
            a.free(self.directory);
        }
        self.* = .{};
    }
    pub fn image(self: *Store, a: std.mem.Allocator, png: []const u8) ![]const u8 {
        try validate(png);
        if (self.files.items.len >= 64 or png.len > 128 * 1024 * 1024 -| self.bytes) return error.PasteStorageFull;
        if (self.directory.len == 0) {
            var buffer: [128]u8 = undefined;
            const temp = try std.fmt.bufPrintSentinel(&buffer, "/tmp/letty-paste-XXXXXX", .{}, 0);
            const created = os.c.mkdtemp(temp.ptr) orelse return error.PasteDirectory;
            self.directory = a.dupe(u8, std.mem.span(created)) catch |err| {
                _ = os.c.rmdir(created);
                return err;
            };
        }
        try self.files.ensureUnusedCapacity(a, 1);
        const file = try std.fmt.allocPrint(a, "{s}/image-{d}.png", .{ self.directory, self.files.items.len + 1 });
        errdefer a.free(file);
        try os.atomicFile(a, file, png);
        self.files.appendAssumeCapacity(file);
        self.bytes += png.len;
        return file;
    }
};
pub fn validate(bytes: []const u8) !void {
    if (bytes.len < 24 or bytes.len > 32 * 1024 * 1024 or !std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return error.PasteImageLimit;
    const w = std.mem.readInt(u32, bytes[16..20], .big);
    const h = std.mem.readInt(u32, bytes[20..24], .big);
    if (w == 0 or h == 0 or @as(u64, w) * h > 16 * 1024 * 1024) return error.PasteImageLimit;
}
pub fn readFiles(a: std.mem.Allocator) !?[][]u8 {
    if (mac) {
        const objc = nano.objc;
        const pool = objc.Pool.push();
        defer pool.pop();
        const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
        const classes = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{objc.class("NSURL")});
        const urls = objc.msg(?objc.Object, pb, "readObjectsForClasses:options:", .{ classes, @as(?objc.Object, null) }) orelse return null;
        const count = objc.msg(usize, urls, "count", .{});
        if (count > 1024) return error.PasteLimit;
        var files: std.ArrayList([]u8) = .empty;
        errdefer {
            for (files.items) |file| a.free(file);
            files.deinit(a);
        }
        var total: usize = 0;
        for (0..count) |index| {
            const url = objc.msg(objc.Object, urls, "objectAtIndex:", .{index});
            if (!objc.msg(bool, url, "isFileURL", .{})) continue;
            const path = objc.fromNSString(objc.msg(?objc.Object, url, "path", .{}));
            total += path.len;
            if (total > 1024 * 1024) return error.PasteLimit;
            const owned = try a.dupe(u8, path);
            errdefer a.free(owned);
            try files.append(a, owned);
        }
        if (files.items.len == 0) {
            files.deinit(a);
            return null;
        }
        return try files.toOwnedSlice(a);
    }
    try load();
    const api = &gtk.?;
    const board = api.board(api.atom("CLIPBOARD", 0));
    const values = api.uris(board) orelse return null;
    defer api.strfree(values);
    var files: std.ArrayList([]u8) = .empty;
    errdefer {
        for (files.items) |file| a.free(file);
        files.deinit(a);
    }
    var i: usize = 0;
    var total: usize = 0;
    while (values[i]) |value| : (i += 1) {
        if (i >= 1024) return error.PasteLimit;
        const uri = std.mem.span(value);
        if (!std.mem.startsWith(u8, uri, "file://")) continue;
        const file = try @import("paths.zig").resolve(a, uri, "/", "/");
        errdefer a.free(file);
        total += file.len;
        if (total > 1024 * 1024) return error.PasteLimit;
        try files.append(a, @constCast(file));
    }
    if (files.items.len == 0) {
        files.deinit(a);
        return null;
    }
    return try files.toOwnedSlice(a);
}
pub fn readImage(a: std.mem.Allocator) !?[]u8 {
    if (mac) {
        const objc = nano.objc;
        const pool = objc.Pool.push();
        defer pool.pop();
        const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
        const data = objc.msg(?objc.Object, pb, "dataForType:", .{objc.nsString("public.png")}) orelse blk: {
            const tiff = objc.msg(?objc.Object, pb, "dataForType:", .{objc.nsString("public.tiff")}) orelse return null;
            if (objc.msg(usize, tiff, "length", .{}) > 32 * 1024 * 1024) return error.PasteImageLimit;
            const source = CGImageSourceCreateWithData(tiff, null) orelse return null;
            defer CFRelease(source);
            const props = CGImageSourceCopyPropertiesAtIndex(source, 0, null) orelse return null;
            defer CFRelease(props);
            const w = objc.msg(?objc.Object, props, "objectForKey:", .{kCGImagePropertyPixelWidth}) orelse return null;
            const h = objc.msg(?objc.Object, props, "objectForKey:", .{kCGImagePropertyPixelHeight}) orelse return null;
            const width = objc.msg(u64, w, "unsignedLongLongValue", .{});
            const height = objc.msg(u64, h, "unsignedLongLongValue", .{});
            if (width == 0 or height == 0 or width > 16 * 1024 * 1024 or height > 16 * 1024 * 1024 or width * height > 16 * 1024 * 1024) return error.PasteImageLimit;
            const rep = objc.msg(?objc.Object, objc.class("NSBitmapImageRep"), "imageRepWithData:", .{tiff}) orelse return null;
            break :blk objc.msg(?objc.Object, rep, "representationUsingType:properties:", .{ @as(usize, 4), objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{}) }) orelse return null;
        };
        const count = objc.msg(usize, data, "length", .{});
        if (count > 32 * 1024 * 1024) return error.PasteImageLimit;
        const bytes = objc.msg([*]const u8, data, "bytes", .{})[0..count];
        try validate(bytes);
        return try a.dupe(u8, bytes);
    }
    try load();
    const api = &gtk.?;
    const board = api.board(api.atom("CLIPBOARD", 0));
    const selection = api.contents(board, api.atom("image/png", 0)) orelse return null;
    defer api.selection_free(selection);
    const count = api.length(selection);
    if (count <= 0) return null;
    if (count > 32 * 1024 * 1024) return error.PasteImageLimit;
    const ptr = api.data(selection) orelse return null;
    const bytes = ptr[0..@intCast(count)];
    try validate(bytes);
    return try a.dupe(u8, bytes);
}
const G = *anyopaque;
const Gtk = struct { lib: std.DynLib, atom: *const fn ([*:0]const u8, c_int) callconv(.c) G, board: *const fn (G) callconv(.c) G, uris: *const fn (G) callconv(.c) ?[*:null]?[*:0]u8, strfree: *const fn ([*:null]?[*:0]u8) callconv(.c) void, contents: *const fn (G, G) callconv(.c) ?G, length: *const fn (G) callconv(.c) c_int, data: *const fn (G) callconv(.c) ?[*]const u8, selection_free: *const fn (G) callconv(.c) void };
var gtk: ?Gtk = null;
fn load() !void {
    if (gtk != null) return;
    var lib = try std.DynLib.open("libgtk-3.so.0");
    errdefer lib.close();
    var api: Gtk = undefined;
    api.lib = lib;
    inline for (.{ .{ "atom", "gdk_atom_intern" }, .{ "board", "gtk_clipboard_get" }, .{ "uris", "gtk_clipboard_wait_for_uris" }, .{ "strfree", "g_strfreev" }, .{ "contents", "gtk_clipboard_wait_for_contents" }, .{ "length", "gtk_selection_data_get_length" }, .{ "data", "gtk_selection_data_get_data" }, .{ "selection_free", "gtk_selection_data_free" } }) |entry| @field(api, entry[0]) = lib.lookup(@FieldType(Gtk, entry[0]), entry[1]) orelse return error.ClipboardSymbol;
    gtk = api;
}

const Obj = if (mac) nano.objc.Object else *anyopaque;
extern "c" fn CGImageSourceCreateWithData(Obj, ?Obj) ?Obj;
extern "c" fn CGImageSourceCopyPropertiesAtIndex(Obj, usize, ?Obj) ?Obj;
extern "c" const kCGImagePropertyPixelWidth: Obj;
extern "c" const kCGImagePropertyPixelHeight: Obj;
extern "c" fn CFRelease(Obj) void;
