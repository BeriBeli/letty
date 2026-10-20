//! Native Kitty storage -> Letty-owned bounded renderer snapshot. Feed, resize,
//! capture and destruction are serialized by the host; no page/Pin/image borrow
//! survives take(). terminal_graphics_state connects this boundary to the GUI.
const std = @import("std");
const ghostty = @import("ghostty-vt");
const model = @import("graphics_model.zig");
const png = @import("graphics_png.zig");
pub const BudgetAllocator = @import("vt_native_graphics/budget.zig").BudgetAllocator;
pub const max_images = 32;
pub const max_placements = 128;
pub const storage_bytes = 8 * 1024 * 1024;
pub const snapshot_bytes = 8 * 1024 * 1024;
pub const max_side = model.max_side;
pub const max_image_bytes = model.max_image_bytes;
pub const compiled = @hasDecl(ghostty.kitty.graphics, "ImageStorage");
const NativeImage = if (compiled) ghostty.kitty.graphics.Image else void;
const NativePlacement = if (compiled) ghostty.kitty.graphics.ImageStorage.Placement else void;

pub const Image = struct {
    id: u32,
    width: u32,
    height: u32,
    generation: u64,
    /// Owned straight RGBA, never a borrowed native payload. Free via Snapshot.
    rgba: []const u8,
};
pub const Placement = struct {
    image_index: u32,
    image_id: u32,
    id: u32,
    internal_id: bool,
    x_offset: u32,
    y_offset: u32,
    z: i32,
    col: i32,
    row: i32,
    width: u32,
    height: u32,
    grid_cols: u32,
    grid_rows: u32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
};
pub const Snapshot = struct {
    supported: bool = compiled,
    alternate: bool = false,
    generation: u64 = 0,
    image_count: usize = 0,
    placement_count: usize = 0,
    skipped_images: usize = 0,
    skipped_placements: usize = 0,
    virtual_placements: usize = 0,
    owned_bytes: usize = 0,
    images: [max_images]Image = undefined,
    placements: [max_placements]Placement = undefined,
    pub fn deinit(self: *Snapshot, gpa: std.mem.Allocator) void {
        for (self.images[0..self.image_count]) |image| gpa.free(image.rgba);
        self.* = .{};
    }
    /// Frees previous payloads first to avoid two full host snapshots during
    /// refresh. On OOM this remains empty, never carrying stale geometry/data.
    pub fn refresh(self: *Snapshot, gpa: std.mem.Allocator, terminal: *ghostty.Terminal) !void {
        self.deinit(gpa);
        self.* = try take(gpa, terminal);
    }
};

/// Call at process startup before any terminal is used; native lib's default
/// PNG hook is null. The hook has no userdata, OS I/O, C API or VT re-entry.
pub fn installPngDecoder() void {
    ghostty.sys.decode_png = decodePng;
}
fn decodePng(gpa: std.mem.Allocator, input: []const u8) ghostty.sys.DecodeError!ghostty.sys.Image {
    png.validate(input) catch return error.InvalidData;
    // Native callbacks can use the supplied allocator for BOTH the fixed
    // scratch arena and final pixels, counting peak decode overlap in the
    // terminal's cumulative quota instead of a second untracked allocation.
    const scratch = try gpa.alloc(u8, model.decode_scratch_bytes);
    defer gpa.free(scratch);
    var arena: std.heap.FixedBufferAllocator = .init(scratch);
    const decoded = png.decode(arena.allocator(), input) catch return error.InvalidData;
    const output = try gpa.dupe(u8, decoded.rgba);
    return .{ .width = decoded.width, .height = decoded.height, .data = output };
}

/// Apply only outside feed. Both currently initialized screens are changed.
/// New alternate screens inherit the active screen's limits upstream. Real
/// std.Io remains on Terminal; choosing direct-only medium does not replace it.
pub fn configure(terminal: *ghostty.Terminal, enabled: bool) error{ Unsupported, UnboundedAllocator }!void {
    if (comptime !compiled) {
        if (enabled) return error.Unsupported;
        return;
    }
    if (enabled) {
        const quota = BudgetAllocator.fromAllocator(terminal.gpa()) orelse return error.UnboundedAllocator;
        if (quota.limit == 0 or quota.limit > 64 * 1024 * 1024) return error.UnboundedAllocator;
    }
    terminal.setKittyGraphicsLoadingLimits(.direct);
    terminal.setKittyGraphicsSizeLimit(terminal.gpa(), if (enabled) storage_bytes else 0);
}
/// Stream protocol collection is separate from resident storage. Disabled drops
/// recognition for future commands, while an already parsing APC may complete
/// (and will be rejected by zero storage). No parser reset/re-entry is performed.
pub fn configureStream(stream: *ghostty.TerminalStream, enabled: bool) void {
    stream.handler.apc_handler.max_bytes.put(.kitty, if (enabled) model.max_png_input_bytes * 4 / 3 + 4096 else 4096);
    stream.handler.apc_handler.enable(.kitty, enabled and compiled);
}

