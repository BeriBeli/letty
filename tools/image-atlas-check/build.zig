const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const portable = b.option(bool, "portable", "Use CPU text and the portable decoder") orelse (target.result.os.tag != .macos);
    const options = b.addOptions();
    options.addOption(bool, "portable", portable);
    options.addOption([]const u8, "version", "image-atlas-check");
    const nano = b.createModule(.{ .root_source_file = b.path("../../vendor/nanoui/src/nanoui.zig"), .target = target, .optimize = .ReleaseSafe, .link_libc = true });
    const option_module = options.createModule();
    nano.addImport("build_options", option_module);
    if (target.result.os.tag == .macos) {
        for ([_][]const u8{ "AppKit", "WebKit", "Metal", "QuartzCore", "CoreText", "CoreGraphics", "CoreFoundation", "Foundation", "ImageIO", "UniformTypeIdentifiers", "CoreVideo" }) |f| nano.linkFramework(f, .{});
        nano.linkSystemLibrary("objc", .{});
    }
    if (target.result.os.tag == .linux) {
        nano.addCSourceFile(.{ .file = b.path("../../src/platform/compat.c"), .flags = &.{"-std=c11"} });
        for ([_][]const u8{ "util", "dl", "pthread" }) |lib| nano.linkSystemLibrary(lib, .{});
    }
    const mod = b.createModule(.{ .root_source_file = b.path("main.zig"), .target = target, .optimize = .ReleaseSafe, .link_libc = true, .imports = &.{.{ .name = "nanoui", .module = nano }} });
    mod.addImport("check_options", option_module);
    b.installArtifact(b.addExecutable(.{ .name = "image-atlas-check", .root_module = mod }));
}
