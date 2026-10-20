//! Actual bounded graphics checks against the application's native Context.
const std = @import("std");
pub fn main(init: std.process.Init) !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer if (debug.deinit() == .leak) @panic("graphics Context allocator leak");
    const count = try @import("vt_zig/fixtures.zig").runGraphics(debug.allocator(), init.io);
    std.debug.print("All {d} native graphics Context checks passed.\n", .{count});
}
