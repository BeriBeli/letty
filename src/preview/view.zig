//! Native read-only document view: bounded visible rows, owned absolute byte
//! selection, and explicit intents. Never reads a file or mutates a source.
const flow_render = @import("flowchart_render.zig");
const inline_math = @import("math_inline.zig");
const std = @import("std");
const ui = @import("nanoui").ui;
const chrome = @import("../chrome.zig");
pub const header_height: f32 = 36;
const md_render = @import("markdown_render.zig");
pub const Intent = enum { none, close, refresh, open_file, open_path, external, link };
const size: f32 = 14;
const pad: f32 = 8;
const gap: f32 = 6;
const path_row: f32 = 28;
const action_row: f32 = 30;
const note_row: f32 = 28;
const actions = [_][]const u8{ "Copy", "Copy Path", "Refresh", "External" };
fn control(p: anytype, ctx: *ui.Context, kind: @import("panel.zig").Control, label: []const u8, options: ui.ButtonOptions) bool {
    const enabled = if (@hasField(@TypeOf(options), "disabled")) !options.disabled else true;
    const selected = switch (kind) {
        .rendered, .source, .fit, .actual => options.variant == .primary,
        .find => p.show_find,
        else => false,
    };
    if (p.ax_count < p.ax_controls.len) {
        p.ax_controls[p.ax_count] = .{ .widget = ctx.peekId(null), .control = kind, .label = label, .enabled = enabled, .selected = selected };
        p.ax_count += 1;
    }
    return chrome.button(ctx, label, options).clicked;
}
fn buttonWidth(ctx: *ui.Context, label: []const u8) f32 {
    // ui.button pads by its font size on each side; +2 absorbs weight/rounding.
    return @ceil(ctx.text.layout(label, .{ .size = 10 }).width) + 22;
}
fn iconControl(p: anytype, ctx: *ui.Context, kind: @import("panel.zig").Control, label: []const u8, icon: chrome.Icon, selected: bool, disabled: bool) bool {
    ui.key(ctx, label);
    const id = ctx.peekId(null);
    if (p.ax_count < p.ax_controls.len) {
        p.ax_controls[p.ax_count] = .{ .widget = id, .control = kind, .label = label, .enabled = !disabled, .selected = selected };
        p.ax_count += 1;
    }
    const it = chrome.iconControl(ctx, icon, 28, selected, disabled);
    return it.clicked;
}
fn leadWidth(p: anytype, ctx: *ui.Context) f32 {
    return if (p.model.kind == .image) buttonWidth(ctx, "Fit") + buttonWidth(ctx, "Actual") + buttonWidth(ctx, "−") + buttonWidth(ctx, "+") + 16 + ctx.text.layout("0000×0000", .{ .size = 10 }).width + 4 else 0;
}
/// Row of each toolbar action; row 0 is shared with the mode controls.
pub const Plan = struct { rows: [actions.len]u8 = @splat(0), count: u8 = 1 };
pub fn plan(p: anytype, ctx: *ui.Context, width: f32) Plan {
    const available = width - pad * 2;
    const lead = leadWidth(p, ctx);
    var total = lead;
    for (actions) |label| total += 4 + buttonWidth(ctx, label);
    if (total <= available) return .{};
    var out: Plan = .{};
    var row: u8 = if (lead > 0) 1 else 0;
    var used: f32 = 0;
    for (actions, 0..) |label, index| {
        const w = buttonWidth(ctx, label);
        if (used > 0 and used + 4 + w > available) {
            row += 1;
            used = 0;
        }
        used += (if (used > 0) @as(f32, 4) else 0) + w;
        out.rows[index] = row;
    }
    out.count = row + 1;
    return out;
}
/// Exact sum of the fixed-height toolbar rows, so paint and hit testing share
/// one body rectangle at every width.
pub fn toolbarHeight(p: anytype, ctx: *ui.Context, width: f32) f32 {
    var y = pad + header_height + gap;
    if (p.show_actions or p.focus_path) {
        y += path_row + gap;
        if (p.path_truncated) y += note_row + gap;
        y += @as(f32, @floatFromInt(plan(p, ctx, width).count)) * (action_row + gap);
    }
    if (p.show_find) y += action_row + gap;
    if (p.notice.len > 0) y += 32 + gap;
    return y;
}
pub fn draw(p: anytype, ctx: *ui.Context, rect: ui.Rect) Intent {
    if (!p.opened or rect.w <= 0 or rect.h <= 0) return .none;
    p.rect = rect;
    ctx.wants_wheel = true;
    p.ax_count = 0;
    p.ax_path = 0;
    p.ax_copy = 0;
    p.ax_refresh = 0;
    if (p.focus_path) p.show_actions = true;
    p.ax_results = 0;
    p.ax_status = 0;
    p.ax_readonly = 0;
    p.ax_query = 0;
    p.ax_body = 0;
    var intent: Intent = .none;
    if (p.focused and p.field != .body and p.key_frame != ctx.frame and ctx.input.key == .escape) {
        p.key_frame = ctx.frame;
        if (!composing(ctx)) {
            p.show_find = false;
            p.field = .body;
            ctx.focus = 0;
            ctx.changed = true;
        }
        // Native text input cancels composition; synthetic Escape must never
        // make the single-line widget blur an active marked range.
        ctx.input.key = null;
    }
    ui.key(ctx, "document-preview");
    ui.column(ctx, .{ .absolute = true, .offset = .{ .x = rect.x, .y = rect.y }, .width = .{ .px = rect.w }, .height = .{ .px = rect.h }, .padding = .all(pad), .gap = gap, .clip = true, .background = ctx.theme.surface });
    defer ui.end(ctx);
    const busy = composing(ctx) or p.edit_busy;
    ui.row(ctx, .{ .width = .fill, .height = .{ .px = header_height }, .gap = 4, .align_items = .center });
    if (!p.embedded_header) {
        chrome.icon(ctx, .document, 16);
        const name = std.fs.path.basename(p.model.path.text());
        ui.text(ctx, chrome.ellipsize(ctx, if (name.len > 0) name else "Document", @max(1, rect.w - 148), 12), .{ .size = 12, .weight = .medium });
    }
    ui.spacer(ctx);
    if (p.editor == null and p.model.kind == .markdown and iconControl(p, ctx, .toggle_source, "Source view", .code, p.mode == .source, busy or (p.mode == .source and (p.prepared == null or p.prepared.?.markdown == null)))) setMode(p, ctx, if (p.mode == .source) .rendered else .source);
    if (p.editor == null and iconControl(p, ctx, .find, "Find in document", .search, p.show_find, busy)) {
        p.show_find = true;
        p.focus_query = true;
        p.field = .query;
    }
    if (iconControl(p, ctx, .more, "More document actions", .more, p.show_actions, busy)) toggleActions(p, ctx);
    ui.end(ctx);
    chrome.box(ctx, 0, pad + header_height, rect.w - pad * 2, 1, ctx.theme.border);
    if (p.show_actions) {
        ui.row(ctx, .{ .width = .fill, .height = .{ .px = path_row }, .gap = 4, .align_items = .center });
        ui.key(ctx, "preview-open-path");
        if (p.focus_path) {
            ctx.focus = ctx.peekId(null);
            p.focus_path = false;
        }
        p.ax_path = ctx.peekId(null);
        const path_field = ui.textField(ctx, &p.path, .{ .width = .fill, .size = 11, .placeholder = "Local file path" });
        if (path_field.focused) p.field = .path;
        if (path_field.changed) p.path_truncated = false;
        const open_clicked = control(p, ctx, .open, "Open", .{ .size = 11, .disabled = p.path_truncated or busy });
        if (!p.path_truncated and !busy and (path_field.submitted or open_clicked)) intent = .open_path;
        if (control(p, ctx, .browse, "Browse", .{ .size = 11 })) intent = .open_file;
        ui.end(ctx);
        if (p.path_truncated) {
            ui.row(ctx, .{ .width = .fill, .height = .{ .px = note_row }, .align_items = .center });
            ui.text(ctx, "Path shortened (1024-byte field); Browse or edit.", .{ .size = 10, .color = ctx.theme.muted });
            ui.end(ctx);
        }
        // Mode controls lead the first row; document actions share it when they
        // fit and otherwise flow into measured rows, so nothing is clipped.
        const flow = plan(p, ctx, rect.w);
        var row: u8 = 0;
        ui.row(ctx, .{ .width = .fill, .height = .{ .px = action_row }, .gap = 4, .align_items = .center });
        if (p.model.kind == .image) {
            if (control(p, ctx, .fit, "Fit", .{ .size = 10, .variant = if (p.fit_image) .primary else .ghost })) {
                p.fit_image = true;
                p.layout_width = -1;
            }
            if (control(p, ctx, .actual, "Actual", .{ .size = 10, .variant = if (!p.fit_image and p.image_zoom == 1) .primary else .ghost })) {
                p.fit_image = false;
                p.image_zoom = 1;
                p.layout_width = -1;
            }
            if (control(p, ctx, .zoom_out, "−", .{ .size = 10, .variant = .ghost })) zoom(p, ctx, false);
            if (control(p, ctx, .zoom_in, "+", .{ .size = 10, .variant = .ghost })) zoom(p, ctx, true);
            if (p.imageAt(0)) |image| ui.text(ctx, ctx.print("{d}×{d}", .{ image.original_width, image.original_height }), .{ .size = 10, .color = ctx.theme.muted });
        }
        for (actions, 0..) |label, index| {
            if (flow.rows[index] != row) {
                ui.end(ctx);
                row = flow.rows[index];
                ui.row(ctx, .{ .width = .fill, .height = .{ .px = action_row }, .gap = 4, .align_items = .center });
            } else if (index == 0 and row == 0) ui.spacer(ctx);
            switch (index) {
                0 => {
                    p.ax_copy = ctx.peekId(null);
                    if (chrome.button(ctx, label, .{ .size = 10, .variant = .ghost, .disabled = p.selection.range().start == p.selection.range().end }).clicked) {
                        p.copy(ctx);
                        ctx.copy_done = true;
                    }
                },
                1 => if (control(p, ctx, .copy_path, label, .{ .size = 10, .variant = .ghost, .disabled = p.model.path.len == 0 })) {
                    ctx.clipboard.write(ctx.clipboard.ctx, p.model.path.text());
                    ctx.copy_done = true;
                },
                2 => {
                    p.ax_refresh = ctx.peekId(null);
                    if (chrome.button(ctx, label, .{ .size = 10, .variant = .ghost }).clicked) intent = .refresh;
                },
                else => if (control(p, ctx, .external, label, .{ .size = 10, .variant = .ghost, .disabled = p.model.path.len == 0 })) {
                    intent = .external;
                },
            }
        }
        ui.end(ctx);
    }
    if (p.show_find) {
        ui.row(ctx, .{ .width = .fill, .height = .{ .px = action_row }, .gap = 4, .align_items = .center });
        ui.key(ctx, "preview-find-query");
        if (p.focus_query) {
            ctx.focus = ctx.peekId(null);
            p.focus_query = false;
        }
        p.ax_query = ctx.peekId(null);
        const result = ui.textField(ctx, &p.query, .{ .width = .fill, .size = 11, .placeholder = "Find in document" });
        if (result.focused) p.field = .query;
        if (composing(ctx)) {
            p.search_valid = false;
            p.match_count = 0;
            p.selection = .{};
            for (ctx.input.ops) |op| if (op == .unmark) {
                ctx.animationFrame();
            };
        } else if (p.search_frame != ctx.frame) {
            p.search_frame = ctx.frame;
            p.updateSearch();
        }
        if (p.searching and !composing(ctx)) ctx.animationFrame();
        p.ax_results = ctx.peekId(null);
        ui.text(ctx, if (composing(ctx)) "Composing…" else if (p.searching) ctx.print("{d} found…", .{p.match_count}) else ctx.print("{d}/{d}{s}", .{ if (p.match_count > 0) p.match_current + 1 else 0, p.match_count, if (p.match_count == p.matches.len) "+" else "" }), .{ .size = 10, .color = ctx.theme.muted });
        if (control(p, ctx, .previous, "Prev", .{ .size = 10, .variant = .ghost, .disabled = busy })) p.find(true);
        if (control(p, ctx, .next, "Next", .{ .size = 10, .variant = .ghost, .disabled = busy }) or (result.submitted and !busy)) p.find(result.submitted and ctx.input.shift);
        if (control(p, ctx, .done, "Done", .{ .size = 10, .variant = .ghost })) {
            p.show_find = false;
            p.field = .body;
            ctx.focus = 0;
        }
        ui.end(ctx);
    }
    const reason = if (p.model.status == .ready and !p.model.stale) (switch (p.model.kind) {
        .markdown => "Markdown",
        .image => "PNG",
        else => "Text",
    }) else statusLabel(p.model.status, p.model.stale);
    const failed = failure(p.model.status);
    ui.row(ctx, .{ .absolute = true, .offset = .{ .x = 0, .y = rect.h - pad * 2 - note_row }, .width = .fill, .height = .{ .px = note_row }, .gap = 6, .align_items = .center, .clip = true });
    p.ax_status = ctx.peekId(null);
    ui.text(ctx, if (p.model.stale) ctx.print("{s} · showing previous content", .{reason}) else reason, .{ .size = 10, .color = if (failed or p.model.stale) ctx.theme.danger else ctx.theme.muted });
    ui.spacer(ctx);
    if (p.editor) |editor| {
        ui.text(ctx, if (editor.dirty) "Edited" else "Editing", .{ .size = 10, .color = ctx.theme.muted });
        if (control(p, ctx, .discard, "Discard", .{ .size = 10, .variant = .ghost, .disabled = busy })) {
            p.edit_request = .discard;
            ctx.changed = true;
        }
        if (control(p, ctx, .save, "Save", .{ .size = 10, .variant = .primary, .disabled = busy })) {
            p.edit_request = .save;
            ctx.changed = true;
        }
    }
    if (iconControl(p, ctx, .unlock, if (p.editor == null) "Unlock to edit" else "Lock document", .lock, p.editor != null, busy or p.model.status != .ready or p.model.kind == .image or p.model.kind == .unsupported)) {
        p.edit_request = .unlock;
        ctx.changed = true;
    }
    p.ax_readonly = if (p.ax_count > 0) p.ax_controls[p.ax_count - 1].widget else 0;
    ui.end(ctx);
    if (p.notice.len > 0) {
        ui.text(ctx, chrome.ellipsize(ctx, p.notice.text(), @max(1, rect.w - 16), 11), .{ .size = 11, .color = ctx.theme.muted });
    }
    const lock_rect = ctx.rects.get(p.ax_readonly);
    defer if (lock_rect != null and lock_rect.?.contains(ctx.input.mouse)) {
        ui.column(ctx, .{ .absolute = true, .offset = .{ .x = @max(0, rect.w - 158), .y = rect.h - pad * 2 - note_row - 32 }, .padding = .xy(8, 5), .radius = 5, .background = ctx.theme.background, .border = ctx.theme.border });
        ui.text(ctx, if (p.editor != null) "Lock document" else if (p.model.kind == .image) "Read-only image" else "Unlock to edit", .{ .size = 11, .color = ctx.theme.muted });
        ui.end(ctx);
    };
    const toolbar = toolbarHeight(p, ctx, rect.w);
    p.body_rect = .{ .x = rect.x + pad, .y = rect.y + toolbar, .w = @max(1, rect.w - pad * 2), .h = @max(1, rect.h - toolbar - pad * 2 - note_row) };
    // Body placement uses explicit same geometry for paint and hit testing.
    p.ax_body = ctx.peekId(null);
    ui.column(ctx, .{ .absolute = true, .offset = .{ .x = 0, .y = toolbar - pad }, .width = .{ .px = p.body_rect.w }, .height = .{ .px = p.body_rect.h }, .clip = true, .background = ctx.theme.surface });
    defer ui.end(ctx);
    if (p.editor != null) {
        @import("editor_view.zig").draw(p, ctx);
        return intent;
    }
    if (p.prepared) |*prepared| {
        if (prepared.prepare_error) |err| notice(ctx, prepareLabel(err), "Source view remains available for text.");
        if (p.model.kind == .image) {
            imageInput(p, ctx);
            if (p.imageAt(0)) |image| drawImage(p, ctx, image, 0, 0, p.body_rect.h) else if (prepared.prepare_error == null) notice(ctx, "PNG preview unavailable", "");
        } else if (p.model.kind == .unsupported) {
            notice(ctx, "Unsupported format", "This file is not UTF-8 text, Markdown or PNG. Choose External to open it deliberately.");
        } else if (p.document()) |doc| {
            ensureLayout(p, ctx) catch {
                notice(ctx, "Document layout budget unavailable", "");
                return intent;
            };
            if (bodyInput(p, ctx)) |action| intent = action;
            _ = doc;
            if (p.reveal_match) revealMatch(p, ctx);
            p.scroll_x = std.math.clamp(p.scroll_x, 0, p.scroll_x_max);
            const first = visualAt(p, p.scroll_y);
            const last = @min(p.visual_rows.items.len, visualAt(p, p.scroll_y + p.body_rect.h) + 2);
            for (first..last) |index| drawLine(p, ctx, index);
            scrollbar(p, ctx);
        }
    } else if (p.model.status == .loading) {
        notice(ctx, "Loading…", p.model.path.text());
    } else if (failure(p.model.status)) {
        notice(ctx, statusLabel(p.model.status, false), statusHint(p.model.status));
    } else notice(ctx, "No document", "Open a local UTF-8 text, Markdown or PNG file. Cmd/Ctrl-click a path in the terminal to preview it here.");
    return intent;
}
pub fn toggleActions(p: anytype, ctx: *ui.Context) void {
    p.show_actions = !p.show_actions;
    if (!p.show_actions and p.field == .path) {
        p.field = .body;
        ctx.focus = 0;
    }
    ctx.changed = true;
}
pub fn setMode(p: anytype, ctx: *ui.Context, mode: @TypeOf(p.mode)) void {
    if (p.editor != null or p.mode == mode) return;
    p.mode = mode;
    p.selection = .{};
    p.scroll_x = 0;
    p.scroll_y = 0;
    p.layout_width = -1;
    p.query_hash = 0;
    p.search_valid = false;
    p.search_frame = null;
    p.match_count = 0;
    ctx.changed = true;
}
pub fn zoom(p: anytype, ctx: *ui.Context, increase: bool) void {
    if (p.zoom_frame == ctx.frame) return;
    p.zoom_frame = ctx.frame;
    p.zoom = std.math.clamp(p.zoom + (if (increase) @as(f32, 0.1) else -0.1), 0.6, 2);
    p.image_zoom = std.math.clamp(p.image_zoom + (if (increase) @as(f32, 0.25) else -0.25), 0.25, 4);
    p.fit_image = false;
    p.layout_width = -1;
    ctx.changed = true;
}
fn imageHeight(p: anytype, image: anytype) f32 {
    const factor = if (p.fit_image) @min(1, p.body_rect.w / @as(f32, @floatFromInt(image.original_width))) else p.image_zoom;
    return @as(f32, @floatFromInt(image.original_height)) * factor;
}
fn ensureLayout(p: anytype, ctx: *ui.Context) !void {
    const doc = p.document() orelse return;
    var font_hash = std.hash.Wyhash.init(@as(u64, @bitCast(@as(f64, ctx.text.zoom))));
    font_hash.update(ctx.text.family orelse "");
    font_hash.update(ctx.text.mono_family orelse "");
    const fonts = font_hash.final();
    if (p.layout_font == fonts and p.layout_width == p.body_rect.w and p.layout_zoom == p.zoom and p.layout_mode == p.mode and p.row_y.items.len == doc.lines.len + 1) return;
    if (p.mode == .rendered) if (p.prepared.?.markdown) |*markdown| {
        try p.tables.rebuild(ctx, markdown, doc, size * p.zoom, @max(1, p.body_rect.w - 52));
    };
    try p.row_y.resize(ctx.gpa, doc.lines.len + 1);
    p.visual_rows.clearRetainingCapacity();
    var y: f32 = if (p.mode == .rendered) 18 else 6;
    var content_width: f32 = 0;
    for (doc.lines, 0..) |line, index| {
        const code = p.mode == .rendered and p.prepared.?.markdown != null and index < p.prepared.?.markdown.?.lines.len and p.prepared.?.markdown.?.lines[index].kind == .code;
        if (code and (index == 0 or p.prepared.?.markdown.?.lines[index - 1].kind != .code)) y += 28;
        p.row_y.items[index] = y;
        const height = lineHeight(p, ctx, index);
        var wrapped = false;
        if (p.mode == .rendered) if (p.prepared.?.markdown) |*markdown| if (index < markdown.lines.len) {
            const block = markdown.lines[index];
            if (block.kind != .code and block.kind != .table and block.kind != .rule and block.kind != .diagram and block.kind != .math and line.start != line.end) {
                const rows = md_render.wrap(ctx, markdown, block, size * p.zoom, @max(1, p.body_rect.w - 52 - md_render.indent(block, size * p.zoom)));
                var start = line.start;
                for (rows, 0..) |_, i| {
                    const end = if (i + 1 < rows.len) doc.ceil(line.start + rows[i + 1].start) else line.end;
                    if (end <= start) continue;
                    if (p.visual_rows.items.len >= 131072) return error.PreviewVisualRowLimit;
                    var fragment = block;
                    fragment.start = start;
                    fragment.end = end;
                    const fragment_height = if (inline_math.has(markdown, fragment)) md_render.height(ctx, markdown, fragment, size * p.zoom) + 2 else height;
                    content_width = @max(content_width, md_render.xAt(ctx, markdown, fragment, end - start, size * p.zoom) + md_render.indent(block, size * p.zoom));
                    try p.visual_rows.append(ctx.gpa, .{ .row = index, .start = start, .end = end, .y = y, .height = fragment_height });
                    y += fragment_height;
                    start = end;
                }
                wrapped = start == line.end;
            }
        };
        if (!wrapped) {
            content_width = @max(content_width, unwrappedWidth(p, ctx, index));
            try p.visual_rows.append(ctx.gpa, .{ .row = index, .start = line.start, .end = line.end, .y = y, .height = height });
            y += height;
        }
        if (code and (index + 1 >= p.prepared.?.markdown.?.lines.len or p.prepared.?.markdown.?.lines[index + 1].kind != .code)) y += 18;
        if (p.mode == .rendered) for (p.prepared.?.images[0..p.prepared.?.image_count]) |maybe| if (maybe) |image| if (image.line == index) {
            y += imageHeight(p, image) + 12;
        };
        if (p.mode == .rendered) for (p.prepared.?.image_errors[0..p.prepared.?.image_error_count]) |failed_image| if (failed_image.line == index) {
            y += 18;
        };
    }
    if (p.show_find and p.match_count > 0) p.reveal_match = true;
    p.row_y.items[doc.lines.len] = y;
    p.scroll_x_max = @max(0, content_width - horizontalAvailable(p));
    p.scroll_x = std.math.clamp(p.scroll_x, 0, p.scroll_x_max);
    p.layout_font = fonts;
    p.layout_width = p.body_rect.w;
    p.layout_zoom = p.zoom;
    p.layout_mode = p.mode;
    if (p.pending_reveal) |at| {
        p.pending_reveal = null;
        p.reveal(at);
    }
    p.scroll_y = std.math.clamp(p.scroll_y, 0, @max(0, y - p.body_rect.h));
}
fn horizontalAvailable(p: anytype) f32 {
    return @max(1, p.body_rect.w - (if (p.mode == .source) @as(f32, 56) else 52));
}
/// Measure once per layout revision, never scan the document on wheel frames.
/// Wrapped prose and rules do not participate in horizontal scrolling.
fn unwrappedWidth(p: anytype, ctx: *ui.Context, index: usize) f32 {
    if (p.mode == .rendered) if (p.prepared.?.markdown) |*markdown| if (index < markdown.lines.len) {
        const block = markdown.lines[index];
        return switch (block.kind) {
            .table => p.tables.rows.items[index].width + md_render.indent(block, size * p.zoom),
            .diagram => flow_render.geometry(ctx, block.diagram.?, size * p.zoom).width,
            .math => md_render.xAt(ctx, markdown, block, block.end - block.start, size * p.zoom),
            .code => md_render.xAt(ctx, markdown, block, block.end - block.start, size * p.zoom),
            else => 0,
        };
    };
    const doc = p.document().?;
    const line = doc.lines[index];
    return ctx.text.layout(doc.text[line.start..line.end], sourceStyle(p)).width;
}
fn lineHeight(p: anytype, ctx: *ui.Context, index: usize) f32 {
    if (p.mode == .rendered) if (p.prepared.?.markdown) |markdown| if (index < markdown.lines.len) {
        const line = markdown.lines[index];
        if (line.kind == .diagram) return flow_render.geometry(ctx, line.diagram.?, size * p.zoom).height + 12;
        if (line.kind == .table) return p.tables.rows.items[index].height;
        // Blank IR rows separate blocks; a full text row per gap doubled spacing.
        if (line.start == line.end and line.kind == .paragraph) return @ceil(size * p.zoom * 0.6);
        // Code/table/quote rows stay contiguous so block backgrounds don't stripe.
        return md_render.height(ctx, &markdown, line, size * p.zoom) + switch (line.kind) {
            .code, .table, .quote => @as(f32, 0),
            .heading => 6,
            else => 2,
        };
    };
    return size * p.zoom * 1.5;
}
fn rowAt(p: anytype, y: f32) usize {
    if (p.row_y.items.len < 2) return 0;
    var low: usize = 0;
    var high = p.row_y.items.len - 1;
    while (low + 1 < high) {
        const middle = (low + high) / 2;
        if (p.row_y.items[middle] <= y) low = middle else high = middle;
    }
    return low;
}
fn sourceStyle(p: anytype) ui.TextStyle {
    return .{ .size = size * p.zoom, .mono = true };
}
pub fn visualAt(p: anytype, y: f32) usize {
    var low: usize = 0;
    var high = p.visual_rows.items.len;
    while (low + 1 < high) {
        const mid = (low + high) / 2;
        if (p.visual_rows.items[mid].y <= y) low = mid else high = mid;
    }
    return low;
}
fn visualBlock(p: anytype, index: usize) @import("markdown.zig").Line {
    const row = p.visual_rows.items[index];
    var block = p.prepared.?.markdown.?.lines[row.row];
    block.start = row.start;
    block.end = row.end;
    return block;
}
fn horizontal(p: anytype, index: usize) f32 {
    const row = p.visual_rows.items[index].row;
    if (p.mode == .rendered and p.prepared.?.markdown != null and row < p.prepared.?.markdown.?.lines.len) {
        const kind = p.prepared.?.markdown.?.lines[row].kind;
        if (kind != .code and kind != .table and kind != .rule and kind != .diagram and kind != .math and !inline_math.has(&p.prepared.?.markdown.?, visualBlock(p, index))) return 0;
    }
    return p.scroll_x;
}
fn xAt(p: anytype, ctx: *ui.Context, index: usize, byte: usize) f32 {
    const doc = p.document().?;
    const line = p.visual_rows.items[index];
    if (p.mode == .rendered and p.prepared.?.markdown != null and line.row < p.prepared.?.markdown.?.lines.len) {
        const block = visualBlock(p, index);
        if (block.diagram) |graph| return md_render.indent(block, size * p.zoom) + flow_render.pointAt(ctx, graph, flow_render.geometry(ctx, graph, size * p.zoom), byte - line.start).x;
    }
    if (p.mode == .rendered and p.prepared.?.markdown != null and line.row < p.prepared.?.markdown.?.lines.len and p.prepared.?.markdown.?.lines[line.row].kind == .table)
        return md_render.indent(visualBlock(p, index), size * p.zoom) + p.tables.pointAt(ctx, &p.prepared.?.markdown.?, line.row, byte, size * p.zoom).x;
    if (p.mode == .rendered and p.prepared.?.markdown != null and line.row < p.prepared.?.markdown.?.lines.len)
        return md_render.indent(visualBlock(p, index), size * p.zoom) + md_render.xAt(ctx, &p.prepared.?.markdown.?, visualBlock(p, index), byte - line.start, size * p.zoom);
    const layout = ctx.text.layout(doc.text[line.start..line.end], sourceStyle(p));
    const relative = byte - line.start;
    if (relative == line.end - line.start) return layout.width;
    var at: usize = 0;
    var x: f32 = 0;
    for (layout.glyphs) |glyph| if (glyph.index <= relative and glyph.index >= at) {
        at = glyph.index;
        x = glyph.x;
    };
    return x;
}
fn hit(p: anytype, ctx: *ui.Context, point: ui.Point) usize {
    const doc = p.document().?;
    const index = visualAt(p, point.y - p.body_rect.y + p.scroll_y);
    const line = p.visual_rows.items[index];
    const gutter: f32 = if (p.mode == .source) 48 else 24;
    const x = point.x - p.body_rect.x - gutter + horizontal(p, index);
    if (p.mode == .rendered and p.prepared.?.markdown != null and line.row < p.prepared.?.markdown.?.lines.len) {
        const block = visualBlock(p, index);
        if (block.diagram) |graph| return doc.floor(line.start + flow_render.hit(ctx, graph, flow_render.geometry(ctx, graph, size * p.zoom), .{ .x = x - md_render.indent(block, size * p.zoom), .y = point.y - p.body_rect.y + p.scroll_y - line.y }));
    }
    if (p.mode == .rendered and p.prepared.?.markdown != null and line.row < p.prepared.?.markdown.?.lines.len and p.prepared.?.markdown.?.lines[line.row].kind == .table)
        return doc.floor(p.tables.hit(ctx, &p.prepared.?.markdown.?, line.row, .{ .x = x - md_render.indent(visualBlock(p, index), size * p.zoom), .y = point.y - p.body_rect.y + p.scroll_y - line.y }, size * p.zoom));
    if (p.mode == .rendered and p.prepared.?.markdown != null and line.row < p.prepared.?.markdown.?.lines.len)
        return doc.floor(line.start + md_render.hitTest(ctx, &p.prepared.?.markdown.?, visualBlock(p, index), x - md_render.indent(visualBlock(p, index), size * p.zoom), size * p.zoom));
    const layout = ctx.text.layout(doc.text[line.start..line.end], sourceStyle(p));
    var nearest = line.end - line.start;
    var distance = @abs(x - layout.width);
    for (layout.glyphs) |glyph| {
        const d = @abs(x - glyph.x);
        if (d < distance) {
            distance = d;
            nearest = glyph.index;
        }
    }
    return doc.floor(line.start + nearest);
}
fn revealMatch(p: anytype, ctx: *ui.Context) void {
    p.reveal_match = false;
    const found = p.selection.range();
    const rows = p.visual_rows.items;
    for (rows, 0..) |row, index| {
        if (found.start < row.start or found.start >= row.end) continue;
        if (p.mode == .rendered and p.prepared.?.markdown != null and row.row < p.prepared.?.markdown.?.lines.len) {
            const block = visualBlock(p, index);
            if (block.diagram) |graph| {
                const point = flow_render.pointAt(ctx, graph, flow_render.geometry(ctx, graph, size * p.zoom), found.start - row.start);
                const x = point.x + md_render.indent(block, size * p.zoom);
                const available = @max(1, p.body_rect.w - 52);
                if (x < p.scroll_x) p.scroll_x = @max(0, x - 4) else if (x + point.w > p.scroll_x + available) p.scroll_x = @min(p.scroll_x_max, @max(0, x + point.w - available + 4));
                const y = row.y + point.y;
                if (y < p.scroll_y) p.scroll_y = y else if (y + point.h > p.scroll_y + p.body_rect.h) p.scroll_y = y + point.h - p.body_rect.h;
                return;
            }
        }
        if (p.mode == .rendered and p.prepared.?.markdown != null and row.row < p.prepared.?.markdown.?.lines.len and p.prepared.?.markdown.?.lines[row.row].kind == .table) {
            const markdown = &p.prepared.?.markdown.?;
            const fragment = p.tables.fragmentAt(row.row, found.start) orelse return;
            const point = p.tables.pointAt(ctx, markdown, row.row, found.start, size * p.zoom);
            const end = p.tables.pointAt(ctx, markdown, row.row, @min(found.end, fragment.block.end -| 1), size * p.zoom);
            const available = @max(1, p.body_rect.w - 52);
            if (point.x < p.scroll_x or end.x - point.x > available) p.scroll_x = @max(0, point.x - 4) else if (end.x > p.scroll_x + available) p.scroll_x = @max(0, end.x - available + 4);
            const top = row.y + point.y;
            if (top < p.scroll_y) p.scroll_y = top else if (top + fragment.height > p.scroll_y + p.body_rect.h) p.scroll_y = top + fragment.height - p.body_rect.h;
            return;
        }
        const x0 = xAt(p, ctx, index, found.start);
        const x1 = xAt(p, ctx, index, @min(found.end, row.end));
        const available = @max(1, p.body_rect.w - (if (p.mode == .source) @as(f32, 56) else 52));
        if (x1 - x0 > available or x0 < p.scroll_x) p.scroll_x = @max(0, x0 - 4) else if (x1 > p.scroll_x + available) p.scroll_x = @max(0, x1 - available + 4);
        var bottom = row.y + row.height;
        for (rows[index + 1 ..]) |next| {
            if (next.start >= found.end) break;
            bottom = next.y + next.height;
        }
        if (row.y < p.scroll_y or bottom - row.y > p.body_rect.h) p.scroll_y = row.y else if (bottom > p.scroll_y + p.body_rect.h) p.scroll_y = bottom - p.body_rect.h;
        return;
    }
}
fn bodyInput(p: anytype, ctx: *ui.Context) ?Intent {
    if (p.body_frame == ctx.frame) return null;
    p.body_frame = ctx.frame;
    const doc = p.document().?;
    const over = p.body_rect.contains(ctx.input.mouse);
    if (over and ctx.input.pressed and ctx.input.mouse_button == 1) {
        p.field = .body;
        p.focused = true;
        ctx.focus = 0;
        p.selection.place(doc, hit(p, ctx, ctx.input.mouse), ctx.input.shift);
        p.selection.dragging = true;
    }
    if (p.selection.dragging and ctx.input.down) {
        p.selection.place(doc, hit(p, ctx, ctx.input.mouse), true);
        if (ctx.input.mouse.y < p.body_rect.y) p.scroll_y -= 16;
        if (ctx.input.mouse.y >= p.body_rect.y + p.body_rect.h) p.scroll_y += 16;
    }
    if (p.selection.dragging and ctx.input.released) {
        p.selection.dragging = false;
        if (p.selection.anchor == p.selection.caret and over and p.mode == .rendered) if (p.prepared.?.markdown) |markdown| {
            const at = hit(p, ctx, ctx.input.mouse);
            for (markdown.links) |link| if (!link.image and at >= link.start and at < link.end) {
                if (!link.safe) return null;
                if (std.mem.startsWith(u8, link.target, "#")) {
                    _ = p.anchor(link.target);
                    return null;
                }
                p.link_target.set(link.target);
                return .link;
            };
        };
    }
    if (over) {
        p.scroll_y -= ctx.input.scroll.y;
        p.scroll_x = std.math.clamp(p.scroll_x - ctx.input.scroll.x, 0, p.scroll_x_max);
    }
    if (p.focused and p.field == .body) keyboard(p, ctx);
    const max_y = @max(0, p.row_y.items[p.row_y.items.len - 1] - p.body_rect.h);
    p.scroll_y = std.math.clamp(p.scroll_y, 0, max_y);
    if (over) ctx.cursor = .text;
    return null;
}
fn moveVisual(p: anytype, ctx: *ui.Context, down: bool) void {
    const rows = p.visual_rows.items;
    if (rows.len == 0) return;
    var index: usize = 0;
    for (rows, 0..) |row, i| {
        if (row.start > p.selection.caret) break;
        index = i;
    }
    const current = rows[index];
    if (p.mode == .rendered and p.prepared.?.markdown != null and current.row < p.prepared.?.markdown.?.lines.len and p.prepared.?.markdown.?.lines[current.row].kind == .table) {
        if (p.tables.moveVertical(ctx, &p.prepared.?.markdown.?, current.row, p.selection.caret, down, size * p.zoom)) |at| {
            p.selection.place(p.document().?, p.document().?.floor(at), ctx.input.shift);
            p.reveal_match = true;
            return;
        }
    }
    const x = xAt(p, ctx, index, @min(current.end, p.selection.caret));
    const target_index = if (down) @min(rows.len - 1, index + 1) else index -| 1;
    const target = rows[target_index];
    const gutter: f32 = if (p.mode == .source) 48 else 24;
    const at = hit(p, ctx, .{ .x = p.body_rect.x + gutter + x - horizontal(p, target_index), .y = p.body_rect.y + target.y + 1 - p.scroll_y });
    p.selection.place(p.document().?, at, ctx.input.shift);
    p.reveal_match = true;
}
fn keyboard(p: anytype, ctx: *ui.Context) void {
    const doc = p.document().?;
    if (ctx.input.key) |key| switch (key) {
        .left => p.selection.move(doc, .left, ctx.input.shift),
        .right => p.selection.move(doc, .right, ctx.input.shift),
        .up => moveVisual(p, ctx, false),
        .down => moveVisual(p, ctx, true),
        .home => p.selection.move(doc, if (ctx.input.cmd or ctx.input.ctrl) .start else .home, ctx.input.shift),
        .end => p.selection.move(doc, if (ctx.input.cmd or ctx.input.ctrl) .finish else .end, ctx.input.shift),
        .page_up => p.scroll_y -= p.body_rect.h * 0.8,
        .page_down => p.scroll_y += p.body_rect.h * 0.8,
        .escape => {
            if (p.show_find) p.show_find = false else p.focused = false;
            p.field = .body;
            ctx.focus = 0;
        },
        else => {},
    } else for (ctx.input.ops) |op| if (op == .command) switch (op.command) {
        .select_all => p.selection.all(doc),
        .copy => {
            p.copy(ctx);
            ctx.copy_done = true;
        },
        .move_left => p.selection.move(doc, .left, false),
        .move_right => p.selection.move(doc, .right, false),
        .select_left => p.selection.move(doc, .left, true),
        .select_right => p.selection.move(doc, .right, true),
        .move_line_start => p.selection.move(doc, .home, false),
        .move_line_end => p.selection.move(doc, .end, false),
        .select_line_start => p.selection.move(doc, .home, true),
        .select_line_end => p.selection.move(doc, .end, true),
        .cancel => {
            p.show_find = false;
            p.focused = false;
            ctx.focus = 0;
        },
        else => {}, // insert/cut/delete/IME never mutate a read-only document.
    };
}
fn imageInput(p: anytype, ctx: *ui.Context) void {
    if (p.body_frame == ctx.frame) return;
    p.body_frame = ctx.frame;
    if (p.body_rect.contains(ctx.input.mouse)) {
        p.scroll_y -= ctx.input.scroll.y;
        p.scroll_x -= ctx.input.scroll.x;
    }
    if (p.imageAt(0)) |image| {
        const factor = if (p.fit_image) @min(1, @min(p.body_rect.w / @as(f32, @floatFromInt(image.original_width)), p.body_rect.h / @as(f32, @floatFromInt(image.original_height)))) else p.image_zoom;
        p.scroll_y = std.math.clamp(p.scroll_y, 0, @max(0, @as(f32, @floatFromInt(image.original_height)) * factor - p.body_rect.h));
        p.scroll_x = std.math.clamp(p.scroll_x, 0, @max(0, @as(f32, @floatFromInt(image.original_width)) * factor - p.body_rect.w));
    }
}
fn drawImage(p: anytype, ctx: *ui.Context, image: anytype, index: usize, y: f32, available: f32) void {
    const fit = if (p.fit_image) @min(1, @min(p.body_rect.w / @as(f32, @floatFromInt(image.original_width)), available / @as(f32, @floatFromInt(image.original_height)))) else p.image_zoom;
    const w = @as(f32, @floatFromInt(image.original_width)) * fit;
    const h = @as(f32, @floatFromInt(image.original_height)) * fit;
    if (p.image_keys[index] == 0) {
        ui.text(ctx, "Preparing bounded image resource…", .{ .size = 11 });
        return;
    }
    ctx.imageRegion(.{ .key = p.image_keys[index], .destination = .{ .x = -p.scroll_x, .y = y - p.scroll_y, .w = w, .h = h }, .source_pixels = .{ .x = 0, .y = 0, .w = @floatFromInt(image.width), .h = @floatFromInt(image.height) }, .clip = .{ .x = 0, .y = 0, .w = p.body_rect.w, .h = p.body_rect.h } }) catch {};
}
pub fn copyCode(p: anytype, ctx: *ui.Context, first: usize) void {
    if (p.mode != .rendered or composing(ctx)) return;
    const prepared = p.prepared orelse return;
    const markdown = prepared.markdown orelse return;
    if (first < markdown.lines.len) if (markdown.lines[first].diagram) |graph| {
        ctx.clipboard.write(ctx.clipboard.ctx, graph.source);
        return;
    };
    if (first >= markdown.lines.len or markdown.lines[first].kind != .code or (first > 0 and markdown.lines[first - 1].kind == .code)) return;
    var last = first;
    while (last + 1 < markdown.lines.len and markdown.lines[last + 1].kind == .code) : (last += 1) {}
    ctx.clipboard.write(ctx.clipboard.ctx, markdown.text[markdown.lines[first].start..markdown.lines[last].end]);
}
fn drawLine(p: anytype, ctx: *ui.Context, index: usize) void {
    const doc = p.document().?;
    const line = p.visual_rows.items[index];
    const logical = line.row;
    const y = line.y - p.scroll_y;
    const gutter: f32 = if (p.mode == .source) 48 else 24;
    if (p.mode == .rendered) if (p.prepared.?.markdown) |*markdown| if (logical < markdown.lines.len and markdown.lines[logical].kind == .code and (logical == 0 or markdown.lines[logical - 1].kind != .code or (y <= 0 and y + line.height > 0))) {
        var first = logical;
        while (first > 0 and markdown.lines[first - 1].kind == .code) : (first -= 1) {}
        var last = logical;
        while (last + 1 < markdown.lines.len and markdown.lines[last + 1].kind == .code) : (last += 1) {}
        // Paint once even when the first row has scrolled above the viewport.
        if (logical == first or (y <= 0 and y + line.height > 0)) {
            const top = p.row_y.items[first] - p.scroll_y - 28;
            const height = p.row_y.items[last + 1] - p.row_y.items[first] + 28;
            _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = 12, .y = top }, .width = .{ .px = @max(1, p.body_rect.w - 24) }, .height = .{ .px = height }, .radius = 6, .border = ctx.theme.border, .background = ctx.theme.text.alpha(0.035) }, .none, null);
            if (top >= 0 and markdown.lines[first].language.len > 0) {
                ui.column(ctx, .{ .absolute = true, .offset = .{ .x = 24, .y = top + 6 } });
                ui.text(ctx, markdown.lines[first].language, .{ .size = 10, .color = ctx.theme.muted });
                ui.end(ctx);
            }
            if (top >= 0 and top + 28 <= p.body_rect.h and p.ax_count < p.ax_controls.len) {
                ui.key(ctx, ctx.print("code-copy-{d}", .{first}));
                ui.row(ctx, .{ .absolute = true, .offset = .{ .x = p.body_rect.w - 44, .y = top + 1 } });
                const at = p.ax_count;
                if (iconControl(p, ctx, .copy_code, ctx.print("Copy code block {d}", .{first + 1}), .copy, false, composing(ctx))) copyCode(p, ctx, first);
                p.ax_controls[at].offset = first;
                ui.end(ctx);
            }
        }
    };
    const selected = p.selection.range();
    var quote_indent: f32 = 0;
    if (p.mode == .rendered and p.prepared.?.markdown != null and logical < p.prepared.?.markdown.?.lines.len) {
        const block = p.prepared.?.markdown.?.lines[logical];
        quote_indent = md_render.indent(block, size * p.zoom);
        if (block.quote_depth > 0) {
            _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = gutter, .y = y }, .width = .{ .px = @max(1, p.body_rect.w - gutter - 16) }, .height = .{ .px = line.height }, .background = ctx.theme.text.alpha(0.025) }, .none, null);
            for (0..block.quote_depth) |depth| _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = gutter + @as(f32, @floatFromInt(depth)) * size * p.zoom * 1.3, .y = y }, .width = .{ .px = 3 }, .height = .{ .px = line.height }, .background = ctx.theme.accent.alpha(0.5) }, .none, null);
        }
        if (block.diagram) |graph| {
            const geometry = flow_render.geometry(ctx, graph, size * p.zoom);
            flow_render.draw(ctx, graph, geometry, .{ .x = gutter + quote_indent - p.scroll_x, .y = y }, .{ .w = p.body_rect.w, .h = p.body_rect.h }, selected.end > line.start and selected.start < line.end);
            if (y >= 0 and y + 28 <= p.body_rect.h and p.ax_count < p.ax_controls.len) {
                ui.key(ctx, ctx.print("diagram-copy-{d}", .{logical}));
                ui.row(ctx, .{ .absolute = true, .offset = .{ .x = @min(p.body_rect.w - 44, gutter + quote_indent + geometry.width - p.scroll_x - 30), .y = y + 2 } });
                const control_index = p.ax_count;
                if (iconControl(p, ctx, .copy_code, "Copy flowchart source", .copy, false, composing(ctx))) copyCode(p, ctx, logical);
                p.ax_controls[control_index].offset = logical;
                ui.end(ctx);
            }
            return;
        }
    }
    if (p.mode == .rendered and p.prepared.?.markdown != null and logical < p.prepared.?.markdown.?.lines.len and p.prepared.?.markdown.?.lines[logical].kind == .table) {
        ui.key(ctx, ctx.print("document-table-{d}", .{logical}));
        p.tables.draw(ctx, &p.prepared.?.markdown.?, logical, .{ .x = gutter + quote_indent - p.scroll_x, .y = y }, .{ .w = p.body_rect.w, .h = p.body_rect.h }, size * p.zoom, .{ .start = selected.start, .end = selected.end });
    } else {
        if (selected.end > line.start and selected.start < line.end) {
            const start = @max(selected.start, line.start);
            const end = @min(selected.end, line.end);
            const x0 = xAt(p, ctx, index, start);
            const x1 = xAt(p, ctx, index, end);
            _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = gutter + x0 - horizontal(p, index), .y = y }, .width = .{ .px = @max(1, x1 - x0) }, .height = .{ .px = line.height - 3 }, .background = ctx.theme.accent.alpha(0.25) }, .none, null);
        }
        ui.key(ctx, ctx.print("document-line-{d}", .{index}));
        ui.column(ctx, .{ .absolute = true, .offset = .{ .x = gutter + quote_indent - horizontal(p, index), .y = y }, .height = .{ .px = line.height } });
        if (p.mode == .rendered and p.prepared.?.markdown != null and logical < p.prepared.?.markdown.?.lines.len) {
            const markdown = &p.prepared.?.markdown.?;
            md_render.drawLine(ctx, markdown, visualBlock(p, index), size * p.zoom);
        } else ui.text(ctx, doc.text[line.start..line.end], sourceStyle(p));
        ui.end(ctx);
        if (p.mode == .source) {
            // Painted after the text: horizontally scrolled source slides beneath
            // an opaque gutter instead of over the line numbers.
            ui.column(ctx, .{ .absolute = true, .offset = .{ .x = 0, .y = y }, .width = .{ .px = 42 }, .height = .{ .px = line.height }, .padding = .{ .right = 8 }, .align_items = .end, .background = ctx.theme.background.mix(ctx.theme.surface, 0.7) });
            ui.text(ctx, ctx.print("{d}", .{logical + 1}), .{ .size = 11 * p.zoom, .mono = true, .color = ctx.theme.muted });
            ui.end(ctx);
        }
    }
    if (p.mode == .rendered and line.end == doc.lines[logical].end) {
        var image_y = line.y + line.height;
        for (p.prepared.?.images[0..p.prepared.?.image_count], 0..) |maybe, i| if (maybe) |image| if (image.line == logical) {
            drawImage(p, ctx, image, i, image_y, imageHeight(p, image));
            image_y += imageHeight(p, image) + 12;
        };
        for (p.prepared.?.image_errors[0..p.prepared.?.image_error_count]) |failed_image| if (failed_image.line == logical) {
            ui.column(ctx, .{ .absolute = true, .offset = .{ .x = gutter, .y = image_y - p.scroll_y }, .height = .{ .px = 18 } });
            ui.text(ctx, ctx.print("Image unavailable: {s}", .{failed_image.message.text()}), .{ .size = 10, .color = ctx.theme.muted });
            ui.end(ctx);
            image_y += 18;
        };
    }
}

