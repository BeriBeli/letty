//! Isolated check build; production backend selection is untouched.
const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dependency = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .simd = false,
        .@"emit-exe" = false,
        .@"emit-lib-vt" = true,
        .@"emit-xcframework" = false,
    });
    const module = b.createModule(.{
        .root_source_file = b.path("../../vt_native_graphics_check.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("ghostty-vt", dependency.module("ghostty-vt"));
    const exe = b.addExecutable(.{ .name = "native-graphics-check", .root_module = module });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Check native Kitty graphics ownership, budgets and geometry").dependOn(&run.step);
}
