const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const n2 = b.option(bool, "n2", "Build isolated N2 native navigation/selection/search fixture") orelse false;
    const dependency = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .simd = false,
        .@"emit-exe" = false,
        .@"emit-lib-vt" = true,
        .@"emit-xcframework" = false,
    });
    const module = b.createModule(.{
        .root_source_file = b.path(if (n2) "src/n2_main.zig" else "src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("ghostty-vt", dependency.module("ghostty-vt"));
    if (n2) {
        const files = b.addWriteFiles();
        inline for (.{ "selection.zig", "search.zig", "navigation.zig" }) |filename| {
            _ = files.addCopyFile(b.path("../../src/vt_zig/" ++ filename), filename);
        }
        const adapter = b.createModule(.{ .root_source_file = files.add("root.zig",
            \\pub const selection = @import("selection.zig");
            \\pub const search = @import("search.zig");
            \\pub const navigation = @import("navigation.zig");
        ), .target = target, .optimize = optimize });
        adapter.addImport("ghostty-vt", dependency.module("ghostty-vt"));
        module.addImport("native-adapters", adapter);
    }
    const exe = b.addExecutable(.{ .name = if (n2) "native-vt-n2-check" else "native-vt-probe", .root_module = module });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Run isolated native Zig VT checks").dependOn(&run.step);
}
