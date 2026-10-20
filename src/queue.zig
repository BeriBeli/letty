const std = @import("std");
/// Fixed capacity ring: no output drops or growing allocation under pressure.
pub const Queue = struct {
    bytes: []u8,
    head: usize = 0,
    len: usize = 0,
    pub fn init(a: std.mem.Allocator, cap: usize) !Queue {
        return .{ .bytes = try a.alloc(u8, cap) };
    }
    pub fn deinit(q: *Queue, a: std.mem.Allocator) void {
        a.free(q.bytes);
    }
    pub fn free(q: Queue) usize {
        return q.bytes.len - q.len;
    }
    pub fn push(q: *Queue, s: []const u8) bool {
        if (s.len > q.free()) return false;
        const tail = (q.head + q.len) % q.bytes.len;
        const first = @min(s.len, q.bytes.len - tail);
        @memcpy(q.bytes[tail..][0..first], s[0..first]);
        @memcpy(q.bytes[0 .. s.len - first], s[first..]);
        q.len += s.len;
        return true;
    }
    pub fn peek(q: Queue) []const u8 {
        return q.bytes[q.head..][0..@min(q.len, q.bytes.len - q.head)];
    }
    pub fn consume(q: *Queue, n: usize) void {
        std.debug.assert(n <= q.len);
        q.head = (q.head + n) % q.bytes.len;
        q.len -= n;
    }
};
test "partial writes wrap and rejected input leaves order intact" {
    var q = try Queue.init(std.testing.allocator, 8);
    defer q.deinit(std.testing.allocator);
    try std.testing.expect(q.push("abcdef"));
    q.consume(5);
    try std.testing.expect(q.push("1234567"));
    try std.testing.expect(!q.push("lost"));
    try std.testing.expectEqualStrings("f12", q.peek());
    q.consume(3);
    try std.testing.expectEqualStrings("34567", q.peek());
    q.consume(5);
    try std.testing.expectEqual(@as(usize, 8), q.free());
}
