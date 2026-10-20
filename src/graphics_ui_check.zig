//! Leaf resource/geometry tests, plus an actual Kitty protocol -> snapshot ->
//! managed-resource fixture. The resource store here is an owned test adapter,
//! NOT a nanoui atlas/GPU. Root must wire and test nanoui before GUI completion.
const std = @import("std");
const graphics_view = @import("terminal_graphics_view.zig");
const View = graphics_view.View;
const Draw = graphics_view.Draw;
const Raw = graphics_view.Raw;
const Geometry = graphics_view.Geometry;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const slices = std.testing.expectEqualSlices;

const Mock = struct {
    const Bitmap = struct { key: u64, width: u32, height: u32, pixels: []u8 };
    gpa: std.mem.Allocator,
    bitmaps: [32]?Bitmap = @splat(null),
    draws: [128]Draw = undefined,
    draw_count: usize = 0,
    puts: usize = 0,
    removes: usize = 0,
    bytes: usize = 0,
    peak_bytes: usize = 0,
    fail_put: bool = false,
    fail_draw: bool = false,
    fn resources(self: *Mock) graphics_view.Resources {
        return .{ .ctx = self, .putRaw = put, .remove = remove, .draw = draw };
    }
    fn bitmap(self: *Mock, key: u64) ?Bitmap {
        for (self.bitmaps) |slot| if (slot) |b| if (b.key == key) return b;
        return null;
    }
    fn put(ctx: *anyopaque, raw: Raw) !void {
        const self: *Mock = @ptrCast(@alignCast(ctx));
        if (self.fail_put) return error.MockUploadFailed;
        if (self.bitmap(raw.key) != null) return error.DuplicateResource;
        if (raw.width > 1024 or raw.height > 1024 or raw.bgra.len != @as(usize, raw.width) * raw.height * 4) return error.BadUpload;
        for (&self.bitmaps) |*slot| if (slot.* == null) {
            const owned = try self.gpa.dupe(u8, raw.bgra);
            slot.* = .{ .key = raw.key, .width = raw.width, .height = raw.height, .pixels = owned };
            self.bytes += owned.len;
            self.peak_bytes = @max(self.bytes, self.peak_bytes);
            self.puts += 1;
            return;
        };
        return error.MockResourceLimit;
    }
    fn remove(ctx: *anyopaque, key: u64) void {
        const self: *Mock = @ptrCast(@alignCast(ctx));
        for (&self.bitmaps) |*slot| if (slot.*) |b| if (b.key == key) {
            self.bytes -= b.pixels.len;
            self.gpa.free(b.pixels);
            self.removes += 1;
            slot.* = null;
            return;
        };
    }
    fn draw(ctx: *anyopaque, command: Draw) !void {
        const self: *Mock = @ptrCast(@alignCast(ctx));
        if (self.fail_draw) return error.MockDrawFailed;
        const b = self.bitmap(command.key) orelse return error.DanglingDraw;
        const source = command.source_pixels;
        if (source.x < 0 or source.y < 0 or source.x + source.width > @as(f32, @floatFromInt(b.width)) + 0.001 or source.y + source.height > @as(f32, @floatFromInt(b.height)) + 0.001) return error.BadSource;
        if (self.draw_count == self.draws.len) return error.MockDrawLimit;
        self.draws[self.draw_count] = command;
        self.draw_count += 1;
    }
};
const Image = struct { id: u32 = 1, width: u32 = 1, height: u32 = 1, generation: u64 = 1, rgba: []const u8 = &.{ 255, 0, 30, 128 } };
const Placement = struct {
    image_index: u32 = 0,
    image_id: u32 = 1,
    id: u32 = 1,
    internal_id: bool = false,
    col: i32 = 0,
    row: i32 = 0,
    x_offset: u32 = 0,
    y_offset: u32 = 0,
    width: u32 = 16,
    height: u32 = 32,
    z: i32 = 0,
    source_x: u32 = 0,
    source_y: u32 = 0,
    source_width: u32 = 1,
    source_height: u32 = 1,
};
const Snapshot = struct {
    supported: bool = true,
    alternate: bool = false,
    image_count: usize = 1,
    placement_count: usize = 1,
    images: [3]Image = .{ .{}, .{ .id = 2 }, .{ .id = 3 } },
    placements: [4]Placement = .{ .{}, .{}, .{}, .{} },
};
const geometry: Geometry = .{ .viewport = .{ .x = 10, .y = 20, .width = 80, .height = 80 }, .origin_x = 10, .origin_y = 20, .cell_width = 8, .cell_height = 16, .scale = 2 };
const active: graphics_view.State = .{ .enabled = true, .visible = true };

