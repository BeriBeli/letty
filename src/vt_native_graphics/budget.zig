//! Request-accounting heap budget for native terminal allocations. Keep this
//! wrapper at a stable address until stream AND terminal have been deinitialized.
//! Screen mmap reservations, upstream allocator metadata and renderer uploads
//! are excluded; native PNG scratch IS counted. This is never an RSS claim.
const std = @import("std");
pub const default_limit = 64 * 1024 * 1024;
pub const BudgetAllocator = struct {
    child: std.mem.Allocator,
    limit: usize = default_limit,
    used: usize = 0,
    peak: usize = 0,
    limit_exceeded: bool = false,
    rejected: usize = 0,
    pub fn init(child: std.mem.Allocator, limit: usize) error{InvalidLimit}!BudgetAllocator {
        if (limit == 0 or limit > default_limit) return error.InvalidLimit;
        return .{ .child = child, .limit = limit };
    }
    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
    pub fn allocator(self: *BudgetAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    /// The native graphics entry can reject accidental enablement on a plain
    /// unbounded terminal allocator. This does not unwrap unknown allocators.
    pub fn fromAllocator(value: std.mem.Allocator) ?*BudgetAllocator {
        if (value.vtable != &vtable) return null;
        return @ptrCast(@alignCast(value.ptr));
    }
    fn check(self: *BudgetAllocator, addition: usize) bool {
        if (addition <= self.limit - self.used) return true;
        self.limit_exceeded = true;
        self.rejected +|= 1;
        return false;
    }
    fn grown(self: *BudgetAllocator, size: usize) void {
        self.used += size;
        self.peak = @max(self.peak, self.used);
    }
    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *BudgetAllocator = @ptrCast(@alignCast(context));
        if (!self.check(len)) return null;
        const memory = self.child.rawAlloc(len, alignment, ret) orelse return null;
        self.grown(len);
        return memory;
    }
    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
        const self: *BudgetAllocator = @ptrCast(@alignCast(context));
        if (new_len > memory.len and !self.check(new_len - memory.len)) return false;
        if (!self.child.rawResize(memory, alignment, new_len, ret)) return false;
        self.used -= memory.len;
        self.grown(new_len);
        return true;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        // A child's remap may hold both old/new allocations during relocation.
        // Force the ordinary alloc/copy/free path, counting that overlap too.
        return null;
    }
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *BudgetAllocator = @ptrCast(@alignCast(context));
        std.debug.assert(memory.len <= self.used);
        self.child.rawFree(memory, alignment, ret);
        self.used -= memory.len;
    }
};

test "native graphics budget enforces cumulative limits and recovers after frees" {
    var quota = try BudgetAllocator.init(std.testing.allocator, 128);
    const a = quota.allocator();
    try std.testing.expect(BudgetAllocator.fromAllocator(a).? == &quota);
    try std.testing.expect(BudgetAllocator.fromAllocator(std.testing.allocator) == null);
    const first = try a.alloc(u8, 80);
    const second = try a.alloc(u8, 40);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 9));
    try std.testing.expectEqual(@as(usize, 120), quota.peak);
    try std.testing.expect(quota.limit_exceeded);
    a.free(first);
    const third = try a.alloc(u8, 88);
    try std.testing.expectEqual(@as(usize, 128), quota.used);
    a.free(second);
    a.free(third);
    try std.testing.expectEqual(@as(usize, 0), quota.used);
}
test "native graphics budget rejects before child allocation and bounds resize" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var quota = try BudgetAllocator.init(failing.allocator(), 32);
    try std.testing.expectError(error.OutOfMemory, quota.allocator().alloc(u8, 33));
    try std.testing.expect(!failing.has_induced_failure);
    var live = try BudgetAllocator.init(std.testing.allocator, 128);
    const a = live.allocator();
    const first = try a.alloc(u8, 96);
    defer a.free(first);
    try std.testing.expect(!a.resize(first, 129));
    try std.testing.expectEqual(@as(usize, 96), live.used);
    try std.testing.expect(a.remap(first, 120) == null);
    try std.testing.expectEqual(@as(usize, 96), live.used);
}
