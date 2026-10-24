//! Virtualized local Git/SVN changes. Text stays selectable; edits use owned actions.
const std = @import("std");
const ui = @import("nanoui").ui;
const L = @import("localized.zig");
const C = @import("presentation.zig");
const vcs = @import("vcs.zig");
const git = vcs.git;
const diff = @import("diff.zig");
const syntax = @import("syntax.zig");
const A = std.mem.Allocator;
pub const Event = union(enum) { refresh, close, context: u32, base: git.Base, select: []const u8, open: []const u8, edit: []const u8, revert_hunk: usize };
pub const View = struct {
    model: diff.Model = .{},
    search: diff.Search = .{},
    query: ui.TextBuffer = .{},
    line_states: std.ArrayList(syntax.State) = .empty,
    language: syntax.Language = .plain,
    model_error: []const u8 = "",
    pending: ?Event = null,
    hunk_actions: bool = false,
    kept: std.AutoHashMapUnmanaged(u64, void) = .empty,
    kept_path: []const u8 = "",
    allocator: A = std.heap.smp_allocator,
    header_rect: ui.Rect = .{},
    find_open: bool = false,
    selected_collapsed: bool = false,
    split_override: ?bool = null,
    pub fn deinit(self: *View, a: A) void {
        self.model.deinit(a);
        self.search.deinit(a);
        self.line_states.deinit(a);
        self.kept.deinit(a);
        a.free(self.kept_path);
    }
    pub fn draw(self: *View, ctx: *ui.Context, a: A, state: *vcs.State, bounds: ui.Rect, layout: []const u8, allow_hunks: bool) !?Event {
        self.allocator = a;
        self.pending = null;
        self.hunk_actions = allow_hunks and state.backend == .git and state.base() == .turn;
        if (!std.mem.eql(u8, self.kept_path, state.selected())) {
            const owned = try a.dupe(u8, state.selected());
            a.free(self.kept_path);
            self.kept_path = owned;
            self.kept.clearRetainingCapacity();
            self.selected_collapsed = false;
        }
        const height = bounds.h;
        const reload = self.model.version != state.patchVersion();
        if (reload) self.model_error = "";
        self.model.load(a, state.patch(), state.patchVersion()) catch |err| {
            if (err != error.DiffLineLimit) return err;
            try self.model.load(a, "", state.patchVersion());
            self.model_error = "Diff exceeds the 100000-line preview limit. Open the file externally.";
        };
        if (reload) {
            self.language = syntax.language(state.selected());
            self.line_states.clearRetainingCapacity();
            var old_state: syntax.State = .{};
            var new_state: syntax.State = .{};
            var sink: [0]syntax.Token = .{};
            for (self.model.lines.items) |line| {
                try self.line_states.append(a, if (line.kind == .removed) old_state else new_state);
                if (line.kind == .removed or line.kind == .context) _ = syntax.scan(&old_state, self.language, line.text, &sink);
                if (line.kind == .added or line.kind == .context) _ = syntax.scan(&new_state, self.language, line.text, &sink);
                if (line.kind == .meta and std.mem.startsWith(u8, line.text, "@@")) {
                    old_state = .{};
                    new_state = .{};
                }
            }
            try self.search.find(a, self.model.lines.items, self.query.text());
        }
        ui.column(ctx, .{ .absolute = true, .offset = .{ .x = bounds.x, .y = bounds.y }, .width = .{ .px = bounds.w }, .height = .{ .px = height }, .background = C.card(ctx), .radius = 14, .border = C.edge(ctx), .shadow = .{ .color = C.shadow(ctx), .blur = 6, .y = 2 }, .clip = true });
        defer ui.end(ctx);
        const header = ctx.open(.{ .direction = .row, .width = .fill, .height = .{ .px = 44 }, .padding = .{ .left = 16, .right = if (@import("builtin").os.tag == .macos) 10 else 104 }, .gap = 8, .align_items = .center }, "changes-header");
        self.header_rect = ctx.rects.get(ctx.node(header).id) orelse .{};
        C.icon(ctx, .diff, 14);
        L.text(ctx, "Changes", .{ .weight = .semibold, .size = 14 });
        if (bounds.w > 390 and state.root().len > 0) ui.text(ctx, C.ellipsize(ctx, safe(ctx, state.root()), @max(0, bounds.w - 230), 13), .{ .size = 13, .color = C.faint(ctx) });
        ui.spacer(ctx);
        const refresh = C.button(ctx, .reset, "Refresh changes", 28);
        const close = C.button(ctx, .close, "Close changes", 28);
        ui.end(ctx);
        if (close) return .close;
        if (refresh) return .refresh;
        ui.column(ctx, .{ .width = .fill, .height = .fill, .grow = 1 });
        defer ui.end(ctx);
        if (self.model_error.len > 0) L.text(ctx, self.model_error, .{ .size = 12, .wrap = true, .color = ctx.theme.muted });
        if (state.message().len > 0) ui.text(ctx, safe(ctx, state.message()), .{ .size = 12, .wrap = true, .color = ui.Color.hex(0xd93a35) });
        if (state.backend == .git) {
            ui.row(ctx, .{ .width = .fill, .height = .{ .px = 34 }, .padding = .xy(12, 0), .align_items = .center });
            ui.row(ctx, .{ .height = .{ .px = 24 }, .padding = .all(2), .gap = 2, .radius = 7, .background = ctx.theme.text.alpha(0.06), .align_items = .center });
            var base: ?git.Base = null;
            inline for (.{ git.Base.head, git.Base.branch, git.Base.turn }) |value| if (state.supportsBase(value)) {
                if (C.textControl(ctx, switch (value) {
                    .head => "Uncommitted",
                    .branch => "Branch",
                    .turn => "Agent turn",
                }, state.base() == value)) base = value;
            };
            ui.end(ctx);
            ui.end(ctx);
            if (base) |value| return .{ .base = value };
        } else if (state.backend == .svn) L.text(ctx, "SVN Working Copy Changes", .{ .size = 12, .weight = .medium });
        const files = state.files();
        var added: usize = 0;
        var removed: usize = 0;
        for (files) |file| {
            added +|= file.added;
            removed +|= file.removed;
        }
        ui.row(ctx, .{ .width = .fill, .height = .{ .px = 34 }, .padding = .xy(12, 0), .gap = 8, .align_items = .center });
        ui.text(ctx, ctx.print("{d} {s}", .{ files.len, @import("locale.zig").t(if (files.len == 1) "file" else "files") }), .{ .size = 13, .color = ctx.theme.muted });
        if (added > 0) ui.text(ctx, ctx.print("+{d}", .{added}), .{ .size = 12.5, .color = .hex(if (ctx.theme.dark) 0x88e3a2 else 0x22863a) });
        if (removed > 0) ui.text(ctx, ctx.print("−{d}", .{removed}), .{ .size = 12.5, .color = .hex(if (ctx.theme.dark) 0xff8585 else 0xd93a35) });
        ui.spacer(ctx);
        if (state.busy()) ui.text(ctx, "…", .{ .size = 12, .color = ctx.theme.muted });
        if (C.button(ctx, .search, "Find in diff…", 24)) self.find_open = !self.find_open;
        const automatic_split = std.mem.eql(u8, layout, "split") or (std.mem.eql(u8, layout, "auto") and bounds.w >= 740);
        const split = self.split_override orelse automatic_split;
        if (C.button(ctx, if (split) .split_down else .split_right, if (split) "Unified" else "Split", 24)) self.split_override = !split;
        ui.end(ctx);
        var search_changed = false;
        if (self.find_open or self.query.len > 0) {
            ui.row(ctx, .{ .width = .fill, .height = .{ .px = 30 }, .padding = .xy(12, 0), .gap = 4, .align_items = .center });
            C.icon(ctx, .search, 14);
            ui.key(ctx, "diff-query");
            const field = L.field(ctx, &self.query, .{ .placeholder = "Find in diff…", .width = .fill, .size = 12, .bare = true });
            search_changed = field.changed;
            if (field.changed) try self.search.find(a, self.model.lines.items, self.query.text());
            const previous = C.button(ctx, .up, "Previous diff match", 24);
            const next = C.button(ctx, .down, "Next diff match", 24);
            if (previous or next or field.submitted) {
                self.search.next(previous or (field.submitted and ctx.input.shift));
                search_changed = true;
            }
            ui.text(ctx, ctx.print("{d}/{d}{s}", .{ if (self.search.matches.items.len > 0) self.search.selected + 1 else 0, self.search.matches.items.len, if (self.search.limited) "+" else "" }), .{ .size = 11 });
            if (C.button(ctx, .close, "Close diff find", 24)) {
                self.find_open = false;
                self.query.clear();
                try self.search.find(a, self.model.lines.items, "");
            }
            ui.end(ctx);
        }
        var shown: std.ArrayList(usize) = .empty;
        if (split) {
            for (self.model.pairs.items, 0..) |pair, index| {
                const line = self.model.lines.items[pair.left orelse pair.right orelse continue];
                if (!self.hiddenMeta(line)) try shown.append(ctx.alloc(), index);
            }
        } else for (self.model.lines.items, 0..) |line, index| if (!self.hiddenMeta(line)) {
            try shown.append(ctx.alloc(), index);
        };
        ui.key(ctx, "patch");
        const patch_node = ctx.open(.{ .scroll = true, .width = .fill, .height = .fill, .grow = 1, .selectable = true, .clip = true, .background = C.card(ctx) }, null);
        defer ui.end(ctx);
        const scroll_id = ctx.node(patch_node).id;
        var scroll = ctx.scroll.get(scroll_id) orelse 0;
        var selected_top: f32 = 0;
        for (files) |file| {
            if (std.mem.eql(u8, file.path, state.selected())) break;
            selected_top += 32;
        }
        if (search_changed and self.search.matches.items.len > 0) {
            const target = self.search.matches.items[self.search.selected].line;
            for (shown.items, 0..) |index, row| {
                const matches = if (split) self.model.pairs.items[index].left == target or self.model.pairs.items[index].right == target else index == target;
                if (matches) {
                    scroll = selected_top + 32 + @as(f32, @floatFromInt(row)) * 19;
                    try ctx.scroll.put(ctx.gpa, scroll_id, scroll);
                    break;
                }
            }
        }
        const viewport = (ctx.rects.get(scroll_id) orelse ui.Rect{ .h = height - 112 }).h;
        var y: f32 = 0;
        var skipped: f32 = 0;
        var event: ?Event = null;
        for (files) |file| {
            const selected = std.mem.eql(u8, file.path, state.selected());
            const expanded = selected and !self.selected_collapsed;
            const patch_height = if (expanded) @as(f32, @floatFromInt(shown.items.len)) * 19 + 26 else 0;
            const item_height = 32 + patch_height;
            if (y + item_height < scroll or y > scroll + viewport + 64) {
                skipped += item_height;
                y += item_height;
                continue;
            }
            if (skipped > 0) {
                pixelSpacer(ctx, skipped);
                skipped = 0;
            }
            ui.key(ctx, file.path);
            // Consume the path key above. A constant explicit key would
            // override it and give every file header the same hit target.
            const header_node = ctx.open(.{ .direction = .row, .width = .fill, .height = .{ .px = 32 }, .padding = .{ .left = 12, .right = 10 }, .gap = 8, .align_items = .center, .background = ctx.theme.text.alpha(0.045), .control = true }, null);
            const hit = ctx.interact(header_node, .{});
            C.icon(ctx, if (expanded) .down else .right, 12);
            const status_color = ui.Color.hex(if (std.mem.eql(u8, file.status, "deleted")) 0xd93a35 else if (std.mem.eql(u8, file.status, "added") or std.mem.eql(u8, file.status, "untracked")) 0x22863a else 0xb58900);
            ui.column(ctx, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .radius = 5, .background = status_color.alpha(0.13), .align_items = .center, .justify = .center });
            const letter: u8 = if (file.status.len > 0) std.ascii.toUpper(file.status[0]) else 'M';
            ui.text(ctx, ctx.print("{c}", .{letter}), .{ .size = 11, .weight = .semibold, .color = status_color });
            ui.end(ctx);
            ui.text(ctx, C.ellipsize(ctx, safe(ctx, std.fs.path.basename(file.path)), @max(60, bounds.w - 180), 13), .{ .size = 13, .weight = .semibold });
            if (state.backend == .svn) {
                if (std.mem.eql(u8, file.property_status, "modified") or std.mem.eql(u8, file.property_status, "conflicted")) ui.text(ctx, "properties", .{ .size = 11, .color = C.faint(ctx) });
                if (file.tree_conflicted) ui.text(ctx, "tree conflict", .{ .size = 11, .color = .hex(0xd93a35) });
                if (file.copied) ui.text(ctx, "copied", .{ .size = 11, .color = C.faint(ctx) });
            }
            if (bounds.w > 400) if (std.fs.path.dirname(file.path)) |dir| ui.text(ctx, C.ellipsize(ctx, safe(ctx, dir), @max(40, bounds.w / 3 - 60), 12.5), .{ .size = 12.5, .color = C.faint(ctx) });
            ui.spacer(ctx);
            if (file.added > 0) ui.text(ctx, ctx.print("+{d}", .{file.added}), .{ .size = 12, .color = .hex(0x22863a) });
            if (file.removed > 0) ui.text(ctx, ctx.print("−{d}", .{file.removed}), .{ .size = 12, .color = .hex(0xd93a35) });
            const open = state.canOpen(file.path) and C.button(ctx, .external, "Open file", 24);
            const edit = state.canOpen(file.path) and C.button(ctx, .code, "Edit file", 24);
            ui.end(ctx);
            if (open) event = .{ .open = file.path } else if (edit) event = .{ .edit = file.path } else if (hit.clicked) {
                ctx.changed = true;
                if (selected) self.selected_collapsed = !self.selected_collapsed else event = .{ .select = file.path };
            }
            y += 32;
            if (expanded) {
                const start = @min(shown.items.len, @as(usize, @intFromFloat(@floor(@max(0, scroll - y) / 19))));
                const end = @min(shown.items.len, start + @as(usize, @intFromFloat(@ceil(@max(0, viewport) / 19))) + 6);
                spacer(ctx, start, 19);
                for (shown.items[start..end]) |index| self.patchRow(ctx, index, split);
                spacer(ctx, shown.items.len - end, 19);
                ui.row(ctx, .{ .width = .fill, .height = .{ .px = 26 }, .padding = .xy(12, 0), .gap = 4, .align_items = .center });
                if (!state.busy()) {
                    if (state.contextLines() < 100000 and C.textControl(ctx, "More context", false)) event = .{ .context = @min(100000, state.contextLines() + 20) };
                    if (state.contextLines() < 100000 and C.textControl(ctx, "All context", false)) event = .{ .context = 100000 };
                    if (state.contextLines() != 3 and C.textControl(ctx, "Collapse context", false)) event = .{ .context = 3 };
                }
                ui.end(ctx);
                y += patch_height;
            }
        }
        if (skipped > 0) pixelSpacer(ctx, skipped);
        if (files.len == 0 and !state.busy()) L.text(ctx, "No changes", .{ .size = 13, .color = C.faint(ctx) });
        return event orelse self.pending;
    }
    fn hiddenMeta(self: *View, line: diff.Line) bool {
        if (line.kind != .meta) return false;
        if (std.mem.startsWith(u8, line.text, "@@ -")) return !self.hunk_actions;
        for ([_][]const u8{ "diff --git ", "index ", "--- ", "+++ ", "Index: ", "====" }) |prefix| if (std.mem.startsWith(u8, line.text, prefix)) return true;
        return line.text.len == 0;
    }
    fn patchRow(self: *View, ctx: *ui.Context, index: usize, split: bool) void {
        ui.key(ctx, ctx.print("diff-row-{d}", .{index}));
        if (!split) {
            self.drawLine(ctx, index, 19, .fill, false);
            return;
        }
        const pair = self.model.pairs.items[index];
        if (pair.left) |left| if (self.model.lines.items[left].kind == .meta) {
            self.drawLine(ctx, left, 19, .fill, true);
            return;
        };
        ui.row(ctx, .{ .width = .fill, .height = .{ .px = 19 }, .gap = 1 });
        inline for (.{ true, false }) |left| {
            ui.column(ctx, .{ .width = .fill, .grow = 1, .height = .{ .px = 19 }, .clip = true });
            if (if (left) pair.left else pair.right) |item| self.drawLine(ctx, item, 19, .fill, left);
            ui.end(ctx);
        }
        ui.end(ctx);
    }
    fn drawLine(self: *View, ctx: *ui.Context, index: usize, height: f32, width: ui.Length, old_side: bool) void {
        const line = self.model.lines.items[index];
        if (line.kind == .meta and std.mem.startsWith(u8, line.text, "@@ -") and self.hunk_actions) {
            const offset = @intFromPtr(line.text.ptr) - @intFromPtr(self.model.source.ptr);
            const end = if (std.mem.indexOf(u8, self.model.source[offset + 1 ..], "\n@@ -")) |at| offset + 1 + at else self.model.source.len;
            const key = std.hash.Wyhash.hash(std.hash.Wyhash.hash(0, self.kept_path), self.model.source[offset..end]);
            ui.row(ctx, .{ .width = width, .height = .{ .px = height }, .gap = 6, .background = ctx.theme.surface });
            defer ui.end(ctx);
            ui.text(ctx, safe(ctx, line.text), .{ .mono = true, .size = 11 });
            ui.spacer(ctx);
            if (self.kept.contains(key)) L.text(ctx, "Kept", .{ .size = 11 }) else {
                if (hunkButton(ctx, "Revert hunk")) self.pending = .{ .revert_hunk = offset };
                if (hunkButton(ctx, "Keep") and self.kept.count() < 8192) self.kept.put(self.allocator, key, {}) catch {};
            }
            return;
        }
        const fg = ctx.theme.text;
        const bg = if (line.kind == .removed) ui.Color.hex(0xd93a35).alpha(0.1) else if (line.kind == .added) ui.Color.hex(0x22863a).alpha(0.1) else C.card(ctx);
        ui.row(ctx, .{ .width = width, .height = .{ .px = height }, .gap = 6, .background = bg, .clip = true });
        ui.column(ctx, .{ .width = .{ .px = 42 }, .height = .{ .px = height } });
        const number = if (old_side) line.old else line.new orelse line.old;
        ui.text(ctx, ctx.print("{s: >4}", .{if (number) |n| ctx.print("{d}", .{n}) else ""}), .{ .mono = true, .size = 11, .color = ctx.theme.muted });
        ui.end(ctx);
        const text = safe(ctx, line.text);
        var tokens: [128]syntax.Token = undefined;
        var spans: [256]ui.Span = undefined;
        var count: usize = 0;
        if (std.mem.eql(u8, text, line.text[0..@min(text.len, line.text.len)])) {
            var state_ = self.line_states.items[index];
            for (syntax.scan(&state_, if (line.kind == .meta) .plain else self.language, text, &tokens)) |token| {
                spans[count] = .{ .start = token.start, .end = token.end, .color = switch (token.kind) {
                    .keyword => ui.Color.hex(if (ctx.theme.dark) 0xc7a4ff else 0x7040a0),
                    .string => ui.Color.hex(if (ctx.theme.dark) 0x9ad89b else 0x256c36),
                    .comment => ctx.theme.muted,
                    .number => ui.Color.hex(if (ctx.theme.dark) 0xffc078 else 0x985600),
                } };
                count += 1;
            }
            for (self.search.matches.items, 0..) |match, n| if (match.line == index and match.end <= text.len and count < spans.len) {
                spans[count] = .{ .start = @intCast(match.start), .end = @intCast(match.end), .background = ui.Color.hex(0xe6ad30).alpha(if (n == self.search.selected) 0.7 else 0.3), .color = if (n == self.search.selected) ui.Color.black else null };
                count += 1;
            };
        }
        ui.richText(ctx, text, orderedSpans(ctx, spans[0..count], @intCast(text.len)), .{ .mono = true, .size = 12, .color = fg });
        ui.end(ctx);
    }
};
const Range = struct { start: usize, end: usize };
fn visible(ctx: *ui.Context, node: u32, length: usize, row: f32, fallback: f32) Range {
    const id = ctx.node(node).id;
    const offset = ctx.scroll.get(id) orelse 0;
    const bounds = ctx.rects.get(id);
    const start = @min(length, @as(usize, @intFromFloat(@max(0, @floor(offset / row)))));
    return .{ .start = start, .end = @min(length, start + @as(usize, @intFromFloat(@ceil((if (bounds) |r| r.h else fallback) / row))) + 4) };
}
fn spacer(ctx: *ui.Context, count: usize, height: f32) void {
    if (count > 0) _ = ctx.leaf(.{ .width = .fill, .height = .{ .px = @as(f32, @floatFromInt(count)) * height } }, .none, null);
}
pub fn safe(ctx: *ui.Context, bytes: []const u8) []const u8 {
    var length = @min(bytes.len, 2048);
    while (length > 0 and !std.unicode.utf8ValidateSlice(bytes[0..length])) : (length -= 1) {
        if (bytes.len - length > 4) break;
    }
    if (std.unicode.utf8ValidateSlice(bytes[0..length]) and std.mem.indexOfAny(u8, bytes[0..length], "\x00\r\n\t") == null) return ctx.alloc().dupe(u8, bytes[0..length]) catch "";
    var out: std.ArrayList(u8) = .empty;
    for (bytes[0..@min(bytes.len, 2048)]) |byte| out.appendSlice(ctx.alloc(), switch (byte) {
        '\n' => "\\n",
        '\r' => "\\r",
        '\t' => "\\t",
        0 => "\\0",
        else => if (byte >= 32 and byte < 127) &.{byte} else "?",
    }) catch return "";
    return out.items;
}

