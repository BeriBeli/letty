//! Owned, geometrically grown storage. Callers publish only after allocation succeeds.
const std = @import("std");
pub const allocator = std.heap.page_allocator;
pub fn ensure(comptime T: type, storage: *[]T, needed: usize, initial: T) !void {
    if (needed <= storage.len) return;
    const size = @max(needed, std.math.mul(usize, @max(storage.len, 4), 2) catch needed);
    const next = try allocator.alloc(T, size);
    @memcpy(next[0..storage.len], storage.*);
    @memset(next[storage.len..], initial);
    allocator.free(storage.*);
    storage.* = next;
}
pub fn release(comptime T: type, storage: *[]T) void {
    allocator.free(storage.*);
    storage.* = &.{};
}
