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
    const run = b.step("run", "Run isolated settings checks; no user's config/windows/clipboard");
    for ([_]bool{ false, true }) |metadata_fixture| {
        const mod = b.createModule(.{ .root_source_file = b.path(if (metadata_fixture) "../../src/settings_metadata_check.zig" else "../../src/settings_check.zig"), .target = target, .optimize = optimize, .link_libc = true });
        mod.addImport("nanoui", nano);
        mod.addIncludePath(b.path("../../src"));
        mod.addCSourceFiles(.{ .files = &.{ "../../src/platform/compat.c", if (metadata_fixture) "../../tools/fixtures/config_edit_no_xattr.c" else "../../src/platform/config_edit.c", "../../tools/fixtures/config_edit_native.c" }, .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-ffunction-sections", "-fdata-sections" } });
        if (metadata_fixture) mod.addCSourceFiles(.{ .files = &.{ "../../src/platform/accessibility.c", if (target.result.os.tag == .macos) "../../src/platform/accessibility_macos.c" else "../../src/platform/accessibility_atk.c" }, .flags = &.{ "-std=c11", "-Wall", "-Wextra" } });
        if (portable) mod.addObjectFile(b.path(if (target.result.os.tag == .macos) "../../.cache/shaper/native/lib/libportable_shaper.a" else "../../.cache/shaper/linux/lib/libportable_shaper.a"));
        if (target.result.os.tag == .linux) {
            mod.linkSystemLibrary("dl", .{});
            mod.linkSystemLibrary("pthread", .{});
        }
        const executable = b.addExecutable(.{ .name = if (metadata_fixture) "letty-settings-metadata-check" else "letty-settings-check", .root_module = mod });
        b.installArtifact(executable);
        run.dependOn(&b.addRunArtifact(executable).step);
    }
}
