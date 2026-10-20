//! Owned Kitty snapshot -> bounded, replaceable nanoui picture resources.
//! No VT/parser, atlas UV, image pixel or placement borrow survives sync().
//! The host supplies the three resource operations; geometry/ownership tests
//! stay independent of nanoui, while nanoui_graphics_resources owns uploads.
const std = @import("std");
const model = @import("graphics_model.zig");
pub const Rect = model.Rect;
pub const Layer = model.Layer;
pub const max_images = 32;
pub const max_placements = 128;
/// Rendering resolution, deliberately lower than the VT storage limit (2048).
/// A 1024 image plus the nanoui atlas padding fits its 2048 atlas.
pub const render_max_side = 1024;

pub const Raw = struct { key: u64, width: u32, height: u32, bgra: []const u8 };
pub const Draw = struct {
    key: u64,
    /// Pixel coordinates in the uploaded (possibly downsampled) bitmap.
    source_pixels: Rect,
    /// Original placement crop in uploaded pixels, before viewport clipping.
    /// The sampler clamps to this boundary; scrolling must not invent a new
    /// crop edge within an existing picture's interpolation footprint.
    sample_bounds: Rect,
    destination: Rect,
    clip: Rect,
    opacity: f32 = 1,
    layer: Layer,
    z: i32,
    image_id: u32,
    placement_id: u32,
    internal_id: bool,
};
pub const Resources = struct {
    ctx: *anyopaque,
    /// Success synchronously copies all pixels. On failure there is no live
    /// resource for raw.key. These keys are reserved for managed raw pictures,
    /// in a namespace distinct from hashed encoded-image keys.
    putRaw: *const fn (*anyopaque, Raw) anyerror!void,
    /// Infallible and idempotent. Frees decoded pixels and residency/accounting
    /// before returning. The host must repaint retained instances after it.
    remove: *const fn (*anyopaque, u64) void,
    /// Enqueue in the current paint layer. Resolve atlas UV during paint, not
    /// here: atlas repacks invalidate UV. Never retain a pointer to Draw.
    draw: *const fn (*anyopaque, Draw) anyerror!void,
};

/// Share ONE source between all views using a resource store, on its UI thread.
/// A discarded view never recycles its keys. No session-id hashing/truncation.
pub const KeySource = struct {
    next_key: u64 = 1,
    pub fn next(self: *KeySource) error{ResourceKeyExhausted}!u64 {
        if (self.next_key == 0) return error.ResourceKeyExhausted;
        const value = self.next_key;
        self.next_key = if (value == std.math.maxInt(u64)) 0 else value + 1;
        return value;
    }
};
pub const Limits = struct { images: usize = max_images, bytes: usize = 8 * 1024 * 1024 };
pub const State = struct {
    enabled: bool = false,
    visible: bool = false,
    /// Change on terminal reset/replacement even if screen/generation repeats.
    epoch: u64 = 0,
};
pub const Geometry = struct {
    viewport: Rect,
    origin_x: f32,
    origin_y: f32,
    /// Grid dimensions and origins are points; VT offsets/sizes are pixels.
    cell_width: f32,
    cell_height: f32,
    scale: f32,
};
pub const Stats = struct {
    uploaded: usize = 0,
    reused: usize = 0,
    downsampled: usize = 0,
    skipped: usize = 0,
    draws: usize = 0,
};
const Entry = struct {
    key: u64,
    image_id: u32,
    revision: u64,
    original_width: u32,
    original_height: u32,
    width: u32,
    height: u32,
    bytes: usize,
    used_at: u64,
};

