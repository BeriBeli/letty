//! Main-thread static HarfBuzz cache shared by portable windows. Font bytes
//! are owned by HB; no Db/TextSystem borrow survives a shape callback.
const std = @import("std");
const ui = @import("nanoui").ui;
const grid = ui.gridText;
const shaper = @import("portable_shaper.zig");
const mapping = @import("run_clusters.zig");
const features = @import("font_features.zig");
pub const max_fonts = 16;
pub const max_source_bytes = 64 << 20;
const Entry = struct { digest: [32]u8, index: u32, bytes: usize, used: u64, font: shaper.Font };
pub const Stats = struct { fonts: usize = 0, source_bytes: usize = 0, evictions: u64 = 0, hits: u64 = 0, misses: u64 = 0, last_error: ?[]const u8 = null };
const Cache = struct {
    slots: [max_fonts]?Entry = @splat(null),
    raw: [shaper.max_glyphs]shaper.Glyph = undefined,
    clock: u64 = 0,
    clients: usize = 0,
    stats: Stats = .{},
    fn remove(self: *Cache, slot: usize) void {
        if (self.slots[slot]) |*entry| {
            entry.font.deinit();
            self.stats.source_bytes -= entry.bytes;
            self.stats.fonts -= 1;
            self.slots[slot] = null;
        }
    }
    fn oldest(self: *Cache) usize {
        var result: ?usize = null;
        for (self.slots, 0..) |slot, i| {
            const entry = slot orelse continue;
            if (result == null or entry.used < self.slots[result.?].?.used) result = i;
        }
        return result orelse 0;
    }
    fn vacant(self: *Cache) usize {
        for (self.slots, 0..) |slot, i| if (slot == null) return i;
        unreachable;
    }
    fn get(self: *Cache, source: grid.Source) !*shaper.Font {
        self.clock +|= 1;
        for (&self.slots) |*slot| if (slot.*) |*entry| {
            if (entry.index == source.index and std.mem.eql(u8, &entry.digest, &source.digest)) {
                self.stats.hits +|= 1;
                entry.used = self.clock;
                return &entry.font;
            }
        };
        self.stats.misses +|= 1;
        if (source.bytes.len > max_source_bytes) return error.FontCacheLimit;
        while (self.stats.source_bytes > max_source_bytes - source.bytes.len or self.stats.fonts == max_fonts) {
            self.remove(self.oldest());
            self.stats.evictions +|= 1;
        }
        const slot = self.vacant();
        const font = try shaper.Font.init(source.bytes, source.index);
        self.slots[slot] = .{ .digest = source.digest, .index = source.index, .bytes = source.bytes.len, .used = self.clock, .font = font };
        self.stats.source_bytes += source.bytes.len;
        self.stats.fonts += 1;
        return &self.slots[slot].?.font;
    }
};
var shared: Cache = .{};
pub fn stats() Stats {
    return shared.stats;
}
pub fn install(text: anytype) void {
    if (comptime !@hasDecl(@TypeOf(text.*), "setRunShaper")) return;
    if (text.run_shaper != null) return;
    shared.clients += 1;
    text.setRunShaper(.{ .context = &shared, .shape = shape, .deinit = release });
}
fn release(context: *anyopaque, _: std.mem.Allocator) void {
    const cache: *Cache = @ptrCast(@alignCast(context));
    std.debug.assert(cache.clients > 0);
    cache.clients -= 1;
    if (cache.clients == 0) {
        for (0..max_fonts) |i| cache.remove(i);
        cache.clock = 0;
    }
}
fn shape(context: *anyopaque, gpa: std.mem.Allocator, request: grid.Request) ![]grid.Shaped {
    const cache: *Cache = @ptrCast(@alignCast(context));
    return shapeInner(cache, gpa, request) catch |err| {
        cache.stats.last_error = @errorName(err);
        return err;
    };
}
fn shapeInner(cache: *Cache, gpa: std.mem.Allocator, request: grid.Request) ![]grid.Shaped {
    if (request.features.len > features.capacity) return error.TooManyFontFeatures;
    var settings: [features.capacity]features.Feature = undefined;
    for (request.features, 0..) |feature, i| settings[i] = .{ .tag = feature.tag, .value = feature.value };
    const font = try cache.get(request.source);
    const count = try font.shapeInto(request.text, request.physical_px, settings[0..request.features.len], &cache.raw);
    const cells = try gpa.alloc(mapping.CellSpan, request.cells.len);
    defer gpa.free(cells);
    for (cells, request.cells) |*dst, cell| dst.* = .{ .byte_start = cell.byte_start, .byte_end = cell.byte_end, .col = cell.col, .width = cell.width };
    var run = try mapping.Run.init(gpa, request.text, cells);
    defer run.deinit(gpa);
    const placed = try run.place(gpa, cache.raw[0..count], .{ .scale = request.scale, .cell_width = request.cell_width });
    defer gpa.free(placed);
    const result = try gpa.alloc(grid.Shaped, placed.len);
    for (result, placed) |*dst, item| dst.* = .{ .glyph = item.glyph, .index = item.byte_start, .x = item.x, .y = -item.y };
    return result;
}
