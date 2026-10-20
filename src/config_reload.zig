//! Parse and validate every recipient before replacing the shared config snapshot.
const std = @import("std");
const config = @import("config.zig");
const ui = @import("nanoui").ui;
pub fn reload(s: anytype, ctx: *ui.Context) void {
    var next_arena = std.heap.ArenaAllocator.init(s.gpa);
    defer next_arena.deinit();
    const a = next_arena.allocator();
    const path = config.selectPath(a, s.explicit_config) catch {
        s.status = "Cannot resolve configuration path";
        return;
    };
    const loaded = config.loadDetailed(a, path, &s.config_diagnostic) catch |err| {
        s.status = std.fmt.bufPrint(&s.notice_buffer, "Config unchanged: {s} ({s})", .{ @errorName(err), path }) catch "Config unchanged";
        @import("application_theme_browser.zig").cancel(s);
        @import("application_commands.zig").diagnostics(s, ctx);
        const d = &s.config_diagnostic;
        std.debug.print("Config reload rejected: {s}:{d}: {s}\n", .{ if (d.path_len > 0) d.path[0..d.path_len] else path, d.line, @errorName(err) });
        if (d.chain_len > 0) std.debug.print("Included from:\n{s}{s}", .{ d.chain[0..d.chain_len], if (d.chain_truncated) "[include chain truncated]\n" else "" });
        return;
    };
    var transaction = prepare(s, &next_arena, loaded) catch |err| {
        s.status = std.fmt.bufPrint(&s.notice_buffer, "Config unchanged: {s}", .{@errorName(err)}) catch "Config unchanged";
        return;
    };
    defer transaction.deinit();
    transaction.commit(ctx);
}

pub const Transaction = @import("config_transaction.zig").Transaction;
pub fn prepare(s: anytype, arena: *std.heap.ArenaAllocator, candidate: config.Config) !Transaction(@TypeOf(s)) {
    return Transaction(@TypeOf(s)).prepare(s, arena, candidate);
}
