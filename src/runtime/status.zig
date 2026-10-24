//! Kero's OSC 7501 record reduction, using libghostty-vt's validated parser.
const std = @import("std");
const proto = @import("model.zig");
const ghostty = @import("ghostty-vt");
pub const Records = struct {
    list: std.ArrayList(proto.Record) = .empty,
    pub fn deinit(self: *Records, a: std.mem.Allocator) void {
        for (self.list.items) |r| free(a, r);
        self.list.deinit(a);
    }
    fn free(a: std.mem.Allocator, r: proto.Record) void {
        inline for (.{ "id", "state", "kind", "app", "title", "msg" }) |f| a.free(@field(r, f));
    }
    pub fn apply(self: *Records, a: std.mem.Allocator, r: proto.Record) !void {
        if (std.mem.eql(u8, r.state, "clear")) {
            var i: usize = 0;
            while (i < self.list.items.len) {
                const id = self.list.items[i].id;
                if (r.id.len == 0 or std.mem.eql(u8, id, r.id) or (std.mem.startsWith(u8, id, r.id) and id.len > r.id.len and id[r.id.len] == '/')) {
                    free(a, self.list.orderedRemove(i));
                } else i += 1;
            }
            return;
        }
        var index: ?usize = null;
        for (self.list.items, 0..) |existing, i| if (std.mem.eql(u8, existing.id, r.id)) {
            index = i;
            break;
        };
        if (index == null and self.list.items.len >= 128) return error.RecordLimit;
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        // Build a replacement transactionally before publishing any field.
        var replacement = r;
        var owned: std.ArrayList([]const u8) = .empty;
        defer owned.deinit(arena.allocator());
        errdefer for (owned.items) |s| a.free(s);
        inline for (.{ "id", "state", "kind", "app", "title", "msg" }) |f| {
            const text = try a.dupe(u8, @field(r, f));
            owned.append(arena.allocator(), text) catch |err| {
                a.free(text);
                return err;
            };
            @field(replacement, f) = text;
        }
        if (index) |i| {
            free(a, self.list.items[i]);
            self.list.items[i] = replacement;
        } else try self.list.append(a, replacement);
    }
    pub fn report(self: *Records, a: std.mem.Allocator, r: ghostty.osc.Command.ProgramStatus.Report, now: i64) !void {
        var title: [192]u8 = undefined;
        var msg: [2048]u8 = undefined;
        var tw: std.Io.Writer = .fixed(&title);
        var mw: std.Io.Writer = .fixed(&msg);
        try r.writeText(.title, &tw);
        try r.writeText(.msg, &mw);
        try self.apply(a, .{ .id = r.readOption(.id) orelse "", .state = @tagName(r.state), .kind = if (r.readOption(.kind)) |k| @tagName(k) else "", .progress = if (r.readOption(.progress)) |p| @intCast(p) else -1, .app = r.readOption(.app) orelse "", .title = tw.buffered(), .msg = mw.buffered(), .updated = now });
    }
    pub fn dropLive(self: *Records, a: std.mem.Allocator) void {
        var i: usize = 0;
        while (i < self.list.items.len) {
            const state = self.list.items[i].state;
            if (std.mem.eql(u8, state, "working") or std.mem.eql(u8, state, "blocked")) free(a, self.list.orderedRemove(i)) else i += 1;
        }
    }
    pub fn dismiss(self: *Records, a: std.mem.Allocator) void {
        var i: usize = 0;
        while (i < self.list.items.len) {
            const state = self.list.items[i].state;
            if (std.mem.eql(u8, state, "done") or std.mem.eql(u8, state, "error")) free(a, self.list.orderedRemove(i)) else i += 1;
        }
    }
    pub fn leading(self: *const Records) ?proto.Record {
        var best: ?proto.Record = null;
        var rank: u8 = 0;
        for (self.list.items) |r| {
            const next = priority(r.state);
            if (best == null or next > rank or (next == rank and r.updated > best.?.updated)) {
                best = r;
                rank = next;
            }
        }
        return best;
    }
    pub fn declared(self: *const Records) bool {
        const r = self.leading() orelse return false;
        return std.mem.eql(u8, r.state, "working") or std.mem.eql(u8, r.state, "blocked");
    }
    fn priority(s: []const u8) u8 {
        const names = [_][]const u8{ "idle", "done", "error", "working", "blocked" };
        for (names, 0..) |name, i| if (std.mem.eql(u8, s, name)) return @intCast(i);
        return 0;
    }
};
test "blocked outranks working; hierarchical clear; completed persists through prompt" {
    const a = std.testing.allocator;
    var records: Records = .{};
    defer records.deinit(a);
    try records.apply(a, .{ .id = "build", .state = "working" });
    try records.apply(a, .{ .id = "build/test", .state = "blocked", .kind = "permission" });
    try records.apply(a, .{ .id = "done", .state = "done" });
    try std.testing.expectEqualStrings("blocked", records.leading().?.state);
    try records.apply(a, .{ .id = "build", .state = "clear" });
    records.dropLive(a);
    try std.testing.expectEqual(@as(usize, 1), records.list.items.len);
    records.dismiss(a);
    try std.testing.expectEqual(@as(usize, 0), records.list.items.len);
}
