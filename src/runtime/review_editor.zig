//! Virtualized native text editing over current nanoui input/IME interfaces.
const std = @import("std");
const ui = @import("nanoui").ui;
const L = @import("localized.zig");
const C = @import("presentation.zig");
const text = @import("text_buffer.zig");
const A = std.mem.Allocator;
pub const State = struct {
    file: ?@import("review_file.zig").File = null,
    buffer: text.Buffer = .{},
    path: []const u8 = "",
    root: []const u8 = "",
    pane: u64 = 0,
    workspace: u64 = 0,
    epoch: u64 = 0,
    focus: bool = false,
    composition: text.Composition = .{},
    query: ui.TextBuffer = .{},
    find_open: bool = false,
    error_text: []const u8 = "",
    pub fn open(self: *const State) bool {
        return self.file != null;
    }
    pub fn dirty(self: *const State) bool {
        return self.file != null and (self.composition.range != null or !std.mem.eql(u8, self.file.?.bytes, self.buffer.text));
    }
    pub fn deinit(self: *State, a: A) void {
        if (self.file) |*file| file.deinit(a);
        self.buffer.deinit(a);
        a.free(self.path);
        a.free(self.root);
        self.composition.clear(a);
        a.free(self.error_text);
        self.* = .{};
    }
    pub fn load(self: *State, a: A, root: []const u8, path: []const u8, pane: u64, workspace: u64, epoch: u64) !void {
        var file = try @import("review_file.zig").File.open(a, root, path);
        errdefer file.deinit(a);
        var buffer = try text.Buffer.init(a, file.bytes);
        errdefer buffer.deinit(a);
        const owned = try a.dupe(u8, path);
        errdefer a.free(owned);
        const root_copy = try a.dupe(u8, root);
        self.deinit(a);
        self.* = .{ .file = file, .buffer = buffer, .path = owned, .root = root_copy, .pane = pane, .workspace = workspace, .epoch = epoch, .focus = true };
    }
    pub fn save(self: *State, a: A) !void {
        try self.composition.finish(a, &self.buffer);
        if (self.file) |*file| try file.write(a, self.buffer.text);
    }
};
pub const Event = enum { save, reload, close };
pub fn view(self: *State, ctx: *ui.Context, a: A, bounds: ui.Rect, enabled: bool) !?Event {
    ui.column(ctx, .{ .absolute = true, .offset = .{ .x = bounds.x, .y = bounds.y }, .width = .{ .px = bounds.w }, .height = .{ .px = bounds.h }, .background = C.card(ctx), .radius = 14, .border = C.edge(ctx), .shadow = .{ .color = C.shadow(ctx), .blur = 6, .y = 2 }, .clip = true });
    defer ui.end(ctx);
    ui.row(ctx, .{ .width = .fill, .height = .{ .px = 44 }, .padding = .{ .left = 16, .right = if (@import("builtin").os.tag == .macos) 10 else 104 }, .gap = 8, .align_items = .center });
    C.icon(ctx, .code, 14);
    ui.text(ctx, C.ellipsize(ctx, ctx.print("{s}{s}", .{ self.path, if (self.dirty()) " •" else "" }), @max(40, bounds.w - 170), 13.5), .{ .size = 13.5, .weight = .semibold });
    ui.spacer(ctx);
    const save = C.textControl(ctx, "Save file", false) and enabled and self.dirty();
    const reload = C.button(ctx, .reset, "Reload file", 28);
    const close = C.button(ctx, .close, "Close editor", 28);
    ui.end(ctx);
    if (save) return .save;
    if (reload) return .reload;
    if (close) return .close;
    ui.row(ctx, .{ .width = .fill, .height = .{ .px = 28 }, .padding = .xy(12, 0), .gap = 4, .align_items = .center });
    if (C.textControl(ctx, "Undo", false)) {
        self.composition.clear(a);
        try self.buffer.history(a, false);
    }
    if (C.textControl(ctx, "Redo", false)) {
        self.composition.clear(a);
        try self.buffer.history(a, true);
    }
    ui.spacer(ctx);
    if (C.button(ctx, .search, "Find in file…", 24)) self.find_open = !self.find_open;
    ui.end(ctx);
    if (!enabled) L.text(ctx, "Return to this pane and wait for the agent to finish before saving.", .{ .size = 11, .wrap = true });
    if (self.error_text.len > 0) ui.text(ctx, ctx.print("{s}", .{self.error_text}), .{ .size = 11, .color = ui.Color.hex(0xd93a35), .wrap = true });
    var find: ui.TextFieldResult = .{};
    if (self.find_open or self.query.len > 0) {
        ui.row(ctx, .{ .width = .fill, .height = .{ .px = 30 }, .padding = .xy(12, 0), .gap = 6, .align_items = .center });
        C.icon(ctx, .search, 14);
        ui.key(ctx, "file-find");
        find = L.field(ctx, &self.query, .{ .placeholder = "Find in file…", .width = .fill, .bare = true, .size = 12 });
        const next = C.button(ctx, .down, "Next match", 24);
        if (C.button(ctx, .close, "Close find", 24)) {
            self.find_open = false;
            self.query.clear();
        }
        ui.end(ctx);
        if (find.submitted or next) if (self.query.len > 0) {
            try self.composition.finish(a, &self.buffer);
            const start = @min(self.buffer.caret + 1, self.buffer.text.len);
            const index = if (std.mem.indexOf(u8, self.buffer.text[start..], self.query.text())) |i| start + i else std.mem.indexOf(u8, self.buffer.text, self.query.text());
            if (index) |at| {
                self.buffer.anchor = at;
                self.buffer.caret = at + self.query.len;
                self.focus = true;
            }
        };
    }
    const node = ctx.open(.{ .width = .fill, .height = .fill, .grow = 1, .scroll = true, .clip = true, .padding = .xy(12, 4), .background = C.card(ctx) }, "native-editor");
    defer ui.end(ctx);
    const id = ctx.node(node).id;
    const hit = ctx.interact(node, .{ .focusable = true });
    if (self.focus) {
        ctx.focus = id;
        self.focus = false;
    }
    const edge = ctx.state(struct { frame: u64 = 0 }, "editor-input-edge");
    if (ctx.focus == id and edge.frame != ctx.frame) {
        edge.frame = ctx.frame;
        try input(self, ctx, a);
    }
    const display = try self.composition.display(ctx.alloc(), &self.buffer);
    const font: ui.TextStyle = .{ .mono = true, .size = 12 };
    const cell = @max(1, ctx.text.width("M", font));
    const height: f32 = 20;
    const viewport = ctx.rects.get(id) orelse bounds;
    const scroll = ctx.scroll.get(id) orelse 0;
    var line_count: usize = 1;
    for (display.text) |ch| {
        if (ch == '\n') line_count += 1;
    }
    const first: usize = @min(line_count, @as(usize, @intFromFloat(@max(0, @floor(scroll / height)))));
    const last = @min(line_count, first + @as(usize, @intFromFloat(@ceil(@max(1, viewport.h) / height))) + 3);
    if (first > 0) _ = ctx.leaf(.{ .height = .{ .px = @as(f32, @floatFromInt(first)) * height } }, .none, null);
    var lines = std.mem.splitScalar(u8, display.text, '\n');
    var offset: usize = 0;
    var row: usize = 0;
    var caret_rect: ui.Rect = .{ .x = viewport.x + 52, .y = viewport.y, .w = 1, .h = height };
    while (lines.next()) |line| : (row += 1) {
        defer offset += line.len + 1;
        if (row < first) continue;
        if (row >= last) break;
        ui.key(ctx, ctx.print("editor-line-{d}", .{row}));
        const n = ctx.open(.{ .direction = .row, .width = .fill, .height = .{ .px = height }, .gap = 6 }, null);
        const line_rect = ctx.rects.get(ctx.node(n).id) orelse ui.Rect{ .x = viewport.x, .y = viewport.y + @as(f32, @floatFromInt(row)) * height - scroll, .w = viewport.w, .h = height };
        if (hit.pressed and ctx.input.mouse.y >= line_rect.y and ctx.input.mouse.y < line_rect.y + height) {
            var pos: usize = 0;
            var width: f32 = 0;
            const x = @max(0, ctx.input.mouse.x - line_rect.x - 52);
            while (pos < line.len) {
                const end = text.next(line, pos);
                const advance = ctx.text.width(line[pos..end], font);
                if (width + advance / 2 >= x) break;
                width += advance;
                pos = end;
            }
            try self.composition.finish(a, &self.buffer);
            self.buffer.move(offset + pos, ctx.input.shift or !ctx.input.pressed);
        }
        ui.column(ctx, .{ .width = .{ .px = 46 }, .height = .{ .px = height } });
        ui.text(ctx, ctx.print("{d}", .{row + 1}), .{ .mono = true, .size = 11, .color = ctx.theme.muted });
        ui.end(ctx);
        const content = ctx.open(.{ .width = .fill, .height = .{ .px = height }, .clip = true }, null);
        const selection = [2]usize{ @min(display.caret, display.anchor), @max(display.caret, display.anchor) };
        const start = @min(line.len, selection[0] -| offset);
        const end = @min(line.len, selection[1] -| offset);
        if (end > start) {
            const left = ctx.text.width(line[0..start], font);
            const w = ctx.text.width(line[start..end], font);
            _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = left }, .width = .{ .px = w }, .height = .{ .px = height }, .background = ctx.theme.accent.alpha(0.25) }, .none, null);
        }
        if (display.marked) |range| {
            const marked_start = @min(line.len, range[0] -| offset);
            const marked_end = @min(line.len, range[1] -| offset);
            if (marked_end > marked_start) _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = ctx.text.width(line[0..marked_start], font), .y = height - 2 }, .width = .{ .px = ctx.text.width(line[marked_start..marked_end], font) }, .height = .{ .px = 1 }, .background = ctx.theme.accent }, .none, null);
        }
        const shown = line[0..@min(line.len, 8192)];
        var length = shown.len;
        while (length > 0 and length < line.len and (line[length] & 0xc0) == 0x80) length -= 1;
        ui.text(ctx, ctx.alloc().dupe(u8, shown[0..length]) catch "", font);
        if (display.caret >= offset and display.caret <= offset + line.len) {
            const x = ctx.text.width(line[0 .. display.caret - offset], font);
            caret_rect = .{ .x = line_rect.x + 52 + x, .y = line_rect.y, .w = cell, .h = height };
            if (ctx.focus == id) _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = x }, .width = .{ .px = 1 }, .height = .{ .px = height }, .background = ctx.theme.accent }, .none, null);
        }
        _ = content;
        ui.end(ctx);
        ui.end(ctx);
    }
    if (last < line_count) _ = ctx.leaf(.{ .height = .{ .px = @as(f32, @floatFromInt(line_count - last)) * height } }, .none, null);
    if (ctx.focus == id) {
        // The same inline preedit and byte selection drive painting and the
        // native IME client; its candidate rectangle follows the preedit caret.
        ctx.focused_text = .{ .id = id, .editable = true, .text = try ctx.alloc().dupe(u8, display.text), .caret = display.caret, .anchor = display.anchor, .marked = display.marked, .caret_rect = caret_rect };
        const target_row = std.mem.count(u8, display.text[0..display.caret], "\n");
        const target_y = @as(f32, @floatFromInt(target_row)) * height;
        if (!ctx.input.down and ctx.input.scroll.y == 0 and (ctx.input.ops.len > 0 or ctx.input.key != null or find.submitted)) {
            if (target_y < scroll) ctx.scroll.put(ctx.gpa, id, target_y) catch {} else if (target_y + height > scroll + viewport.h) ctx.scroll.put(ctx.gpa, id, @max(0, target_y + height - viewport.h)) catch {};
        }
    }
    return null;
}
fn input(self: *State, ctx: *ui.Context, a: A) !void {
    if (ctx.input.shortcut) |s| if ((s.cmd or s.ctrl) and !s.alt) {
        switch (s.key) {
            'a' => {
                try self.composition.finish(a, &self.buffer);
                self.buffer.anchor = 0;
                self.buffer.caret = self.buffer.text.len;
                ctx.shortcut_taken = true;
                return;
            },
            'c', 'x' => {
                try self.composition.finish(a, &self.buffer);
                const range = self.buffer.selection();
                ctx.clipboard.write(ctx.clipboard.ctx, self.buffer.text[range[0]..range[1]]);
                if (s.key == 'x') try self.buffer.insert(a, "");
                ctx.shortcut_taken = true;
                return;
            },
            'z' => {
                self.composition.clear(a);
                try self.buffer.history(a, s.shift);
                ctx.shortcut_taken = true;
                return;
            },
            else => {},
        }
    };
    for (ctx.input.ops) |op| switch (op) {
        .insert => |value| try self.composition.commit(a, &self.buffer, value),
        .set_marked => |value| try self.composition.set(a, &self.buffer, value.text, value.sel_start, value.sel_len),
        .unmark => try self.composition.finish(a, &self.buffer),
        .command => |command| try editCommand(self, ctx, a, command),
    };
    if (ctx.input.ops.len > 0) return;
    if (ctx.input.key) |key| {
        const command: ?ui.Command = switch (key) {
            .backspace => .delete_backward,
            .delete => .delete_forward,
            .left => if (ctx.input.shift) .select_left else .move_left,
            .right => if (ctx.input.shift) .select_right else .move_right,
            .up => if (ctx.input.shift) .select_up else .move_up,
            .down => if (ctx.input.shift) .select_down else .move_down,
            .home => .move_line_start,
            .end => .move_line_end,
            .enter => .insert_newline,
            .tab => .insert_tab,
            else => null,
        };
        if (command) |cmd| try editCommand(self, ctx, a, cmd);
    } else if (ctx.input.chars.len > 0 and !ctx.input.cmd and !ctx.input.ctrl) try self.composition.commit(a, &self.buffer, ctx.input.chars);
}
fn editCommand(self: *State, ctx: *ui.Context, a: A, command: ui.Command) !void {
    if (command == .cancel) {
        self.composition.clear(a);
        return;
    }
    try self.composition.finish(a, &self.buffer);
    const b = &self.buffer;
    const range = b.selection();
    switch (command) {
        .delete_backward, .delete_forward, .delete_word_backward, .delete_word_forward, .delete_to_line_start, .delete_to_line_end => {
            if (range[0] != range[1]) try b.insert(a, "") else {
                const from = if (command == .delete_to_line_start) text.lineStart(b.text, b.caret) else if (command == .delete_word_backward) b.wordLeft(b.caret) else if (command == .delete_backward) b.previous(b.caret) else b.caret;
                const to = if (command == .delete_to_line_end) text.lineEnd(b.text, b.caret) else if (command == .delete_word_forward) b.wordRight(b.caret) else if (command == .delete_forward) text.next(b.text, b.caret) else b.caret;
                if (from != to) try b.replace(a, from, to, "");
            }
        },
        .move_left, .select_left => b.move(b.previous(b.caret), command == .select_left),
        .move_word_left, .select_word_left => b.move(b.wordLeft(b.caret), command == .select_word_left),
        .move_right, .select_right => b.move(text.next(b.text, b.caret), command == .select_right),
        .move_word_right, .select_word_right => b.move(b.wordRight(b.caret), command == .select_word_right),
        .move_line_start, .select_line_start => b.move(text.lineStart(b.text, b.caret), command == .select_line_start),
        .move_line_end, .select_line_end => b.move(text.lineEnd(b.text, b.caret), command == .select_line_end),
        .move_up, .select_up => b.vertical(false, command == .select_up),
        .move_down, .select_down => b.vertical(true, command == .select_down),
        .select_all => {
            b.anchor = 0;
            b.caret = b.text.len;
        },
        .insert_newline, .insert_line_break => try b.insert(a, if (std.mem.indexOf(u8, b.text, "\r\n") != null) "\r\n" else "\n"),
        .insert_tab => try b.insert(a, "\t"),
        .copy, .cut => {
            ctx.clipboard.write(ctx.clipboard.ctx, b.text[range[0]..range[1]]);
            if (command == .cut) try b.insert(a, "");
        },
        .cancel => unreachable,
    }
}
