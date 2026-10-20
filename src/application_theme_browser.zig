//! Staged WindowState adapter; deliberately does not import app.zig.
//! Required window fields (root patch supplies them):
//! theme_browser: browser.Browser, theme_pending: browser.Intent,
//! theme_original: ?Config, theme_applied: ?Candidate,
//! theme_lease_generation: u64. Existing id/host/cfg/gpa/app/window/refs fields
//! and retain/release/configureSession/syncFocus methods retain their meanings.
//!
//! Arena pinning is an enforced root lifecycle barrier, not a token illusion:
//! cancel EVERY open browser before any config reload commits/frees an arena;
//! cancel before WindowState.deinit; deinit all windows before Host arena free.
//! Keep theme_applied alive during preview. Rebind cfg to the new root before
//! releaseApplied on reload. No callback resolves through Host.active().
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("nanoui").ui;
const config = @import("config.zig");
const browser = @import("theme_browser_ui.zig");
const themes = @import("theme_browser.zig");
const appearance = @import("appearance.zig");
pub const Browser = browser.Browser;
pub const Intent = browser.Intent;
pub const Candidate = themes.Candidate;
pub const Options = struct {
    config_path: ?[]const u8 = null,
    home: ?[]const u8 = null,
    user_theme_directory: ?[]const u8 = null,
    bundled_theme_directory: ?[]const u8 = null,
    include_bundled: bool = true,
};
const visual_fields = .{ "theme", "foreground", "background", "cursor", "explicit_cursor", "explicit_selection_fg", "explicit_selection_bg", "selection_foreground", "selection_background", "palette", "ui_panel", "ui_border", "ui_accent", "split_divider_color", "font_features", "font_ligatures", "theme_branches" };