pub const View = struct {
    gpa: std.mem.Allocator,
    resources: Resources,
    /// Stable host-owned shared source, which must outlive this view.
    keys: *KeySource,
    limits: Limits,
    entries: [max_images]?Entry = @splat(null),
    commands: [max_placements]Draw = undefined,
    command_count: usize = 0,
    used_bytes: usize = 0,
    clock: u64 = 0,
    screen: ?bool = null,
    epoch: ?u64 = null,
    active: bool = false,

    pub fn init(gpa: std.mem.Allocator, resources: Resources, keys: *KeySource, limits: Limits) error{InvalidLimits}!View {
        if (limits.images == 0 or limits.images > max_images or limits.bytes == 0 or limits.bytes > 8 * 1024 * 1024) return error.InvalidLimits;
        return .{ .gpa = gpa, .resources = resources, .keys = keys, .limits = limits };
    }
    /// Invoke outside the paint transaction: any previously retained draw list
    /// must be discarded and repainted by the host after this call.
    pub fn reset(self: *View) void {
        self.command_count = 0;
        for (0..self.entries.len) |i| self.removeAt(i);
        self.screen = null;
        self.epoch = null;
        self.active = false;
    }
    pub fn deinit(self: *View) void {
        self.reset();
        self.* = undefined;
    }
    /// Call immediately on config-disable or tab-hide, even when no terminal
    /// capture/frame follows. Re-show requires sync of a fresh snapshot.
    pub fn deactivate(self: *View) void {
        self.reset();
    }
    pub fn liveCount(self: *const View) usize {
        var count: usize = 0;
        for (self.entries) |e| if (e != null) {
            count += 1;
        };
        return count;
    }
    fn removeAt(self: *View, index: usize) void {
        const e = self.entries[index] orelse return;
        self.resources.remove(self.resources.ctx, e.key);
        self.used_bytes -= e.bytes;
        self.entries[index] = null;
    }
    /// Snapshot is structurally the owned vt_native_graphics.Snapshot. Keeping
    /// it generic avoids importing a second terminal engine into the UI module.
    /// All parser storage and pixels remain owned by the caller, only during
    /// this call. Errors clear every draw/resource: no stale partial frame.
    pub fn sync(self: *View, snapshot: anytype, geometry: Geometry, state: State) !Stats {
        self.command_count = 0;
        errdefer self.reset();
        if (!state.enabled or !state.visible or !snapshot.supported) {
            self.reset();
            return .{};
        }
        if (!validGeometry(geometry)) return error.InvalidGeometry;
        if (snapshot.image_count > snapshot.images.len or snapshot.image_count > max_images or snapshot.placement_count > snapshot.placements.len or snapshot.placement_count > max_placements) return error.InvalidSnapshot;
        if (self.epoch != null and (self.epoch.? != state.epoch or self.screen.? != snapshot.alternate)) self.reset();
        // Avoid an age wrap alias. This happens only after 2^64 syncs.
        if (self.clock == std.math.maxInt(u64)) {
            self.reset();
            self.clock = 0;
        }
        self.clock += 1;
        self.epoch = state.epoch;
        self.screen = snapshot.alternate;
        self.active = true;
        const images = snapshot.images[0..snapshot.image_count];
        const placements = snapshot.placements[0..snapshot.placement_count];
        // Deleted/hidden image or same-ID replacement releases before upload.
        // This does not use snapshot.generation: resize/scroll changes geometry
        // without changing image pixels, and a placement change is not a pixel
        // revision. Screen/reset identities are handled above.
        for (self.entries, 0..) |entry, i| if (entry) |e| {
            var exists = false;
            for (images) |image| if (matches(e, image)) {
                exists = true;
                break;
            };
            if (!exists) self.removeAt(i);
        };
        var stats: Stats = .{};
        for (placements) |placement| {
            if (placement.image_index >= images.len) return error.InvalidSnapshot;
            const image = images[placement.image_index];
            if (placement.image_id != image.id or !validImage(image)) return error.InvalidSnapshot;
            if (!validSource(placement, image)) {
                stats.skipped += 1;
                continue;
            }
            const destination: Rect = .{
                .x = geometry.origin_x + @as(f32, @floatFromInt(placement.col)) * geometry.cell_width + @as(f32, @floatFromInt(placement.x_offset)) / geometry.scale,
                .y = geometry.origin_y + @as(f32, @floatFromInt(placement.row)) * geometry.cell_height + @as(f32, @floatFromInt(placement.y_offset)) / geometry.scale,
                .width = @as(f32, @floatFromInt(placement.width)) / geometry.scale,
                .height = @as(f32, @floatFromInt(placement.height)) / geometry.scale,
            };
            if (!validRect(destination)) return error.InvalidGeometry;
            const source: Rect = .{
                .x = @floatFromInt(placement.source_x),
                .y = @floatFromInt(placement.source_y),
                .width = @floatFromInt(placement.source_width),
                .height = @floatFromInt(placement.source_height),
            };
            const sample = model.clip(source, destination, geometry.viewport) orelse continue;
            const index = (try self.resident(image, &stats)) orelse {
                stats.skipped += 1;
                continue;
            };
            const entry = self.entries[index].?;
            const sx = @as(f32, @floatFromInt(entry.width)) / @as(f32, @floatFromInt(image.width));
            const sy = @as(f32, @floatFromInt(entry.height)) / @as(f32, @floatFromInt(image.height));
            self.commands[self.command_count] = .{
                .key = entry.key,
                .source_pixels = .{ .x = sample.source.x * sx, .y = sample.source.y * sy, .width = sample.source.width * sx, .height = sample.source.height * sy },
                .sample_bounds = .{ .x = source.x * sx, .y = source.y * sy, .width = source.width * sx, .height = source.height * sy },
                .destination = sample.destination,
                .clip = geometry.viewport,
                .layer = model.layer(placement.z),
                .z = placement.z,
                .image_id = placement.image_id,
                .placement_id = placement.id,
                .internal_id = placement.internal_id,
            };
            self.command_count += 1;
        }
        std.mem.sort(Draw, self.commands[0..self.command_count], {}, drawLess);
        stats.draws = self.command_count;
        return stats;
    }
    fn resident(self: *View, image: anytype, stats: *Stats) !?usize {
        for (&self.entries, 0..) |*slot, i| if (slot.*) |*e| {
            if (matches(e.*, image)) {
                e.used_at = self.clock;
                stats.reused += 1;
                return i;
            }
        };
        const dimensions = fitted(image.width, image.height);
        const bytes = @as(usize, dimensions[0]) * dimensions[1] * 4;
        if (bytes > self.limits.bytes) return null;
        while (self.liveCount() >= self.limits.images or bytes > self.limits.bytes - self.used_bytes) {
            var oldest: ?usize = null;
            for (self.entries, 0..) |slot, i| if (slot) |e| {
                // Never evict a bitmap referenced by an already built command.
                if (e.used_at == self.clock) continue;
                if (oldest == null or e.used_at < self.entries[oldest.?].?.used_at) oldest = i;
            };
            self.removeAt(oldest orelse return null);
        }
        const bgra = try self.gpa.alloc(u8, bytes);
        defer self.gpa.free(bgra);
        downsample(bgra, dimensions[0], dimensions[1], image.rgba, image.width, image.height);
        const key = try self.keys.next();
        try self.resources.putRaw(self.resources.ctx, .{ .key = key, .width = dimensions[0], .height = dimensions[1], .bgra = bgra });
        // No fallible operations after putRaw; an installed key is always owned
        // by an entry and removed on every reset/error/deinit path.
        for (&self.entries, 0..) |*slot, i| if (slot.* == null) {
            slot.* = .{ .key = key, .image_id = image.id, .revision = image.generation, .original_width = image.width, .original_height = image.height, .width = dimensions[0], .height = dimensions[1], .bytes = bytes, .used_at = self.clock };
            self.used_bytes += bytes;
            stats.uploaded += 1;
            if (image.width != dimensions[0] or image.height != dimensions[1]) stats.downsampled += 1;
            return i;
        };
        unreachable;
    }
    /// Host inserts these calls at actual paint-order boundaries:
    /// pane bg -> below_background -> cell bgs -> below_text -> glyphs ->
    /// above_text -> selection/search/cursor/preedit overlays.
    pub fn drawLayer(self: *const View, wanted: Layer) !usize {
        var count: usize = 0;
        if (!self.active) return 0;
        for (self.commands[0..self.command_count]) |command| if (command.layer == wanted) {
            try self.resources.draw(self.resources.ctx, command);
            count += 1;
        };
        return count;
    }
};

