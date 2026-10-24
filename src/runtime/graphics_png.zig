//! Bounded straight-RGBA PNG decoding for the VT callback.
//! Derived from locked nanoui png_decode.zig; pixel output deliberately keeps
//! straight channels (unpremultiplying renderer BGRA would lose information).
// MIT License
//
// Copyright (c) 2026 Rach Pradhan
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
const std = @import("std");

pub const Decoded = struct {
    width: u32,
    height: u32,
    /// Straight RGBA, `width * 4` bytes a row.
    rgba: []u8,

    pub fn deinit(d: Decoded, gpa: std.mem.Allocator) void {
        gpa.free(d.rgba);
    }
};

pub const Error = error{ NotPng, Unsupported, Corrupt, TooLarge, OutOfMemory };

const signature = "\x89PNG\r\n\x1a\n";
/// Hard cap: one megapixel, checked before allocation.
const max_pixels = 1024 * 1024;

fn be32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) Error!Decoded {
    try validate(bytes);
    var pos: usize = signature.len;
    var width: u32 = 0;
    var height: u32 = 0;
    var depth: u8 = 0;
    var color: u8 = 0;
    var interlace: u8 = 0;
    var palette: [256][4]u8 = @splat(.{ 0, 0, 0, 255 });
    var palette_count: usize = 0;
    var trns_gray: ?u16 = null;
    var trns_rgb: ?[3]u16 = null;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    while (pos + 12 <= bytes.len) {
        const len = be32(bytes[pos..]);
        const kind = bytes[pos + 4 .. pos + 8];
        if (pos + 12 + len > bytes.len) return error.Corrupt;
        const data = bytes[pos + 8 .. pos + 8 + len];
        pos += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len < 13) return error.Corrupt;
            width = be32(data);
            height = be32(data[4..]);
            depth = data[8];
            color = data[9];
            interlace = data[12];
            if (width == 0 or height == 0) return error.Corrupt;
            if (@as(u64, width) * height > max_pixels) return error.TooLarge;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            palette_count = len / 3;
            var i: usize = 0;
            while (i < 256 and i * 3 + 2 < len) : (i += 1) palette[i] = .{ data[i * 3], data[i * 3 + 1], data[i * 3 + 2], 255 };
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            switch (color) {
                3 => for (data, 0..) |a, i| if (i < 256) {
                    palette[i][3] = a;
                },
                0 => if (len >= 2) {
                    trns_gray = std.mem.readInt(u16, data[0..2], .big);
                },
                2 => if (len >= 6) {
                    trns_rgb = .{ std.mem.readInt(u16, data[0..2], .big), std.mem.readInt(u16, data[2..4], .big), std.mem.readInt(u16, data[4..6], .big) };
                },
                else => {},
            }
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
    }
    if (width == 0) return error.Corrupt;
    const channels: u8 = switch (color) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        else => return error.Unsupported,
    };
    switch (depth) {
        1, 2, 4 => if (color != 0 and color != 3) return error.Unsupported,
        8 => {},
        16 => if (color == 3) return error.Unsupported,
        else => return error.Unsupported,
    }
    if (interlace > 1) return error.Unsupported;

    // Inflate the zlib stream of every IDAT.
    var input: std.Io.Reader = .fixed(idat.items);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var z: std.compress.flate.Decompress = .init(&input, .zlib, &window);
    const raw = z.reader.allocRemaining(gpa, .limited(max_pixels * 8 + height * 8)) catch return error.Corrupt;
    defer gpa.free(raw);

    const bits_pp: usize = @as(usize, channels) * depth;
    const bpp: usize = @max(1, bits_pp / 8);
    const out = try gpa.alloc(u8, @as(usize, width) * height * 4);
    errdefer gpa.free(out);
    const pass = Pass{ .palette = &palette, .palette_count = palette_count, .trns_gray = trns_gray, .trns_rgb = trns_rgb, .color = color, .depth = depth, .channels = channels, .out = out, .width = width };

    var at: usize = 0;
    if (interlace == 0) {
        at = try pass.run(gpa, raw, at, width, height, bits_pp, bpp, 0, 0, 1, 1);
    } else {
        // Adam7: seven sub-images, each a grid of every so many pixels.
        const starts = [7][2]u32{ .{ 0, 0 }, .{ 4, 0 }, .{ 0, 4 }, .{ 2, 0 }, .{ 0, 2 }, .{ 1, 0 }, .{ 0, 1 } };
        const steps = [7][2]u32{ .{ 8, 8 }, .{ 8, 8 }, .{ 4, 8 }, .{ 4, 4 }, .{ 2, 4 }, .{ 2, 2 }, .{ 1, 2 } };
        for (starts, steps) |s, st| {
            if (s[0] >= width or s[1] >= height) continue;
            const pw = (width - s[0] + st[0] - 1) / st[0];
            const ph = (height - s[1] + st[1] - 1) / st[1];
            at = try pass.run(gpa, raw, at, pw, ph, bits_pp, bpp, s[0], s[1], st[0], st[1]);
        }
    }
    if (at != raw.len) return error.Corrupt;
    return .{ .width = width, .height = height, .rgba = out };
}

