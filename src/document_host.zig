//! Explicit document-native boundary. No preceding application is imported.
//! Only fixed text, URI, PNG and guarded POSIX snapshot leaves are reused.
const std = @import("std");
const ui = @import("nanoui").ui;
const Watch = @import("runtime/document/watch.zig").Watch;
pub const panel = @import("runtime/document/panel.zig");
pub const path = @import("runtime/document/path.zig");
pub const loader = @import("runtime/document/loader.zig");
pub const terminal_paths = @import("runtime/document/terminal_paths.zig");
pub const path_token = @import("runtime/document/path_token.zig");
pub const markdown = @import("runtime/document/markdown.zig");
pub const read_only_text = @import("runtime/document/read_only_text.zig");
pub const view = @import("runtime/document/view.zig");
pub const fileIcon = @import("runtime/document/chrome.zig").fileIcon;
pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.ConcurrentChange, error.FileChangedExternallyReloadFirst => "File changed on disk. Draft kept; reload the disk version before trying again.",
        error.SavedButFileChangedAgain => "Saved, then changed by another writer. Draft kept; reload before saving again.",
        error.MetadataNotPreserved, error.MetadataUnsupported, error.MetadataAccessDenied, error.MetadataIo => "Cannot preserve file metadata. Draft kept; file was not replaced.",
        error.UnsavedDocumentChooseSaveOrDiscard => "Unsaved changes. Choose Save or Discard before closing.",
        error.DocumentDraftActive => "Editing draft kept. Reload disk version to discard it.",
        error.FinishCompositionBeforeSaving, error.FinishCompositionBeforeSwitching => "Finish or cancel the current input first; draft kept.",
        error.DraftWorkersBusy, error.EditorBusy => "Document workers are busy; retry shortly.",
        else => @errorName(err),
    };
}
const hooks = @import("runtime/document/prepare_hooks.zig");
const EditJob = @import("runtime/document/edit_job.zig").Job;
const DraftJob = @import("runtime/document/draft_job.zig").Job;
const A = std.mem.Allocator;
test {
    _ = @import("runtime/document/rich_check.zig");
    _ = @import("runtime/document/markdown_check.zig");
    _ = @import("runtime/document/markdown_extension_check.zig");
    _ = terminal_paths;
    _ = path_token;
    _ = read_only_text;
}
pub const Notify = struct {
    context: ?*anyopaque = null,
    changed: ?*const fn (?*anyopaque, u64) void = null,
    fn send(self: Notify, id: u64) void {
        if (self.changed) |f| f(self.context, id);
    }
};
/// Heap stable until both readiness sources are cancelled. Jobs retain owned
/// snapshots, never this pointer; generation revocation is enforced by model.
pub const Document = struct {
    a: A,
    id: u64,
    requested: @import("fixed_text.zig").Text(4096) = .{},
    panel: panel.Panel = .{},
    notify: Notify,
    reading: ?*Watch = null,
    editing: ?*Watch = null,
    job: ?*EditJob = null,
    draft_job: ?*DraftJob = null,
    draft_watch: ?*Watch = null,
    draft_timer: ?*Watch = null,
    draft_epoch: u64 = 0,
    draft_revision: ?u64 = null,
    scheduled_revision: ?u64 = null,
    preview: panel.Panel = .{},
    presented: bool = false,
    presentation_enabled: bool = true,
    checking_disk: bool = false,
    fallback: ?path.Resolved = null,
    inline_attempted: bool = false,
    edit_failed: bool = false,
    autosave_timer: ?*Watch = null,
    autosave_revision: ?u64 = null,
    autosave_failed_revision: ?u64 = null,
    pub const autosave_delay_ms = 500;
    pub fn create(a: A, id: u64, absolute_path: []const u8, notify: Notify) !*Document {
        const self = try a.create(Document);
        errdefer a.destroy(self);
        self.* = .{ .a = a, .id = id, .notify = notify };
        self.requested.set(absolute_path);
        self.panel.model.id = id;
        self.panel.model.hooks = hooks.hooks;
        try self.panel.model.open(a, absolute_path);
        errdefer self.panel.deinit(a);
        self.panel.opened = true;
        self.panel.inline_edit = true;
        self.panel.path.set(absolute_path);
        self.panel.path_truncated = absolute_path.len > self.panel.path.buf.len;
        self.reading = try Watch.create(self.panel.model.fd().?, false, self, readable);
        return self;
    }
    pub fn destroy(self: *Document) void {
        self.cancelAutosave();
        if (self.reading) |w| w.cancel();
        if (self.editing) |w| w.cancel();
        if (self.job) |j| j.release();
        self.stopPresentation();
        if (self.draft_watch) |w| w.cancel();
        if (self.draft_job) |j| j.release();
        self.preview.deinit(self.a);
        self.panel.deinit(self.a);
        self.a.destroy(self);
    }
    pub fn absolute(self: *const Document) []const u8 {
        return self.panel.model.path.text();
    }
    pub fn hasUnsaved(self: *const Document) bool {
        if (self.job) |job| if (!job.saving and self.panel.editor == null) return false;
        return self.panel.hasUnsaved();
    }
    pub fn refresh(self: *Document) !void {
        if (self.panel.editor != null or self.job != null) return error.DocumentDraftActive;
        try self.panel.model.refresh();
        self.notify.send(self.id);
    }
    /// Event-driven revalidation for filesystems with unreliable notifications.
    /// The host calls this once on actual focus restoration, never per frame.
    pub fn gainedFocus(self: *Document) !void {
        if (self.checking_disk or self.job != null or self.panel.model.status == .loading) return;
        self.checking_disk = true;
        errdefer self.checking_disk = false;
        try self.panel.model.refresh();
    }
    fn readable(raw: ?*anyopaque) callconv(.c) void {
        const self: *Document = @ptrCast(@alignCast(raw.?));
        self.drain() catch |err| self.panel.notice.set(@errorName(err));
        self.notify.send(self.id);
    }
    pub fn drain(self: *Document) !void {
        while (try self.panel.model.drain(self.a)) {}
        if (self.job) |job| if (job.done.load(.acquire)) edited(self);
        if (self.draft_job) |job| if (job.done.load(.acquire)) drafted(self);
        if (self.checking_disk and self.panel.model.status != .loading) {
            self.checking_disk = false;
            if (self.panel.editor) |editor| {
                if (self.panel.model.status != .ready and self.panel.model.status != .watch_error or !std.mem.eql(u8, self.panel.model.bytes, editor.original.bytes)) {
                    self.panel.notice.set("File changed on disk. Draft kept; reload the disk version before saving again.");
                    self.panel.external_changed = true;
                } else self.panel.external_changed = false;
            }
        }
        // A literal colon-containing filename always wins. Strip a source
        // location only after the original path was explicitly missing.
        if (self.panel.model.status == .missing and self.fallback == null) {
            const original = try path.resolve(self.absolute(), "", "");
            if (path.locationFallback(original)) |location| {
                self.fallback = location;
                if (self.reading) |w| w.cancel();
                self.reading = null;
                try self.panel.model.open(self.a, location.path.text());
                self.reading = try Watch.create(self.panel.model.fd().?, false, self, readable);
                return;
            }
        }
        if (self.panel.editor == null and self.panel.model.revision != self.panel.prepared_revision) {
            if (self.panel.model.takePrepared()) |prepared| {
                self.panel.apply(hooks.take(prepared), self.panel.model.revision);
                self.panel.path.set(self.absolute());
                self.panel.path_truncated = self.absolute().len > self.panel.path.buf.len;
                if (self.fallback) |location| {
                    self.panel.mode = .source;
                    if (self.panel.document()) |doc| {
                        const row = doc.lines[@min(location.line -| 1, doc.lines.len - 1)];
                        self.panel.pending_reveal = row.start + @min(location.column -| 1, row.end - row.start);
                    }
                }
            }
        }
        if (self.panel.inline_edit and !self.inline_attempted and self.panel.model.kind == .markdown and self.panel.model.status == .ready and self.panel.prepared != null and self.panel.editor == null and self.job == null) {
            self.inline_attempted = true;
            try self.startEdit(null);
        }
        try self.noteAutosave();
    }
    pub fn draw(self: *Document, ctx: *ui.Context, rect: ui.Rect) panel.Intent {
        ui.key(ctx, ctx.print("document-{d}", .{self.id}));
        ui.column(ctx, .{ .fixed = true, .absolute = true, .offset = .{ .x = rect.x, .y = rect.y }, .width = .{ .px = rect.w }, .height = .{ .px = rect.h } });
        defer ui.end(ctx);
        self.presented = self.presentation_enabled;
        self.panel.header_leading = if (@import("builtin").os.tag == .macos and rect.x < 80 and rect.y < 12) 78 else 0;
        const original_inset = self.panel.header_inset;
        const split = self.panel.editor != null and self.panel.model.kind == .markdown and self.panel.live_split and rect.w >= 900;
        var source = rect;
        if (split) {
            source.w = (rect.w - 8) / 2;
            self.panel.header_inset = 0;
            self.panel.editor_rendered = false;
        }
        const result = view.draw(&self.panel, ctx, source);
        if (split) {
            // Borrow immutable prepared data only for this synchronous frame.
            // The source panel remains its sole owner across async completions.
            self.preview.prepared = self.panel.prepared;
            defer self.preview.prepared = null;
            self.preview.model.path = self.panel.model.path;
            self.preview.model.kind = .markdown;
            self.preview.model.status = .ready;
            self.preview.inline_edit = true; // Passive preview has no lock UI.
            self.preview.opened = true;
            self.preview.mode = .rendered;
            self.preview.title_override = "Live preview";
            self.preview.header_inset = original_inset;
            const right = ui.Rect{ .x = rect.x + source.w + 8, .y = rect.y, .w = source.w, .h = rect.h };
            // Main and passive panels need distinct widget ownership. Their
            // identical view subtree otherwise overwrites the other's rects.
            ui.key(ctx, "live-preview-host");
            ui.column(ctx, .{ .fixed = true, .absolute = true, .offset = .{ .x = right.x, .y = right.y }, .width = .{ .px = right.w }, .height = .{ .px = right.h } });
            defer ui.end(ctx);
            _ = self.preview.prepareInput(ctx, right);
            const event = view.draw(&self.preview, ctx, right);
            if (event == .close) self.panel.live_split = false;
        } else self.preview.focused = false;
        self.noteDraft() catch |err| self.panel.notice.set(@errorName(err));
        self.noteAutosave() catch |err| self.panel.notice.set(describe(err));
        return result;
    }
    pub fn autosaves(self: *const Document) bool {
        return self.panel.inline_edit and self.panel.model.kind == .markdown;
    }
    fn cancelAutosave(self: *Document) void {
        if (self.autosave_timer) |watch| watch.cancel();
        self.autosave_timer = null;
        self.autosave_revision = null;
    }
    /// Coalesce committed changes into one deadline, independent of visibility.
    /// Preedit never reaches disk; conflicts pause automatic writes until reload.
    pub fn noteAutosave(self: *Document) !void {
        const editor = self.panel.editor orelse return;
        if (!self.autosaves()) return;
        if (!editor.dirty and !self.panel.external_changed and self.panel.autosave_failed) {
            self.panel.autosave_failed = false;
            self.edit_failed = false;
            self.autosave_failed_revision = null;
            self.panel.notice.set("");
        }
        if (!editor.dirty or editor.composition.range != null or self.panel.external_changed) {
            self.cancelAutosave();
            return;
        }
        if (self.job != null or self.autosave_failed_revision == editor.buffer.revision or self.autosave_revision == editor.buffer.revision) return;
        self.cancelAutosave();
        self.autosave_timer = try Watch.timer(autosave_delay_ms, self, autosaveTimer);
        self.autosave_revision = editor.buffer.revision;
    }
    fn autosaveTimer(raw: ?*anyopaque) callconv(.c) void {
        const self: *Document = @ptrCast(@alignCast(raw.?));
        self.cancelAutosave();
        self.flushAutosave() catch |err| {
            // Worker saturation is transient. Other errors wait for another
            // source revision or an explicit retry, avoiding an idle retry loop.
            if (err == error.EditorBusy) {
                self.noteAutosave() catch |timer_error| self.panel.notice.set(describe(timer_error));
            } else {
                self.edit_failed = true;
                self.panel.autosave_failed = true;
                if (self.panel.editor) |editor| self.autosave_failed_revision = editor.buffer.revision;
                self.panel.notice.set(describe(err));
            }
        };
        self.notify.send(self.id);
    }
    /// Closing flushes the newest committed revision and waits for completion.
    /// Hiding or moving a document preserves its pending automatic write.
    pub fn flushAutosave(self: *Document) !void {
        if (!self.autosaves() or self.job != null or self.checking_disk or self.panel.external_changed) return;
        const editor = self.panel.editor orelse return;
        if (!editor.dirty or editor.composition.range != null) return;
        try self.startEdit(editor);
    }
    pub fn stopPresentation(self: *Document) void {
        self.presented = false;
        if (self.draft_timer) |w| w.cancel();
        self.draft_timer = null;
        self.scheduled_revision = null;
    }
    /// Called after committed edits, never parses on the UI thread. Repeated
    /// edits replace one debounce; at most one owned draft snapshot is active.
    pub fn noteDraft(self: *Document) !void {
        const editor = self.panel.editor orelse return;
        if ((self.panel.model.kind != .markdown and self.panel.model.kind != .text) or editor.composition.range != null or !self.presented) return;
        const revision = editor.buffer.revision;
        if (self.draft_revision == revision or self.scheduled_revision == revision or self.draft_job != null) return;
        self.panel.draft_pending = true;
        self.panel.source_index_current = false;
        if (self.draft_timer) |w| w.cancel();
        self.draft_timer = null;
        self.draft_timer = try Watch.timer(120, self, draftTimer);
        self.scheduled_revision = revision;
    }
    fn draftTimer(raw: ?*anyopaque) callconv(.c) void {
        const self: *Document = @ptrCast(@alignCast(raw.?));
        if (self.draft_timer) |w| w.cancel();
        self.draft_timer = null;
        self.scheduled_revision = null;
        if (!self.presented) return;
        self.startDraft() catch |err| {
            self.panel.notice.set(describe(err));
            if (err == error.DraftWorkersBusy) self.noteDraft() catch {};
        };
    }
    pub fn startDraft(self: *Document) !void {
        const editor = self.panel.editor orelse return;
        if (self.draft_job != null or editor.composition.range != null) return;
        const job = try DraftJob.create(self.absolute(), editor.buffer.text, self.panel.model.kind, self.draft_epoch, editor.buffer.revision);
        errdefer job.release();
        const watch = try Watch.create(job.pipe[0], false, self, drafted);
        errdefer watch.cancel();
        try job.launch();
        self.draft_job = job;
        self.draft_watch = watch;
    }
    fn drafted(raw: ?*anyopaque) callconv(.c) void {
        const self: *Document = @ptrCast(@alignCast(raw.?));
        const job = self.draft_job orelse return;
        if (!job.done.load(.acquire)) return;
        if (self.draft_watch) |w| w.cancel();
        self.draft_watch = null;
        self.draft_job = null;
        defer job.release();
        if (self.panel.editor) |editor| if (job.epoch == self.draft_epoch and job.revision == editor.buffer.revision and editor.composition.range == null) {
            if (job.failure) |err| {
                self.panel.notice.set(@errorName(err));
                self.draft_revision = job.revision;
                self.panel.draft_pending = false;
            } else if (job.result) |prepared| {
                const y = self.panel.scroll_y;
                const x = self.panel.scroll_x;
                self.panel.apply(prepared, self.panel.prepared_revision);
                self.panel.scroll_y = y;
                self.panel.scroll_x = x;
                self.preview.layout_width = -1;
                self.preview.search_valid = false;
                self.preview.selection = .{};
                self.preview.match_count = 0;
                self.draft_revision = job.revision;
                self.panel.draft_pending = false;
                job.result = null;
                self.panel.source_index_current = true;
                if (prepared.prepare_error) |err| self.panel.notice.set(@errorName(err));
            }
        };
        self.noteDraft() catch |err| self.panel.notice.set(@errorName(err));
        self.notify.send(self.id);
    }
    /// Execute after the frame. UI callers must re-resolve document ID and
    /// generation before dispatching this; the model never captures widgets.
    pub fn edit(self: *Document) !void {
        const request = self.panel.edit_request;
        self.panel.edit_request = .none;
        if (request == .none) return;
        if (self.job != null) return error.DocumentOperationActive;
        switch (request) {
            .none => unreachable,
            .discard => {
                self.cancelAutosave();
                self.autosave_failed_revision = null;
                self.panel.autosave_failed = false;
                self.edit_failed = false;
                self.draft_epoch +%= 1;
                self.draft_revision = null;
                self.stopPresentation();
                self.panel.clearRich();
                if (self.panel.editor) |e| e.release();
                self.panel.editor = null;
                self.inline_attempted = false;
                self.panel.external_changed = false;
                self.panel.notice.set("");
                self.panel.mode = .rendered;
                try self.refresh();
            },
            .unlock => {
                if (self.panel.editor) |editor| {
                    if (editor.dirty) {
                        self.panel.notice.set("Unsaved changes. Choose Save or Discard before locking or closing.");
                        return;
                    }
                    editor.release();
                    self.panel.editor = null;
                    self.draft_epoch +%= 1;
                    self.draft_revision = null;
                    self.panel.mode = .rendered;
                    try self.refresh();
                    return;
                }
                try self.startEdit(null);
            },
            .save => if (self.panel.editor) |editor| try self.startEdit(editor),
        }
    }
    fn startEdit(self: *Document, editor: ?*@import("runtime/document/editor.zig").Editor) !void {
        const job = try EditJob.create(self.absolute(), editor);
        errdefer job.release();
        const watch = try Watch.create(job.pipe[0], false, self, edited);
        errdefer watch.cancel();
        try job.launch();
        self.job = job;
        self.editing = watch;
        self.panel.edit_busy = true;
        self.edit_failed = false;
        self.panel.autosave_failed = false;
        self.cancelAutosave();
    }
    fn edited(raw: ?*anyopaque) callconv(.c) void {
        const self: *Document = @ptrCast(@alignCast(raw.?));
        const job = self.job orelse return;
        if (!job.done.load(.acquire)) return;
        if (self.editing) |w| w.cancel();
        self.editing = null;
        self.job = null;
        self.panel.edit_busy = false;
        defer job.release();
        if (job.failure) |err| {
            self.edit_failed = true;
            self.panel.autosave_failed = job.saving and self.autosaves();
            if (self.panel.editor) |editor| self.autosave_failed_revision = editor.buffer.revision;
            if (err == error.ConcurrentChange or err == error.FileChangedExternallyReloadFirst or err == error.SavedButFileChangedAgain) self.panel.external_changed = true;
            self.panel.notice.set(describe(err));
        } else if (job.saving) {
            self.autosave_failed_revision = null;
            if (self.panel.editor) |editor| {
                editor.original.deinit();
                editor.original = job.saved.?;
                job.saved = null;
                std.heap.page_allocator.free(editor.baseline);
                editor.baseline = job.baseline.?;
                job.baseline = null;
                editor.update();
            }
            self.panel.external_changed = false;
            self.panel.notice.set(if (job.directory_synced) (if (self.panel.inline_edit) "" else "Saved") else "Saved; directory durability was not confirmed.");
        } else {
            self.panel.editor = job.editor;
            job.editor = null;
            self.panel.focused = true;
            self.panel.field = .body;
            self.panel.editor_rendered = self.panel.inline_edit and self.panel.model.kind == .markdown;
            if (self.panel.editor_rendered) self.panel.editor.?.focus = false;
            self.draft_epoch +%= 1;
            self.draft_revision = null;
            self.noteDraft() catch |err| self.panel.notice.set(@errorName(err));
        }
        self.noteAutosave() catch |err| self.panel.notice.set(describe(err));
        self.notify.send(self.id);
    }
    /// Explicit Discard from the close confirmation, never an implicit blur.
    pub fn discardDraft(self: *Document) void {
        self.cancelAutosave();
        self.draft_epoch +%= 1;
        self.stopPresentation();
        self.panel.clearRich();
        if (self.panel.editor) |editor| editor.release();
        self.panel.editor = null;
    }
};
/// Dynamic document ownership. The host decides workspace/side placement.
pub const Collection = struct {
    documents: std.ArrayList(*Document) = .empty,
    active: u64 = 0,
    visible: bool = false,
    tab_scroll: f32 = 0,
    pub const Event = struct { id: u64, generation: u64, intent: panel.Intent, text: []const u8 = "", select: u64 = 0 };
    /// One header for current-document controls and horizontally scrolling tabs.
    /// The host copies Event.text when enqueueing and validates IDs/generation.
    pub fn draw(self: *Collection, ctx: *ui.Context, rect: ui.Rect) ?Event {
        const document = self.selected() orelse return null;
        const p = &document.panel;
        p.embedded_header = self.documents.items.len > 1;
        const intent = document.draw(ctx, rect);
        var result: ?Event = if (intent != .none or p.edit_request != .none) .{ .id = document.id, .generation = p.model.generation, .intent = intent, .text = switch (intent) {
            .open_path => p.path.text(),
            .link => p.link_target.text(),
            else => "",
        } } else null;
        if (self.documents.items.len > 1) {
            const effective_width = if (p.editor != null and p.live_split and rect.w >= 900) (rect.w - 8) / 2 else rect.w;
            const width = @max(28, effective_width - 176 - p.header_inset - p.header_leading);
            const tab_rect: ui.Rect = .{ .x = rect.x + 8 + p.header_leading, .y = rect.y, .w = width, .h = 44 };
            const full = @as(f32, @floatFromInt(self.documents.items.len)) * 152;
            if (tab_rect.contains(ctx.input.mouse)) self.tab_scroll = std.math.clamp(self.tab_scroll - ctx.input.scroll.x - ctx.input.scroll.y, 0, @max(0, full - width));
            ui.key(ctx, "document-tabs");
            ui.row(ctx, .{ .absolute = true, .fixed = true, .offset = .{ .x = tab_rect.x, .y = tab_rect.y }, .width = .{ .px = width }, .height = .{ .px = 44 }, .clip = true, .align_items = .center });
            ui.row(ctx, .{ .absolute = true, .offset = .{ .x = -self.tab_scroll }, .height = .{ .px = 44 }, .gap = 4, .align_items = .center });
            for (self.documents.items) |entry| {
                ui.key(ctx, ctx.print("document-tab-{d}", .{entry.id}));
                const label = @import("runtime/document/chrome.zig").ellipsize(ctx, std.fs.path.basename(entry.absolute()), 124, 11);
                if (ui.button(ctx, label, .{ .width = .{ .px = 148 }, .size = 11, .variant = if (entry.id == self.active) .secondary else .ghost }).clicked) result = .{ .id = document.id, .generation = p.model.generation, .intent = .none, .select = entry.id };
            }
            ui.end(ctx);
            ui.end(ctx);
        }
        return result;
    }
    pub fn get(self: *const Collection, id: u64) ?*Document {
        for (self.documents.items) |d| if (d.id == id) return d;
        return null;
    }
    pub fn selected(self: *const Collection) ?*Document {
        return self.get(self.active);
    }
    pub fn find(self: *const Collection, absolute: []const u8) ?*Document {
        for (self.documents.items) |d| if (std.mem.eql(u8, d.absolute(), absolute) or std.mem.eql(u8, d.requested.text(), absolute)) return d;
        return null;
    }
    pub fn open(self: *Collection, a: A, id: u64, absolute: []const u8, notify: Notify) !*Document {
        if (self.find(absolute)) |existing| {
            self.active = existing.id;
            self.visible = true;
            return existing;
        }
        try self.documents.ensureUnusedCapacity(a, 1);
        const document = try Document.create(a, id, absolute, notify);
        self.documents.appendAssumeCapacity(document);
        self.active = id;
        self.visible = true;
        return document;
    }
    pub fn hasUnsaved(self: *const Collection) bool {
        for (self.documents.items) |d| if (d.hasUnsaved()) return true;
        return false;
    }
    pub fn close(self: *Collection, id: u64) !void {
        for (self.documents.items, 0..) |d, i| if (d.id == id) {
            if (d.hasUnsaved()) {
                d.panel.notice.set(describe(error.UnsavedDocumentChooseSaveOrDiscard));
                return error.UnsavedDocumentChooseSaveOrDiscard;
            }
            _ = self.documents.orderedRemove(i);
            d.destroy();
            if (self.active == id) self.active = if (self.documents.items.len > 0) self.documents.items[@min(i, self.documents.items.len - 1)].id else 0;
            if (self.active == 0) self.visible = false;
            return;
        };
    }
    /// Move reading state and drafts transactionally. Reserve destination
    /// capacity before detaching; document ID/generation and workers survive.
    pub fn moveTo(self: *Collection, a: A, destination: *Collection, id: u64) !void {
        if (self == destination) return;
        const document = self.get(id) orelse return error.DocumentClosed;
        if (destination.find(document.absolute()) != null) return error.DocumentAlreadyOpen;
        try destination.documents.ensureUnusedCapacity(a, 1);
        for (self.documents.items, 0..) |entry, index| if (entry == document) {
            _ = self.documents.orderedRemove(index);
            destination.documents.appendAssumeCapacity(document);
            destination.active = id;
            destination.visible = true;
            if (self.active == id) self.active = if (self.documents.items.len > 0) self.documents.items[@min(index, self.documents.items.len - 1)].id else 0;
            if (self.active == 0) self.visible = false;
            return;
        };
    }
    pub fn deinit(self: *Collection, a: A) void {
        for (self.documents.items) |d| d.destroy();
        self.documents.deinit(a);
        self.* = .{};
    }
};
