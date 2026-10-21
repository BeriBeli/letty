#!/usr/bin/env python3
"""Check owned hidden GTK surfaces and clipped Cairo exposure under private Xvfb."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = r'''
const std = @import("std");
const nano = @import("nanoui");
const ui = nano.ui;
extern "c" fn cairo_image_surface_create_for_data([*]u8, c_int, c_int, c_int, c_int) ?*anyopaque;
extern "c" fn cairo_surface_set_device_scale(*anyopaque, f64, f64) void;
extern "c" fn cairo_surface_flush(*anyopaque) void;
extern "c" fn cairo_surface_destroy(*anyopaque) void;
extern "c" fn cairo_create(*anyopaque) ?*anyopaque;
extern "c" fn cairo_destroy(*anyopaque) void;
extern "c" fn cairo_rectangle(*anyopaque, f64, f64, f64, f64) void;
extern "c" fn cairo_clip(*anyopaque) void;
extern "c" fn cairo_status(*anyopaque) c_int;
extern "c" fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;
const View = struct {
    x: f32 = 10,
    fn draw(self: *@This(), ctx: *ui.Context) void {
        _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = self.x, .y = 10 }, .width = .{ .px = 10 }, .height = .{ .px = 10 }, .background = .hex(0xff0000) }, .none, null);
    }
};
fn drain(surface: anytype) !void {
    for (0..200) |_| {
        if (!surface.stale and surface.present_idle == 0) return;
        nano.runFor(0.001);
    }
    return error.PresentationDidNotComplete;
}
fn expose(surface: anytype, pixels: []u8, clipped: bool) !void {
    const target = cairo_image_surface_create_for_data(pixels.ptr, 0, 400, 200, 1600) orelse return error.CairoSurface;
    defer cairo_surface_destroy(target);
    cairo_surface_set_device_scale(target, 2, 2);
    const cr = cairo_create(target) orelse return error.CairoContext;
    defer cairo_destroy(cr);
    if (clipped) { cairo_rectangle(cr, 0, 0, 50, 50); cairo_clip(cr); }
    var handled: c_int = 0;
    g_signal_emit_by_name(surface.area, "draw", cr, &handled);
    cairo_surface_flush(target);
    try std.testing.expect(cairo_status(cr) == 0 and handled != 0);
}
pub fn main(init: std.process.Init) !void {
    const app = try nano.App.create(init, .{ .name = "Letty X11 presentation check" });
    defer app.destroy();
    app.flags.hidden = true;
    var view: View = .{};
    const window = try app.newWindow(.{ .title = "Owned hidden presentation fixture", .width = 200, .height = 100, .content = .{ .view = .init(&view, View.draw) } });
    var closed = false;
    defer if (!closed) window.close();
    const surface = window.surface orelse return error.GtkUnavailable;
    surface.size = .{ .w = 200, .h = 100 };
    surface.scale = 2;
    surface.text.setScale(2);
    surface.frame();
    const pending = surface.present_idle;
    view.x = 30;
    surface.frame();
    try std.testing.expect(pending != 0 and surface.present_idle == pending);
    try drain(surface);
    try std.testing.expect(surface.cpu.valid);
    const pixels = try init.gpa.alloc(u8, 400 * 200 * 4);
    defer init.gpa.free(pixels);
    @memset(pixels, 0);
    try expose(surface, pixels, false);
    try std.testing.expectEqualSlices(u8, surface.cpu.bytes, pixels);
    std.debug.print("PASS X11 coalesced frames and complete scaled Cairo exposure match current CPU backing\n", .{});
    // Exposure before the pending idle must render latest state, not old pixels.
    view.x = 120;
    surface.frame();
    @memset(pixels, 0);
    try expose(surface, pixels, true);
    try std.testing.expect(!surface.stale);
    for (0..200) |y| for (0..400) |x| {
        const at = (y * 400 + x) * 4;
        if (x < 100 and y < 100) try std.testing.expectEqualSlices(u8, surface.cpu.bytes[at..][0..4], pixels[at..][0..4])
        else try std.testing.expectEqualSlices(u8, &.{0, 0, 0, 0}, pixels[at..][0..4]);
    };
    try drain(surface);
    try expose(surface, pixels, false);
    try std.testing.expectEqualSlices(u8, surface.cpu.bytes, pixels);
    std.debug.print("PASS X11 early partial exposure respects Cairo clip and later full exposure restores all current pixels\n", .{});
    surface.frame();
    try std.testing.expect(surface.present_idle != 0);
    window.close();
    closed = true;
    nano.runFor(0.01);
    std.debug.print("PASS X11 closing a hidden window cancels pending presentation callbacks\n", .{});
}
'''

def main():
    zig = os.environ.get('ZIG') or shutil.which('zig')
    if not zig or subprocess.check_output([zig, 'version'], text=True).strip() != '0.17.0':
        raise SystemExit('Requires exactly Zig 0.17.0')
    xvfb = shutil.which('xvfb-run')
    if not xvfb:
        raise SystemExit('Requires xvfb-run; this check never uses the desktop display')
    with tempfile.TemporaryDirectory(prefix='letty-x11-check-', dir=ROOT / '.cache') as name:
        work = Path(name)
        (work / 'check.zig').write_text(SOURCE)
        (work / 'options.zig').write_text('pub const portable = true;\npub const version = "0.4.0";\n')
        binary = work / 'check'
        env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / '.cache/zig-global'))
        subprocess.run([zig, 'build-exe', '-OReleaseSafe', '-lc', '-lutil', '-ldl', '-lpthread', '-lcairo', '-lgobject-2.0',
                        'src/platform/compat.c', '--dep', 'nanoui', '-Mroot=' + str(work / 'check.zig'),
                        '--dep', 'build_options', '-Mnanoui=vendor/nanoui/src/nanoui.zig',
                        '-Mbuild_options=' + str(work / 'options.zig'), '-femit-bin=' + str(binary)], cwd=ROOT, env=env, check=True)
        subprocess.run([xvfb, '-a', str(binary), '--nanoui-hidden'], cwd=ROOT, env=env, check=True)

if __name__ == '__main__':
    main()
