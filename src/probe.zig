const std = @import("std");
const builtin = @import("builtin");
const c = @import("platform_ffi.zig");
const nano = @import("nanoui");
const Config = @import("config.zig").Config;
pub fn main(init: std.process.Init) void {
    std.debug.print("Letty compatibility probe; executable {s}-{s}; Linux delivery baseline 3.10 / glibc 2.17\n", .{ @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) });
    if (c.lt_probe(1) != 0) std.process.exit(1);
    const TextSystem = @typeInfo(@FieldType(nano.ui.Context, "text")).pointer.child;
    if (@hasField(TextSystem, "db")) {
        var text: TextSystem = .init(init.gpa);
        defer text.deinit();
        const family = (Config{}).font;
        if (text.db.family(family, 400, false)) |face| {
            if (text.db.load(face) != null) std.debug.print("PASS nanoui exact font: {s}\n", .{family}) else {
                std.debug.print("FAIL exact font exists but cannot load\n", .{});
                std.process.exit(1);
            }
        } else std.debug.print("WARN exact font not installed: {s}; fallback will be used\n", .{family});
    }
}
