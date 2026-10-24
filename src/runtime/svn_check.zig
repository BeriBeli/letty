//! Private CLI fixture driver. Uses the production job pool and backend without
//! creating windows. Not a user-facing command or part of the default install.
const std = @import("std");
const os = @import("platform.zig");
const jobs = @import("jobs.zig");
const vcs = @import("vcs.zig");
const mac = @import("builtin").os.tag == .macos;
extern "c" var kCFRunLoopDefaultMode: *const anyopaque;
extern "c" fn CFRunLoopRunInMode(*const anyopaque, f64, bool) i32;
pub fn main(init: std.process.Init) !void {
    const a = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or args.len > 3) return error.ExpectedDirectoryAndOptionalPath;
    var state: vcs.State = .{};
    defer state.deinit(a);
    var pipe: [2]c_int = undefined;
    if (os.c.pipe(&pipe) != 0) return error.Pipe;
    defer for (pipe) |fd| {
        _ = os.c.close(fd);
    };
    for (pipe) |fd| {
        try os.nonblock(fd);
        try os.cloexec(fd);
    }
    var pool: jobs.Pool = .{ .a = a, .wake_fd = pipe[1] };
    defer pool.deinit();
    try state.request(a, .{ .window = 1, .workspace = 2, .pane = 3 }, args[1], false);
    // Detection is tested for all backend kinds. Only SVN commands run here.
    if (state.backend == .svn) {
        try finish(&state, &pool, pipe[0]);
        if (args.len == 3) {
            try state.select(a, args[2]);
            try finish(&state, &pool, pipe[0]);
        }
    }
    const json = try std.json.Stringify.valueAlloc(a, .{
        .backend = @tagName(state.backend),
        .root = state.svn_state.root,
        .files = state.files(),
        .patch = state.patch(),
        .message = state.message(),
    }, .{});
    defer a.free(json);
    try os.output(json);
    try os.output("\n");
}
fn finish(state: *vcs.State, pool: *jobs.Pool, wake_fd: c_int) !void {
    const deadline = os.millis() + 20000;
    var glib: ?std.DynLib = null;
    defer if (glib) |*lib| lib.close();
    const Iteration = *const fn (?*anyopaque, c_int) callconv(.c) c_int;
    var iteration: ?Iteration = null;
    if (!mac) {
        glib = try std.DynLib.open("libglib-2.0.so.0");
        iteration = glib.?.lookup(Iteration, "g_main_context_iteration") orelse return error.GlibSymbol;
    }
    while (state.busy()) {
        if (os.millis() > deadline) return error.FixtureTimeout;
        try state.pump(pool.a, pool);
        if (mac) {
            _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, false);
        } else {
            _ = iteration.?(null, 0);
            os.sleep(1);
        }
        pool.reap();
        while (pool.take()) |job| {
            defer job.destroy();
            try state.consume(pool.a, job);
        }
        var buffer: [256]u8 = undefined;
        while (os.c.read(wake_fd, &buffer, buffer.len) > 0) {}
    }
}
