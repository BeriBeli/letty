//! Records failed heap allocations that upstream parsers may otherwise handle
//! by dropping a sequence. A failed in-place resize/remap is NOT an OOM: ordinary
//! allocators use that result to request alloc/copy/free instead. This observes
//! only child rawAlloc failures; direct OS mmap errors remain upstream's concern.
const std = @import("std");
pub const Audit = struct {
    child: std.mem.Allocator,
    failure_epoch: u64 = 0,
    failed_requests: usize = 0,
    last_failed_bytes: usize = 0,
    pub fn init(child: std.mem.Allocator) Audit {
        return .{ .child = child };
    }
    pub fn allocator(self: *Audit) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    pub fn fromAllocator(value: std.mem.Allocator) ?*Audit {
        if (value.vtable != &vtable) return null;
        return @ptrCast(@alignCast(value.ptr));
    }
    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Audit = @ptrCast(@alignCast(raw));
        return self.child.rawAlloc(len, alignment, ret) orelse {
            self.failure_epoch +%= 1;
            self.failed_requests +|= 1;
            self.last_failed_bytes = len;
            return null;
        };
    }
    fn resize(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
        const self: *Audit = @ptrCast(@alignCast(raw));
        return self.child.rawResize(memory, alignment, new_len, ret);
    }
    fn remap(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
        const self: *Audit = @ptrCast(@alignCast(raw));
        return self.child.rawRemap(memory, alignment, new_len, ret);
    }
    fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Audit = @ptrCast(@alignCast(raw));
        self.child.rawFree(memory, alignment, ret);
    }
};
test "audit distinguishes failed allocation from normal resize/remap fallback" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    var audit = Audit.init(failing.allocator());
    const allocator = audit.allocator();
    try std.testing.expect(Audit.fromAllocator(allocator).? == &audit);
    try std.testing.expect(Audit.fromAllocator(std.testing.allocator) == null);
    const first = try allocator.alloc(u8, 16);
    defer allocator.free(first);
    try std.testing.expect(!allocator.resize(first, 32));
    try std.testing.expect(allocator.remap(first, 32) == null);
    try std.testing.expectEqual(@as(u64, 0), audit.failure_epoch);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 64));
    try std.testing.expectEqual(@as(u64, 1), audit.failure_epoch);
    try std.testing.expectEqual(@as(usize, 1), audit.failed_requests);
    try std.testing.expectEqual(@as(usize, 64), audit.last_failed_bytes);
}