const Pass = struct {
    palette: *const [256][4]u8,
    palette_count: usize,
    trns_gray: ?u16,
    trns_rgb: ?[3]u16,
    color: u8,
    depth: u8,
    channels: u8,
    out: []u8,
    width: u32,

    /// Unfilters a (sub-)image of `w`×`h` from `raw` at `at` and writes its
    /// pixels at (x0 + x·dx, y0 + y·dy); returns where the next one starts.
    fn run(p: Pass, gpa: std.mem.Allocator, raw: []const u8, at_in: usize, w: u32, h: u32, bits_pp: usize, bpp: usize, x0: u32, y0: u32, dx: u32, dy: u32) Error!usize {
        const stride = (@as(usize, w) * bits_pp + 7) / 8;
        const prev = try gpa.alloc(u8, stride);
        defer gpa.free(prev);
        @memset(prev, 0);
        var at = at_in;
        for (0..h) |y| {
            if (at + 1 + stride > raw.len) return error.Corrupt;
            const filter = raw[at];
            const line: []u8 = @constCast(raw[at + 1 .. at + 1 + stride]);
            at += 1 + stride;
            unfilter(filter, line, prev, bpp) catch return error.Corrupt;
            for (0..w) |x| {
                // Unspecified palette entries are invalid pixels, not black.
                if (p.color == 3 and p.sample(line, x) >= p.palette_count) return error.Corrupt;
                const px = p.pixel(line, x);
                const ox = x0 + @as(u32, @intCast(x)) * dx;
                const oy = y0 + @as(u32, @intCast(y)) * dy;
                const o = (@as(usize, oy) * p.width + ox) * 4;
                @memcpy(p.out[o..][0..4], &px);
            }
            @memcpy(prev, line);
        }
        return at;
    }

    /// Sample `i` of a row as 16 bits (or an index, for palettes).
    fn sample(p: Pass, line: []const u8, i: usize) u16 {
        return switch (p.depth) {
            16 => std.mem.readInt(u16, line[i * 2 ..][0..2], .big),
            8 => line[i],
            else => blk: {
                const per = 8 / p.depth;
                const byte = line[i / per];
                const shift: u3 = @intCast(8 - p.depth * (1 + i % per));
                const mask: u8 = (@as(u8, 1) << @intCast(p.depth)) - 1;
                break :blk (byte >> shift) & mask;
            },
        };
    }

    /// A sample scaled to 8 bits.
    fn to8(p: Pass, v: u16) u8 {
        return switch (p.depth) {
            16 => @intCast(v >> 8),
            8 => @intCast(v),
            else => @intCast(v * 255 / ((@as(u16, 1) << @intCast(p.depth)) - 1)),
        };
    }

    fn pixel(p: Pass, line: []const u8, x: usize) [4]u8 {
        const n = p.channels;
        return switch (p.color) {
            3 => p.palette[p.sample(line, x) & 0xff],
            0 => blk: {
                const v = p.sample(line, x);
                const g = p.to8(v);
                break :blk .{ g, g, g, if (p.trns_gray != null and p.trns_gray.? == v) 0 else 255 };
            },
            4 => blk: {
                const g = p.to8(p.sample(line, x * n));
                break :blk .{ g, g, g, p.to8(p.sample(line, x * n + 1)) };
            },
            2 => blk: {
                const r = p.sample(line, x * n);
                const g = p.sample(line, x * n + 1);
                const b = p.sample(line, x * n + 2);
                const clear = if (p.trns_rgb) |t| t[0] == r and t[1] == g and t[2] == b else false;
                break :blk .{ p.to8(r), p.to8(g), p.to8(b), if (clear) 0 else 255 };
            },
            else => .{ p.to8(p.sample(line, x * n)), p.to8(p.sample(line, x * n + 1)), p.to8(p.sample(line, x * n + 2)), p.to8(p.sample(line, x * n + 3)) },
        };
    }
};

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn unfilter(filter: u8, line: []u8, prev: []const u8, bpp: usize) !void {
    switch (filter) {
        0 => {},
        1 => for (bpp..line.len) |i| {
            line[i] +%= line[i - bpp];
        },
        2 => for (line, prev) |*l, u| {
            l.* +%= u;
        },
        3 => for (line, 0..) |*l, i| {
            const left: u16 = if (i >= bpp) line[i - bpp] else 0;
            l.* +%= @intCast((left + prev[i]) / 2);
        },
        4 => for (line, 0..) |*l, i| {
            const left = if (i >= bpp) line[i - bpp] else 0;
            const ul = if (i >= bpp) prev[i - bpp] else 0;
            l.* +%= paeth(left, prev[i], ul);
        },
        else => return error.Corrupt,
    }
}

