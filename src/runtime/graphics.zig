//! Native Ghostty Kitty placements -> current nanoui frame textures. No grid IPC.
const std = @import("std");
const ui = @import("nanoui").ui;
const ghostty = @import("ghostty-vt");
const geometry = @import("graphics_geometry.zig");
const png = @import("graphics_png.zig");
const A = std.mem.Allocator;
const Placement = struct {
    image: u32,
    generation: u64,
    layer: geometry.Layer,
    z: i32,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
};
const Image = struct { id: u32, generation: u64, width: u32, height: u32, pixels: []u8, used: bool = false };
pub const State = struct {
    images: std.ArrayList(Image) = .empty,
    placements: std.ArrayList(Placement) = .empty,
    bytes: usize = 0,
    pub fn deinit(self: *State, a: A) void {
        for (self.images.items) |image| a.free(image.pixels);
        self.images.deinit(a);
        self.placements.deinit(a);
    }
    pub fn prepare(self: *State, a: A, t: *ghostty.Terminal, render: *ghostty.RenderState, cell_w: f32, cell_h: f32, pixel_scale: f32) !void {
        if (!std.math.isFinite(pixel_scale) or pixel_scale <= 0) return error.InvalidPixelScale;
        self.placements.clearRetainingCapacity();
        for (self.images.items) |*image| image.used = false;
        const storage = &t.screens.active.kitty_images;
        var it = storage.placements.iterator();
        var scanned: usize = 0;
        while (it.next()) |entry| {
            scanned += 1;
            if (scanned > 2048 or self.placements.items.len == 512) break;
            const p = entry.value_ptr;
            const image = storage.imageById(entry.key_ptr.image_id) orelse continue;
            const origin: struct { pin: *const ghostty.Pin, dx: i32 = 0, dy: i32 = 0 } = switch (p.location) {
                .virtual => continue,
                .pin => |pin| .{ .pin = pin },
                .relative => |relative| root: {
                    const chain = storage.resolveChain(relative) orelse continue;
                    if (chain.root.location != .pin) continue; // RenderState supplies virtual roots.
                    break :root .{ .pin = chain.root.location.pin, .dx = chain.horizontal_offset, .dy = chain.vertical_offset };
                },
            };
            if (origin.pin.garbage) continue;
            const pages = &t.screens.active.pages;
            const point = pages.pointFromPin(.screen, origin.pin.*) orelse continue;
            const top = pages.pointFromPin(.screen, pages.getTopLeft(.viewport)) orelse continue;
            const col = @as(i64, point.screen.x) + origin.dx;
            const row = @as(i64, point.screen.y) - @as(i64, top.screen.y) + origin.dy;
            const size = p.pixelSize(image, t);
            const offset = p.cellOffset(t);
            const source = p.sourceRect(image);
            try self.append(a, .{ .image = image.id, .generation = image.generation, .layer = geometry.layer(p.z), .z = p.z, .x = @as(f32, @floatFromInt(col)) * cell_w + @as(f32, @floatFromInt(offset.x)) / pixel_scale, .y = @as(f32, @floatFromInt(row)) * cell_h + @as(f32, @floatFromInt(offset.y)) / pixel_scale, .width = @as(f32, @floatFromInt(size.width)) / pixel_scale, .height = @as(f32, @floatFromInt(size.height)) / pixel_scale, .source_x = source.x, .source_y = source.y, .source_width = source.width, .source_height = source.height }, t, cell_w, cell_h);
        }
        var placeholders = render.imagePlacementIterator();
        while (placeholders.next()) |p| {
            if (self.placements.items.len == 512) break;
            try self.append(a, .{ .image = p.image_id, .generation = p.image_generation, .layer = switch (p.layer) {
                .below_background => .below_background,
                .below_text => .below_text,
                .above_text => .above_text,
            }, .z = p.z, .x = @as(f32, @floatFromInt(p.x)) * cell_w + @as(f32, @floatFromInt(p.offset_x)) / pixel_scale, .y = @as(f32, @floatFromInt(p.y)) * cell_h + @as(f32, @floatFromInt(p.offset_y)) / pixel_scale, .width = @as(f32, @floatFromInt(p.width)) / pixel_scale, .height = @as(f32, @floatFromInt(p.height)) / pixel_scale, .source_x = p.source_x, .source_y = p.source_y, .source_width = p.source_width, .source_height = p.source_height }, t, cell_w, cell_h);
        }
        std.mem.sort(Placement, self.placements.items, {}, less);
        // Protect every unchanged image needed by this frame before replacing
        // an animated image. Updating one image must not evict the rest.
        for (self.placements.items) |placement| for (self.images.items) |*image_| {
            if (image_.id == placement.image and image_.generation == placement.generation) image_.used = true;
        };
        var index = self.images.items.len;
        while (index > 0) {
            index -= 1;
            if (!self.images.items[index].used) {
                const image = self.images.orderedRemove(index);
                self.bytes -= image.pixels.len;
                a.free(image.pixels);
            }
        }
        var visible: usize = 0;
        for (self.placements.items) |placement| {
            if (try self.cacheImage(a, t, placement.image, placement.generation) == null) continue;
            self.placements.items[visible] = placement;
            visible += 1;
        }
        self.placements.items.len = visible;
    }
    fn append(self: *State, a: A, p: Placement, t: *ghostty.Terminal, cw: f32, ch: f32) !void {
        if (p.width <= 0 or p.height <= 0 or p.source_width == 0 or p.source_height == 0 or p.x >= cw * @as(f32, @floatFromInt(t.cols)) or p.y >= ch * @as(f32, @floatFromInt(t.rows)) or p.x + p.width <= 0 or p.y + p.height <= 0) return;
        try self.placements.append(a, p);
    }
    fn cacheImage(self: *State, a: A, t: *ghostty.Terminal, id: u32, generation: u64) !?*Image {
        for (self.images.items) |*cached| if (cached.id == id and cached.generation == generation) {
            cached.used = true;
            return cached;
        };
        // Evict only copies no placement in this frame references.
        var i = self.images.items.len;
        while (i > 0) {
            i -= 1;
            if (!self.images.items[i].used) {
                const old = self.images.orderedRemove(i);
                self.bytes -= old.pixels.len;
                a.free(old.pixels);
            }
        }
        const native = t.screens.active.kitty_images.imageById(id) orelse return null;
        if (native.width == 0 or native.height == 0 or native.width > 2048 or native.height > 2048 or native.compression != .none) return null;
        const length = @as(usize, native.width) * native.height * 4;
        if (length > 4 * 1024 * 1024 or length > 8 * 1024 * 1024 -| self.bytes or self.images.items.len == 32) return null;
        const channels: usize = switch (native.format) {
            .rgb => 3,
            .rgba => 4,
            .gray => 1,
            .gray_alpha => 2,
            else => return null,
        };
        const bytes = native.renderData().bytes() orelse return null;
        if (bytes.len != length / 4 * channels) return null;
        const pixels = try a.alloc(u8, length);
        errdefer a.free(pixels);
        for (0..length / 4) |n| {
            const source = bytes[n * channels ..][0..channels];
            const target = pixels[n * 4 ..][0..4];
            const alpha: u32 = if (channels == 4) source[3] else if (channels == 2) source[1] else 255;
            target[0] = @intCast((@as(u32, if (channels >= 3) source[2] else source[0]) * alpha + 127) / 255);
            target[1] = @intCast((@as(u32, if (channels >= 3) source[1] else source[0]) * alpha + 127) / 255);
            target[2] = @intCast((@as(u32, source[0]) * alpha + 127) / 255);
            target[3] = @intCast(alpha);
        }
        try self.images.append(a, .{ .id = id, .generation = generation, .width = native.width, .height = native.height, .pixels = pixels, .used = true });
        self.bytes += length;
        return &self.images.items[self.images.items.len - 1];
    }
    /// The native ticker owns frame advancement. Scheduling is restricted to
    /// visible images, so an animation retained in history never keeps the GUI
    /// waking at its frame rate. A later viewport/input event resumes it.
    pub fn tick(self: *const State, t: *ghostty.Terminal, now_ms: u64) ?u64 {
        const storage = &t.screens.active.kitty_images;
        var playing = false;
        for (self.images.items) |cached| {
            const native = storage.imageById(cached.id) orelse continue;
            const anim = native.animation orelse continue;
            if (anim.state == .stopped or anim.frames.items.len == 0 or anim.durationMs() == 0 or (anim.max_loops > 0 and anim.current_loop >= anim.max_loops)) continue;
            playing = true;
            break;
        }
        if (!playing) return null;
        _ = storage.animationTick(t.io(), now_ms);
        var next: ?u64 = null;
        for (self.images.items) |cached| {
            const native = storage.imageById(cached.id) orelse continue;
            const anim = native.animation orelse continue;
            if (anim.state == .stopped or anim.frames.items.len == 0 or (anim.max_loops > 0 and anim.current_loop >= anim.max_loops)) continue;
            const shown = anim.frame_shown_at_ms orelse continue;
            const deadline = shown +| anim.gapAt(anim.current_index);
            if (deadline <= now_ms) continue; // parked/loading or gapless
            const delay = deadline - now_ms;
            next = if (next) |old| @min(old, delay) else delay;
        }
        return next;
    }
    pub fn draw(self: *State, ctx: *ui.Context, layer: geometry.Layer, width: f32, height: f32) void {
        for (self.placements.items) |p| {
            if (p.layer != layer) continue;
            for (self.images.items) |image_| {
                if (image_.id != p.image or image_.generation != p.generation) continue;
                const clipped = geometry.clip(.{ .x = @floatFromInt(p.source_x), .y = @floatFromInt(p.source_y), .width = @floatFromInt(p.source_width), .height = @floatFromInt(p.source_height) }, .{ .x = p.x, .y = p.y, .width = p.width, .height = p.height }, .{ .x = 0, .y = 0, .width = width, .height = height }) orelse continue;
                const source = clipped.source;
                const dest = clipped.destination;
                const iw: f32 = @floatFromInt(image_.width);
                const ih: f32 = @floatFromInt(image_.height);
                ui.texture(ctx, .{ .absolute = true, .offset = .{ .x = dest.x, .y = dest.y }, .width = .{ .px = dest.width }, .height = .{ .px = dest.height } }, .{ .width = image_.width, .height = image_.height, .bgra = image_.pixels }, .{ source.x / iw, source.y / ih, (source.x + source.width) / iw, (source.y + source.height) / ih }, 1);
                break;
            }
        }
    }
};
fn less(_: void, a: Placement, b: Placement) bool {
    if (a.layer != b.layer) return @backingInt(a.layer) < @backingInt(b.layer);
    if (a.z != b.z) return a.z < b.z;
    return a.image < b.image;
}
pub fn installDecoder() void {
    ghostty.sys.decode_png = decode;
}
fn decode(a: A, bytes: []const u8) ghostty.sys.DecodeError!ghostty.sys.Image {
    png.validate(bytes) catch return error.InvalidData;
    const scratch = try a.alloc(u8, 16 * 1024 * 1024);
    defer a.free(scratch);
    var arena: std.heap.FixedBufferAllocator = .init(scratch);
    const result = png.decode(arena.allocator(), bytes) catch return error.InvalidData;
    return .{ .width = result.width, .height = result.height, .data = try a.dupe(u8, result.rgba) };
}
