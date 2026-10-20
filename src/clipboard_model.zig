//! Clipboard-only preprocessing; IME commits never enter this transaction.
const std = @import("std");
pub const limit = 1024 * 1024 - 12;
pub const CopyOnSelect = enum { none, primary, clipboard, both };
pub const Pending = struct { target: u64, bytes: []u8 };
pub fn requiresConfirmation(protection: bool, bracketed_safe: bool, bracketed: bool, text: []const u8) bool {
    if (!protection or (bracketed and bracketed_safe)) return false;
    for (text) |byte| if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return true;
    return false;
}
pub fn normalize(a: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len > limit) return error.PasteLimit;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(a);
    try output.ensureTotalCapacity(a, text.len);
    for (text, 0..) |byte, index| {
        if (byte == '\n' and index > 0 and text[index - 1] == '\r') continue;
        output.appendAssumeCapacity(if (byte == '\r') '\n' else byte);
    }
    return output.toOwnedSlice(a);
}
test "clipboard policy normalizes CRLF and distinguishes bracketed and unsafe pastes" {
    const bytes = try normalize(std.testing.allocator, "one\r\ntwo\rthree");
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("one\ntwo\nthree", bytes);
    try std.testing.expect(requiresConfirmation(true, true, false, bytes));
    try std.testing.expect(!requiresConfirmation(true, true, true, bytes));
    try std.testing.expect(requiresConfirmation(true, false, true, bytes));
    try std.testing.expect(requiresConfirmation(true, true, false, "a\x1bb"));
    try std.testing.expect(!requiresConfirmation(true, true, false, "中文 single line"));
}
