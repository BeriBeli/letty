#!/usr/bin/env python3
"""Build the patched framework with the host's Linux compatibility object supplied.
No example is launched, and cross-built tests are left for target execution.
"""
import argparse, json, os, shutil, subprocess
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--target', required=True, choices=['aarch64-linux-gnu', 'x86_64-windows-gnu'])
    parser.add_argument('--zig', default=shutil.which('zig'))
    args = parser.parse_args()
    directory = ROOT / '.cache/nanoui-validation'
    directory.mkdir(parents=True, exist_ok=True)
    vendor = json.dumps(str(ROOT / 'vendor/nanoui'))
    compat = json.dumps(str(ROOT / 'src/platform/compat.c'))
    source = '''const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = b.addOptions(); options.addOption(bool, "portable", true);
    const nano = b.addModule("nanoui", .{ .root_source_file = .{ .cwd_relative = VENDOR ++ "/src/nanoui.zig" }, .target = target, .optimize = optimize, .link_libc = true });
    nano.addOptions("build_options", options);
    if (target.result.os.tag == .linux) {
        nano.addCSourceFile(.{ .file = .{ .cwd_relative = COMPAT }, .flags = &.{"-std=c11"} });
        for ([_][]const u8{"util", "dl", "pthread"}) |lib| nano.linkSystemLibrary(lib, .{});
    }
    for ([_][]const u8{"counter", "gallery"}) |name| {
        const root = b.createModule(.{ .root_source_file = .{ .cwd_relative = b.fmt("{s}/examples/{s}/main.zig", .{VENDOR,name}) }, .target = target, .optimize = optimize, .imports = &.{.{ .name = "nanoui", .module = nano }} });
        b.installArtifact(b.addExecutable(.{ .name = name, .root_module = root }));
    }
    b.installArtifact(b.addTest(.{ .name = "nanoui-tests", .root_module = nano }));
}
'''.replace('VENDOR', vendor).replace('COMPAT', compat)
    build = directory / 'build.zig'
    build.write_text(source)
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / '.cache/zig-global'))
    command = [args.zig, 'build', '--build-file', str(build), '-Dtarget='+args.target, '-Doptimize=ReleaseSafe', '--prefix', str(directory/args.target), '-j4']
    subprocess.run(command, cwd=ROOT, env=env, check=True)
    print('Framework examples and test binary built:', args.target)
if __name__ == '__main__': main()
