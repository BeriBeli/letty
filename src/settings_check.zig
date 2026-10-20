pub fn main(init: std.process.Init) !void {
    try @import("settings/check.zig").run(init);
}
const std = @import("std");
