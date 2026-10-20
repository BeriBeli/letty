//! Isolated native graphics fixtures. Uses init.io; no app window/user config/
//! clipboard. Compile with the official locked ghostty-vt native module.
const std = @import("std");
const ghostty = @import("ghostty-vt");
const graphics = @import("vt_native_graphics.zig");
const Handler = ghostty.TerminalStream.Handler;
const Fixture = struct {
    quota: graphics.BudgetAllocator,
    terminal: ghostty.Terminal = undefined,
    stream: ghostty.TerminalStream = undefined,
    snapshot: graphics.Snapshot = .{},
    replies: [1024]u8 = @splat(0),
    reply_len: usize = 0,
    reply_calls: usize = 0,
    fn open(self: *Fixture, io: std.Io) !void {
        self.terminal = try .init(io, self.quota.allocator(), .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 1024 * 1024, .max_scrollback_lines = 1000, .kitty_image_storage_limit = 0 });
        errdefer self.terminal.deinit(self.quota.allocator());
        self.stream = self.terminal.vtStream();
        errdefer self.stream.deinit();
        self.stream.handler.effects.write_pty = reply;
        graphics.configureStream(&self.stream, false);
        try self.stream.handler.resize(.{ .cols = 20, .rows = 5, .cell_size_px = .{ .width = 8, .height = 16 } });
    }
    fn close(self: *Fixture) void {
        self.snapshot.deinit(std.heap.page_allocator);
        self.stream.deinit();
        self.terminal.deinit(self.quota.allocator());
    }
    fn reply(handler: *Handler, bytes: []const u8) void {
        const stream: *ghostty.TerminalStream = @fieldParentPtr("handler", handler);
        const self: *Fixture = @fieldParentPtr("stream", stream);
        self.reply_calls += 1;
        if (self.reply_len + bytes.len > self.replies.len) return;
        @memcpy(self.replies[self.reply_len..][0..bytes.len], bytes);
        self.reply_len += bytes.len;
    }
    fn feed(self: *Fixture, bytes: []const u8) !void {
        self.stream.nextSlice(bytes);
        if (self.stream.handler.semantic_failure) return error.NativeGraphicsSemanticFailure;
    }
    fn capture(self: *Fixture) !void {
        try self.snapshot.refresh(std.heap.page_allocator, &self.terminal);
    }
    fn enabled(self: *Fixture, value: bool) !void {
        try graphics.configure(&self.terminal, value);
        graphics.configureStream(&self.stream, value);
    }
    fn image(self: *Fixture, id: u32) ?graphics.Image {
        for (self.snapshot.images[0..self.snapshot.image_count]) |entry| if (entry.id == id) return entry;
        return null;
    }
    fn placement(self: *Fixture, image_id: u32) ?graphics.Placement {
        for (self.snapshot.placements[0..self.snapshot.placement_count]) |entry| if (entry.image_id == image_id) return entry;
        return null;
    }
};
fn expect(ok: bool, name: []const u8, count: *usize) !void {
    std.debug.print("{s} {s}\n", .{ if (ok) "PASS" else "FAIL", name });
    if (!ok) return error.NativeGraphicsCheck;
    count.* += 1;
}
const rgb = "\x1b_Ga=T,f=24,s=1,v=1,i=11,c=2,r=1;/wAA\x1b\\";
const rgba = "\x1b_Ga=T,f=32,s=1,v=1,i=11,c=2,r=1;AP8AgA==\x1b\\";
const png = "\x1b_Ga=T,f=100,i=12,c=1,r=1;iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==\x1b\\";
pub fn run(io: std.Io) !usize {
    if (!graphics.compiled) return error.KittyGraphicsNotCompiled;
    const original_decoder = ghostty.sys.decode_png;
    defer ghostty.sys.decode_png = original_decoder;
    graphics.installPngDecoder();
    var count: usize = 0;
    var fixture: Fixture = .{ .quota = try .init(std.heap.page_allocator, 64 * 1024 * 1024) };
    try fixture.open(io);
    var live = true;
    defer if (live) fixture.close();
    try fixture.feed(rgb);
    try fixture.capture();
    try expect(fixture.snapshot.image_count == 0 and fixture.terminal.screens.active.kitty_images.images.count() == 0, "native disabled Kitty does not collect or store image commands", &count);
    try fixture.enabled(true);
    try fixture.feed(rgb);
    try fixture.capture();
    const first = fixture.image(11).?;
    try expect(std.mem.eql(u8, first.rgba, &.{ 255, 0, 0, 255 }) and fixture.snapshot.placement_count == 1, "native RGB protocol produces owned straight RGBA", &count);
    try expect(fixture.placement(11).?.width == 16 and fixture.placement(11).?.height == 16, "native placement derives pixels from terminal cell geometry", &count);
    var retained = try graphics.take(std.heap.page_allocator, &fixture.terminal);
    defer retained.deinit(std.heap.page_allocator);
    try fixture.feed(rgba);
    try expect(std.mem.eql(u8, retained.images[0].rgba, &.{ 255, 0, 0, 255 }), "native snapshot payload remains valid across feed mutation", &count);
    try fixture.capture();
    try expect(fixture.image(11).?.generation != first.generation and std.mem.eql(u8, fixture.image(11).?.rgba, &.{ 0, 255, 0, 128 }), "native same-ID replacement changes generation and preserves alpha", &count);
    fixture.reply_len = 0;
    fixture.reply_calls = 0;
    try fixture.feed("\x1b_Ga=q,f=24,s=1,v=1,i=99;/wAA\x1b\\");
    try expect(fixture.reply_calls == 1 and std.mem.indexOf(u8, fixture.replies[0..fixture.reply_len], "i=99;OK") != null, "native Kitty query emits one explicit write-pty effect", &count);
    try fixture.feed("\x1b_Ga=T,f=24,s=2,v=1,i=41,c=2,r=1,m=1;/wAA\x1b\\");
    try fixture.capture();
    try expect(fixture.image(41) == null and fixture.terminal.screens.active.kitty_images.loading != null, "native partial chunk stays parser-owned and absent from renderer snapshots", &count);
    try fixture.feed("\x1b_Gm=0;AAD/\x1b\\");
    try fixture.capture();
    try expect(std.mem.eql(u8, fixture.image(41).?.rgba, &.{ 255, 0, 0, 255, 0, 0, 255, 255 }) and fixture.terminal.screens.active.kitty_images.loading == null, "native chunk completion transfers one complete owned image", &count);
    try fixture.feed("\x1b_Ga=d,d=I,i=41\x1b\\");
    try fixture.feed(png);
    try fixture.capture();
    try expect(fixture.image(12) != null and fixture.image(12).?.rgba.len == 4, "native PNG protocol uses installed real decoder", &count);
    var failing = std.testing.FailingAllocator.init(std.heap.page_allocator, .{ .fail_index = 1 });
    var failed_cleanly = false;
    if (graphics.take(failing.allocator(), &fixture.terminal)) |value| {
        var unexpected = value;
        unexpected.deinit(failing.allocator());
    } else |err| failed_cleanly = err == error.OutOfMemory and failing.allocated_bytes == failing.freed_bytes;
    try expect(failed_cleanly, "native snapshot OOM frees already copied image payloads", &count);
    try fixture.feed("\x1b_Ga=T,f=100,i=13;AAAA\x1b\\");
    try fixture.capture();
    try expect(fixture.image(13) == null and fixture.snapshot.image_count == 2, "native malformed PNG does not create a partial image", &count);
    try fixture.feed("\x1b[?1049h");
    try fixture.capture();
    try expect(fixture.snapshot.alternate and fixture.snapshot.image_count == 0 and fixture.terminal.screens.active.kitty_images.total_limit == graphics.storage_bytes, "native alternate storage is isolated and inherits small enabled budget", &count);
    try fixture.feed("\x1b_Ga=T,f=24,s=1,v=1,i=11,c=1,r=1;AAD/\x1b\\");
    try fixture.capture();
    try expect(std.mem.eql(u8, fixture.image(11).?.rgba, &.{ 0, 0, 255, 255 }) and fixture.image(11).?.generation != first.generation, "native image ID reuse across screens cannot alias generations", &count);
    try fixture.feed("\x1b[?1049l");
    try fixture.capture();
    try expect(!fixture.snapshot.alternate and fixture.image(12) != null, "native primary images survive alternate screen lifetime", &count);
    try fixture.feed("\x1b[H\x1b_Ga=T,f=24,s=1,v=1,i=21,c=1,r=3,C=1;/wAA\x1b\\\x1b[5;1H\n");
    try fixture.capture();
    try expect(fixture.placement(21).?.row == -1 and fixture.placement(21).?.height == 48, "native partially scrolled placement keeps negative row for clipping", &count);
    const generation = fixture.snapshot.generation;
    try fixture.stream.handler.resize(.{ .cols = 20, .rows = 5, .cell_size_px = .{ .width = 10, .height = 20 } });
    try fixture.capture();
    try expect(fixture.placement(21).?.width == 10 and fixture.placement(21).?.height == 60 and fixture.snapshot.generation == generation, "native resize updates placement geometry without inventing content revision", &count);
    try fixture.feed("\x1b[H\x1b_Ga=T,f=24,s=1,v=1,i=31,c=1,r=1,X=9999,Y=9999,C=1;/wAA\x1b\\");
    try fixture.capture();
    const offset = fixture.placement(31).?;
    try expect(offset.x_offset < 10 and offset.y_offset < 20 and offset.width == 1 and offset.height == 1, "native hostile pixel offsets clamp consistently with placement size", &count);
    try fixture.feed("\x1b[H\x1b_Ga=p,i=12,p=1,c=3,r=1,C=1\x1b\\\x1b_Ga=p,i=12,p=2,P=12,Q=1,H=-1,V=0,c=2,r=1,C=1,z=-3\x1b\\");
    try fixture.capture();
    var relative_ok = false;
    for (fixture.snapshot.placements[0..fixture.snapshot.placement_count]) |placement| {
        if (placement.image_id == 12 and placement.id == 2 and !placement.internal_id and placement.col == -1 and placement.width == 20 and placement.z == -3) relative_ok = true;
    }
    try expect(relative_ok, "native relative chain resolves negative column without leaking parent Pins", &count);
    try fixture.feed("\x1b_Ga=p,i=12,p=3,U=1,c=1,r=1,C=1\x1b\\");
    try fixture.capture();
    var virtual_hidden = fixture.snapshot.virtual_placements > 0;
    for (fixture.snapshot.placements[0..fixture.snapshot.placement_count]) |placement| {
        if (placement.image_id == 12 and placement.id == 3 and !placement.internal_id) virtual_hidden = false;
    }
    try expect(virtual_hidden, "native unsupported Unicode placeholder placements are counted and not falsely rendered", &count);
    try fixture.feed("\x1b_Ga=d,d=I,i=11\x1b\\");
    try fixture.capture();
    try expect(fixture.image(11) == null, "native protocol delete drops image snapshots and placements", &count);
    // File medium denial is checked without referencing any real local path.
    try fixture.feed("\x1b_Ga=T,t=f,f=24,s=1,v=1,i=61;L25ldmVyLW9wZW4tdGhpcy1maWxl\x1b\\");
    try fixture.capture();
    try expect(fixture.image(61) == null and fixture.terminal.screens.active.kitty_images.image_limits.file == false, "native untrusted file medium stays disabled while std.Io remains available", &count);
    try fixture.feed("\x1b_Ga=T,t=s,f=24,s=1,v=1,i=62;L25ldmVyLW9wZW4tdGhpcy1maWxl\x1b\\");
    try fixture.feed("\x1b_Ga=T,t=t,f=24,s=1,v=1,i=63;L25ldmVyLW9wZW4tdGhpcy1maWxl\x1b\\");
    try fixture.capture();
    try expect(fixture.image(62) == null and fixture.image(63) == null and fixture.terminal.screens.active.kitty_images.image_limits.shared_memory == false, "native shared-memory and temporary-file media are denied without OS access", &count);
    for (100..100 + graphics.max_placements + 8) |index| {
        var command: [128]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&command, "\x1b_Ga=p,i=12,p={d},c=1,r=1,C=1\x1b\\", .{index});
        try fixture.feed(bytes);
    }
    try fixture.capture();
    try expect(fixture.snapshot.placement_count <= graphics.max_placements and fixture.snapshot.skipped_placements > 0, "native placement flood cannot grow renderer snapshot beyond quota", &count);
    try fixture.enabled(false);
    try fixture.capture();
    var screens = fixture.terminal.screens.all.iterator();
    var all_empty = true;
    while (screens.next()) |entry| all_empty = all_empty and entry.value.*.kitty_images.total_bytes == 0 and entry.value.*.kitty_images.total_limit == 0;
    try expect(all_empty and fixture.snapshot.owned_bytes == 0, "native disable evicts both screens and host payloads", &count);
    fixture.close();
    live = false;
    try expect(fixture.quota.used == 0, "native stream then terminal destruction drains tracked heap budget", &count);
    try expect(std.mem.eql(u8, retained.images[0].rgba, &.{ 255, 0, 0, 255 }), "native owned snapshot survives terminal destruction without Pins or handles", &count);
    return count;
}
pub fn main(init: std.process.Init) !void {
    const count = try run(init.io);
    std.debug.print("All {d} native graphics checks passed.\n", .{count});
}