/// Convert currently visible placements only. Geometry must be refreshed after
/// scroll/resize even when storage generation is unchanged. Returned values and
/// pixels remain valid across future feed/resize/reset and after Terminal free.
pub fn take(gpa: std.mem.Allocator, terminal: *ghostty.Terminal) !Snapshot {
    var out: Snapshot = .{ .alternate = terminal.screens.active_key == .alternate };
    errdefer out.deinit(gpa);
    if (comptime !compiled) return out;
    const storage = &terminal.screens.active.kitty_images;
    out.generation = storage.generation;
    if (!storage.enabled()) return out;
    var iterator = storage.placements.iterator();
    var scanned: usize = 0;
    while (iterator.next()) |entry| {
        scanned += 1;
        if (scanned > max_placements * 4) {
            out.skipped_placements += 1;
            break;
        }
        const key = entry.key_ptr;
        const placement = entry.value_ptr;
        if (placement.location == .virtual) {
            out.virtual_placements += 1;
            continue;
        }
        const image = storage.images.getPtr(key.image_id) orelse continue;
        const position = viewportPosition(terminal, placement, image) orelse continue;
        if (out.placement_count == max_placements) {
            out.skipped_placements += 1;
            continue;
        }
        const pixels = placement.pixelSize(image.*, terminal);
        const grid = placement.gridSize(image.*, terminal);
        const source = placement.sourceRect(image.*);
        if (pixels.width == 0 or pixels.height == 0 or source.width == 0 or source.height == 0) continue;
        const index = (try copyImage(gpa, &out, image)) orelse {
            out.skipped_images += 1;
            continue;
        };
        const offset = placement.cellOffset(terminal);
        out.placements[out.placement_count] = .{
            .image_index = @intCast(index),
            .image_id = key.image_id,
            .id = key.placement_id.id,
            .internal_id = key.placement_id.tag == .internal,
            .x_offset = offset.x,
            .y_offset = offset.y,
            .z = placement.z,
            .col = position.col,
            .row = position.row,
            .width = pixels.width,
            .height = pixels.height,
            .grid_cols = grid.cols,
            .grid_rows = grid.rows,
            .source_x = source.x,
            .source_y = source.y,
            .source_width = source.width,
            .source_height = source.height,
        };
        out.placement_count += 1;
    }
    std.mem.sort(Placement, out.placements[0..out.placement_count], {}, placementLess);
    return out;
}
fn placementLess(_: void, a: Placement, b: Placement) bool {
    if (a.z != b.z) return a.z < b.z;
    if (a.image_id != b.image_id) return a.image_id < b.image_id;
    if (a.internal_id != b.internal_id) return !a.internal_id;
    return a.id < b.id;
}
fn copyImage(gpa: std.mem.Allocator, out: *Snapshot, image: *const NativeImage) !?usize {
    for (out.images[0..out.image_count], 0..) |known, index| if (known.id == image.id) return index;
    if (out.image_count == max_images or image.width == 0 or image.height == 0 or image.width > max_side or image.height > max_side or image.compression != .none) return null;
    const pixels = @as(u64, image.width) * image.height;
    if (pixels > max_image_bytes / 4) return null;
    const bytes: usize = @intCast(pixels * 4);
    if (bytes > snapshot_bytes - out.owned_bytes) return null;
    const channels: usize = switch (image.format) {
        .rgb => 3,
        .rgba => 4,
        .gray_alpha => 2,
        .gray => 1,
        else => return null,
    };
    const data = image.renderData().bytes() orelse return null;
    if (data.len != pixels * channels) return null;
    const rgba = try gpa.alloc(u8, bytes);
    var at: usize = 0;
    while (at < pixels) : (at += 1) {
        const source = data[at * channels ..][0..channels];
        const target = rgba[at * 4 ..][0..4];
        if (channels >= 3) @memcpy(target[0..3], source[0..3]) else @memset(target[0..3], source[0]);
        target[3] = if (channels == 4) source[3] else if (channels == 2) source[1] else 255;
    }
    const index = out.image_count;
    out.images[index] = .{ .id = image.id, .width = image.width, .height = image.height, .generation = image.generation, .rgba = rgba };
    out.image_count += 1;
    out.owned_bytes += bytes;
    return index;
}

const Position = struct { col: i32, row: i32 };
fn viewportPosition(terminal: *ghostty.Terminal, placement: *const NativePlacement, image: *const NativeImage) ?Position {
    const storage = &terminal.screens.active.kitty_images;
    const origin: struct { pin: *const ghostty.Pin, col_offset: i32 = 0, row_offset: i32 = 0 } = switch (placement.location) {
        .pin => |pin| .{ .pin = pin },
        .virtual => return null,
        .relative => |relative| chain: {
            const resolved = storage.resolveChain(relative) orelse return null;
            switch (resolved.root.location) {
                .pin => |pin| break :chain .{ .pin = pin, .col_offset = resolved.horizontal_offset, .row_offset = resolved.vertical_offset },
                .virtual => return null,
                .relative => unreachable,
            }
        },
    };
    if (origin.pin.garbage) return null;
    const pages = &terminal.screens.active.pages;
    const placed = pages.pointFromPin(.screen, origin.pin.*) orelse return null;
    const top = pages.pointFromPin(.screen, pages.getTopLeft(.viewport)) orelse return null;
    const difference = @as(i64, placed.screen.y) - @as(i64, top.screen.y);
    const base: i32 = @intCast(std.math.clamp(difference, std.math.minInt(i32), std.math.maxInt(i32)));
    const row = base +| origin.row_offset;
    const col = @as(i32, placed.screen.x) +| origin.col_offset;
    const grid = placement.gridSize(image.*, terminal);
    if (@as(i64, row) + grid.rows <= 0 or row >= terminal.rows or @as(i64, col) + grid.cols <= 0 or col >= terminal.cols) return null;
    return .{ .col = col, .row = row };
}
