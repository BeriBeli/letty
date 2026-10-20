//! App-private font resources. No system installation or runtime downloads.
const std = @import("std");
const builtin = @import("builtin");
pub const family = "Maple Mono Normal NL NF CN";
pub const filenames = [_][]const u8{
    "MapleMonoNormalNL-NF-CN-Regular.ttf",
    "MapleMonoNormalNL-NF-CN-Bold.ttf",
    "MapleMonoNormalNL-NF-CN-Italic.ttf",
    "MapleMonoNormalNL-NF-CN-BoldItalic.ttf",
};
// Allocated from the process arena, before any window or text context exists.
var paths: [filenames.len]?[:0]const u8 = @splat(null);

pub fn initialize(a: std.mem.Allocator, io: std.Io) !void {
    if (paths[0] != null) return;
    const executable = try std.process.executablePathAlloc(io, a);
    const directory = std.fs.path.dirname(executable) orelse return error.InvalidExecutablePath;
    for ([_][]const u8{ "../share/letty/fonts", "../Resources/fonts" }) |relative| {
        var candidate: [filenames.len]?[:0]const u8 = @splat(null);
        var complete = true;
        for (filenames, 0..) |name, i| {
            const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}/{s}", .{ directory, relative, name }, 0);
            candidate[i] = path;
            if (access(path, 4) != 0) complete = false;
        }
        if (!complete) continue;
        if (builtin.os.tag == .macos) for (candidate) |path| try registerMac(path.?);
        paths = candidate;
        return;
    }
    return error.MissingBundledFonts;
}

/// Called before the first view measures text, and for isolated font catalogs.
/// Db owns its path copies and loaded bytes. Repeated frames do not reread files.
pub fn install(text: anytype) void {
    if (comptime @hasField(@TypeOf(text.*), "db")) {
        for (paths) |maybe_path| {
            const path = maybe_path orelse return;
            var found = false;
            for (text.db.faces.items) |face| if (std.mem.eql(u8, face.path, path)) {
                found = true;
                break;
            };
            if (!found) text.db.addFile(path);
        }
    }
}

pub fn available(text: anytype) bool {
    if (paths[0] == null) return false;
    if (comptime @hasField(@TypeOf(text.*), "db")) {
        install(text);
        const weights = [_]u16{ 400, 700, 400, 700 };
        for (paths, weights, 0..) |path, weight, i| {
            const face = text.db.family(family, weight, i >= 2) orelse return false;
            if (!std.mem.eql(u8, text.db.faces.items[face].path, path.?)) return false;
        }
        const regular = text.db.family(family, 400, false) orelse return false;
        return text.db.load(regular) != null;
    }
    return true; // CoreText registration completed before the app was created.
}

fn registerMac(path: []const u8) !void {
    const url = CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), 0) orelse return error.FontUrl;
    defer CFRelease(url);
    var err: ?*const anyopaque = null;
    const ok = CTFontManagerRegisterFontsForURL(url, 1, &err); // process scope
    defer if (err) |value| CFRelease(value);
    if (ok == 0) {
        const code = if (err) |value| CFErrorGetCode(value) else 0;
        if (code != 105 and code != 305) return error.FontRegistration;
    }
}
extern "c" fn access([*:0]const u8, c_int) c_int;
extern "c" fn CFURLCreateFromFileSystemRepresentation(?*const anyopaque, [*]const u8, isize, u8) ?*const anyopaque;
extern "c" fn CTFontManagerRegisterFontsForURL(*const anyopaque, u32, *?*const anyopaque) u8;
extern "c" fn CFErrorGetCode(*const anyopaque) isize;
extern "c" fn CFRelease(*const anyopaque) void;
