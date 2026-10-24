//! Owned hidden Surface plus offscreen pixel assertions; no system input/state.
const std = @import("std");
const builtin = @import("builtin");
const nano = @import("nanoui");
const ui = nano.ui;
const portable = @import("check_options").portable;
const A = std.mem.Allocator;
const Scene = struct {
    phase: usize = 0,
    pngs: [3][]const u8,
    frames: usize = 0,
    fn view(self: *Scene, ctx: *ui.Context) void {
        self.frames += 1;
        ui.column(ctx, .{ .width = .fill, .height = .fill, .background = ui.Color.hex(0xffffff) });
        defer ui.end(ctx);
        for (0..self.phase + 1) |n| {
            ui.column(ctx, .{ .absolute = true, .offset = .{ .x = 8 + @as(f32, @floatFromInt(n)) * 40, .y = 8 }, .width = .{ .px = 32 }, .height = .{ .px = 32 } });
            _ = ui.image(ctx, .{ .key = switch (n) {
                0 => "initial-red",
                1 => "later-green",
                else => "later-blue",
            }, .bytes = self.pngs[n], .scale = 1, .radius = 0 });
            ui.end(ctx);
        }
    }
};
const colors = [3][4]u8{ .{ 0, 0, 255, 255 }, .{ 0, 255, 0, 255 }, .{ 255, 0, 0, 255 } };
var assertions: usize = 0;
var failures: usize = 0;
fn check(ok: bool, label: []const u8) void {
    assertions += 1;
    if (!ok) failures += 1;
    std.debug.print("{s}: {s}\n", .{ if (ok) "PASS" else "FAIL", label });
}
fn solid(a: A, color: [4]u8) ![]u8 {
    var bytes: [32 * 32 * 4]u8 = undefined;
    for (0..32 * 32) |i| bytes[i * 4 ..][0..4].* = color;
    return ui.png.encode(a, .{ .bytes = &bytes, .width = 32, .height = 32 });
}
fn expectPixels(pixels: ui.gpu.Pixels, scale: f32, count: usize, label: []const u8) void {
    var ok = true;
    for (0..count) |n| {
        const x: usize = @intFromFloat((16 + @as(f32, @floatFromInt(n)) * 40) * scale);
        const y: usize = @intFromFloat(16 * scale);
        if (x >= pixels.width or y >= pixels.height) {
            ok = false;
            continue;
        }
        const actual = pixels.bytes[(y * pixels.width + x) * 4 ..][0..4];
        for (actual, colors[n]) |v, expected| {
            const delta = if (v > expected) v - expected else expected - v;
            if (delta > 3) ok = false;
        }
        if (!ok) std.debug.print("  sample {d}: {any}, expected {any}\n", .{ n, actual.*, colors[n] });
    }
    check(ok, label);
}
fn testerPixels(a: A, t: *ui.Tester, count: usize, label: []const u8) !void {
    const pixels = try t.render(a);
    defer pixels.deinit(a);
    expectPixels(pixels, t.scale, count, label);
}
fn testerFrames(a: A, pngs: [3][]const u8) !void {
    var scene: Scene = .{ .pngs = pngs };
    var t: ui.Tester = undefined;
    try t.init(a, .init(&scene, Scene.view), .{ .width = 160, .height = 80, .scale = 2 });
    defer t.deinit();
    check(t.text.images.pixels.len > 0, "first frame has a populated CPU image atlas, not a reset fixture");
    try testerPixels(a, &t, 1, "CPU atlas first PNG draws");
    if (!portable) {
        // Reproduce Surface's old late binding, without clearing its old atlas
        // or entries. It already drew on the GPU and retains its CPU copy.
        t.text.images.sink = .{ .ctx = &t.renderer, .upload = @TypeOf(t.renderer).uploadImage };
    }
    scene.phase = 1;
    t.frame();
    try testerPixels(a, &t, 2, "PNG added after first frame preserves old and new pixels");
    scene.phase = 2;
    t.frame();
    try testerPixels(a, &t, 3, "third distinct PNG preserves prior images");
    for (0..3) |_| t.frame();
    try testerPixels(a, &t, 3, "all three PNGs survive subsequent frames");
}
fn migratedAtlas(a: A, pngs: [3][]const u8) !void {
    if (portable) return;
    var scene: Scene = .{ .pngs = pngs };
    var t: ui.Tester = undefined;
    try t.init(a, .init(&scene, Scene.view), .{ .width = 160, .height = 80 });
    defer t.deinit();
    const Images = @TypeOf(t.text.images);
    check(t.text.images.pixels.len > 0 and t.renderer.images_texture == null, "migration starts with an unsynced CPU atlas and no GPU atlas");
    if (@hasDecl(Images, "bindSink")) {
        t.text.images.bindSink(.{ .ctx = &t.renderer, .upload = @TypeOf(t.renderer).uploadImage });
        check(t.text.images.pixels.len == 0, "binding a sink migrates retained pixels before releasing CPU storage");
    } else {
        t.text.images.sink = .{ .ctx = &t.renderer, .upload = @TypeOf(t.renderer).uploadImage };
    }
    scene.phase = 1;
    t.frame();
    try testerPixels(a, &t, 2, "CPU-to-sink transition keeps unsynced first PNG and newly packed PNG");
    t.frame();
    try testerPixels(a, &t, 2, "migrated atlas remains intact on later frames");
}
fn surfacePixels(a: A, surface: anytype, count: usize, label: []const u8) !void {
    const atlas = if (portable) surface.atlas_texture.? else surface.text.texture();
    const pixels = try surface.renderer.drawOffscreen(a, surface.instances.items, atlas, surface.size, surface.scale, surface.ctx.theme.background);
    defer pixels.deinit(a);
    expectPixels(pixels, surface.scale, count, label);
}
fn realSurface(init: std.process.Init, pngs: [3][]const u8) !void {
    if (builtin.os.tag != .macos) return;
    const app = try nano.App.create(init, .{ .name = "Letty private image atlas check", .quit_on_last_window_closed = false });
    defer app.destroy();
    if (!app.flags.hidden) return error.HiddenFlagRequired;
    var scene: Scene = .{ .pngs = pngs };
    const window = try app.newWindow(.{ .title = "Private image atlas fixture", .visible = false, .width = 160, .height = 80, .content = .{ .view = .init(&scene, Scene.view) } });
    const s = window.surface.?;
    check(scene.frames > 0 and s.text.images.entries.count() > 0, "real hidden Surface packs the first PNG during creation");
    std.debug.print("  Surface initial frames={d}, CPU atlas bytes={d}, sink={any}\n", .{ scene.frames, s.text.images.pixels.len, s.text.images.sink != null });
    check(s.text.images.sink != null and s.text.images.pixels.len == 0, "real Surface binds sink before reentrant AppKit creation frames");
    try surfacePixels(init.gpa, s, 1, "real Surface first PNG pixel is visible");
    scene.phase = 1;
    s.frame();
    try surfacePixels(init.gpa, s, 2, "real Surface later PNG and first PNG both remain visible");
    scene.phase = 2;
    s.frame();
    try surfacePixels(init.gpa, s, 3, "real Surface third PNG and previous PNGs remain visible");
    for (0..3) |_| s.frame();
    try surfacePixels(init.gpa, s, 3, "real Surface PNGs remain visible across multiple frames");
}
pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    var pngs: [3][]const u8 = undefined;
    var made: usize = 0;
    defer for (pngs[0..made]) |png| a.free(png);
    for (colors, 0..) |color, n| {
        pngs[n] = try solid(a, color);
        made += 1;
    }
    try testerFrames(a, pngs);
    try migratedAtlas(a, pngs);
    try realSurface(init, pngs);
    std.debug.print("Image atlas assertions: {d}, failures: {d}, portable: {any}\n", .{ assertions, failures, portable });
    if (failures > 0) return error.ImageAtlasPixels;
}
