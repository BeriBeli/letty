//! Actual upstream parser fixtures for recoverable graphics admission failures.
//! No active Context or vendor patch. Build with the locked ghostty-vt module.
const std = @import("std");
const quota_mod = @import("vt_native_graphics/soft_quota.zig");
const Audit = @import("vt_zig/allocator_audit.zig").Audit;

test "Quota outside Audit records image rejection without falsifying host OOM" {
    var audit = Audit.init(std.testing.allocator);
    var quota = try quota_mod.Quota.init(audit.allocator(), .{ .core_bytes = 8192, .graphics_bytes = 1024, .reserve_core_bytes = 1024 });
    const before = quota.checkpoint();
    const scope = quota.enterApc();
    try std.testing.expectError(error.OutOfMemory, quota.allocator().alloc(u8, 2048));
    scope.deinit();
    try std.testing.expectEqual(quota_mod.Outcome.image_rejected, quota.outcome(before));
    try std.testing.expectEqual(@as(u64, 0), audit.failure_epoch);
    const text = try quota.allocator().alloc(u8, 256);
    quota.allocator().free(text);
    try std.testing.expectEqual(@as(usize, 0), quota.used());
}

const rgb = "\x1b_Ga=T,f=24,s=1,v=1,i=11,c=1,r=1,C=1;/wAA\x1b\\";
const png = "\x1b_Ga=T,f=100,i=12,c=1,r=1,C=1;iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==\x1b\\";
const png_same_id = "\x1b_Ga=T,f=100,i=11,c=1,r=1,C=1;iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==\x1b\\";
fn check(value: bool, name: []const u8, count: *usize) !void {
    std.debug.print("{s} native graphics quota {s}\n", .{ if (value) "PASS" else "FAIL", name });
    if (!value) return error.NativeGraphicsQuotaCheckFailed;
    count.* += 1;
}

