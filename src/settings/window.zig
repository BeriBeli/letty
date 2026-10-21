//! One application-owned settings window; completely separate from terminal slots.
const std = @import("std");
const nano = @import("nanoui");
const ui = nano.ui;
const adapter = @import("adapter.zig");
const Model = @import("model.zig").Model;
const Form = @import("form.zig").Form;
const Intent = @import("form.zig").Intent;
const doc = @import("document.zig");
const themes = @import("../theme_browser.zig");
const appearance = @import("../appearance.zig");
const fonts = @import("fonts.zig");
pub const Host = adapter.Host;
pub const Options = adapter.Options;
pub const Settings = struct {
    /// Embed at a stable address in AppState. Never store in terminal windows[].
    window: ?*nano.Window = null,
    ax: @import("accessibility.zig").Runtime(@This()) = .{},
    model_generation: u64 = 0,
    notice_timer: @import("../one_shot.zig").Handle = .{},
    notice_hash: u64 = 0,
    preview_timer: @import("../one_shot.zig").Handle = .{},
    model: ?Model = null,
    form: Form = .{},
    host: ?Host = null,
    preview: ?doc.Candidate = null,
    catalog: ?themes.Catalog = null,
    font_catalog: ?fonts.Catalog = null,
    pending: Intent = .none,
    scheduled: bool = false,
    alive: bool = true,
    saved: bool = false,
    system_dark: bool = false,
    /// Idempotent: repeated application/menu/palette opens only focus this window.
    pub fn open(self: *Settings, gpa: std.mem.Allocator, app: *nano.App, host: Host, options: Options) !void {
        if (self.window) |window| {
            if (!app.flags.hidden) window.focus();
            return;
        }
        self.clear();
        self.alive = true;
        self.host = host;
        self.model_generation += 1;
        self.model = try Model.init(gpa, options.path, options.home);
        errdefer self.clear();
        self.system_dark = options.dark;
        self.model.?.syncAppearance(options.dark);
        self.form = .{ .dark_preview = options.dark, .category = if (self.model.?.read_only) .advanced else .appearance };
        if (options.effective) |effective| {
            for (@import("schema.zig").fields, 0..) |field, index| self.form.applied_values[index] = try @import("schema.zig").format(self.model.?.arena.allocator(), field.id, effective);
        }
        self.font_catalog = fonts.Catalog.scan(gpa) catch null;
        if (self.font_catalog) |font_catalog| {
            self.form.font_names = font_catalog.names;
            self.form.font_catalog_available = true;
        }
        self.form.command_override.set(options.command_override);
        self.form.cwd_override.set(options.cwd_override);
        self.form.profile_override.set(options.profile_override);
        if (self.model.?.diagnostic.reason_len == 0 and options.diagnostic.reason_len > 0) self.model.?.diagnostic = options.diagnostic;
        self.catalog = themes.Catalog.scan(gpa, options.theme_roots, themes.nativeReader(), .{}) catch null;
        self.window = try app.newWindow(.{ .title = "Letty Settings", .width = 1100, .height = 760, .min_width = 480, .min_height = 360, .theme = self.editorTheme(self.model.?.baseline.forAppearance(options.dark), self.model.?.baseline.font), .content = .{ .view = .init(self, view) }, .on_close_request = .{ .ctx = self, .func = closeRequested }, .on_close = .{ .ctx = self, .func = closed } });
        if (!app.flags.hidden) self.window.?.focus();
    }
    /// Host teardown calls this before destroying its config arena/app.
    pub fn deinit(self: *Settings) void {
        self.alive = false;
        self.ax.detach();
        self.preview_timer.cancel();
        self.preview_timer = .{};
        self.notice_timer.cancel();
        self.notice_timer = .{};
        self.pending = .none;
        if (self.window) |window| {
            window.on_close_request = null;
            window.on_close = null;
            window.close();
            self.window = null;
        }
        self.clear();
    }
    fn clear(self: *Settings) void {
        if (self.preview) |*p| p.deinit();
        self.preview = null;
        if (self.catalog) |*catalog| catalog.deinit();
        self.catalog = null;
        if (self.font_catalog) |*catalog| catalog.deinit();
        self.font_catalog = null;
        if (self.model) |*model| model.deinit();
        self.model = null;
        self.pending = .none;
        self.saved = false;
    }
    pub fn syncAppearance(self: *Settings, dark: bool) void {
        self.system_dark = dark;
        if (self.model) |*model| model.syncAppearance(dark);
        if (self.model) |*model| if (self.window) |window| {
            if (window.surface) |surface| {
                surface.theme_override = self.editorTheme(model.baseline.forAppearance(dark), if (self.preview) |preview| preview.cfg.font else model.baseline.font);
                surface.text.setFamilies(surface.theme_override.?.font, surface.theme_override.?.mono_font);
            }
            window.redraw();
        };
    }
    pub fn unsaved(self: *const Settings) bool {
        return self.window != null and self.model != null and !self.saved and self.model.?.dirtyCount() > 0;
    }
    /// Host invokes before any Quit transaction can destroy terminal sessions.
    /// A rejected Quit keeps all windows/processes alive; the user resolves the
    /// draft here, then requests Quit again.
    pub fn guardQuit(self: *Settings) bool {
        if (!self.unsaved()) return true;
        _ = self.form.requestClose(&self.model.?);
        self.model.?.notice_error = false;
        self.model.?.notice.set("Save or discard the Settings draft, then choose Quit again.");
        if (self.window) |window| {
            window.redraw();
            if (!window.app.flags.hidden) window.focus();
        }
        return false;
    }
    fn schedule(self: *Settings, intent: Intent) void {
        if (intent == .none or !self.alive) return;
        if (intent == .preview) {
            self.preview_timer.cancel();
            self.preview_timer = @import("../one_shot.zig").start(120, self, updatePreview) catch .{};
            return;
        }
        self.preview_timer.cancel();
        self.preview_timer = .{};
        self.pending = intent;
        if (self.scheduled) return;
        self.scheduled = true;
        nano.App.after(0, self, execute);
    }
    fn updatePreview(raw: ?*anyopaque) callconv(.c) void {
        const self: *Settings = @ptrCast(@alignCast(raw.?));
        self.preview_timer.fired();
        self.preview_timer = .{};
        if (!self.alive or self.window == null or self.model == null) return;
        self.handle(.preview) catch return;
        if (self.window) |window| window.redraw();
    }
    fn execute(raw: ?*anyopaque) callconv(.c) void {
        const self: *Settings = @ptrCast(@alignCast(raw.?));
        self.scheduled = false;
        if (!self.alive or self.model == null) return;
        const intent = self.pending;
        self.pending = .none;
        self.handle(intent) catch |err| {
            if (self.model) |*model| {
                model.notice_error = true;
                model.notice.set(if (err == error.ConcurrentChange or err == error.IncludedSourceChanged) "The configuration or an included file changed externally. Your draft is preserved. Close and reopen Settings to load the changed file before editing again." else @import("schema.zig").validationMessage(err));
                if (model.last_error_field) |field| {
                    self.form.category = @import("schema.zig").descriptor(field).category;
                    self.form.query.clear();
                    self.form.reveal_error = field;
                }
            }
        };
        if (self.window) |window| window.redraw();
    }
    fn handle(self: *Settings, intent: Intent) !void {
        switch (intent) {
            .none, .migration => {},
            .close, .discard => if (self.window) |window| {
                window.close();
            },
            .open_config => try self.host.?.open_config(self.host.?.context),
            .preview => {
                const next = self.model.?.previewCandidate() catch return;
                // Update native font provider before retiring its former owner.
                if (self.window) |window| if (window.surface) |surface| {
                    surface.theme_override = self.editorTheme(self.model.?.baseline.forAppearance(self.system_dark), next.cfg.font);
                    surface.text.setFamilies(null, surface.theme_override.?.mono_font);
                };
                if (self.preview) |*old| old.deinit();
                self.preview = next;
            },
            .save => {
                if (self.saved) return error.ReopenSettingsAfterSave;
                const result = try self.model.?.save(self.host.?) orelse return;
                self.saved = true;
                // Disk and runtime are now committed. Refresh failure must never
                // be represented as a rejected save or allow stale-snapshot writes.
                self.reload() catch {
                    self.model.?.read_only = true;
                    // The draft was committed. Avoid an "unsaved" prompt when
                    // closing this read-only recovery view after refresh OOM.
                    for (self.model.?.values) |*value| if (!value.locked) {
                        value.original = value.input.text();
                    };
                    self.model.?.binding_edits.clearRetainingCapacity();
                    self.model.?.notice.set("Saved and applied, but the draft could not be refreshed. Close and reopen Settings.");
                    return;
                };
                self.model.?.notice.set(if (result.directory_synced) "Saved and applied to every window. Existing processes were kept running." else "Saved and applied, but directory durability could not be confirmed. Keep a backup of the configuration.");
                self.model.?.notice_error = !result.directory_synced;
            },
        }
    }
    fn reload(self: *Settings) !void {
        const current = &self.model.?;
        var next = try Model.init(current.gpa, current.path, current.home);
        next.syncAppearance(self.system_dark);
        // native/provider and draw refs drop borrowed old strings before free.
        if (self.window) |window| if (window.surface) |surface| {
            const theme = self.editorTheme(next.baseline.forAppearance(self.system_dark), next.baseline.font);
            surface.text.setFamilies(theme.font, theme.mono_font);
            surface.theme_override = theme;
        };
        if (self.preview) |*p| p.deinit();
        self.preview = null;
        self.form.applied_values = @splat(null);
        current.deinit();
        self.model = next;
        self.model_generation += 1;
        self.saved = false;
        self.form.confirm_discard = false;
    }
    fn view(self: *Settings, ctx: *ui.Context) void {
        @import("../bundled_fonts.zig").install(ctx.text);
        if (self.model) |*model| {
            const cfg = if (self.preview) |p| p.cfg else model.baseline;
            self.form.preview_font_available = if (self.font_catalog) |*catalog| catalog.contains(cfg.font) else false;
            ctx.theme.font = null;
            ctx.theme.mono_font = if (self.form.preview_font_available) cfg.font else null;
            ctx.text.setFamilies(null, ctx.theme.mono_font);
            self.ax.begin(self, ctx);
            const intent = self.form.draw(ctx, model, if (self.preview) |p| p.cfg else null, if (self.catalog) |*c| c else null);
            self.schedule(intent);
            const hash = std.hash.Wyhash.hash(0, model.notice.text());
            if (hash != self.notice_hash) {
                self.notice_hash = hash;
                self.notice_timer.cancel();
                self.notice_timer = .{};
                if (!model.notice_error and std.mem.startsWith(u8, model.notice.text(), "Saved and applied")) self.notice_timer = @import("../one_shot.zig").start(4000, self, clearNotice) catch .{};
            }
        }
    }
    fn clearNotice(raw: ?*anyopaque) callconv(.c) void {
        const self: *Settings = @ptrCast(@alignCast(raw.?));
        self.notice_timer.fired();
        self.notice_timer = .{};
        if (self.model) |*model| if (!model.notice_error and self.notice_hash == std.hash.Wyhash.hash(0, model.notice.text())) model.notice.set("");
        if (self.window) |window| window.redraw();
    }
    fn editorTheme(self: *Settings, cfg: @import("../config.zig").Config, preview_font: []const u8) ui.Theme {
        var theme = systemTheme(cfg);
        // Match the frame's provider to the preview. Otherwise frame.run would
        // switch mono→system→mono and flush the font cache on every redraw.
        if (self.font_catalog) |*catalog| if (catalog.contains(preview_font)) {
            theme.mono_font = preview_font;
        };
        return theme;
    }
    fn closeRequested(raw: *anyopaque, _: *nano.Window) bool {
        const self: *Settings = @ptrCast(@alignCast(raw));
        if (self.model) |*model| {
            if (model.dirtyCount() > 0 and !self.saved) {
                _ = self.form.requestClose(model);
                if (self.window) |window| window.redraw();
                return false;
            }
        }
        return true;
    }
    fn closed(raw: *anyopaque, _: *nano.Window) void {
        const self: *Settings = @ptrCast(@alignCast(raw));
        self.ax.detach();
        self.preview_timer.cancel();
        self.preview_timer = .{};
        self.notice_timer.cancel();
        self.notice_timer = .{};
        self.window = null;
        // Native surface is still unwinding; keep model/preview allocations
        // until next open or host teardown, never free draw text in this callback.
        self.pending = .none;
        if (self.host) |host| if (host.closed) |callback| callback(host.context);
    }
};
pub fn systemTheme(cfg: @import("../config.zig").Config) ui.Theme {
    var theme = appearance.theme(cfg);
    // Chrome must remain legible even with missing custom/CJK fonts.
    theme.font = null;
    theme.mono_font = null;
    return theme;
}
