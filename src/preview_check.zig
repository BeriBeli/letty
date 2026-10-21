const std = @import("std");
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(std.heap.page_allocator);
    defer std.heap.page_allocator.free(args);
    if (args.len == 7 and std.mem.eql(u8, args[1], "--markdown") and (std.mem.eql(u8, args[3], "--screenshot") or std.mem.eql(u8, args[3], "--diagram-screenshot") or std.mem.eql(u8, args[3], "--row-screenshot"))) {
        try @import("preview/ui_check.zig").captureMarkdown(init, args[2], args[4], try std.fmt.parseInt(usize, args[5], 10), try std.fmt.parseFloat(f32, args[6]), if (std.mem.eql(u8, args[3], "--diagram-screenshot")) .diagram else if (std.mem.eql(u8, args[3], "--row-screenshot")) .row else .table);
        return;
    }
    for (args) |arg| if (std.mem.eql(u8, arg, "--perf")) {
        try @import("preview/performance_check.zig").run(init);
        return;
    };
    try @import("preview/ui_check.zig").run(init);
    try @import("preview/editor_check.zig").run();
}