/// The 64KiB graphics limit is deliberately tiny: a valid 1px PNG reaches the
/// real decoder's 16MiB scratch request and must fail admission before Audit.
/// The host quota does not manufacture a reply: upstream emits ENOMEM when it
/// has a complete command; parser-buffer rejection is a host image-failure
/// event without a wire reply because no complete command/id is available.
pub fn run(gpa: std.mem.Allocator, io: std.Io) !usize {
    const ghostty = @import("ghostty-vt");
    const native = @import("vt_native_graphics.zig");
    const guarded = @import("vt_native_graphics/guarded_stream.zig");
    const Fixture = struct {
        audit: Audit,
        quota: quota_mod.Quota = undefined,
        terminal: ghostty.Terminal = undefined,
        stream: guarded.Stream = undefined,
        replies: [4096]u8 = @splat(0),
        reply_len: usize = 0,
        reply_calls: usize = 0,
        fn open(self: *@This(), host_io: std.Io) !void {
            var limits = try quota_mod.Limits.fromHistory(1024 * 1024);
            limits.graphics_bytes = 64 * 1024;
            self.quota = try .init(self.audit.allocator(), limits);
            self.terminal = try .init(host_io, self.quota.allocator(), .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 1024 * 1024, .max_scrollback_lines = 1000, .kitty_image_storage_limit = 0 });
            errdefer self.terminal.deinit(self.quota.allocator());
            self.stream = try guarded.init(&self.terminal, &self.quota);
            errdefer self.stream.deinit();
            self.stream.handler.core.effects.write_pty = reply;
            try self.stream.handler.core.resize(.{ .cols = 20, .rows = 5, .cell_size_px = .{ .width = 8, .height = 16 } });
            try guarded.configure(&self.stream, true);
        }
        fn close(self: *@This()) void {
            self.stream.deinit();
            self.terminal.deinit(self.quota.allocator());
        }
        fn reply(handler: *guarded.CoreHandler, bytes: []const u8) void {
            const wrapper: *guarded.Handler = @fieldParentPtr("core", handler);
            const stream: *guarded.Stream = @fieldParentPtr("handler", wrapper);
            const self: *@This() = @fieldParentPtr("stream", stream);
            self.reply_calls += 1;
            if (bytes.len > self.replies.len - self.reply_len) return;
            @memcpy(self.replies[self.reply_len..][0..bytes.len], bytes);
            self.reply_len += bytes.len;
        }
        fn feed(self: *@This(), bytes: []const u8) void {
            self.stream.nextSlice(bytes);
        }
    };
    const original_decoder = ghostty.sys.decode_png;
    defer ghostty.sys.decode_png = original_decoder;
    native.installPngDecoder();
    var count: usize = 0;
    var fixture: Fixture = .{ .audit = .init(gpa) };
    try fixture.open(io);
    var live = true;
    defer if (live) fixture.close();
    fixture.feed(rgb);
    try check(fixture.terminal.screens.active.kitty_images.images.contains(11), "small RGB succeeds within image pool", &count);
    const before = fixture.quota.checkpoint();
    const audit_before = fixture.audit.failure_epoch;
    fixture.reply_len = 0;
    fixture.feed(png);
    try check(fixture.quota.outcome(before) == .image_rejected and fixture.audit.failure_epoch == audit_before and !fixture.stream.handler.core.semantic_failure, "real PNG scratch overbudget is soft with unchanged Audit epoch", &count);
    try check(std.mem.indexOf(u8, fixture.replies[0..fixture.reply_len], "i=12;ENOMEM") != null, "complete rejected image gets upstream ENOMEM reply", &count);
    try check(fixture.terminal.screens.active.kitty_images.images.contains(11) and !fixture.terminal.screens.active.kitty_images.images.contains(12) and fixture.terminal.screens.active.kitty_images.loading == null, "failed decode preserves prior image and clears loading state", &count);
    const after_image = fixture.quota.checkpoint();
    fixture.reply_len = 0;
    fixture.feed("\x1b[HOK\x1b[6n");
    const text = try fixture.terminal.plainString(gpa);
    defer gpa.free(text);
    try check(std.mem.startsWith(u8, text, "OK") and fixture.quota.outcome(after_image) == .ok and !fixture.stream.handler.core.semantic_failure, "ordinary text continues after image budget rejection", &count);
    try check(std.mem.indexOf(u8, fixture.replies[0..fixture.reply_len], "\x1b[1;3R") != null, "ordinary DSR write-pty effect continues after rejection", &count);
    fixture.feed(png_same_id);
    try check(!fixture.terminal.screens.active.kitty_images.images.contains(11) and fixture.terminal.screens.active.kitty_images.loading == null, "same-ID failed replacement follows upstream deletion semantics without half image", &count);
    fixture.feed(rgb);
    try check(fixture.terminal.screens.active.kitty_images.images.contains(11), "a new small image can be accepted after previous admission failure", &count);

    // Drive the SAME upstream parser through sliced, oversized APC collection.
    // The wrapper never scans these bytes or reconstructs an APC command.
    const before_chunk = fixture.quota.checkpoint();
    fixture.feed("\x1b_Ga=T,f=24,s=128,v=128,i=13,m=1;/wAA\x1b\\");
    try check(fixture.terminal.screens.active.kitty_images.loading != null, "incomplete chunk is tracked before subsequent chunk budget failure", &count);
    fixture.feed("\x1b_Gm=0;");
    var payload: [128 * 1024]u8 = @splat('A');
    fixture.feed(&payload);
    fixture.feed("\x1b\\\x1b[HAFTER\x1b[6n");
    const after_chunk = try fixture.terminal.plainString(gpa);
    defer gpa.free(after_chunk);
    try check(fixture.quota.outcome(before_chunk) == .image_rejected and fixture.audit.failure_epoch == audit_before and !fixture.stream.handler.core.semantic_failure and fixture.terminal.screens.active.kitty_images.loading == null, "APC buffer overbudget cancels incomplete upload through official parser", &count);
    try check(std.mem.startsWith(u8, after_chunk, "AFTER") and std.mem.indexOf(u8, fixture.replies[0..fixture.reply_len], "\x1b[1;6R") != null, "text and PTY recover after dropped APC collection", &count);
    fixture.feed("\x1b_Ga=T,f=24,s=128,v=128,i=14;");
    fixture.feed(payload[0..4096]);
    const graphics_before_disable = fixture.quota.graphics_used;
    try guarded.configure(&fixture.stream, false);
    try check(fixture.quota.graphics_used < graphics_before_disable and fixture.terminal.screens.active.kitty_images.total_bytes == 0 and fixture.terminal.screens.active.kitty_images.images.count() == 0 and std.meta.activeTag(fixture.stream.handler.core.apc_handler.state) == .ignore, "disable releases image pixels/maps/APC buffer through original tagged allocator", &count);
    fixture.feed("AAAA\x1b\\\x1b[HRELOAD\x1b[6n");
    const after_disable = try fixture.terminal.plainString(gpa);
    defer gpa.free(after_disable);
    try check(std.mem.startsWith(u8, after_disable, "RELOAD") and !fixture.stream.handler.core.semantic_failure, "disable in mid-APC drops tail and preserves subsequent normal text", &count);
    fixture.close();
    live = false;
    try check(fixture.quota.used() == 0, "stream then terminal destruction drains both pools", &count);

    // Real child failure after an earlier soft image rejection is still fatal.
    // It may be swallowed by the upstream APC parser, so checking only its
    // semantic_failure flag is insufficient; the Audit/Quota epochs are real.
    var failure = std.testing.FailingAllocator.init(gpa, .{});
    var failing: Fixture = .{ .audit = .init(failure.allocator()) };
    try failing.open(io);
    var failing_live = true;
    defer if (failing_live) failing.close();
    const failure_before = failing.quota.checkpoint();
    failing.feed(png);
    failure.fail_index = failure.alloc_index;
    const host_epoch = failing.audit.failure_epoch;
    failing.feed(rgb);
    try check(failing.quota.outcome(failure_before) == .fatal and failing.quota.soft_epoch != failure_before.soft and failing.audit.failure_epoch != host_epoch, "real host OOM wins over a soft image rejection in same operation", &count);
    // A real Context stops further feed on fatal; this fixture does likewise.
    failing.close();
    failing_live = false;
    try check(failing.quota.used() == 0 and failure.allocated_bytes == failure.freed_bytes, "host allocation failure cleanup has no partial-resource leak", &count);
    return count;
}
pub fn main(init: std.process.Init) !void {
    const count = try run(init.gpa, init.io);
    std.debug.print("All {d} native graphics quota checks passed (Context integration pending).\n", .{count});
}
