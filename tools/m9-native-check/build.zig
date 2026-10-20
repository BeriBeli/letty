const std = @import("std");
pub fn build(b: *std.Build) void {
 const target = b.standardTargetOptions(.{});
 const optimize = b.standardOptimizeOption(.{});
 const Check = enum { quota, renderer };
 const check = b.option(Check, "check", "Standalone component to build") orelse .quota;
 const dependency = b.dependency("ghostty", .{ .target = target, .optimize = optimize, .simd = false, .@"emit-exe" = false, .@"emit-lib-vt" = true, .@"emit-xcframework" = false });
 const module = b.createModule(.{ .root_source_file = b.path(switch(check) { .quota => "../../src/vt_native_graphics_quota_check.zig", .renderer => "../../src/graphics_ui_check.zig" }), .target = target, .optimize = optimize, .link_libc = true });
 module.addImport("ghostty-vt", dependency.module("ghostty-vt"));
 const exe = b.addExecutable(.{ .name = switch(check) { .quota => "m9-quota-check", .renderer => "m9-renderer-check" }, .root_module = module });
 b.installArtifact(exe);
 const run = b.addRunArtifact(exe);
 b.step("run", "Check a standalone M9 component; GUI integration remains pending").dependOn(&run.step);
}
