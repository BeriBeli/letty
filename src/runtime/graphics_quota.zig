//! Stable, UI-thread-confined allocator above the host allocator. Every allocation
//! records its pool in a header, so delayed/reset/free paths remain correct
//! outside APC scope. This bounds requested heap bytes, NOT mmap or process RSS.
const std = @import("std");
const MiB = 1024 * 1024;
pub const Limits = struct {
    core_bytes: usize,
    graphics_bytes: usize = 48 * MiB,
    reserve_core_bytes: usize = 16 * MiB,
    /// The core allowance follows the host's explicitly bounded history policy;
    /// it must not reuse the old standalone graphics allocator's 64 MiB check.
    /// History mmap is still outside accounting (it has its own upstream limit).
    pub fn fromHistory(history_bytes: usize) error{InvalidLimits}!Limits {
        if (history_bytes > 128 * MiB) return error.InvalidLimits;
        return .{ .core_bytes = history_bytes + 32 * MiB };
    }
};
pub const Outcome = enum { ok, image_rejected, fatal };
pub const Checkpoint = struct { soft: u64, hard: u64, host: u64 };
const Pool = enum { core, graphics };
const Header = struct {
    owner: *Quota,
    raw_len: usize,
    prefix: usize,
    payload_len: usize,
    pool: Pool,
};
pub const Quota = struct {
    /// The backing allocator stays at a stable address until VT teardown.
    child: std.mem.Allocator,
    limits: Limits,
    core_used: usize = 0,
    graphics_used: usize = 0,
    peak: usize = 0,
    soft_epoch: u64 = 0,
    hard_epoch: u64 = 0,
    host_epoch: u64 = 0,
    soft_rejections: usize = 0,
    hard_rejections: usize = 0,
    host_failures: usize = 0,
    scope_depth: usize = 0,

    pub fn init(child: std.mem.Allocator, limits: Limits) error{InvalidLimits}!Quota {
        if (limits.core_bytes == 0 or limits.core_bytes > 160 * MiB or limits.graphics_bytes == 0 or limits.graphics_bytes > 48 * MiB or limits.reserve_core_bytes > limits.core_bytes) return error.InvalidLimits;
        return .{ .child = child, .limits = limits };
    }
    /// Host settings reload, outside feed. Failure leaves the old policy intact;
    /// never lower a live allocation below its charge or swap its allocator.
    pub fn reconfigure(self: *Quota, limits: Limits) error{ InvalidLimits, ActiveScope, LiveAllocationsExceedLimit }!void {
        _ = try Quota.init(self.child, limits);
        if (self.scope_depth != 0) return error.ActiveScope;
        if (limits.core_bytes < self.core_used or limits.graphics_bytes < self.graphics_used) return error.LiveAllocationsExceedLimit;
        self.limits = limits;
    }
    pub fn allocator(self: *Quota) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    pub fn fromAllocator(value: std.mem.Allocator) ?*Quota {
        if (value.vtable != &vtable) return null;
        return @ptrCast(@alignCast(value.ptr));
    }
    pub fn used(self: *const Quota) usize {
        return self.core_used + self.graphics_used;
    }
    pub fn checkpoint(self: *const Quota) Checkpoint {
        return .{ .soft = self.soft_epoch, .hard = self.hard_epoch, .host = self.host_epoch };
    }
    /// Context.status must test this BEFORE selecting its return status. Soft
    /// rejections produce a host image-failure event; never clear existing host
    /// or semantic errors merely because the same feed rejected an image too.
    pub fn outcome(self: *const Quota, before: Checkpoint) Outcome {
        if (self.host_epoch != before.host or self.hard_epoch != before.hard) return .fatal;
        return if (self.soft_epoch != before.soft) .image_rejected else .ok;
    }
    pub const Scope = struct {
        quota: *Quota,
        depth: usize,
        pub fn deinit(self: Scope) void {
            std.debug.assert(self.quota.scope_depth == self.depth);
            self.quota.scope_depth -= 1;
        }
    };
    /// Only around upstream's decoded APC action dispatch. Not around feed(),
    /// which can also contain ordinary text/OSC and true unrelated failures.
    pub fn enterApc(self: *Quota) Scope {
        self.scope_depth += 1;
        return .{ .quota = self, .depth = self.scope_depth };
    }
    fn rejected(self: *Quota) void {
        if (self.scope_depth > 0) {
            self.soft_epoch +%= 1;
            self.soft_rejections +|= 1;
        } else {
            self.hard_epoch +%= 1;
            self.hard_rejections +|= 1;
        }
    }
    fn permits(self: *const Quota, pool: Pool, addition: usize) bool {
        const cap = switch (pool) {
            .graphics => self.limits.graphics_bytes,
            // APC may grow an existing core allocation (notably page pins).
            // Reserve a core headroom even in that case. Normal text gets the
            // full core allowance and can run after an image quota rejection.
            .core => self.limits.core_bytes - if (self.scope_depth > 0) self.limits.reserve_core_bytes else 0,
        };
        const current = switch (pool) {
            .core => self.core_used,
            .graphics => self.graphics_used,
        };
        return current <= cap and addition <= cap - current;
    }
    fn charge(self: *Quota, pool: Pool, bytes: usize) void {
        switch (pool) {
            .core => self.core_used += bytes,
            .graphics => self.graphics_used += bytes,
        }
        self.peak = @max(self.peak, self.used());
    }
    fn uncharge(self: *Quota, pool: Pool, bytes: usize) void {
        switch (pool) {
            .core => self.core_used -= bytes,
            .graphics => self.graphics_used -= bytes,
        }
    }
    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Quota = @ptrCast(@alignCast(ctx));
        const child_alignment = alignment.max(.of(Header));
        const padding = child_alignment.toByteUnits() - 1;
        const worst_prefix = std.math.add(usize, @sizeOf(Header), padding) catch {
            self.rejected();
            return null;
        };
        const prefix = child_alignment.backward(worst_prefix);
        const raw_len = std.math.add(usize, prefix, len) catch {
            self.rejected();
            return null;
        };
        const pool: Pool = if (self.scope_depth > 0) .graphics else .core;
        if (!self.permits(pool, raw_len)) {
            self.rejected();
            return null;
        }
        const raw = self.child.rawAlloc(raw_len, child_alignment, ret) orelse {
            self.host_epoch +%= 1;
            self.host_failures +|= 1;
            return null;
        };
        const payload = raw + prefix;
        const header: *Header = @ptrCast(@alignCast(payload - @sizeOf(Header)));
        header.* = .{ .owner = self, .raw_len = raw_len, .prefix = prefix, .payload_len = len, .pool = pool };
        self.charge(pool, raw_len);
        return payload;
    }
    fn headerOf(self: *Quota, memory: []u8) *Header {
        const header: *Header = @ptrCast(@alignCast(memory.ptr - @sizeOf(Header)));
        std.debug.assert(header.owner == self and header.payload_len == memory.len);
        return header;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
        const self: *Quota = @ptrCast(@alignCast(ctx));
        const header = self.headerOf(memory);
        const raw_len = std.math.add(usize, header.prefix, new_len) catch return false;
        if (new_len > memory.len and !self.permits(header.pool, new_len - memory.len)) return false;
        const raw = (memory.ptr - header.prefix)[0..header.raw_len];
        // A failed in-place resize is an ordinary allocator fallback, not an
        // OOM/rejection epoch. rawAlloc will classify a failed fallback itself.
        if (!self.child.rawResize(raw, alignment.max(.of(Header)), raw_len, ret)) return false;
        self.uncharge(header.pool, header.raw_len);
        header.raw_len = raw_len;
        header.payload_len = new_len;
        self.charge(header.pool, raw_len);
        return true;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        // Count alloc/copy/free overlap; the child may transiently retain both
        // allocations when moving, which a transparent remap would hide.
        return null;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Quota = @ptrCast(@alignCast(ctx));
        const header = self.headerOf(memory).*;
        const raw = (memory.ptr - header.prefix)[0..header.raw_len];
        self.child.rawFree(raw, alignment.max(.of(Header)), ret);
        self.uncharge(header.pool, header.raw_len);
    }
};

