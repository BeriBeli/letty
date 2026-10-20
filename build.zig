const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // The upstream option registers the official Zig module. No C VT artifact is linked.
    const ghostty = b.lazyDependency("ghostty", .{ .target = target, .optimize = optimize, .simd = false, .@"emit-exe" = false, .@"emit-lib-vt" = true, .@"emit-xcframework" = false }) orelse return;
    const portable = b.option(bool, "portable", "Use nanoui portable renderer on macOS") orelse (target.result.os.tag != .macos);
    const options = b.addOptions();
    options.addOption(bool, "portable", portable);
    const nano = b.addModule("nanoui", .{ .root_source_file = b.path("vendor/nanoui/src/nanoui.zig"), .target = target, .optimize = optimize, .link_libc = true });
    nano.addOptions("build_options", options);
    if (target.result.os.tag == .macos) {
        for ([_][]const u8{ "AppKit", "WebKit", "Metal", "QuartzCore", "CoreText", "CoreGraphics", "CoreFoundation", "Foundation", "ImageIO", "UniformTypeIdentifiers" }) |f| nano.linkFramework(f, .{});
        nano.linkSystemLibrary("objc", .{});
    }
    const shape_prefix = if (target.result.os.tag == .macos) ".cache/shaper/native" else ".cache/shaper/linux";
    const shape_target = if (target.result.os.tag == .macos) "aarch64-macos" else "x86_64-linux.3.10-gnu.2.17";
    const shape_build = if (portable) b.addSystemCommand(&.{ "python3", "tools/build-shaper.py", "--zig", b.graph.zig_exe, "--target", shape_target, "--prefix", shape_prefix }) else null;
    for ([_][]const u8{ "letty", "letty-check", "letty-probe" }) |name| {
        const source = if (std.mem.eql(u8, name, "letty")) "src/app.zig" else if (std.mem.eql(u8, name, "letty-check")) "src/check.zig" else "src/probe.zig";
        const mod = b.createModule(.{ .root_source_file = b.path(source), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{ .{ .name = "nanoui", .module = nano }, .{ .name = "ghostty-vt", .module = ghostty.module("ghostty-vt") } } });
        mod.addIncludePath(b.path("src"));
        mod.addCSourceFiles(.{ .files = &.{ "src/platform/compat.c", "src/platform/drop.c", "src/platform/drop_macos.c", "src/platform/drop_gtk.c" }, .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-ffunction-sections", "-fdata-sections" } });
        mod.addCSourceFiles(.{ .files = &.{ "src/platform/config_edit.c", "src/platform/hotkey.c", "src/platform/accessibility.c" }, .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-ffunction-sections", "-fdata-sections" } });
        mod.addCSourceFiles(.{ .files = &.{ "src/platform/navigation_provider.c", "src/platform/file_preview.c" }, .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-ffunction-sections", "-fdata-sections" } });
        const bridge_suffix = if (target.result.os.tag == .macos) "macos" else "x11";
        mod.addCSourceFiles(.{ .files = &.{ b.fmt("src/platform/hotkey_{s}.c", .{bridge_suffix}), if (target.result.os.tag == .macos) "src/platform/accessibility_macos.c" else "src/platform/accessibility_atk.c" }, .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-ffunction-sections", "-fdata-sections" } });
        // Hidden acceptance helpers operate only on the fixture's tempfiles.
        if (std.mem.eql(u8, name, "letty")) mod.addCSourceFiles(.{ .files = &.{"tools/fixtures/config_edit_native.c"}, .flags = &.{ "-std=c11", "-Wall", "-Wextra" } });
        if (target.result.os.tag == .linux) {
            mod.linkSystemLibrary("util", .{});
            mod.linkSystemLibrary("dl", .{});
            mod.linkSystemLibrary("pthread", .{});
        }
        if (portable) {
            mod.addObjectFile(b.path(b.fmt("{s}/lib/libportable_shaper.a", .{shape_prefix})));
            mod.linkSystemLibrary("pthread", .{});
        }
        const executable = b.addExecutable(.{ .name = name, .root_module = mod });
        if (shape_build) |prepare| executable.step.dependOn(&prepare.step);
        b.installArtifact(executable);
    }
    const Fixture = struct { name: []const u8, source: []const u8, step: []const u8 };
    for ([_]Fixture{
        .{ .name = "letty-vt-replay", .source = "src/vt_replay.zig", .step = "replay-bin" },
        .{ .name = "letty-vt-n2", .source = "src/vt_n2_replay.zig", .step = "n2-replay-bin" },
        .{ .name = "letty-vt-protocol", .source = "src/vt_protocol_replay.zig", .step = "protocol-bin" },
        .{ .name = "letty-vt-graphics", .source = "src/vt_graphics_check.zig", .step = "graphics-bin" },
        .{ .name = "letty-vt-boundary", .source = "src/vt_native_boundary.zig", .step = "native-boundary-bin" },
    }) |fixture| {
        const mod = b.createModule(.{ .root_source_file = b.path(fixture.source), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "ghostty-vt", .module = ghostty.module("ghostty-vt") }} });
        const exe = b.addExecutable(.{ .name = fixture.name, .root_module = mod });
        const install = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&install.step);
        b.step(fixture.step, "Build native VT acceptance fixture").dependOn(&install.step);
        if (std.mem.eql(u8, fixture.step, "replay-bin")) b.step("replay", "Run the native facade replay").dependOn(&b.addRunArtifact(exe).step);
    }
    b.installDirectory(.{ .source_dir = b.path("assets/shell-integration"), .install_dir = .prefix, .install_subdir = "share/letty/shell-integration" });
    const unit = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/unit_tests.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
    unit.root_module.addImport("ghostty-vt", ghostty.module("ghostty-vt"));
    if (target.result.os.tag == .linux) unit.root_module.linkSystemLibrary("pthread", .{});
    unit.root_module.addCSourceFiles(.{ .files = &.{ "src/platform/config_edit.c", "src/platform/file_preview.c" }, .flags = &.{ "-std=c11", "-Wall", "-Wextra" } });
    b.step("test", "Run queue, config and layout checks").dependOn(&b.addRunArtifact(unit).step);
    b.step("test-bin", "Install unit checks for the target").dependOn(&b.addInstallArtifact(unit, .{ .dest_sub_path = "letty-unit-tests" }).step);
}