/// Validate framing, CRCs and dimensions before IDAT accumulation/inflation.
/// The callback also supplies a bounded allocator for all working memory.
pub fn validate(bytes: []const u8) Error!void {
    if (bytes.len > 4 * 1024 * 1024) return error.TooLarge;
    if (!std.mem.startsWith(u8, bytes, signature)) return error.NotPng;
    var pos: usize = 8;
    var chunks: usize = 0;
    var header = false;
    var data_seen = false;
    var data_ended = false;
    var palette_seen = false;
    var palette_count: usize = 0;
    var transparency_seen = false;
    var color: u8 = 0;
    var depth: u8 = 0;
    while (pos <= bytes.len and bytes.len - pos >= 12) {
        chunks += 1;
        if (chunks > 4096) return error.TooLarge;
        const len: usize = be32(bytes[pos..]);
        if (len > bytes.len - pos - 12) return error.Corrupt;
        const kind = bytes[pos + 4 ..][0..4];
        const payload = bytes[pos + 8 ..][0..len];
        const crc = be32(bytes[pos + 8 + len ..]);
        if (std.hash.Crc32.hash(bytes[pos + 4 ..][0 .. len + 4]) != crc) return error.Corrupt;
        if (!header and !std.mem.eql(u8, kind, "IHDR")) return error.Corrupt;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (header or len != 13) return error.Corrupt;
            const w = be32(payload);
            const h = be32(payload[4..]);
            if (w == 0 or h == 0) return error.Corrupt;
            if (w > 2048 or h > 2048 or @as(u64, w) * h > max_pixels) return error.TooLarge;
            if (payload[10] != 0 or payload[11] != 0 or payload[12] > 1) return error.Unsupported;
            depth = payload[8];
            color = payload[9];
            const valid_depth = switch (color) {
                0 => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
                2, 4, 6 => depth == 8 or depth == 16,
                3 => depth == 1 or depth == 2 or depth == 4 or depth == 8,
                else => false,
            };
            if (!valid_depth) return error.Unsupported;
            header = true;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            if (data_ended) return error.Corrupt;
            if (color == 3 and !palette_seen) return error.Corrupt;
            data_seen = true;
        } else if (std.mem.eql(u8, kind, "IEND")) {
            if (len != 0 or !data_seen or pos + 12 != bytes.len) return error.Corrupt;
            return;
        } else {
            if (data_seen) data_ended = true;
            if (std.mem.eql(u8, kind, "PLTE")) {
                if (palette_seen or data_seen or transparency_seen or color == 0 or color == 4 or len == 0 or len > 768 or len % 3 != 0) return error.Corrupt;
                palette_count = len / 3;
                if (color == 3 and palette_count > @as(usize, 1) << @intCast(depth)) return error.Corrupt;
                palette_seen = true;
            } else if (std.mem.eql(u8, kind, "tRNS")) {
                if (data_seen or transparency_seen) return error.Corrupt;
                switch (color) {
                    0 => if (len != 2 or std.mem.readInt(u16, payload[0..2], .big) >= @as(u32, 1) << @intCast(depth)) return error.Corrupt,
                    2 => {
                        if (len != 6) return error.Corrupt;
                        for (0..3) |i| if (std.mem.readInt(u16, payload[i * 2 ..][0..2], .big) >= @as(u32, 1) << @intCast(depth)) return error.Corrupt;
                    },
                    3 => if (!palette_seen or len == 0 or len > palette_count) return error.Corrupt,
                    else => return error.Corrupt,
                }
                transparency_seen = true;
            } else if (kind[0] & 0x20 == 0) return error.Unsupported;
        }
        pos += 12 + len;
    }
    return error.Corrupt;
}