test "raw upload is owned premultiplied BGRA and image revisions replace within budget" {
    var mock: Mock = .{ .gpa = std.testing.allocator };
    var keys: graphics_view.KeySource = .{};
    var view = try View.init(std.testing.allocator, mock.resources(), &keys, .{ .bytes = 4 });
    defer view.deinit();
    var snap: Snapshot = .{};
    const first = try view.sync(&snap, geometry, active);
    try equal(@as(usize, 1), first.uploaded);
    const key = view.commands[0].key;
    try slices(u8, &.{ 15, 0, 128, 128 }, mock.bitmap(key).?.pixels);
    snap.images[0].rgba = &.{ 0, 255, 0, 128 };
    snap.images[0].generation = 2;
    const second = try view.sync(&snap, geometry, active);
    try equal(@as(usize, 1), second.uploaded);
    try expect(mock.bitmap(key) == null);
    try slices(u8, &.{ 0, 128, 0, 128 }, mock.bitmap(view.commands[0].key).?.pixels);
    try equal(@as(usize, 4), mock.peak_bytes);
    try equal(@as(usize, 1), mock.removes);
}
test "all three layers preserve z order and negative viewport crop at scale two" {
    var mock: Mock = .{ .gpa = std.testing.allocator };
    var keys: graphics_view.KeySource = .{};
    var view = try View.init(std.testing.allocator, mock.resources(), &keys, .{});
    defer view.deinit();
    var snap: Snapshot = .{ .placement_count = 4 };
    snap.placements[0].z = 2;
    snap.placements[1].z = std.math.minInt(i32);
    snap.placements[2].z = -1;
    snap.placements[3] = .{ .z = 0, .row = -1, .height = 64, .x_offset = 4 };
    const stats = try view.sync(&snap, geometry, active);
    try equal(@as(usize, 1), stats.uploaded);
    try equal(@as(usize, 3), stats.reused);
    try equal(@as(usize, 1), try view.drawLayer(.below_background));
    try equal(@as(usize, 1), try view.drawLayer(.below_text));
    try equal(@as(usize, 2), try view.drawLayer(.above_text));
    const crop = mock.draws[2];
    try equal(@as(f32, 12), crop.destination.x);
    try equal(@as(f32, 20), crop.destination.y);
    try equal(@as(f32, 16), crop.destination.height);
    try equal(@as(f32, 0.5), crop.source_pixels.y);
    try equal(@as(f32, 0.5), crop.source_pixels.height);
    try equal(@as(f32, 0), crop.sample_bounds.y);
    try equal(@as(f32, 1), crop.sample_bounds.height);
    try equal(@as(i32, 2), mock.draws[3].z);
}
test "fractional viewport crop retains the original sampler boundary" {
    var mock: Mock = .{ .gpa = std.testing.allocator };
    var keys: graphics_view.KeySource = .{};
    var view = try View.init(std.testing.allocator, mock.resources(), &keys, .{});
    defer view.deinit();
    var snap: Snapshot = .{};
    snap.images[0] = .{ .width = 4, .rgba = &.{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 } };
    snap.placements[0] = .{ .width = 64, .height = 64, .source_x = 1, .source_width = 3 };
    var clipped_geometry = geometry;
    clipped_geometry.viewport = .{ .x = 18, .y = 20, .width = 16, .height = 16 };
    _ = try view.sync(&snap, clipped_geometry, active);
    const clipped = view.commands[0];
    try equal(@as(f32, 1.75), clipped.source_pixels.x);
    try equal(@as(f32, 1.5), clipped.source_pixels.width);
    try equal(@as(f32, 1), clipped.sample_bounds.x);
    try equal(@as(f32, 3), clipped.sample_bounds.width);
    try equal(@as(f32, 0), clipped.sample_bounds.y);
    try equal(@as(f32, 1), clipped.sample_bounds.height);
    const original_key = clipped.key;
    clipped_geometry.viewport.x += 4;
    const stats = try view.sync(&snap, clipped_geometry, active);
    try equal(@as(usize, 0), stats.uploaded);
    try equal(original_key, view.commands[0].key);
    try expect(view.commands[0].source_pixels.x != clipped.source_pixels.x);
    try expect(std.meta.eql(clipped.sample_bounds, view.commands[0].sample_bounds));
}
test "resize changes geometry without reupload and draw never owns source pointers" {
    var mock: Mock = .{ .gpa = std.testing.allocator };
    var keys: graphics_view.KeySource = .{};
    var view = try View.init(std.testing.allocator, mock.resources(), &keys, .{});
    defer view.deinit();
    var snap: Snapshot = .{};
    snap.placements[0].col = 2;
    _ = try view.sync(&snap, geometry, active);
    var changed = geometry;
    changed.cell_width = 10;
    snap.placements[0].width = 20;
    const stats = try view.sync(&snap, changed, active);
    try equal(@as(usize, 0), stats.uploaded);
    snap = .{ .image_count = 0, .placement_count = 0 };
    _ = try view.drawLayer(.above_text);
    try equal(@as(f32, 30), mock.draws[0].destination.x);
    try equal(@as(f32, 10), mock.draws[0].destination.width);
    try slices(u8, &.{ 15, 0, 128, 128 }, mock.bitmap(mock.draws[0].key).?.pixels);
}
test "hidden disabled alternate epoch reset and destruction release all resources" {
    var mock: Mock = .{ .gpa = std.testing.allocator };
    var keys: graphics_view.KeySource = .{};
    var view = try View.init(std.testing.allocator, mock.resources(), &keys, .{});
    var snap: Snapshot = .{};
    _ = try view.sync(&snap, geometry, active);
    const primary_key = view.commands[0].key;
    snap.alternate = true;
    _ = try view.sync(&snap, geometry, active);
    try expect(mock.bitmap(primary_key) == null);
    const alternate_key = view.commands[0].key;
    snap.alternate = false;
    _ = try view.sync(&snap, geometry, active);
    try expect(mock.bitmap(alternate_key) == null);
    const before_epoch = view.commands[0].key;
    _ = try view.sync(&snap, geometry, .{ .enabled = true, .visible = true, .epoch = 1 });
    try expect(mock.bitmap(before_epoch) == null);
    _ = try view.sync(&snap, geometry, .{ .enabled = true, .visible = false });
    try equal(@as(usize, 0), mock.bytes);
    try equal(@as(usize, 0), try view.drawLayer(.above_text));
    _ = try view.sync(&snap, geometry, active);
    _ = try view.sync(&snap, geometry, .{ .visible = true });
    try equal(@as(usize, 0), mock.bytes);
    _ = try view.sync(&snap, geometry, active);
    view.deactivate();
    try equal(@as(usize, 0), mock.bytes);
    _ = try view.sync(&snap, geometry, active);
    view.reset();
    try equal(@as(usize, 0), mock.bytes);
    _ = try view.sync(&snap, geometry, active);
    view.deinit();
    try equal(@as(usize, 0), mock.bytes);
    try equal(mock.puts, mock.removes);
}
test "bounded LRU evicts old pictures but never current draw dependencies" {
    var mock: Mock = .{ .gpa = std.testing.allocator };
    var keys: graphics_view.KeySource = .{};
    var view = try View.init(std.testing.allocator, mock.resources(), &keys, .{ .images = 1, .bytes = 4 });
    defer view.deinit();
    var snap: Snapshot = .{ .image_count = 2 };
    _ = try view.sync(&snap, geometry, active);
    const old_key = view.commands[0].key;
    snap.placements[0] = .{ .image_id = 2, .image_index = 1 };
    _ = try view.sync(&snap, geometry, active);
    try expect(mock.bitmap(old_key) == null);
    snap.placement_count = 2;
    snap.placements[1] = .{};
    const stats = try view.sync(&snap, geometry, active);
    try equal(@as(usize, 1), stats.skipped);
    try equal(@as(usize, 1), stats.draws);
    try equal(@as(usize, 4), mock.peak_bytes);
    _ = try view.drawLayer(.above_text);
}
test "deleted images and unsupported snapshots release cached pixels" {
    var mock: Mock = .{ .gpa = std.testing.allocator };
    var keys: graphics_view.KeySource = .{};
    var view = try View.init(std.testing.allocator, mock.resources(), &keys, .{});
    defer view.deinit();
    var snap: Snapshot = .{};
    _ = try view.sync(&snap, geometry, active);
    snap.image_count = 0;
    snap.placement_count = 0;
    _ = try view.sync(&snap, geometry, active);
    try equal(@as(usize, 0), mock.bytes);
    snap = .{};
    _ = try view.sync(&snap, geometry, active);
    snap.supported = false;
    _ = try view.sync(&snap, geometry, active);
    try equal(@as(usize, 0), mock.bytes);
}
test "2048 storage image has explicit 1024 rendering limit and scaled source crop" {
    const pixels = try std.testing.allocator.alloc(u8, 2048 * 4);
    defer std.testing.allocator.free(pixels);
    for (0..1024) |i| @memcpy(pixels[i * 8 ..][0..8], &[_]u8{ 255, 0, 0, 255, 0, 0, 255, 0 });
    var mock: Mock = .{ .gpa = std.testing.allocator };
    var keys: graphics_view.KeySource = .{};
    var view = try View.init(std.testing.allocator, mock.resources(), &keys, .{});
    defer view.deinit();
    var snap: Snapshot = .{};
    snap.images[0] = .{ .width = 2048, .rgba = pixels };
    snap.placements[0].source_x = 1024;
    snap.placements[0].source_width = 1024;
    const stats = try view.sync(&snap, geometry, active);
    try equal(@as(usize, 1), stats.downsampled);
    const bitmap = mock.bitmap(view.commands[0].key).?;
    try equal(@as(u32, 1024), bitmap.width);
    try equal(@as(usize, 4096), bitmap.pixels.len);
    try slices(u8, &.{ 0, 0, 128, 128 }, bitmap.pixels[0..4]);
    try equal(@as(f32, 512), view.commands[0].source_pixels.x);
    try equal(@as(f32, 512), view.commands[0].source_pixels.width);
    try equal(@as(f32, 512), view.commands[0].sample_bounds.x);
    try equal(@as(f32, 512), view.commands[0].sample_bounds.width);
    _ = try view.drawLayer(.above_text);
}
test "failed upload and malformed metadata clear old resources and draws" {
    var mock: Mock = .{ .gpa = std.testing.allocator };
    var keys: graphics_view.KeySource = .{};
    var view = try View.init(std.testing.allocator, mock.resources(), &keys, .{});
    defer view.deinit();
    var snap: Snapshot = .{};
    _ = try view.sync(&snap, geometry, active);
    mock.fail_put = true;
    snap.images[0].generation += 1;
    try std.testing.expectError(error.MockUploadFailed, view.sync(&snap, geometry, active));
    try equal(@as(usize, 0), mock.bytes);
    try equal(@as(usize, 0), view.command_count);
    mock.fail_put = false;
    _ = try view.sync(&snap, geometry, active);
    snap.placements[0].image_index = 2;
    try std.testing.expectError(error.InvalidSnapshot, view.sync(&snap, geometry, active));
    try equal(@as(usize, 0), mock.bytes);
    snap = .{};
    snap.images[0].rgba = &.{ 1, 2, 3 };
    try std.testing.expectError(error.InvalidSnapshot, view.sync(&snap, geometry, active));
}
test "allocator failure at staging and resource copy is leak free" {
    for (0..2) |fail_index| {
        var failure = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var mock: Mock = .{ .gpa = failure.allocator() };
        var keys: graphics_view.KeySource = .{};
        var view = try View.init(failure.allocator(), mock.resources(), &keys, .{});
        defer view.deinit();
        const snap: Snapshot = .{};
        try std.testing.expectError(error.OutOfMemory, view.sync(&snap, geometry, active));
        try equal(@as(usize, 0), mock.bytes);
        try equal(@as(usize, 0), view.command_count);
        try equal(failure.allocated_bytes, failure.freed_bytes);
    }
}
test "resource key source never wraps or aliases separate views" {
    var keys: graphics_view.KeySource = .{ .next_key = std.math.maxInt(u64) };
    try equal(std.math.maxInt(u64), try keys.next());
    try std.testing.expectError(error.ResourceKeyExhausted, keys.next());
    keys = .{};
    var mock: Mock = .{ .gpa = std.testing.allocator };
    var first = try View.init(std.testing.allocator, mock.resources(), &keys, .{});
    defer first.deinit();
    var second = try View.init(std.testing.allocator, mock.resources(), &keys, .{});
    defer second.deinit();
    const snap: Snapshot = .{};
    _ = try first.sync(&snap, geometry, active);
    _ = try second.sync(&snap, geometry, active);
    try expect(first.commands[0].key != second.commands[0].key);
    keys.next_key = 0;
    var next = snap;
    next.images[0].generation += 1;
    try std.testing.expectError(error.ResourceKeyExhausted, first.sync(&next, geometry, active));
    try equal(@as(usize, 4), mock.bytes);
}
test "bad geometry fails closed while offscreen and invalid crops avoid upload" {
    var mock: Mock = .{ .gpa = std.testing.allocator };
    var keys: graphics_view.KeySource = .{};
    var view = try View.init(std.testing.allocator, mock.resources(), &keys, .{});
    defer view.deinit();
    var snap: Snapshot = .{};
    var invalid = geometry;
    invalid.scale = std.math.nan(f32);
    try std.testing.expectError(error.InvalidGeometry, view.sync(&snap, invalid, active));
    invalid = geometry;
    invalid.scale = std.math.floatMin(f32);
    snap.placements[0].width = std.math.maxInt(u32);
    try std.testing.expectError(error.InvalidGeometry, view.sync(&snap, invalid, active));
    snap = .{};
    snap.placements[0].row = 200;
    const stats = try view.sync(&snap, geometry, active);
    try equal(@as(usize, 0), stats.uploaded);
    snap.placements[0] = .{ .source_x = std.math.maxInt(u32) };
    const cropped = try view.sync(&snap, geometry, active);
    try equal(@as(usize, 1), cropped.skipped);
    try equal(@as(usize, 0), mock.bytes);
    try std.testing.expectError(error.InvalidLimits, View.init(std.testing.allocator, mock.resources(), &keys, .{ .images = 33 }));
}
test "draw errors propagate and leave independently owned resources valid" {
    var mock: Mock = .{ .gpa = std.testing.allocator };
    var keys: graphics_view.KeySource = .{};
    var view = try View.init(std.testing.allocator, mock.resources(), &keys, .{});
    defer view.deinit();
    const snap: Snapshot = .{};
    _ = try view.sync(&snap, geometry, active);
    mock.fail_draw = true;
    try std.testing.expectError(error.MockDrawFailed, view.drawLayer(.above_text));
    mock.fail_draw = false;
    try equal(@as(usize, 1), try view.drawLayer(.above_text));
}

