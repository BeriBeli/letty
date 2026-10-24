//! Kero's bundled JetBrains Mono Nerd Font, registered only in this process.
const std = @import("std");
const mac = @import("builtin").os.tag == .macos;
pub const family = "JetBrainsMono Nerd Font";
const names = [_][]const u8{ "Regular", "Bold", "Italic", "BoldItalic", "ExtraBold", "Light", "Medium", "SemiBold" };
var paths: [names.len]?[:0]const u8 = @splat(null);
pub fn load(a: std.mem.Allocator, io: std.Io) !void {
    const exe = try std.process.executablePathAlloc(io, a);
    const bin = std.fs.path.dirname(exe) orelse return error.ExecutablePath;
    var dir = try std.fmt.allocPrint(a, "{s}/../share/letty/terminal/fonts", .{bin});
    const probe = try std.fmt.allocPrintSentinel(a, "{s}/JetBrainsMonoNerdFont-Regular.ttf", .{dir}, 0);
    if (std.c.access(probe.ptr, 4) != 0) dir = try std.fmt.allocPrint(a, "{s}/../Resources/terminal/fonts", .{bin});
    for (names, 0..) |name, i| {
        const path = try std.fmt.allocPrintSentinel(a, "{s}/JetBrainsMonoNerdFont-{s}.ttf", .{ dir, name }, 0);
        if (std.c.access(path.ptr, 4) != 0) return error.MissingBundledFont;
        if (mac) {
            const url = CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), 0) orelse return error.FontUrl;
            defer CFRelease(url);
            var err: ?*const anyopaque = null;
            const ok = CTFontManagerRegisterFontsForURL(url, 1, &err);
            defer if (err) |e| CFRelease(e);
            if (ok == 0 and (err == null or (CFErrorGetCode(err.?) != 105 and CFErrorGetCode(err.?) != 305))) return error.FontRegistration;
        }
        paths[i] = path;
    }
}
pub fn install(text: anytype, requested: []const u8) void {
    @import("terminal-shaper").install(text);
    if (comptime @hasField(@TypeOf(text.*), "db")) for (paths) |path| if (path) |value| text.db.addFile(value);
    text.setFamilies(null, if (requested.len > 0 and !std.mem.eql(u8, requested, "monospace")) requested else if (requested.len == 0 and paths[0] != null) family else null);
}
extern "c" fn CFURLCreateFromFileSystemRepresentation(?*const anyopaque, [*]const u8, isize, u8) ?*const anyopaque;
extern "c" fn CTFontManagerRegisterFontsForURL(*const anyopaque, u32, *?*const anyopaque) u8;
extern "c" fn CFErrorGetCode(*const anyopaque) isize;
extern "c" fn CFRelease(*const anyopaque) void;
