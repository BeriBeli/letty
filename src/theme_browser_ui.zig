//! nanoui theme picker with Kero palette styling.
//! draw() emits intents only; call handle() from the UI event loop on the next
//! turn, like WindowState.pending/perform. Native IO never runs inside draw().
//! Every preview/save/ownership transfer uses theme_browser.Controller.
const std = @import("std");
const ui = @import("nanoui").ui;
const themes = @import("theme_browser.zig");
const edit = @import("config_edit.zig");
const config = @import("config.zig");
const chrome = @import("chrome.zig");
const Text = @import("fixed_text.zig").Text;
pub const max_results = 512;
pub const max_visible = 12;
pub const Intent = union(enum) { none, preview: usize, cancel, apply, save };
pub const Outcome = enum { unchanged, previewed, cancelled, applied, saved, saved_not_synced };
pub const Current = struct { cfg: config.Config, dark: bool };
/// Host retains the live WindowState and pins the ORIGINAL configuration arena.
/// A plain Config copy is insufficient. token identifies a configuration lease,
/// not a native pointer; alive must reject closed/moved/reconfigured targets.
pub const Lease = struct { window: u64, token: u64 };
pub const Host = struct {
    context: *anyopaque,
    acquire: *const fn (*anyopaque, u64) anyerror!Lease,
    alive: *const fn (*anyopaque, Lease) bool,
    current: *const fn (*anyopaque, Lease) anyerror!Current,
    /// Replace visuals atomically, preserving temporary font size and session
    /// processes. A failed callback must leave its prior visuals intact.
    preview: *const fn (*anyopaque, Lease, config.Config) anyerror!void,
    /// Infallible restore of original visual fields (preserve temporary zoom)
    /// while the lease is valid; a closing target may ignore it. Must drop every
    /// borrowed candidate pointer before returning.
    restore: *const fn (*anyopaque, Lease) void,
    /// Reserve ownership/storage and validate all affected targets. No visible
    /// mutation. Must be safe to abandon if the following checked save fails.
    prepare_apply: *const fn (*anyopaque, Lease, *const themes.Candidate) anyerror!void,
    /// Infallible ownership transfer AFTER prepare_apply and Controller.apply.
    /// Keep candidate alive for all borrowing Configs, including other windows.
    /// Update those configs before freeing any previous applied owner.
    commit_apply: *const fn (*anyopaque, Lease, themes.Candidate) void,
    release: *const fn (*anyopaque, Lease) void,
};
pub const Options = struct {
    window: u64,
    config_path: []const u8,
    home: []const u8 = "",
    roots: []const themes.Root = &.{},
};
pub const Row = struct { catalog_index: usize, widget: u64, rect: ?ui.Rect };
pub const Keyboard = enum { query, cancel, apply, save };
/// Copied geometry only: root may turn this into M11 records after layout.
/// No frame strings, UI nodes, Context or text input pointers are retained.
pub const Geometry = struct {
    dialog: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    rows: [max_visible]Row = undefined,
    row_count: usize = 0,
    cancel: ?ui.Rect = null,
    apply: ?ui.Rect = null,
    save: ?ui.Rect = null,
    /// Resolve these IDs against final post-layout nodes. The optional rects
    /// above are interaction-time rectangles, not final-frame AX geometry.
    dialog_node: u64 = 0,
    query_node: u64 = 0,
    cancel_node: u64 = 0,
    apply_node: u64 = 0,
    save_node: u64 = 0,
};
pub const Browser = struct {
    open: bool = false,
    gpa: ?std.mem.Allocator = null,
    host: ?Host = null,
    lease: ?Lease = null,
    catalog: ?themes.Catalog = null,
    original: ?edit.Snapshot = null,
    home: []const u8 = &.{},
    controller: themes.Controller = .{},
    query: ui.TextBuffer = .{},
    previous: Text(256) = .{},
    filtered: [max_results]usize = undefined,
    filtered_count: usize = 0,
    selected: usize = 0,
    wheel: @import("scroll_input.zig").Rows = .{},
    first: usize = 0,
    composing: bool = false,
    focus_query: bool = false,
    keyboard: Keyboard = .query,
    /// Host adapter defers an intent beyond same-frame nanoui rebuild passes.
    intent_frame: ?u64 = null,
    preview_cfg: ?config.Config = null,
    preview_index: ?usize = null,
    notice: Text(512) = .{},
    diagnostic: config.Diagnostic = .{},
    geometry: Geometry = .{},

    /// Real bounded catalog scan + physical regular-file snapshot. Missing root
    /// files/JSON roots are errors, never silently created or converted to text.
    /// Caller reports begin failures through its existing diagnostic UI.
    pub fn begin(self: *Browser, gpa: std.mem.Allocator, host: Host, options: Options) !void {
        if (self.open) return error.ThemeBrowserAlreadyOpen;
        var original = try edit.Native.capture(gpa, options.config_path);
        errdefer original.deinit();
        const probe = try edit.replaceTheme(gpa, original.bytes, "paper");
        gpa.free(probe);
        var catalog = try themes.Catalog.scan(gpa, options.roots, themes.nativeReader(), .{ .entries = max_results });
        errdefer catalog.deinit();
        const home = try gpa.dupe(u8, options.home);
        errdefer gpa.free(home);
        const lease = try host.acquire(host.context, options.window);
        errdefer host.release(host.context, lease);
        if (lease.window != options.window or lease.window == 0 or !host.alive(host.context, lease)) return error.ThemeTargetClosed;
        self.* = .{ .open = true, .gpa = gpa, .host = host, .lease = lease, .catalog = catalog, .original = original, .home = home, .focus_query = true };
        // Catalog limits guarantee this initial result set fits fixed storage.
        self.filtered_count = self.catalog.?.filter("", &self.filtered) catch unreachable;
    }
    /// Always call before WindowState.deinit/reload releases a pinned config.
    /// Cancel restores runtime visuals; it does not undo an already committed
    /// root-file save. Completed Apply/Save already transferred ownership.
    pub fn deinit(self: *Browser) void {
        if (!self.open) return;
        const host = self.host.?;
        const lease = self.lease.?;
        if (self.controller.candidate != null) host.restore(host.context, lease);
        self.controller.cancel();
        self.finish();
    }
    fn finish(self: *Browser) void {
        const gpa = self.gpa.?;
        self.preview_cfg = null;
        self.controller.deinit();
        if (self.original) |*original| original.deinit();
        if (self.catalog) |*catalog| catalog.deinit();
        gpa.free(self.home);
        self.host.?.release(self.host.?.context, self.lease.?);
        self.* = .{};
    }
    /// IO and host effects are explicit event-loop work. Error keeps the dialog
    /// open and its last valid preview owned. Save failure precedes rename; a
    /// directory-fsync failure is a successful committed save with a distinct
    /// outcome, never reported as an unchanged file.
    pub fn handle(self: *Browser, intent: Intent) !Outcome {
        if (!self.open or intent == .none) return .unchanged;
        const host = self.host.?;
        const lease = self.lease.?;
        if (intent == .cancel) {
            self.deinit();
            return .cancelled;
        }
        if (!host.alive(host.context, lease)) {
            self.deinit();
            return error.ThemeTargetClosed;
        }
        self.notice.set("");
        return self.perform(intent) catch |err| {
            self.notice.set(@errorName(err));
            return err;
        };
    }
    fn perform(self: *Browser, intent: Intent) !Outcome {
        const host = self.host.?;
        const lease = self.lease.?;
        const gpa = self.gpa.?;
        switch (intent) {
            .none, .cancel => unreachable,
            .preview => |index| {
                const entry = try self.controller.select(&self.catalog.?, index);
                self.diagnostic = .{};
                var candidate = try themes.Candidate.prepare(gpa, self.original.?, entry, config.includes.nativeReader(self.home), &self.diagnostic);
                var owned = true;
                errdefer if (owned) candidate.deinit();
                const current = try host.current(host.context, lease);
                const visual = previewVisual(&candidate, current);
                // The old candidate remains owned until new visuals succeed.
                // No current Config may borrow it when Controller replaces it.
                host.restore(host.context, lease);
                host.preview(host.context, lease, visual) catch |err| {
                    // Best-effort restoration of the former preview, otherwise
                    // the pinned baseline stays valid. Never free a live borrow.
                    if (self.controller.candidate) |*previous| {
                        const prior = previewVisual(previous, current);
                        host.preview(host.context, lease, prior) catch {
                            self.preview_cfg = null;
                            self.preview_index = null;
                        };
                    }
                    return err;
                };
                self.controller.preview(candidate) catch |err| {
                    host.restore(host.context, lease);
                    self.preview_cfg = null;
                    self.preview_index = null;
                    return err;
                };
                owned = false;
                self.preview_cfg = visual;
                self.preview_index = index;
                return .previewed;
            },
            .apply, .save => {
                if (!self.canApply()) return error.SelectedThemeNotPreviewed;
                const candidate = if (self.controller.candidate) |*value| value else return error.NoThemePreview;
                try host.prepare_apply(host.context, lease, candidate);
                var synced = true;
                if (intent == .save) synced = (try self.controller.save(gpa, self.original.?)).directory_synced;
                // Presence was checked before IO. apply only transfers the same
                // owned candidate; it has no further IO/allocation failure path.
                const applied = self.controller.apply() catch unreachable;
                host.commit_apply(host.context, lease, applied);
                self.finish();
                return if (intent == .apply) .applied else if (synced) .saved else .saved_not_synced;
            },
        }
    }
    /// Called on the UI turn after system-appearance changes. Uses only cached
    /// candidate branches: no file reads, font-size or family reset.
    pub fn syncAppearance(self: *Browser) !void {
        if (!self.open or self.controller.candidate == null) return;
        const host = self.host.?;
        const lease = self.lease.?;
        if (!host.alive(host.context, lease)) return error.ThemeTargetClosed;
        const current = try host.current(host.context, lease);
        const visual = previewVisual(&self.controller.candidate.?, current);
        try host.preview(host.context, lease, visual);
        self.preview_cfg = visual;
    }
    fn refilter(self: *Browser) void {
        // TextBuffer's native IME capacity is 1024; Catalog's query contract is
        // 256 bytes. Clamp only after composition, always at a UTF-8 boundary.
        if (!self.composing and self.query.len > 256) {
            var n: usize = 256;
            while (self.query.buf[n] & 0xc0 == 0x80) n -= 1;
            self.query.len = n;
            self.query.want_caret = n;
        }
        if (self.query.len > 256 or std.mem.eql(u8, self.previous.text(), self.query.text())) return;
        self.previous.set(self.query.text());
        self.filtered_count = self.catalog.?.filter(self.query.text(), &self.filtered) catch 0;
        self.selected = 0;
        self.first = 0;
        self.wheel = .{};
    }
    pub fn canApply(self: *const Browser) bool {
        return self.controller.candidate != null and self.preview_index != null and self.filtered_count > 0 and
            self.selected < self.filtered_count and self.filtered[self.selected] == self.preview_index.?;
    }
    fn tab(self: *Browser, reverse: bool) void {
        var index: usize = @backingInt(self.keyboard);
        for (0..4) |_| {
            index = if (reverse) (index + 3) % 4 else (index + 1) % 4;
            const next: Keyboard = @fromBackingInt(@intCast(index));
            if ((next == .apply or next == .save) and !self.canApply()) continue;
            self.keyboard = next;
            self.focus_query = next == .query;
            return;
        }
    }
    pub fn draw(self: *Browser, ctx: *ui.Context) Intent {
        if (!self.open) return .none;
        ctx.wants_wheel = true;
        self.geometry = .{};
        var composing = self.composing;
        for (ctx.input.ops) |op| if (op == .set_marked) {
            composing = true;
        };
        var cancel = !composing and take(ctx, .escape, ui.Shortcut.escape);
        var tabbed = !composing and take(ctx, .tab, ui.Shortcut.tab);
        var submitted = false;
        for (ctx.input.ops) |op| if (!composing and op == .command) {
            if (op.command == .cancel) cancel = true;
            if (op.command == .insert_tab) tabbed = true;
            if (op.command == .insert_newline) submitted = true;
        };
        if (tabbed and !cancel) {
            self.tab(ctx.input.shift);
            ctx.changed = true;
        }
        if (self.keyboard != .query) ctx.focus = 0;
        const up = !composing and take(ctx, .up, ui.Shortcut.up);
        const down = !composing and take(ctx, .down, ui.Shortcut.down);
        const enter = !composing and (take(ctx, .enter, ui.Shortcut.enter) or submitted);
        var keyboard_intent: Intent = .none;
        if (enter) switch (self.keyboard) {
            .cancel => keyboard_intent = .cancel,
            .apply => if (self.canApply()) {
                keyboard_intent = .apply;
            },
            .save => if (self.canApply()) {
                keyboard_intent = .save;
            },
            .query => {},
        };
        const width = @max(1, @min(640, ctx.size.w - 24));
        const height = @max(1, @min(600, ctx.size.h - 16));
        const compact = height < 420;
        const rect: ui.Rect = .{ .x = (ctx.size.w - width) / 2, .y = (ctx.size.h - height) / 2, .w = width, .h = height };
        self.geometry.dialog = rect;
        if (ctx.input.pressed and !rect.contains(ctx.input.mouse)) cancel = true;
        ui.key(ctx, "theme-browser-modal");
        const overlay = ctx.open(.{ .absolute = true, .width = .{ .px = ctx.size.w }, .height = .{ .px = ctx.size.h }, .background = @import("rex_chrome.zig").overlay(ctx) }, null);
        _ = ctx.interact(overlay, .{});
        defer ctx.end();
        ui.key(ctx, "theme-browser-card");
        self.geometry.dialog_node = ctx.peekId(null);
        ui.column(ctx, .{ .absolute = true, .offset = .{ .x = rect.x, .y = rect.y }, .width = .{ .px = width }, .height = .{ .px = height }, .padding = .all(16), .radius = 14, .border = ctx.theme.border, .background = ctx.theme.surface, .clip = true });
        defer ui.end(ctx);
        // A clipped body and an absolute footer reserve real button space even
        // at the application's 240px minimum height. Acceptance uses final
        // Tester layout, not this size calculation, to prove reachability.
        ui.column(ctx, .{ .width = .fill, .height = .{ .px = @max(1, height - 60) }, .gap = 6, .clip = true });
        ui.text(ctx, "Themes", .{ .size = 16 });
        ui.key(ctx, "theme-browser-query");
        self.geometry.query_node = ctx.peekId(null);
        if (self.focus_query) {
            ctx.focus = ctx.peekId(null);
            self.focus_query = false;
        }
        const field = ui.textField(ctx, &self.query, .{ .placeholder = "Search themes", .width = .fill, .size = 13 });
        if (field.focused) self.keyboard = .query;
        self.composing = if (ctx.focused_text) |f| f.marked != null else false;
        self.refilter();
        const visible: usize = @intFromFloat(@max(1, @min(max_visible, @floor((height - @as(f32, if (compact) 142 else 380)) / 30))));
        const previous_selection = self.selected;
        if (self.filtered_count > 0) {
            self.selected = @min(self.selected, self.filtered_count - 1);
            if (up) self.selected = (self.selected + self.filtered_count - 1) % self.filtered_count;
            if (down) self.selected = (self.selected + 1) % self.filtered_count;
            if ((ctx.input.scroll.y != 0 or ctx.input.scroll_started) and rect.contains(ctx.input.mouse)) {
                self.selected = self.wheel.select(ctx.input, 30, self.selected, self.filtered_count);
                ctx.changed = true;
            }
            if (self.selected < self.first) self.first = self.selected;
            if (self.selected >= self.first + visible) self.first = self.selected + 1 - visible;
        }
        var intent: Intent = .none;
        if ((up or down or previous_selection != self.selected) and self.filtered_count > 0) intent = .{ .preview = self.filtered[self.selected] };
        ui.column(ctx, .{ .width = .fill, .height = .{ .px = @as(f32, @floatFromInt(visible)) * 30 }, .clip = true });
        if (self.filtered_count == 0) ui.text(ctx, "No matching themes", .{ .size = 13, .color = ctx.theme.muted });
        for (self.first..@min(self.filtered_count, self.first + visible)) |index| {
            const at = self.filtered[index];
            const entry = self.catalog.?.entries[at];
            ui.key(ctx, ctx.print("theme-browser-theme-{d}", .{at}));
            const it = chrome.control(ctx, .{ .direction = .row, .width = .fill, .height = .{ .px = 30 }, .padding = .xy(8, 0), .gap = 8, .align_items = .center, .control = true, .radius = 8, .background = if (index == self.selected) ctx.theme.accent.alpha(0.12) else null }, ctx.theme.surface_hover);
            self.geometry.rows[self.geometry.row_count] = .{ .catalog_index = at, .widget = it.id, .rect = it.rect };
            self.geometry.row_count += 1;
            ui.text(ctx, chrome.ellipsize(ctx, entry.name, @max(1, width - 130), 13), .{ .size = 13 });
            ui.spacer(ctx);
            ui.text(ctx, @tagName(entry.origin), .{ .size = 10, .color = ctx.theme.muted });
            ui.end(ctx);
            if (it.clicked) {
                self.selected = index;
                intent = .{ .preview = at };
            }
        }
        ui.end(ctx);
        if (self.keyboard == .query and !composing and (enter or field.submitted) and self.filtered_count > 0) intent = .{ .preview = self.filtered[self.selected] };
        if (!compact) {
            self.drawPreview(ctx, width);
        } else if (self.preview_index) |index| {
            ui.text(ctx, chrome.ellipsize(ctx, ctx.print("Preview: {s}", .{self.catalog.?.entries[index].name}), @max(1, width - 20), 10), .{ .size = 10, .color = ctx.theme.muted });
        }
        const hint = if (self.notice.len > 0) self.notice.text() else if (self.catalog.?.truncated) "Catalog limit reached; narrow theme directories to see more." else "Apply uses the preview now. Save also updates the root config.";
        ui.text(ctx, if (compact) chrome.ellipsize(ctx, hint, @max(1, width - 20), 11) else hint, .{ .size = 11, .color = ctx.theme.muted, .wrap = !compact });
        if (!compact) {
            ui.text(ctx, chrome.ellipsize(ctx, self.original.?.path, @max(1, width - 20), 10), .{ .size = 10, .color = ctx.theme.muted });
            if (self.diagnostic.path_len > 0) ui.text(ctx, chrome.ellipsize(ctx, ctx.print("{s}:{d}", .{ self.diagnostic.path[0..self.diagnostic.path_len], self.diagnostic.line }), @max(1, width - 20), 10), .{ .size = 10, .color = ctx.theme.muted });
        }
        ui.end(ctx);
        ui.row(ctx, .{ .absolute = true, .offset = .{ .y = @max(0, height - 52) }, .width = .fill, .height = .{ .px = 32 }, .gap = 8, .align_items = .center });
        ui.key(ctx, "theme-browser-cancel");
        const cancel_button = chrome.button(ctx, "Cancel", .{ .variant = if (self.keyboard == .cancel) .primary else .ghost, .size = 12 });
        self.geometry.cancel = cancel_button.rect;
        self.geometry.cancel_node = cancel_button.id;
        ui.spacer(ctx);
        ui.key(ctx, "theme-browser-apply");
        const apply_button = chrome.button(ctx, "Apply", .{ .variant = if (self.keyboard == .apply) .primary else .secondary, .disabled = !self.canApply(), .size = 12 });
        self.geometry.apply = apply_button.rect;
        self.geometry.apply_node = apply_button.id;
        ui.key(ctx, "theme-browser-save");
        const save_button = chrome.button(ctx, "Save", .{ .variant = if (self.keyboard == .query or self.keyboard == .save) .primary else .secondary, .disabled = !self.canApply(), .size = 12 });
        self.geometry.save = save_button.rect;
        self.geometry.save_node = save_button.id;
        ui.end(ctx);
        switch (self.keyboard) {
            .query => {},
            .cancel => ctx.focus = cancel_button.id,
            .apply => ctx.focus = apply_button.id,
            .save => ctx.focus = save_button.id,
        }
        // Until deferred handle() commits, keep the actual modal tree laid out
        // even on Escape/Enter so post-frame accessibility never sees a phantom
        // open dialog with zero node IDs.
        if (cancel or cancel_button.clicked) return .cancel;
        if (keyboard_intent != .none) return keyboard_intent;
        if (apply_button.clicked) return .apply;
        if (save_button.clicked) return .save;
        return intent;
    }
    fn drawPreview(self: *Browser, ctx: *ui.Context, width: f32) void {
        const cfg = self.preview_cfg orelse {
            ui.text(ctx, "Select a theme to preview", .{ .size = 12, .color = ctx.theme.muted });
            return;
        };
        if (self.preview_index) |index| ui.text(ctx, chrome.ellipsize(ctx, ctx.print("Preview: {s}", .{self.catalog.?.entries[index].name}), @max(1, width - 28), 11), .{ .size = 11, .color = ctx.theme.muted });
        ui.column(ctx, .{ .width = .fill, .padding = .all(10), .gap = 6, .background = ui.Color.hex(cfg.background), .border = ctx.theme.border, .radius = 5, .clip = true });
        ui.text(ctx, "Letty  ~  $ printf 'hello, 世界'", .{ .size = 12, .mono = true, .color = ui.Color.hex(cfg.foreground) });
        ui.row(ctx, .{ .width = .fill, .gap = 0 });
        for (cfg.palette) |rgb| _ = ctx.leaf(.{ .width = .{ .px = @max(1, (width - 50) / 16) }, .height = .{ .px = 12 }, .background = ui.Color.hex(rgb) }, .none, null);
        ui.end(ctx);
        ui.end(ctx);
    }
};
fn take(ctx: *ui.Context, comptime key: anytype, shortcut: u21) bool {
    const found = ctx.shortcut(.{ .key = shortcut }) or ctx.input.key == key;
    if (found) ctx.input.key = null;
    return found;
}
fn previewVisual(candidate: *const themes.Candidate, current: Current) config.Config {
    return candidate.preview(current.cfg, current.dark);
}