fn feed(stream: anytype, bytes: []const u8) !void {
    stream.nextSlice(bytes);
    if (stream.handler.semantic_failure) return error.NativeGraphicsSemanticFailure;
}

fn protocolCheck(ok: bool, name: []const u8, count: *usize) !void {
    std.debug.print("{s} graphics resource {s}\n", .{ if (ok) "PASS" else "FAIL", name });
    if (!ok) return error.GraphicsResourceCheckFailed;
    count.* += 1;
}

/// Compile with the locked official ghostty-vt module, not a handwritten APC
/// parser. No OS/window/config/clipboard effects. This is component evidence;
/// actual nanoui paint/CPU/Metal output remains a root integration check.
pub fn run(gpa: std.mem.Allocator, io: std.Io) !usize {
    const ghostty = @import("ghostty-vt");
    const native = @import("vt_native_graphics.zig");
    const previous_decoder = ghostty.sys.decode_png;
    defer ghostty.sys.decode_png = previous_decoder;
    native.installPngDecoder();
    var quota = try native.BudgetAllocator.init(gpa, 64 * 1024 * 1024);
    var terminal = try ghostty.Terminal.init(io, quota.allocator(), .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 1024 * 1024, .max_scrollback_lines = 1000, .kitty_image_storage_limit = 0 });
    defer terminal.deinit(quota.allocator());
    var stream = terminal.vtStream();
    defer stream.deinit();
    try stream.handler.resize(.{ .cols = 20, .rows = 5, .cell_size_px = .{ .width = 16, .height = 32 } });
    try native.configure(&terminal, true);
    native.configureStream(&stream, true);
    var snapshot: native.Snapshot = .{};
    defer snapshot.deinit(gpa);
    var mock: Mock = .{ .gpa = gpa };
    var keys: graphics_view.KeySource = .{};
    var view = try View.init(gpa, mock.resources(), &keys, .{});
    defer view.deinit();
    var count: usize = 0;
    try feed(&stream, "\x1b_Ga=T,f=24,s=1,v=1,i=11,c=2,r=1,C=1;/wAA\x1b\\");
    try snapshot.refresh(gpa, &terminal);
    var stats = try view.sync(&snapshot, geometry, active);
    try protocolCheck(stats.uploaded == 1 and stats.draws == 1 and std.mem.eql(u8, mock.bitmap(view.commands[0].key).?.pixels, &.{ 0, 0, 255, 255 }), "RGB protocol upload owns BGRA", &count);
    const first_key = view.commands[0].key;
    try feed(&stream, "\x1b_Ga=T,f=32,s=1,v=1,i=11,c=2,r=1,C=1;AP8AgA==\x1b\\");
    try snapshot.refresh(gpa, &terminal);
    stats = try view.sync(&snapshot, geometry, active);
    try protocolCheck(stats.uploaded == 1 and mock.bitmap(first_key) == null and std.mem.eql(u8, mock.bitmap(view.commands[0].key).?.pixels, &.{ 0, 128, 0, 128 }), "same ID revision replaces RGBA resource", &count);
    try feed(&stream, "\x1b_Ga=T,f=100,i=12,c=1,r=1,C=1;iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==\x1b\\");
    try snapshot.refresh(gpa, &terminal);
    stats = try view.sync(&snapshot, geometry, active);
    try protocolCheck(stats.uploaded == 1 and view.liveCount() == 2, "native PNG decoder feeds managed upload", &count);
    try feed(&stream, "\x1b_Ga=p,i=11,p=1,c=2,r=1,C=1,z=-2147483648\x1b\\\x1b_Ga=p,i=11,p=2,c=2,r=1,C=1,z=-1\x1b\\");
    try snapshot.refresh(gpa, &terminal);
    _ = try view.sync(&snapshot, geometry, active);
    mock.draw_count = 0;
    const below = try view.drawLayer(.below_background);
    const middle = try view.drawLayer(.below_text);
    const above = try view.drawLayer(.above_text);
    try protocolCheck(below == 1 and middle == 1 and above >= 1, "protocol z maps three actual draw boundaries", &count);
    try stream.handler.resize(.{ .cols = 20, .rows = 5, .cell_size_px = .{ .width = 20, .height = 40 } });
    try snapshot.refresh(gpa, &terminal);
    var resized = geometry;
    resized.cell_width = 10;
    resized.cell_height = 20;
    stats = try view.sync(&snapshot, resized, active);
    try protocolCheck(stats.uploaded == 0 and view.commands[0].destination.width == 20, "resize changes point geometry without pixel upload", &count);
    try feed(&stream, "\x1b[?1049h\x1b[H");
    try snapshot.refresh(gpa, &terminal);
    _ = try view.sync(&snapshot, resized, active);
    try protocolCheck(mock.bytes == 0 and snapshot.alternate, "alternate entry releases primary GUI cache", &count);
    try feed(&stream, "\x1b_Ga=T,f=24,s=1,v=1,i=11,c=1,r=1,C=1;AAD/\x1b\\");
    try snapshot.refresh(gpa, &terminal);
    _ = try view.sync(&snapshot, resized, active);
    const alt_key = view.commands[0].key;
    try protocolCheck(std.mem.eql(u8, mock.bitmap(alt_key).?.pixels, &.{ 255, 0, 0, 255 }), "alternate reused image ID has isolated pixels", &count);
    try feed(&stream, "\x1b[?1049l");
    try snapshot.refresh(gpa, &terminal);
    _ = try view.sync(&snapshot, resized, active);
    try protocolCheck(mock.bitmap(alt_key) == null and view.liveCount() == 2, "return to primary recaptures original resources", &count);
    try feed(&stream, "\x1b_Ga=d,d=I,i=11\x1b\\");
    try snapshot.refresh(gpa, &terminal);
    _ = try view.sync(&snapshot, resized, active);
    try protocolCheck(view.liveCount() == 1, "protocol image deletion releases upload", &count);
    view.deactivate();
    try protocolCheck(mock.bytes == 0 and view.command_count == 0, "tab hide immediately drops draw and image resources", &count);
    _ = try view.sync(&snapshot, resized, active);
    // Disable must clear the engine and stream separately, then GUI resources.
    try native.configure(&terminal, false);
    native.configureStream(&stream, false);
    try snapshot.refresh(gpa, &terminal);
    _ = try view.sync(&snapshot, resized, .{ .visible = true });
    try protocolCheck(mock.bytes == 0 and snapshot.image_count == 0, "config disable releases VT and GUI storage", &count);
    return count;
}
pub fn main(init: std.process.Init) !void {
    const count = try run(init.gpa, init.io);
    std.debug.print("All {d} graphics resource protocol checks passed (nanoui integration pending).\n", .{count});
}
