const std = @import("std");
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(std.heap.page_allocator);
    defer std.heap.page_allocator.free(args);
    for (args) |arg| if (std.mem.eql(u8, arg, "--perf")) {
        try @import("preview/performance_check.zig").run(init);
        return;
    };
    try @import("preview/ui_check.zig").run(init);
}
