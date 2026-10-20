//! Additional native-only failure/lifetime checks, without GUI or OS effects.
const std = @import("std");
pub fn main(init: std.process.Init) !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer if (debug.deinit() == .leak) @panic("native boundary allocator leak");
    const count = try @import("vt_zig/fixtures.zig").run(debug.allocator(), init.io) + try @import("vt_zig/prompt_clear.zig").runFixtures(debug.allocator(), init.io);
    std.debug.print("All {d} native VT boundary checks passed.\n", .{count});
}
