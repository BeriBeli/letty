//! Host contract: callbacks run on the UI thread, outside a draw rebuild.
const std = @import("std");
const config = @import("../config.zig");
const document = @import("document.zig");
pub const Candidate = document.Candidate;
pub const Host = struct {
    context: *anyopaque,
    /// Prepare every window/profile/service using candidate.cfg. No visible
    /// changes and no ownership transfer; failure leaves runtime unchanged.
    prepare: *const fn (*anyopaque, *const Candidate) anyerror!*anyopaque,
    /// Release reservations on save/conflict failure; no runtime changes.
    abort: *const fn (*anyopaque, *anyopaque) void,
    /// Infallible after prepare + file save; consumes candidate.arena. All
    /// configs update before old arenas retire. Existing PTY/PIDs stay intact.
    commit: *const fn (*anyopaque, *anyopaque, Candidate) void,
    open_config: *const fn (*anyopaque) anyerror!void,
    /// Called on native close (owner remains allocated until app teardown).
    closed: ?*const fn (*anyopaque) void = null,
};
pub const Options = struct {
    path: []const u8,
    home: []const u8,
    dark: bool = false,
    command_override: []const u8 = "",
    cwd_override: []const u8 = "",
    profile_override: []const u8 = "",
    diagnostic: config.Diagnostic = .{},
    /// Borrowed only during open; Settings copies formatted values immediately.
    effective: ?config.Config = null,
    theme_roots: []const @import("../theme_browser.zig").Root = &.{},
};
comptime {
    _ = std;
}
