//! Set Linux application identity and the fallback icon before any window exists.
const std = @import("std");
extern "c" fn readlink([*:0]const u8, [*]u8, usize) isize;

pub fn initialize() !void {
    if (@import("builtin").os.tag != .linux) return;
    var gtk = try std.DynLib.open("libgtk-3.so.0");
    defer gtk.close();
    var gdk = try std.DynLib.open("libgdk-3.so.0");
    defer gdk.close();
    const SetName = *const fn ([*:0]const u8) callconv(.c) void;
    const SetIcon = *const fn ([*:0]const u8, *?*anyopaque) callconv(.c) c_int;
    const FreeError = *const fn (*anyopaque) callconv(.c) void;
    const set_class = gdk.lookup(SetName, "gdk_set_program_class") orelse return error.IconApiUnavailable;
    const set_icon = gtk.lookup(SetIcon, "gtk_window_set_default_icon_from_file") orelse return error.IconApiUnavailable;
    const free_error = gtk.lookup(FreeError, "g_error_free") orelse return error.IconApiUnavailable;
    set_class("Letty");

    // /proc/self/exe resolves ~/.local/bin/letty and the version's current link.
    // This also works when launching an extracted archive or build directly.
    var executable: [4096]u8 = undefined;
    const count = readlink("/proc/self/exe", &executable, executable.len);
    if (count <= 0 or count >= executable.len) return error.ExecutablePathUnavailable;
    const directory = std.fs.path.dirname(executable[0..@intCast(count)]) orelse return error.ExecutablePathUnavailable;
    var buffer: [4096]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&buffer, "{s}/../share/icons/hicolor/256x256/apps/letty.png", .{directory}, 0);
    var err: ?*anyopaque = null;
    defer if (err) |value| free_error(value);
    if (set_icon(path, &err) == 0) return error.ApplicationIconUnavailable;
}
