//! Decoded OSC 52 writes only. Protocol decoding belongs to Ghostty. The host
//! takes an owned copy after feed returns; no reply/context borrow is retained.
const std = @import("std");
pub const limit = 64 * 1024;
pub const Policy = enum { deny, ask, allow };
pub const Request = struct { bytes: []u8, policy: Policy };
pub const State = struct {
    policy: Policy = .deny,
    pending: ?Request = null,
    accepted: u64 = 0,
    denied: u64 = 0,
    invalid: u64 = 0,
    busy: u64 = 0,

    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        if (self.pending) |request| gpa.free(request.bytes);
        self.pending = null;
    }
    pub fn configure(self: *State, gpa: std.mem.Allocator, policy: Policy) void {
        // Reload revokes an outstanding write instead of upgrading old consent.
        if (self.policy != policy) self.deinit(gpa);
        self.policy = policy;
    }
    pub fn queue(self: *State, gpa: std.mem.Allocator, bytes: []const u8) !void {
        if (self.policy == .deny) {
            self.denied +|= 1;
            return error.ClipboardWriteDenied;
        }
        if (bytes.len > limit or !std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null) {
            self.invalid +|= 1;
            return error.InvalidClipboardWrite;
        }
        if (self.pending != null) {
            self.busy +|= 1;
            return error.ClipboardWriteBusy;
        }
        const owned = try gpa.dupe(u8, bytes);
        self.pending = .{ .bytes = owned, .policy = self.policy };
        self.accepted +|= 1;
    }
    /// Transfer to a different host allocator before a Session/VT can close.
    /// Failed copy retains the original pending request; callers can retry.
    pub fn take(self: *State, source: std.mem.Allocator, host: std.mem.Allocator) !?Request {
        const request = self.pending orelse return null;
        const owned = try host.dupe(u8, request.bytes);
        self.deinit(source);
        return .{ .bytes = owned, .policy = request.policy };
    }
};

test "OSC52 defaults deny and explicit ask copies decoded text before source dies" {
    const a = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(a);
    try std.testing.expectError(error.ClipboardWriteDenied, state.queue(a, "secret"));
    state.configure(a, .ask);
    var bytes = [_]u8{ 'a', 'b', 'c' };
    try state.queue(a, &bytes);
    bytes[0] = 'X';
    const result = (try state.take(a, a)).?;
    defer a.free(result.bytes);
    try std.testing.expectEqualStrings("abc", result.bytes);
    try std.testing.expectEqual(Policy.ask, result.policy);
    try std.testing.expect(state.pending == null);
}
test "OSC52 bounds UTF8 NUL duplicate writes and reload revocation" {
    const a = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(a);
    state.configure(a, .allow);
    try std.testing.expectError(error.InvalidClipboardWrite, state.queue(a, "\xff"));
    try std.testing.expectError(error.InvalidClipboardWrite, state.queue(a, "a\x00b"));
    const large = try a.alloc(u8, limit + 1);
    defer a.free(large);
    @memset(large, 'x');
    try std.testing.expectError(error.InvalidClipboardWrite, state.queue(a, large));
    try state.queue(a, ""); // Explicit empty OSC 52 clears the clipboard.
    try std.testing.expectError(error.ClipboardWriteBusy, state.queue(a, "second"));
    state.configure(a, .ask);
    try std.testing.expect(state.pending == null);
}
test "OSC52 allocation failures preserve ownership and never publish partial data" {
    const a = std.testing.allocator;
    var fail = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var state: State = .{ .policy = .allow };
    defer state.deinit(a);
    try std.testing.expectError(error.OutOfMemory, state.queue(fail.allocator(), "text"));
    try std.testing.expect(state.pending == null);
    try state.queue(a, "text");
    try std.testing.expectError(error.OutOfMemory, state.take(a, fail.allocator()));
    try std.testing.expectEqualStrings("text", state.pending.?.bytes);
}