/// Toggle/open for exactly s.id. A missing root delegates to the existing
/// open_config command; no file is created and JSON is never rewritten.
pub fn open(s: anytype, ctx: *ui.Context, options: Options) void {
    if (s.theme_browser.open) {
        cancel(s);
        resetInput(s, ctx);
        return;
    }
    if (s.closing or s.deinitialized or s.shutting_down) return;
    if (s.modalOpen()) {
        s.status = "Finish or cancel the current prompt first";
        return;
    }
    var arena = std.heap.ArenaAllocator.init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const path = if (options.config_path) |value| value else config.selectPath(a, s.explicit_config) catch {
        s.status = "Cannot resolve configuration path";
        return;
    };
    begin(s, path, options, a) catch |err| {
        s.config_diagnostic = .{};
        s.config_diagnostic.setPath(path);
        s.config_diagnostic.fail(0, "theme", err);
        s.status = std.fmt.bufPrint(&s.notice_buffer, "Cannot browse themes: {s}", .{@errorName(err)}) catch "Cannot browse themes";
        // A fixture-only root override must not redirect the application's
        // existing open_config command to an unrelated real user config.
        s.pending = .{ .action = if (err == error.ConfigNotFound and options.config_path == null) .open_config else .diagnostics };
        ctx.frameIn(0.001);
        return;
    };
    @import("input_dispatch.zig").cancel(s, .modal);
    s.search_open = false;
    s.clearSearch();
    s.drag_split = null;
    s.drag_tab = null;
    resetInput(s, ctx);
}
fn begin(s: anytype, path: []const u8, options: Options, a: std.mem.Allocator) !void {
    const user_directory = if (options.user_theme_directory) |value| value else try std.fs.path.join(a, &.{ try config.configDir(a), "themes" });
    var roots: [2]themes.Root = undefined;
    var count: usize = 0;
    if (options.include_bundled) {
        const bundled = options.bundled_theme_directory orelse try bundledDirectory(s.app.io, a);
        roots[count] = .{ .directory = bundled, .origin = .bundled };
        count += 1;
    }
    roots[count] = .{ .directory = user_directory, .origin = .user };
    count += 1;
    const Bridge = Callbacks(@TypeOf(s.*));
    try s.theme_browser.begin(s.gpa, .{ .context = s, .acquire = Bridge.acquire, .alive = Bridge.alive, .current = Bridge.current, .preview = Bridge.preview, .restore = Bridge.restore, .prepare_apply = Bridge.prepare, .commit_apply = Bridge.commit, .release = Bridge.release }, .{ .window = s.id, .config_path = path, .home = options.home orelse config.env("HOME"), .roots = roots[0..count] });
}
/// Matches actual package layouts; never uses cwd or Ghostty configuration.
/// Mac: Letty.app/Contents/MacOS/../Resources/config/themes.
/// Linux: extracted/versioned package bin/../config/themes.
fn bundledDirectory(io: std.Io, a: std.mem.Allocator) ![]const u8 {
    const executable = try std.process.executablePathAlloc(io, a);
    const directory = std.fs.path.dirname(executable) orelse return error.InvalidExecutablePath;
    return std.fs.path.join(a, &.{ directory, if (builtin.os.tag == .macos) "../Resources/config/themes" else "../config/themes" });
}
/// Consume only last turn's intent. This is the sole runtime entry that loads,
/// validates, previews or saves, outside draw/native accessibility callbacks.
pub fn process(s: anytype, ctx: *ui.Context) void {
    if (s.theme_browser.intent_frame) |frame| if (frame == ctx.frame) return;
    const intent = s.theme_pending;
    s.theme_pending = .none;
    if (intent == .none or !s.theme_browser.open) return;
    const outcome = s.theme_browser.handle(intent) catch |err| {
        if (s.theme_browser.open and s.theme_browser.diagnostic.path_len > 0) s.config_diagnostic = s.theme_browser.diagnostic;
        s.status = std.fmt.bufPrint(&s.notice_buffer, "Theme unchanged: {s}", .{@errorName(err)}) catch "Theme unchanged";
        if (!s.theme_browser.open) resetInput(s, ctx);
        ctx.changed = true;
        return;
    };
    switch (outcome) {
        .applied => s.status = "Theme applied to this window; configuration not saved",
        .saved => s.status = "Theme saved to root configuration and applied to this window",
        .saved_not_synced => s.status = "Theme saved and applied; directory sync was not confirmed",
        else => {},
    }
    if (!s.theme_browser.open) resetInput(s, ctx);
    ctx.theme = appearance.theme(s.cfg);
    ctx.text.setFamilies(ctx.theme.font, ctx.theme.mono_font);
    ctx.changed = true;
}
pub fn draw(s: anytype, ctx: *ui.Context) void {
    if (!s.theme_browser.open) return;
    const intent = s.theme_browser.draw(ctx);
    if (intent == .none) return;
    // A modal close wins over an earlier layout pass's selection intent.
    if (s.theme_pending != .cancel) s.theme_pending = intent;
    s.theme_browser.intent_frame = ctx.frame;
    ctx.frameIn(0.001);
}
pub fn cancel(s: anytype) void {
    s.theme_pending = .none;
    s.theme_browser.deinit();
}
/// Must run after root reload installs w.cfg, before old root arena is freed.
/// A stale Config must not borrow the old candidate when this is called.
pub fn releaseApplied(s: anytype) void {
    std.debug.assert(!s.theme_browser.open and s.theme_original == null);
    if (s.theme_applied) |*candidate| candidate.deinit();
    s.theme_applied = null;
}
pub fn deinit(s: anytype) void {
    cancel(s);
    // Host cfg outlives WindowState.deinit by the required lifecycle barrier.
    // Drop the window's last candidate borrow before destroying that owner.
    s.cfg = s.host.cfg;
    releaseApplied(s);
}
pub fn syncAppearance(s: anytype) void {
    if (!s.theme_browser.open) return;
    s.theme_browser.syncAppearance() catch |err| {
        cancel(s);
        s.status = @errorName(err);
    };
}
fn resetInput(s: anytype, ctx: *ui.Context) void {
    ctx.focus = 0;
    ctx.active = 0;
    ctx.input.clearEdges();
    ctx.changed = true;
    s.syncFocus();
}
fn merge(base: config.Config, selected: config.Config, font_size: f32) config.Config {
    var result = base;
    result.font_size = font_size;
    inline for (visual_fields) |field| @field(result, field) = @field(selected, field);
    return result;
}
fn refresh(s: anytype) void {
    if (s.closing or s.deinitialized or s.shutting_down) return;
    for (s.sessions) |entry| if (entry) |session| s.configureSession(session);
    if (s.window) |window| {
        const theme = appearance.theme(s.cfg);
        if (window.surface) |surface| {
            surface.text.setFamilies(theme.font, theme.mono_font);
            surface.theme_override = theme;
        }
        if (builtin.os.tag == .macos) @import("macos_chrome.zig").configure(window, s.cfg.background);
        window.redraw();
    }
}
fn Callbacks(comptime Window: type) type {
    return struct {
        fn state(raw: *anyopaque) *Window {
            return @ptrCast(@alignCast(raw));
        }
        fn matches(s: *Window, lease: browser.Lease) bool {
            return s.id == lease.window and s.theme_lease_generation == lease.token and s.theme_original != null;
        }
        fn acquire(raw: *anyopaque, id: u64) !browser.Lease {
            const s = state(raw);
            if (id != s.id or s.closing or s.deinitialized or s.shutting_down or s.host.find(id) != s) return error.ThemeTargetClosed;
            if (s.theme_original != null) return error.ThemeLeaseBusy;
            if (s.theme_lease_generation == std.math.maxInt(u64)) return error.ThemeLeaseExhausted;
            s.theme_lease_generation += 1;
            s.theme_original = s.cfg;
            // Old applied owner remains stored, and root lifecycle barriers pin
            // the root arena; retaining a Window alone would not pin its Config.
            s.retain();
            return .{ .window = id, .token = s.theme_lease_generation };
        }
        fn alive(raw: *anyopaque, lease: browser.Lease) bool {
            const s = state(raw);
            return matches(s, lease) and !s.closing and !s.deinitialized and !s.shutting_down and s.host.find(lease.window) == s;
        }
        fn current(raw: *anyopaque, lease: browser.Lease) !browser.Current {
            if (!alive(raw, lease)) return error.ThemeTargetClosed;
            const s = state(raw);
            return .{ .cfg = s.cfg, .dark = s.host.system_dark };
        }
        fn preview(raw: *anyopaque, lease: browser.Lease, cfg: config.Config) !void {
            if (!alive(raw, lease)) return error.ThemeTargetClosed;
            const s = state(raw);
            const next = merge(s.theme_original.?, cfg, s.cfg.font_size);
            if (std.meta.eql(s.cfg, next)) return;
            s.cfg = next;
            refresh(s);
        }
        fn restore(raw: *anyopaque, lease: browser.Lease) void {
            const s = state(raw);
            if (!matches(s, lease)) return;
            // Even a closing window must drop borrowed preview pointers before
            // Controller.cancel frees them. Native/VT refresh skips dead state.
            const next = merge(s.theme_original.?, s.theme_original.?.forAppearance(s.host.system_dark), s.cfg.font_size);
            if (std.meta.eql(s.cfg, next)) return;
            s.cfg = next;
            refresh(s);
        }
        fn prepare(raw: *anyopaque, lease: browser.Lease, _: *const themes.Candidate) !void {
            if (!alive(raw, lease)) return error.ThemeTargetClosed;
            // Fixed optional field stores ownership: no allocation or other
            // fallible work remains after the checked save/Controller.apply.
        }
        fn commit(raw: *anyopaque, lease: browser.Lease, candidate: themes.Candidate) void {
            const s = state(raw);
            std.debug.assert(alive(raw, lease));
            var previous = s.theme_applied;
            const next = merge(s.theme_original.?, candidate.cfg.forAppearance(s.host.system_dark), s.cfg.font_size);
            s.theme_applied = candidate;
            s.cfg = next;
            // Retire every original borrow before freeing its prior owner.
            // Browser.finish will clear this temporary lease snapshot next.
            s.theme_original = next;
            refresh(s);
            if (previous) |*old| old.deinit();
        }
        fn release(raw: *anyopaque, lease: browser.Lease) void {
            const s = state(raw);
            if (!matches(s, lease)) return;
            s.theme_original = null;
            // Root barriers ensure host_deinitialized is still false here:
            // Browser.finish must complete before embedded WindowState can die.
            s.release();
        }
    };
}