fn hunkButton(ctx: *ui.Context, label: []const u8) bool {
    const node = ctx.open(.{ .height = .{ .px = 19 }, .padding = .xy(6, 1), .radius = 4, .control = true }, label);
    defer ui.end(ctx);
    const hit = ctx.interact(node, .{});
    if (hit.hovered) ctx.node(node).style.background = ctx.theme.surface_hover;
    L.text(ctx, label, .{ .size = 11 });
    return hit.clicked;
}

// nanoui expects sorted, disjoint ranges. Compose search backgrounds with
// lexical colors before handing them to the framework.
fn orderedSpans(ctx: *ui.Context, input: []const ui.Span, length: u32) []const ui.Span {
    var edges: [514]u32 = undefined;
    var count: usize = 2;
    edges[0] = 0;
    edges[1] = length;
    for (input) |span| {
        edges[count] = span.start;
        edges[count + 1] = span.end;
        count += 2;
    }
    std.mem.sort(u32, edges[0..count], {}, std.sort.asc(u32));
    var result: std.ArrayList(ui.Span) = .empty;
    for (1..count) |i| {
        const start = edges[i - 1];
        const end = edges[i];
        if (start == end) continue;
        var span: ui.Span = .{ .start = start, .end = end };
        for (input) |source| if (source.start <= start and source.end >= end) {
            if (source.color) |value| span.color = value;
            if (source.background) |value| span.background = value;
        };
        if (span.color != null or span.background != null) result.append(ctx.alloc(), span) catch return &.{};
    }
    return result.items;
}

fn pixelSpacer(ctx: *ui.Context, height: f32) void {
    if (height > 0) _ = ctx.leaf(.{ .width = .fill, .height = .{ .px = height } }, .none, null);
}
