//! A close transaction snapshots stable identities, never reusable pane slots.
const std = @import("std");
pub const Policy = enum { prompt, never, always };
pub const Scope = enum { pane, tab, others, window, quit };
pub const Ref = struct { id: u64, tab: u64, live: bool = true };
pub const Pending = struct {
    scope: Scope = .pane,
    ids: []u64 = &.{},
    count: usize = 0,
    document_tabs: []u64 = &.{},
    document_count: usize = 0,
    pub fn capture(scope: Scope, tab: u64, pane: u64, refs: []const Ref) !Pending {
        var result: Pending = .{ .scope = scope };
        result.ids = try std.heap.page_allocator.alloc(u64, refs.len);
        for (refs) |ref| {
            const included = switch (scope) {
                .pane => ref.id == pane,
                .tab => ref.tab == tab,
                .others => ref.tab != tab,
                .window, .quit => true,
            };
            if (included and ref.live and result.count < result.ids.len) {
                result.ids[result.count] = ref.id;
                result.count += 1;
            }
        }
        return result;
    }
    pub fn deinit(p: *Pending) void {
        std.heap.page_allocator.free(p.ids);
        std.heap.page_allocator.free(p.document_tabs);
        p.* = .{};
    }
    pub fn contains(p: Pending, id: u64) bool {
        return std.mem.indexOfScalar(u64, p.ids[0..p.count], id) != null;
    }
};
test "close transaction retains requested IDs when tab ordering and slots change" {
    const refs = [_]Ref{ .{ .id = 11, .tab = 1 }, .{ .id = 12, .tab = 1 }, .{ .id = 13, .tab = 2 }, .{ .id = 14, .tab = 2, .live = false } };
    var tab = try Pending.capture(.tab, 1, 11, &refs);
    var others = try Pending.capture(.others, 1, 11, &refs);
    defer tab.deinit();
    try std.testing.expect(tab.count == 2 and tab.contains(11) and tab.contains(12) and !tab.contains(13));
    defer others.deinit();
    try std.testing.expect(others.count == 1 and others.contains(13));
    const reused_slot_id: u64 = 15;
    try std.testing.expect(!tab.contains(reused_slot_id));
}

test "close capture includes every live session beyond former capacity" {
    var refs: [300]Ref = undefined;
    for (&refs, 0..) |*ref, i| ref.* = .{ .id = i + 1, .tab = i / 3 + 1 };
    var pending = try Pending.capture(.quit, 1, 1, &refs);
    defer pending.deinit();
    try std.testing.expect(pending.count == refs.len and pending.contains(300));
    refs[299].id = 999;
    try std.testing.expect(pending.contains(300) and !pending.contains(999));
}
