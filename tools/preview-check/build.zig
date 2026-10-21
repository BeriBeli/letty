const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const portable = b.option(bool, "portable", "Use portable renderer") orelse (target.result.os.tag != .macos);
    const options = b.addOptions();
    options.addOption(bool, "portable", portable);
    options.addOption([]const u8, "version", "0.4.0");
    const nano = b.createModule(.{ .root_source_file = b.path("../../vendor/nanoui/src/nanoui.zig"), .target = target, .optimize = optimize, .link_libc = true });
    nano.addOptions("build_options", options);
    if (target.result.os.tag == .macos) {
        for ([_][]const u8{ "AppKit", "WebKit", "Metal", "QuartzCore", "CoreText", "CoreGraphics", "CoreFoundation", "Foundation", "ImageIO", "UniformTypeIdentifiers", "CoreVideo" }) |f| nano.linkFramework(f, .{});
        nano.linkSystemLibrary("objc", .{});
    }
    const dependency = b.dependency("ghostty", .{ .target = target, .optimize = optimize, .simd = false, .@"emit-exe" = false, .@"emit-lib-vt" = true, .@"emit-xcframework" = false });
    const mod = b.createModule(.{ .root_source_file = b.path("../../src/preview_check.zig"), .target = target, .optimize = optimize, .link_libc = true });
    mod.addImport("nanoui", nano);
    mod.addImport("ghostty-vt", dependency.module("ghostty-vt"));
    mod.addIncludePath(b.path("../../src"));
    mod.addCSourceFiles(.{ .files = &.{ "../../src/platform/compat.c", "../../src/platform/config_edit.c", "../../src/platform/file_preview.c", "../../tools/fixtures/config_edit_native.c" }, .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-ffunction-sections", "-fdata-sections" } });
    if (portable) mod.addObjectFile(b.path(if (target.result.os.tag == .macos) "../../.cache/shaper/native/lib/libportable_shaper.a" else "../../.cache/shaper/linux/lib/libportable_shaper.a"));
    if (target.result.os.tag == .linux) {
        mod.linkSystemLibrary("dl", .{});
        mod.linkSystemLibrary("pthread", .{});
    }
    const executable = b.addExecutable(.{ .name = "letty-preview-check", .root_module = mod });
    b.installArtifact(executable);
    b.step("run", "Run isolated read-only preview checks").dependOn(&b.addRunArtifact(executable).step);
}
