//! Per-document reading state. CPU preparation is pure/worker-only; apply and
//! draw own no filesystem operations. Root owns doc IDs, watchers and GPU keys.
const std = @import("std");
const ui = @import("nanoui").ui;
const model = @import("model.zig");
const md = @import("markdown.zig");
const text = @import("read_only_text.zig");
const fixed = @import("../fixed_text.zig");
const View = @import("view.zig");
pub const Intent = View.Intent;
pub const Mode = enum { rendered, source };
pub const Layout = struct { terminal: ui.Rect, preview: ui.Rect };
pub const Image = struct {
    gpa: std.mem.Allocator,
    width: u32,
    height: u32,
    original_width: u32,
    original_height: u32,
    bgra: []u8,
    /// Markdown block index, or null for a standalone PNG.
    line: ?usize = null,
    pub fn deinit(self: *Image) void {
        self.gpa.free(self.bgra);
        self.* = undefined;
    }
};
pub const Prepared = struct {
    source: text.Document,
    rendered: ?text.Document = null,
    markdown: ?md.Document = null,
    images: [9]?Image = @splat(null),
    image_count: usize = 0,
    image_errors: [8]struct { line: usize = 0, message: fixed.Text(192) = .{} } = @splat(.{}),
    image_error_count: usize = 0,
    prepare_error: ?anyerror = null,
    pub fn init(gpa: std.mem.Allocator, kind: model.Kind, bytes: []const u8) !Prepared {
        return initWithPath(gpa, kind, bytes, "");
    }
    /// Called with owned request bytes/path by the loader's bounded worker.
    pub fn initWithPath(gpa: std.mem.Allocator, kind: model.Kind, bytes: []const u8, absolute_path: []const u8) !Prepared {
        var self: Prepared = .{ .source = try text.Document.init(gpa, if (kind == .image or kind == .unsupported) "" else bytes) };
        errdefer self.deinit();
        if (kind == .markdown) {
            if (bytes.len > md.max_source) {
                self.prepare_error = error.PreviewMarkdownLimit;
                return self;
            }
            self.markdown = try md.Document.init(gpa, bytes);
            if (self.markdown.?.truncated) {
                self.markdown.?.deinit();
                self.markdown = null;
                self.prepare_error = error.PreviewMarkdownLimit;
                return self;
            }
            self.rendered = try text.Document.init(gpa, self.markdown.?.text);
            var used: usize = 0;
            for (self.markdown.?.links) |link| if (link.image) {
                if (self.image_count + self.image_error_count >= 8) break;
                const bytes_resource = @import("loader.zig").readResource(gpa, absolute_path, link.target) catch |err| {
                    self.image_errors[self.image_error_count].line = link.line;
                    self.image_errors[self.image_error_count].message.set(@errorName(err));
                    self.image_error_count += 1;
                    continue;
                };
                defer gpa.free(bytes_resource);
                var image = decodeImage(gpa, bytes_resource) catch |err| {
                    self.image_errors[self.image_error_count].line = link.line;
                    self.image_errors[self.image_error_count].message.set(@errorName(err));
                    self.image_error_count += 1;
                    continue;
                };
                if (image.bgra.len > 4 * 1024 * 1024 -| used) {
                    image.deinit();
                    self.image_errors[self.image_error_count].line = link.line;
                    self.image_errors[self.image_error_count].message.set("DocumentImageBudget");
                    self.image_error_count += 1;
                    continue;
                }
                used += image.bgra.len;
                image.line = link.line;
                self.images[self.image_count] = image;
                self.image_count += 1;
            };
        } else if (kind == .image) {
            self.images[0] = decodeImage(gpa, bytes) catch |err| {
                self.prepare_error = err;
                return self;
            };
            self.image_count = 1;
        }
        return self;
    }
    pub fn deinit(self: *Prepared) void {
        self.source.deinit();
        if (self.rendered) |*rendered| rendered.deinit();
        if (self.markdown) |*markdown| markdown.deinit();
        for (&self.images) |*maybe| if (maybe.*) |*image| image.deinit();
        self.* = undefined;
    }
};
fn decodeImage(gpa: std.mem.Allocator, bytes: []const u8) !Image {
    if (bytes.len > 8 * 1024 * 1024) return error.PreviewImageLimit;
    const decoded = try @import("../graphics_png.zig").decode(gpa, bytes);
    defer decoded.deinit(gpa);
    if (decoded.width > 2048 or decoded.height > 2048) return error.PreviewImageLimit;
    const factor = @min(@as(f64, 1), @min(1024.0 / @as(f64, @floatFromInt(decoded.width)), 1024.0 / @as(f64, @floatFromInt(decoded.height))));
    const w: u32 = @intFromFloat(@max(1, @floor(@as(f64, @floatFromInt(decoded.width)) * factor)));
    const h: u32 = @intFromFloat(@max(1, @floor(@as(f64, @floatFromInt(decoded.height)) * factor)));
    const bgra = try gpa.alloc(u8, @as(usize, w) * h * 4);
    for (0..h) |y| for (0..w) |x| {
        const sx = @min(decoded.width - 1, x * decoded.width / w);
        const sy = @min(decoded.height - 1, y * decoded.height / h);
        const rgba = decoded.rgba[(sy * decoded.width + sx) * 4 ..][0..4];
        const out = bgra[(y * w + x) * 4 ..][0..4];
        const a: u16 = rgba[3];
        out.* = .{ @intCast((@as(u16, rgba[2]) * a + 127) / 255), @intCast((@as(u16, rgba[1]) * a + 127) / 255), @intCast((@as(u16, rgba[0]) * a + 127) / 255), rgba[3] };
    };
    return .{ .gpa = gpa, .width = w, .height = h, .original_width = decoded.width, .original_height = decoded.height, .bgra = bgra };
}
pub const Control = enum { unlock, save, discard, open, browse, rendered, source, toggle_source, more, copy_code, find, copy_path, external, previous, next, done, fit, actual, zoom_out, zoom_in };
pub const ControlNote = struct { offset: usize = 0, widget: u64, control: Control, label: []const u8, enabled: bool, selected: bool };
pub const VisualRow = struct { row: usize, start: usize, end: usize, y: f32, height: f32 };
pub const Panel = struct {
    model: model.State = .{},
    editor: ?*@import("editor.zig").Editor = null,
    edit_busy: bool = false,
    edit_request: enum { none, unlock, save, discard } = .none,
    opened: bool = false,
    focused: bool = false,
    preferred_width: f32 = 440,
    mode: Mode = .rendered,
    prepared: ?Prepared = null,
    prepared_revision: u64 = 0,
    path: ui.TextBuffer = .{},
    path_truncated: bool = false,
    query: ui.TextBuffer = .{},
    show_find: bool = false,
    show_actions: bool = false,
    embedded_header: bool = false,
    focus_query: bool = false,
    focus_path: bool = false,
    selection: text.Selection = .{},
    matches: [text.max_matches]text.Match = undefined,
    match_count: usize = 0,
    match_current: usize = 0,
    query_hash: u64 = 0,
    search_offset: usize = 0,
    searching: bool = false,
    search_valid: bool = false,
    reveal_match: bool = false,
    pending_reveal: ?usize = null,
    scroll_y: f32 = 0,
    scroll_x: f32 = 0,
    /// Measured with row geometry, invalidated by document/font/width/mode changes.
    scroll_x_max: f32 = 0,
    zoom: f32 = 1,
    fit_image: bool = true,
    image_zoom: f32 = 1,
    /// Root issues these from its shared Store.keys and accounts put/remove.
    image_keys: [9]u64 = @splat(0),
    link_target: fixed.Text(4096) = .{},
    notice: fixed.Text(512) = .{},
    rect: ui.Rect = .{},
    body_rect: ui.Rect = .{},
    row_y: std.ArrayList(f32) = .empty,
    visual_rows: std.ArrayList(VisualRow) = .empty,
    tables: @import("table_layout.zig").Layout = .{},
    layout_width: f32 = -1,
    layout_zoom: f32 = -1,
    layout_font: u64 = 0,
    search_frame: ?u64 = null,
    layout_mode: Mode = .rendered,
    input_frame: ?u64 = null,
    key_frame: ?u64 = null,
    body_frame: ?u64 = null,
    zoom_frame: ?u64 = null,
    ax_controls: [16]ControlNote = undefined,
    ax_count: usize = 0,
    ax_results: u64 = 0,
    ax_status: u64 = 0,
    ax_readonly: u64 = 0,
    ax_body: u64 = 0,
    ax_query: u64 = 0,
    ax_refresh: u64 = 0,
    ax_close: u64 = 0,
    ax_copy: u64 = 0,
    ax_path: u64 = 0,
    field: enum { body, path, query } = .body,
    pub fn hasUnsaved(self: *const Panel) bool {
        return self.edit_busy or (if (self.editor) |e| e.dirty else false);
    }
    pub fn layout(self: *const Panel, base: ui.Rect) Layout {
        if (!self.opened) return .{ .terminal = base, .preview = .{} };
        if (base.w < 780) return .{ .terminal = .{ .x = base.x, .y = base.y, .h = base.h }, .preview = base };
        const w = @min(base.w * 0.55, @max(340, self.preferred_width));
        return .{ .terminal = .{ .x = base.x, .y = base.y, .w = base.w - w, .h = base.h }, .preview = .{ .x = base.x + base.w - w, .y = base.y, .w = w, .h = base.h } };
    }
    pub fn close(self: *Panel) void {
        self.opened = false;
        self.focused = false;
        self.selection = .{};
        self.field = .body;
    }
    /// Root removes image_keys through the shared Store before apply/deinit.
    pub fn apply(self: *Panel, prepared: Prepared, revision: u64) void {
        if (self.prepared) |*old| old.deinit();
        self.prepared = prepared;
        self.prepared_revision = revision;
        self.selection = .{};
        self.pending_reveal = null;
        self.scroll_y = 0;
        self.scroll_x = 0;
        self.scroll_x_max = 0;
        self.layout_width = -1;
        self.query_hash = 0;
        self.search_valid = false;
        self.match_count = 0;
        self.image_keys = @splat(0);
        if (self.mode == .rendered and prepared.markdown == null) self.mode = .source;
    }
    /// Fixture-only convenience. Production uses loader worker prepare hooks.
    pub fn sync(self: *Panel, gpa: std.mem.Allocator) !void {
        if (self.model.status != .ready or self.prepared_revision == self.model.revision and self.prepared != null) return;
        const prepared = try Prepared.initWithPath(gpa, self.model.kind, self.model.bytes, self.model.path.text());
        self.apply(prepared, self.model.revision);
        self.path.set(self.model.path.text());
        self.path_truncated = self.model.path.len > self.path.buf.len;
    }
    pub fn deinit(self: *Panel, gpa: std.mem.Allocator) void {
        if (self.editor) |e| e.release();
        self.model.deinit(gpa);
        if (self.prepared) |*prepared| prepared.deinit();
        self.row_y.deinit(gpa);
        self.visual_rows.deinit(gpa);
        self.tables.deinit(gpa);
        self.* = .{};
    }
    pub fn document(self: *const Panel) ?*const text.Document {
        const prepared = if (self.prepared) |*value| value else return null;
        return if (self.mode == .rendered and prepared.rendered != null) &prepared.rendered.? else &prepared.source;
    }
    pub fn imageAt(self: *const Panel, index: usize) ?*const Image {
        const prepared = if (self.prepared) |*value| value else return null;
        if (index >= prepared.image_count) return null;
        return if (prepared.images[index]) |*image| image else null;
    }
    pub fn copy(self: *Panel, ctx: *ui.Context) void {
        if (self.editor) |editor| {
            if (ctx.edits.getPtr(self.ax_body)) |e| {
                const lo = @min(@min(e.anchor, e.caret), editor.buffer.len);
                const hi = @min(@max(e.anchor, e.caret), editor.buffer.len);
                ctx.clipboard.write(ctx.clipboard.ctx, editor.buffer.text()[lo..hi]);
            }
            return;
        }
        if (self.document()) |doc| {
            const selected = self.selection.selected(doc);
            if (selected.len > 0) ctx.clipboard.write(ctx.clipboard.ctx, selected);
        }
    }
    /// A changed query cancels old results immediately; each frame scans at most
    /// 64 KiB of candidate starts, including overlap for cross-chunk matches.
    pub fn updateSearch(self: *Panel) void {
        const doc = self.document() orelse return;
        const query = self.query.text();
        const hash = std.hash.Wyhash.hash(@backingInt(self.mode), query);
        if (!self.search_valid or hash != self.query_hash) {
            self.query_hash = hash;
            self.search_valid = true;
            self.match_count = 0;
            self.match_current = 0;
            self.search_offset = 0;
            self.selection = .{};
            self.reveal_match = false;
            self.searching = query.len > 0;
        }
        if (!self.searching) return;
        const stop = @min(doc.text.len, self.search_offset + 64 * 1024);
        const end = @min(doc.text.len, stop + query.len -| 1);
        while (self.search_offset < stop and self.match_count < self.matches.len) {
            const at = std.mem.indexOfPos(u8, doc.text[0..end], self.search_offset, query) orelse break;
            if (at >= stop) break;
            self.search_offset = at + 1;
            if (!doc.boundary(at) or !doc.boundary(at + query.len)) continue;
            self.matches[self.match_count] = .{ .start = at, .end = at + query.len };
            self.match_count += 1;
            if (self.match_count == 1) self.selectMatch();
        }
        self.search_offset = stop;
        self.searching = stop < doc.text.len and self.match_count < self.matches.len;
    }
    fn selectMatch(self: *Panel) void {
        if (self.match_count == 0) return;
        const found = self.matches[self.match_current];
        self.selection = .{ .anchor = found.start, .caret = found.end };
        self.reveal_match = true;
    }
    pub fn find(self: *Panel, previous: bool) void {
        const old_hash = self.query_hash;
        const valid = self.search_valid;
        self.updateSearch();
        if (self.match_count == 0) return;
        if (valid and old_hash == self.query_hash) {
            self.match_current = if (previous) (self.match_current + self.match_count - 1) % self.match_count else (self.match_current + 1) % self.match_count;
        } else if (previous) self.match_current = self.match_count - 1;
        self.selectMatch();
    }
    pub fn reveal(self: *Panel, at: usize) void {
        const doc = self.document() orelse return;
        const row = doc.lineAt(at);
        if (row < self.row_y.items.len) self.scroll_y = self.row_y.items[row];
    }
    pub fn scrollToLine(self: *Panel, line: usize, column: usize) void {
        const doc = self.document() orelse return;
        const at = doc.lines[@min(line -| 1, doc.lines.len - 1)];
        self.selection.place(doc, at.start + @min(column -| 1, at.end - at.start), false);
        self.reveal(self.selection.caret);
    }
    pub fn anchor(self: *Panel, target: []const u8) bool {
        const prepared = if (self.prepared) |*value| value else return false;
        const markdown = if (prepared.markdown) |*value| value else return false;
        const name = if (std.mem.startsWith(u8, target, "#")) target[1..] else target;
        for (markdown.anchors) |item| if (std.mem.eql(u8, item.slug, name)) {
            const mode_changed = self.mode != .rendered;
            self.mode = .rendered;
            self.layout_width = -1;
            self.reveal(item.start);
            if (mode_changed) self.pending_reveal = item.start;
            return true;
        };
        return false;
    }
    pub fn handleAction(self: *Panel, action: @import("../actions.zig").Action, ctx: *ui.Context) bool {
        if (self.editor) |editor| {
            switch (action) {
                .copy => self.copy(ctx),
                .select_all => if (ctx.edits.getPtr(self.ax_body)) |e| {
                    e.anchor = 0;
                    e.caret = editor.buffer.len;
                },
                .search => self.notice.set("Save or lock the document before searching."),
                else => return false,
            }
            ctx.changed = true;
            return true;
        }
        if (!self.opened or !self.focused) return false;
        if (self.field != .body and (action == .copy or action == .select_all)) {
            const buffer = if (self.field == .path) &self.path else &self.query;
            if (ctx.edits.getPtr(ctx.focus)) |edit| {
                if (action == .select_all) {
                    edit.anchor = 0;
                    edit.caret = buffer.len;
                } else {
                    const start = @min(@min(edit.anchor, edit.caret), buffer.len);
                    const end = @min(@max(edit.anchor, edit.caret), buffer.len);
                    if (end > start) ctx.clipboard.write(ctx.clipboard.ctx, buffer.text()[start..end]);
                    ctx.copy_done = true;
                }
            }
            ctx.changed = true;
            return true;
        }
        switch (action) {
            .copy => self.copy(ctx),
            .select_all => if (self.document()) |doc| {
                self.selection.all(doc);
            },
            .search => {
                self.show_find = true;
                self.focus_query = true;
                self.field = .query;
            },
            .page_up => self.scroll_y = @max(0, self.scroll_y - self.body_rect.h * 0.8),
            .page_down => self.scroll_y += self.body_rect.h * 0.8,
            .scroll_top => self.scroll_y = 0,
            .scroll_bottom => if (self.row_y.items.len > 0) {
                self.scroll_y = @max(0, self.row_y.items[self.row_y.items.len - 1] - self.body_rect.h);
            },
            .search_next => self.find(false),
            .search_previous => self.find(true),
            .end_search => {
                self.show_find = false;
                self.field = .body;
                ctx.focus = 0;
            },
            .font_up => {
                self.zoom = @min(2, self.zoom + 0.1);
                self.image_zoom = @min(4, self.image_zoom + 0.25);
                self.fit_image = false;
                self.layout_width = -1;
            },
            .font_down => {
                self.zoom = @max(0.6, self.zoom - 0.1);
                self.image_zoom = @max(0.25, self.image_zoom - 0.25);
                self.fit_image = false;
                self.layout_width = -1;
            },
            .font_reset => {
                self.zoom = 1;
                self.image_zoom = 1;
            },
            else => return false,
        }
        ctx.changed = true;
        return true;
    }
    /// Call before root shortcuts/terminal input; leave input intact for draw.
    pub fn prepareInput(self: *Panel, ctx: *ui.Context, rect: ui.Rect) bool {
        if (!self.opened) return false;
        self.rect = rect;
        if (self.input_frame == ctx.frame) return self.focused;
        self.input_frame = ctx.frame;
        if (ctx.input.pressed) {
            if (rect.contains(ctx.input.mouse)) self.focused = true else {
                self.focused = false;
                self.selection.dragging = false;
                self.field = .body;
                ctx.focus = 0;
            }
        }
        return self.focused or rect.contains(ctx.input.mouse) and (ctx.input.pressed or ctx.input.scroll.y != 0 or ctx.input.scroll.x != 0);
    }
    pub fn draw(self: *Panel, ctx: *ui.Context, rect: ui.Rect) Intent {
        return View.draw(self, ctx, rect);
    }
};