pub fn statusLabel(status: anytype, stale: bool) []const u8 {
    return switch (status) {
        .closed => "Closed",
        .loading => "Loading…",
        .ready => "Ready",
        .missing => if (stale) "File no longer exists" else "File not found",
        .permission => "Permission denied",
        .too_large => "File exceeds the preview size limit",
        .unsupported => "Binary or unsupported file",
        .invalid_utf8 => "Not valid UTF-8 text",
        .not_regular => "Not a regular file",
        .symlink => "Symbolic link refused",
        .watch_error => "Watch unavailable; use Refresh",
        .io_error => "Cannot read local file",
        .cancelled => "Read cancelled",
        .invalid_image => "PNG data is corrupt",
    };
}
fn statusHint(status: anytype) []const u8 {
    return switch (status) {
        .missing => "Check the path, or use Refresh after the file is created.",
        .permission => "The file is not readable by this user.",
        .too_large => "Limits: text 2 MiB or 50000 lines, Markdown 1 MiB, PNG 4 MiB and 1 megapixel.",
        .unsupported => "Only UTF-8 text, Markdown and PNG are previewed. Choose External to open it deliberately.",
        .invalid_utf8 => "Only UTF-8 text is previewed. Choose External to open it deliberately.",
        .not_regular => "Directories, devices, FIFOs and sockets cannot be previewed.",
        .symlink => "Paths through symbolic links are not followed; open the target path directly.",
        .io_error => "The file changed while it was read or the device reported an error. Use Refresh.",
        .invalid_image => "The PNG could not be decoded.",
        else => "",
    };
}
pub fn failure(status: anytype) bool {
    return switch (status) {
        .closed, .loading, .ready, .watch_error, .cancelled => false,
        else => true,
    };
}
fn prepareLabel(err: anyerror) []const u8 {
    return switch (err) {
        error.PreviewMarkdownLimit => "Markdown exceeds the rendering limit",
        error.PreviewImageLimit => "PNG exceeds the preview size limit",
        else => "Preview could not be prepared",
    };
}
/// Padded explanatory block used for empty, loading and failure states.
fn notice(ctx: *ui.Context, title: []const u8, detail: []const u8) void {
    ui.column(ctx, .{ .width = .fill, .padding = .all(16), .gap = 6 });
    ui.text(ctx, title, .{ .size = 13, .weight = .semibold });
    if (detail.len > 0) ui.text(ctx, detail, .{ .size = 11, .wrap = true, .color = ctx.theme.muted });
    ui.end(ctx);
}
/// Thin read-only position indicator; wheel/keyboard remain the scroll inputs.
fn scrollbar(p: anytype, ctx: *ui.Context) void {
    if (p.scroll_x_max > 0) {
        const available = horizontalAvailable(p);
        const thumb = @min(available, @max(24, available * available / (available + p.scroll_x_max)));
        const x = (available - thumb) * std.math.clamp(p.scroll_x / p.scroll_x_max, 0, 1);
        const gutter: f32 = if (p.mode == .source) 48 else 24;
        _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = gutter + x, .y = p.body_rect.h - 5 }, .width = .{ .px = thumb }, .height = .{ .px = 3 }, .radius = 1.5, .background = ctx.theme.text.alpha(0.3) }, .none, null);
    }
    const total = p.row_y.items[p.row_y.items.len - 1];
    if (total <= p.body_rect.h + 1) return;
    const h = p.body_rect.h;
    const thumb = @max(24, h * h / total);
    const y = (h - thumb) * std.math.clamp(p.scroll_y / @max(1, total - h), 0, 1);
    _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = p.body_rect.w - 6, .y = y + 2 }, .width = .{ .px = 3 }, .height = .{ .px = @max(1, thumb - 4) }, .radius = 1.5, .background = ctx.theme.text.alpha(0.22) }, .none, null);
}

pub fn composing(ctx: *ui.Context) bool {
    if (ctx.marked_text_id != 0 and ctx.focus == ctx.marked_text_id) return true;
    if (ctx.edits.getPtr(ctx.focus)) |edit| if (edit.marked != null) return true;
    for (ctx.input.ops) |op| if (op == .set_marked or op == .unmark) return true;
    return false;
}