fn drawLess(_: void, a: Draw, b: Draw) bool {
    if (a.z != b.z) return a.z < b.z;
    if (a.image_id != b.image_id) return a.image_id < b.image_id;
    if (a.internal_id != b.internal_id) return !a.internal_id;
    return a.placement_id < b.placement_id;
}
fn matches(entry: Entry, image: anytype) bool {
    return entry.image_id == image.id and entry.revision == image.generation and entry.original_width == image.width and entry.original_height == image.height;
}
fn validImage(image: anytype) bool {
    return image.width != 0 and image.height != 0 and image.width <= model.max_side and image.height <= model.max_side and @as(u64, image.width) * image.height * 4 <= model.max_image_bytes and @as(u64, image.width) * image.height * 4 == image.rgba.len;
}
fn validSource(p: anytype, image: anytype) bool {
    return p.width > 0 and p.height > 0 and p.source_width > 0 and p.source_height > 0 and @as(u64, p.source_x) + p.source_width <= image.width and @as(u64, p.source_y) + p.source_height <= image.height;
}
fn finite(value: f32) bool {
    return std.math.isFinite(value);
}
fn validRect(r: Rect) bool {
    return finite(r.x) and finite(r.y) and finite(r.width) and finite(r.height) and finite(r.x + r.width) and finite(r.y + r.height);
}
fn validGeometry(g: Geometry) bool {
    return finite(g.scale) and g.scale > 0 and finite(g.cell_width) and g.cell_width > 0 and finite(g.cell_height) and g.cell_height > 0 and finite(g.origin_x) and finite(g.origin_y) and finite(g.viewport.x) and finite(g.viewport.y) and finite(g.viewport.width) and finite(g.viewport.height) and g.viewport.width >= 0 and g.viewport.height >= 0 and finite(g.viewport.x + g.viewport.width) and finite(g.viewport.y + g.viewport.height);
}
fn fitted(width: u32, height: u32) [2]u32 {
    const longest = @max(width, height);
    if (longest <= render_max_side) return .{ width, height };
    return .{ @max(1, width * render_max_side / longest), @max(1, height * render_max_side / longest) };
}
/// Average premultiplied samples, not straight colors: transparent RGB cannot
/// create colored fringes. Output never exceeds 1024^2*4; scratch is just output.
fn downsample(dst: []u8, width: u32, height: u32, rgba: []const u8, original_width: u32, original_height: u32) void {
    for (0..height) |y| for (0..width) |x| {
        const x0 = x * original_width / width;
        const x1 = @max(x0 + 1, (x + 1) * original_width / width);
        const y0 = y * original_height / height;
        const y1 = @max(y0 + 1, (y + 1) * original_height / height);
        var sum: [4]u64 = @splat(0);
        for (y0..y1) |sy| for (x0..x1) |sx| {
            const pixel = rgba[(sy * original_width + sx) * 4 ..][0..4];
            const alpha: u32 = pixel[3];
            sum[0] += (@as(u32, pixel[2]) * alpha + 127) / 255;
            sum[1] += (@as(u32, pixel[1]) * alpha + 127) / 255;
            sum[2] += (@as(u32, pixel[0]) * alpha + 127) / 255;
            sum[3] += alpha;
        };
        const n = (x1 - x0) * (y1 - y0);
        for (0..4) |channel| dst[(y * width + x) * 4 + channel] = @intCast((sum[channel] + n / 2) / n);
    };
}
