//! Offscreen texture ownership checks. Held old textures must remain immutable
//! after coordinates are reused. This is not a real-window GPU stress claim.
const std = @import("std");
const nano = @import("nanoui");
const ui = nano.ui;
const objc = nano.objc;
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.AtlasOwnershipCheck;
}
const Scene = struct {
    label: []const u8 = "A",
    fn draw(self: *Scene, ctx: *ui.Context) void {
        ui.text(ctx, self.label, .{ .size = 24 });
    }
};
fn prepare(im: anytype, key: u64) !void {
    im.beginFrame();
    defer im.endFrame();
    im.requestRaw(key);
    try im.prepareFrame();
}
fn read(gpa: std.mem.Allocator, texture: anytype, width: usize, height: usize, bpp: usize) ![]u8 {
    const Region = extern struct { x: usize, y: usize, z: usize, w: usize, h: usize, d: usize };
    const bytes = try gpa.alloc(u8, width * height * bpp);
    objc.msg(void, texture, "getBytes:bytesPerRow:fromRegion:mipmapLevel:", .{
        @as(*anyopaque, bytes.ptr), @as(objc.NSUInteger, width * bpp), Region{ .x = 0, .y = 0, .z = 0, .w = width, .h = height, .d = 1 }, @as(objc.NSUInteger, 0),
    });
    return bytes;
}
pub fn run(s: anytype) !void {
    var scene: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(s.gpa, .init(&scene, Scene.draw), .{ .width = 96, .height = 64, .scale = 1 });
    defer t.deinit();
    const Images = @TypeOf(t.text.images);
    const Refusal = struct {
        uploads: usize = 0,
        fn reset(_: *anyopaque) bool {
            return false;
        }
        fn upload(data: *anyopaque, _: u32, _: u32, _: u32, _: u32, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(data));
            self.uploads += 1;
        }
    };
    var refusal: Refusal = .{};
    var rejected: Images = .{ .gpa = s.gpa, .sink = .{ .ctx = &refusal, .reset = Refusal.reset, .upload = Refusal.upload } };
    defer rejected.deinit();
    try rejected.putRaw(1, 1, 1, &.{ 0, 0, 255, 255 });
    var allocation_failed = false;
    prepare(&rejected, 1) catch |err| {
        allocation_failed = err == error.ImageTextureAllocation;
    };
    try check(allocation_failed and rejected.stats.prepare_failed and rejected.entries.count() == 0 and refusal.uploads == 0, "atlas allocation refusal publishes no partial mapping or upload");
    if (comptime @TypeOf(t.renderer) != void) {
        const old_glyph = t.text.atlas.texture;
        _ = objc.msg(objc.Object, old_glyph, "retain", .{});
        defer objc.release(old_glyph);
        const side = t.text.atlas.size;
        const before = try read(s.gpa, old_glyph, side, side, 1);
        defer s.gpa.free(before);
        t.text.atlas.reset();
        scene.label = "W";
        t.frame();
        const after = try read(s.gpa, old_glyph, side, side, 1);
        defer s.gpa.free(after);
        try check(t.text.atlas.texture != old_glyph and std.mem.eql(u8, before, after), "glyph reset replaces texture and preserves held old texels");
        const im = &t.text.images;
        try im.putRaw(1, 1, 1, &.{ 0, 0, 255, 255 });
        try prepare(im, 1);
        try t.renderer.syncImages(im);
        const old_image = t.renderer.images_texture.?;
        _ = objc.msg(objc.Object, old_image, "retain", .{});
        defer objc.release(old_image);
        const old_color = try read(s.gpa, old_image, 1, 1, 4);
        defer s.gpa.free(old_color);
        im.remove(1);
        try im.putRaw(2, 1, 1, &.{ 255, 0, 0, 255 });
        try prepare(im, 2);
        try t.renderer.syncImages(im);
        const old_after = try read(s.gpa, old_image, 1, 1, 4);
        defer s.gpa.free(old_after);
        const new_color = try read(s.gpa, t.renderer.images_texture.?, 1, 1, 4);
        defer s.gpa.free(new_color);
        try check(t.renderer.images_texture.? != old_image and std.mem.eql(u8, old_color, old_after) and std.mem.eql(u8, new_color, &.{ 255, 0, 0, 255 }), "CPU image repack replaces texture without changing old red texels");
        const stable = t.renderer.images_texture.?;
        try t.renderer.syncImages(im);
        try check(stable == t.renderer.images_texture.?, "unchanged image generation retains current texture");
        const Renderer = @TypeOf(t.renderer);
        var sink: Images = .{ .gpa = s.gpa, .sink = .{ .ctx = &t.renderer, .reset = Renderer.resetImages, .upload = Renderer.uploadImage } };
        defer sink.deinit();
        try sink.putRaw(11, 1, 1, &.{ 0, 255, 0, 255 });
        try prepare(&sink, 11);
        const old_sink = t.renderer.images_texture.?;
        _ = objc.msg(objc.Object, old_sink, "retain", .{});
        defer objc.release(old_sink);
        sink.remove(11);
        try sink.putRaw(12, 1, 1, &.{ 255, 0, 0, 255 });
        try prepare(&sink, 12);
        const held_color = try read(s.gpa, old_sink, 1, 1, 4);
        defer s.gpa.free(held_color);
        try check(t.renderer.images_texture.? != old_sink and sink.pixels.len == 0 and std.mem.eql(u8, held_color, &.{ 0, 255, 0, 255 }), "native sink repack preserves old texture without CPU atlas allocation");
    } else std.debug.print("UNSUPPORTED Metal texture ownership: portable renderer; shared failure path checked\n", .{});
}
