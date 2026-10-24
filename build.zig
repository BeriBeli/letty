const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize: std.builtin.OptimizeMode = .ReleaseSafe;
    _ = b.standardOptimizeOption(.{}); // Build artifacts always use ReleaseSafe.
    const ghostty = b.lazyDependency("ghostty", .{ .target = target, .optimize = optimize, .simd = false, .@"emit-exe" = false, .@"emit-lib-vt" = true, .@"emit-xcframework" = false }) orelse return;
    const portable = (b.option(bool, "portable", "Use the CPU renderer on macOS") orelse false) or target.result.os.tag != .macos;
    const options = b.addOptions();
    options.addOption(bool, "portable", portable);
    options.addOption([]const u8, "version", @import("vendor/nanoui/build.zig.zon").version);
    const nano = b.addModule("nanoui", .{ .root_source_file = b.path("vendor/nanoui/src/nanoui.zig"), .target = target, .optimize = optimize, .link_libc = true });
    nano.addOptions("build_options", options);
    if (target.result.os.tag == .macos) {
        for ([_][]const u8{ "AppKit", "WebKit", "Metal", "QuartzCore", "CoreText", "CoreGraphics", "CoreFoundation", "Foundation", "ImageIO", "UniformTypeIdentifiers", "CoreVideo" }) |framework| nano.linkFramework(framework, .{});
        nano.linkSystemLibrary("objc", .{});
    }
    const app_module = b.createModule(.{ .root_source_file = b.path("src/runtime/main.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{ .{ .name = "nanoui", .module = nano }, .{ .name = "ghostty-vt", .module = ghostty.module("ghostty-vt") } } });
    // The shared CPU grid API delegates shaping to the application's pinned
    // HarfBuzz leaf adapter. Native CoreText continues to shape its own runs.
    const shaping = b.createModule(.{ .root_source_file = b.path("src/portable_text_bridge.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "nanoui", .module = nano }} });
    app_module.addImport("terminal-shaper", shaping);
    const ui_assets = b.createModule(.{ .root_source_file = b.path("src/interface_assets.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "nanoui", .module = nano }} });
    app_module.addImport("interface-assets", ui_assets);
    const documents = b.createModule(.{ .root_source_file = b.path("src/document_host.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{ .{ .name = "nanoui", .module = nano }, .{ .name = "ghostty-vt", .module = ghostty.module("ghostty-vt") }, .{ .name = "interface-assets", .module = ui_assets } } });
    documents.addIncludePath(b.path("src"));
    documents.addCSourceFiles(.{ .files = &.{ "src/platform/file_preview.c", "src/platform/config_edit.c", "src/platform/document_process.c" }, .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-ffunction-sections", "-fdata-sections" } });
    app_module.addImport("document-native", documents);
    if (portable) app_module.addObjectFile(b.path(if (target.result.os.tag == .macos) ".cache/shaper/native/lib/libportable_shaper.a" else ".cache/shaper/linux/lib/libportable_shaper.a"));
    const app = b.addExecutable(.{ .name = "letty", .root_module = app_module });
    app_module.addAnonymousImport("locale_en", .{ .root_source_file = b.path("assets/terminal/locales/en.json") });
    app_module.addAnonymousImport("locale_zh", .{ .root_source_file = b.path("assets/terminal/locales/zh-Hans.json") });
    app_module.addAnonymousImport("theme_catalog", .{ .root_source_file = b.path("assets/terminal/themes.json") });
    app_module.addAnonymousImport("detection_rules", .{ .root_source_file = b.path("assets/terminal/detection-compiled.json") });
    b.installArtifact(app);
    if (target.result.os.tag == .linux) {
        app_module.linkSystemLibrary("util", .{});
        app_module.linkSystemLibrary("dl", .{});
        app_module.linkSystemLibrary("pthread", .{});
    }
    const check_module = b.createModule(.{ .root_source_file = b.path("src/runtime/local_check.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "ghostty-vt", .module = ghostty.module("ghostty-vt") }} });
    if (target.result.os.tag == .linux) check_module.linkSystemLibrary("util", .{});
    check_module.addAnonymousImport("locale_en", .{ .root_source_file = b.path("assets/terminal/locales/en.json") });
    check_module.addAnonymousImport("locale_zh", .{ .root_source_file = b.path("assets/terminal/locales/zh-Hans.json") });
    check_module.addAnonymousImport("theme_catalog", .{ .root_source_file = b.path("assets/terminal/themes.json") });
    const check = b.addExecutable(.{ .name = "letty-local-check", .root_module = check_module });
    const install_check = b.addInstallArtifact(check, .{});
    b.getInstallStep().dependOn(&install_check.step);
    b.step("local-check-bin", "Build isolated local PTY checks").dependOn(&install_check.step);
    const test_module = b.createModule(.{ .root_source_file = b.path("src/runtime/tests.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "ghostty-vt", .module = ghostty.module("ghostty-vt") }} });
    test_module.addImport("document-native", documents);
    test_module.addAnonymousImport("locale_en", .{ .root_source_file = b.path("assets/terminal/locales/en.json") });
    test_module.addAnonymousImport("locale_zh", .{ .root_source_file = b.path("assets/terminal/locales/zh-Hans.json") });
    test_module.addAnonymousImport("theme_catalog", .{ .root_source_file = b.path("assets/terminal/themes.json") });
    const tests = b.addTest(.{ .root_module = test_module });
    test_module.addAnonymousImport("detection_rules", .{ .root_source_file = b.path("assets/terminal/detection-compiled.json") });
    test_module.addAnonymousImport("detection_fixtures", .{ .root_source_file = b.path("assets/terminal/detection-fixtures.json") });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run local terminal model/VT checks").dependOn(&run_tests.step);
    b.step("terminal-test", "Run Letty terminal model/VT checks").dependOn(&run_tests.step);
    b.step("test-bin", "Install terminal unit checks").dependOn(&b.addInstallArtifact(tests, .{ .dest_sub_path = "letty-unit-tests" }).step);
    const svn_check_module = b.createModule(.{ .root_source_file = b.path("src/runtime/svn_check.zig"), .target = target, .optimize = optimize, .link_libc = true });
    if (target.result.os.tag == .macos) svn_check_module.linkFramework("CoreFoundation", .{});
    const svn_check = b.addExecutable(.{ .name = "letty-svn-check", .root_module = svn_check_module });
    b.step("svn-check-bin", "Build the private SVN backend fixture driver").dependOn(&b.addInstallArtifact(svn_check, .{}).step);
    b.installDirectory(.{ .source_dir = b.path("assets/terminal"), .install_dir = .prefix, .install_subdir = "share/letty/terminal" });
}
