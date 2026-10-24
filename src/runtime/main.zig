const std = @import("std");
const nano = @import("nanoui");
const platform = @import("platform.zig");
const Config = @import("settings.zig").Config;
comptime {
    _ = @import("font_io.zig");
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 2 and std.mem.startsWith(u8, args[1], "--internal-image=")) return @import("image_helper.zig").run(a, args[1][17..]);
    if (args.len > 1 and std.mem.eql(u8, args[1], "config")) return @import("cli.zig").config(a, args[2..]);
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            try platform.output("Letty 0.3.0-dev · native Zig/libghostty-vt terminal\n");
            return;
        }
        if (std.mem.eql(u8, arg, "--help")) {
            try platform.output("Letty — local terminal emulator\n--cwd=DIR --shell=PATH [-- COMMAND [ARG…]]\n-e COMMAND [ARG…] --check-config --version\nconfig path|show [--defaults]|check|edit\nLETTY_CONFIG selects the key=value configuration.\nPTY, libghostty-vt and renderer run inside Letty; remote display uses X11.\n");
            return;
        }
        if (std.mem.eql(u8, arg, "--") or std.mem.eql(u8, arg, "-e")) break;
    }
    const options = try @import("cli.zig").parse(args[1..]);
    const path = try Config.path(a);
    const source = platform.readFile(a, path, 1024 * 1024) catch |err| blk: {
        if (err != error.OpenFile) return err;
        break :blk "";
    };
    const config = try Config.parse(a, source);
    if (options.check) {
        try platform.output("Configuration valid\n");
        return;
    }
    platform.prepareFileDescriptors();
    try @import("fonts.zig").load(a, init.io);
    const initial_directory = options.directory orelse platform.env("HOME") orelse try platform.cwd(a);
    const app = try nano.App.create(init, .{ .name = "Letty" });
    var runtime: @import("desktop.zig").Runtime = .{ .a = std.heap.smp_allocator, .io = init.io, .app = app, .settings = config.settings, .config_path = path, .initial_config = source, .directory = initial_directory, .shell_path = options.shell, .startup_args = options.command, .hidden = options.ui_checks };
    defer {
        runtime.shutdown();
        app.destroy();
        nano.runFor(0.05);
        runtime.deinit();
    }
    try runtime.init();
    if (options.ui_checks) {
        try runtime.verify();
        return;
    }
    try app.run();
}
