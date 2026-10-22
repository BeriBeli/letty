//! Static HarfBuzz leaf API. Fonts copy by default; explicit borrows need a lease.
const std = @import("std");
const features = @import("font_features.zig");
pub const clusters = @import("run_clusters.zig");
pub const max_glyphs = clusters.max_glyphs;
pub const Glyph = clusters.Glyph;
const CFeature = extern struct { tag: [4]u8, value: u32 };
const Handle = opaque {};
extern "c" fn lt_shape_font_create([*]const u8, usize, u32, *?*Handle) c_int;
extern "c" fn lt_shape_font_create_borrowed([*]const u8, usize, u32, *?*Handle) c_int;
extern "c" fn lt_shape_font_free(*Handle) void;
extern "c" fn lt_shape_font_upem(*const Handle) u32;
extern "c" fn lt_shape_font_has_glyph(*const Handle, u32) c_int;
extern "c" fn lt_shape_run(*const Handle, [*]const u8, usize, i32, [*]const CFeature, usize, [*]Glyph, usize, *usize) c_int;
pub extern "c" fn lt_shape_version() [*:0]const u8;
pub const Error = error{ InvalidFont, InvalidInput, CapacityExceeded, OutOfMemory, ShapeFailed, ClosedFont };
pub const Output = struct {
    glyphs: [max_glyphs]Glyph = undefined,
    len: usize = 0,
    pub fn items(self: *const Output) []const Glyph {
        return self.glyphs[0..self.len];
    }
    pub fn place(self: *const Output, gpa: std.mem.Allocator, run: *const clusters.Run, geometry: clusters.Geometry) clusters.Error![]clusters.PlacedGlyph {
        return run.place(gpa, self.items(), geometry);
    }
};
pub const Font = struct {
    handle: ?*Handle,
    pub fn init(bytes: []const u8, face: u32) Error!Font {
        return construct(bytes, face, false);
    }
    /// The caller must keep bytes immutable and alive until Font.deinit().
    pub fn initBorrowed(bytes: []const u8, face: u32) Error!Font {
        return construct(bytes, face, true);
    }
    fn construct(bytes: []const u8, face: u32, borrowed: bool) Error!Font {
        var handle: ?*Handle = null;
        const result = if (borrowed) lt_shape_font_create_borrowed(bytes.ptr, bytes.len, face, &handle) else lt_shape_font_create(bytes.ptr, bytes.len, face, &handle);
        switch (result) {
            0 => return .{ .handle = handle orelse return error.ShapeFailed },
            1 => return error.InvalidFont,
            2 => return error.CapacityExceeded,
            3 => return error.OutOfMemory,
            else => return error.ShapeFailed,
        }
    }
    pub fn deinit(self: *Font) void {
        if (self.handle) |handle| lt_shape_font_free(handle);
        self.handle = null;
    }
    pub fn upem(self: *const Font) u32 {
        return if (self.handle) |handle| lt_shape_font_upem(handle) else 0;
    }
    pub fn hasGlyph(self: *const Font, codepoint: u21) bool {
        return if (self.handle) |handle| lt_shape_font_has_glyph(handle, codepoint) != 0 else false;
    }
    /// px is the physical em size; returned positions are signed 26.6 pixels.
    /// Keep VT cell width unchanged and map the returned byte clusters there.
    pub fn shape(self: *const Font, text: []const u8, px: f32, settings: []const features.Feature, output: *Output) Error!void {
        output.len = 0;
        output.len = try self.shapeInto(text, px, settings, &output.glyphs);
    }

    /// Native text adapters may supply their own reusable bounded scratch.
    /// On error ignore every element; no HB-owned pointer is ever returned.
    pub fn shapeInto(self: *const Font, text: []const u8, px: f32, settings: []const features.Feature, output: []Glyph) Error!usize {
        const handle = self.handle orelse return error.ClosedFont;
        if (!std.math.isFinite(px) or px <= 0 or px > 512) return error.InvalidInput;
        if (settings.len > features.capacity or output.len > max_glyphs) return error.CapacityExceeded;
        var converted: [features.capacity]CFeature = undefined;
        for (settings, 0..) |feature, index| converted[index] = .{ .tag = feature.tag, .value = feature.value };
        const scale: i32 = @max(1, @as(i32, @intFromFloat(@round(px * 64))));
        var length: usize = 0;
        switch (lt_shape_run(handle, text.ptr, text.len, scale, &converted, settings.len, output.ptr, output.len, &length)) {
            0 => return length,
            1 => return error.InvalidInput,
            2 => return error.CapacityExceeded,
            3 => return error.OutOfMemory,
            else => return error.ShapeFailed,
        }
    }
};

test "portable shaper Zig ABI rejects malformed font bytes" {
    try std.testing.expectError(error.InvalidFont, Font.init("bad", 0));
    try std.testing.expectEqualStrings("14.6.0", std.mem.span(lt_shape_version()));
    var closed: Font = .{ .handle = null };
    var output: Output = .{ .len = 1 };
    try std.testing.expectError(error.ClosedFont, closed.shape("a", 16, &.{}, &output));
    try std.testing.expectEqual(@as(usize, 0), output.len);
    closed.deinit();
}