test "APC quota rejection is soft and normal text allocations retain headroom" {
    var q = try Quota.init(std.testing.allocator, .{ .core_bytes = 4096, .graphics_bytes = 1024, .reserve_core_bytes = 1024 });
    const before = q.checkpoint();
    const scope = q.enterApc();
    try std.testing.expectError(error.OutOfMemory, q.allocator().alloc(u8, 1024));
    scope.deinit();
    try std.testing.expectEqual(Outcome.image_rejected, q.outcome(before));
    const normal = try q.allocator().alloc(u8, 1024);
    q.allocator().free(normal);
    try std.testing.expectEqual(@as(usize, 0), q.used());
    try std.testing.expectEqual(@as(u64, 0), q.hard_epoch);
}
test "image allocation provenance survives delayed free outside APC and reset" {
    var q = try Quota.init(std.testing.allocator, .{ .core_bytes = 4096, .graphics_bytes = 1024, .reserve_core_bytes = 512 });
    const scope = q.enterApc();
    const image = try q.allocator().alignedAlloc(u8, .@"64", 128);
    scope.deinit();
    const image_bytes = q.graphics_used;
    try std.testing.expect(image_bytes >= 128 and @intFromPtr(image.ptr) % 64 == 0);
    const normal = try q.allocator().alloc(u8, 128);
    q.allocator().free(image);
    try std.testing.expectEqual(@as(usize, 0), q.graphics_used);
    try std.testing.expect(q.core_used > 0);
    q.allocator().free(normal);
    try std.testing.expectEqual(@as(usize, 0), q.used());
}
test "true host OOM remains fatal even while an image quota also rejects" {
    var child = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var q = try Quota.init(child.allocator(), .{ .core_bytes = 4096, .graphics_bytes = 1024, .reserve_core_bytes = 512 });
    const before = q.checkpoint();
    const scope = q.enterApc();
    try std.testing.expectError(error.OutOfMemory, q.allocator().alloc(u8, 16));
    try std.testing.expectError(error.OutOfMemory, q.allocator().alloc(u8, 4096));
    scope.deinit();
    try std.testing.expectEqual(Outcome.fatal, q.outcome(before));
    try std.testing.expect(q.soft_epoch > 0 and q.host_epoch > 0);
    try std.testing.expectEqual(@as(usize, 0), q.used());
}
test "ordinary allocation limit is hard while resize fallback is not failure" {
    var child = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    var q = try Quota.init(child.allocator(), .{ .core_bytes = 1024, .graphics_bytes = 1024, .reserve_core_bytes = 128 });
    const normal = try q.allocator().alloc(u8, 32);
    const before = q.checkpoint();
    try std.testing.expect(!q.allocator().resize(normal, 64));
    try std.testing.expect(q.allocator().remap(normal, 64) == null);
    try std.testing.expectEqual(Outcome.ok, q.outcome(before));
    try std.testing.expectError(error.OutOfMemory, q.allocator().alloc(u8, 1024));
    try std.testing.expectEqual(Outcome.fatal, q.outcome(before));
    q.allocator().free(normal);
}
test "history policy validates 128 MiB maximum and reserves core budget for APC pin growth" {
    const limits = try Limits.fromHistory(128 * MiB);
    try std.testing.expectEqual(@as(usize, 208 * MiB), limits.core_bytes + limits.graphics_bytes);
    try std.testing.expectError(error.InvalidLimits, Limits.fromHistory(128 * MiB + 1));
    var q = try Quota.init(std.testing.allocator, .{ .core_bytes = 1024, .graphics_bytes = 1024, .reserve_core_bytes = 512 });
    const normal = try q.allocator().alloc(u8, 480);
    defer q.allocator().free(normal);
    const scope = q.enterApc();
    defer scope.deinit();
    try std.testing.expect(!q.allocator().resize(normal, 640));
    try std.testing.expectEqual(@as(u64, 0), q.hard_epoch);
}