const fixture = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x02\x00\x00\x00\x01\x08\x06\x00\x00\x00\xf4\x22\x7f\x8a\x00\x00\x00\x11\x49\x44\x41\x54\x78\x9c\x63\xd0\x08\xa8\x60\xf8\x20\xd2\xe3\x0b\x00\x0b\xaa\x02\xce\xbd\x27\x72\xae\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";
test "PNG keeps straight alpha channels including transparent RGB" {
    const decoded = try decode(std.testing.allocator, fixture);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2), decoded.width);
    try std.testing.expectEqualSlices(u8, &.{ 40, 80, 120, 0, 240, 20, 140, 77 }, decoded.rgba);
}
test "PNG rejects bad CRC and missing IEND before decoding" {
    var bytes: [fixture.len]u8 = fixture[0..fixture.len].*;
    bytes[45] ^= 1;
    try std.testing.expectError(error.Corrupt, decode(std.testing.allocator, &bytes));
    try std.testing.expectError(error.Corrupt, decode(std.testing.allocator, fixture[0 .. fixture.len - 12]));
}
test "PNG dimension and input caps precede decoder allocation" {
    var bytes: [fixture.len]u8 = fixture[0..fixture.len].*;
    std.mem.writeInt(u32, bytes[16..20], 2049, .big);
    std.mem.writeInt(u32, bytes[29..33], std.hash.Crc32.hash(bytes[12..29]), .big);
    var scratch: [0]u8 = .{};
    var fba: std.heap.FixedBufferAllocator = .init(&scratch);
    try std.testing.expectError(error.TooLarge, decode(fba.allocator(), &bytes));
    try std.testing.expectError(error.Corrupt, decode(fba.allocator(), fixture[0..24]));
}
test "PNG inflate output is bounded by supplied scratch allocator" {
    var scratch: [1]u8 = .{0};
    var fba: std.heap.FixedBufferAllocator = .init(&scratch);
    try std.testing.expectError(error.OutOfMemory, decode(fba.allocator(), fixture));
}

fn decodeFixture(comptime encoded: []const u8) !Decoded {
    var bytes: [std.base64.standard.Decoder.calcSizeForSlice(encoded) catch unreachable]u8 = undefined;
    try std.base64.standard.Decoder.decode(&bytes, encoded);
    return decode(std.testing.allocator, &bytes);
}

test "indexed PNG requires a palette and every decoded index must exist" {
    const valid = try decodeFixture("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAMAAAAoyzS7AAAAA1BMVEX/AAAZ4gk3AAAACklEQVR4nGNgAAAAAgABSK+kcQAAAABJRU5ErkJggg==");
    defer valid.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, valid.rgba);
    try std.testing.expectError(error.Corrupt, decodeFixture("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAMAAAAoyzS7AAAACklEQVR4nGNgAAAAAgABSK+kcQAAAABJRU5ErkJggg=="));
    try std.testing.expectError(error.Corrupt, decodeFixture("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAMAAAAoyzS7AAAAA1BMVEX/AAAZ4gk3AAAACklEQVR4nGNgBAAAAwACS/Xd6gAAAABJRU5ErkJggg=="));
}

test "indexed PNG rejects duplicate or oversized transparency tables" {
    try std.testing.expectError(error.Corrupt, decodeFixture("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAMAAAAoyzS7AAAAA1BMVEX/AAAZ4gk3AAAAAXRSTlP/beQ36wAAAAF0Uk5T/23kN+sAAAAKSURBVHicY2AAAAACAAFIr6RxAAAAAElFTkSuQmCC"));
    try std.testing.expectError(error.Corrupt, decodeFixture("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAMAAAAoyzS7AAAAA1BMVEX/AAAZ4gk3AAAAAnRSTlP//8i138cAAAAKSURBVHicY2AAAAACAAFIr6RxAAAAAElFTkSuQmCC"));
}

test "unsupported PNG color depth is rejected before decoder allocation" {
    var bytes: [fixture.len]u8 = fixture[0..fixture.len].*;
    bytes[24] = 1; // RGBA cannot have a one-bit sample depth.
    std.mem.writeInt(u32, bytes[29..33], std.hash.Crc32.hash(bytes[12..29]), .big);
    var scratch: [0]u8 = .{};
    var fba: std.heap.FixedBufferAllocator = .init(&scratch);
    try std.testing.expectError(error.Unsupported, decode(fba.allocator(), &bytes));
}
