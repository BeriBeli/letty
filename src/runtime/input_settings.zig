//! Native shortcut recorder and environment editor, using current nanoui fields.
const std = @import("std");
const ui = @import("nanoui").ui;
const actions = @import("actions.zig");
const L = @import("localized.zig");
const C = @import("presentation.zig");
pub const State = struct {
    tab: enum { shortcuts, environment } = .shortcuts,
    query: ui.TextBuffer = .{},
    environment: ui.TextBuffer = .{},
    loaded: bool = false,
    too_large: bool = false,
    recording: ?usize = null,
    edge: u64 = std.math.maxInt(u64),
    pub fn load(self: *State, values: []const []const u8) void {
        self.environment.clear();
        self.loaded = true;
        self.too_large = false;
        var total: usize = 0;
        for (values) |value| total += value.len + 1;
        if (total > self.environment.buf.len) {
            self.too_large = true;
            return;
        }
        for (values) |value| {
            _ = self.environment.insert(self.environment.len, value);
            _ = self.environment.insert(self.environment.len, "\n");
        }
    }
};
pub const Event = union(enum) { binding: struct { id: []const u8, chord: []const u8 }, environment: []const u8, edit_config, close };
pub fn capture(state: *State, ctx: *ui.Context) ?Event {
    const index = state.recording orelse return null;
    if (state.edge == ctx.frame) return null;
    state.edge = ctx.frame;
    var cancel = ctx.input.key == .escape or (ctx.input.chars.len == 1 and ctx.input.chars[0] == 27);
    var remove = ctx.input.key == .backspace or ctx.input.key == .delete;
    if (ctx.input.shortcut) |key| cancel = cancel or key.key == 27;
    for (ctx.input.ops) |op| if (op == .command) switch (op.command) {
        .cancel => cancel = true,
        .delete_backward, .delete_forward => remove = true,
        else => {},
    };
    if (cancel) {
        state.recording = null;
        ctx.shortcut_taken = true;
        return null;
    }
    if (remove) {
        state.recording = null;
        ctx.shortcut_taken = true;
        return .{ .binding = .{ .id = actions.all[index].id, .chord = "none" } };
    }
    var key: ?actions.Key = null;
    if (ctx.input.shortcut) |s| key = .{ .key = s.key, .cmd = s.cmd, .ctrl = s.ctrl, .alt = s.alt, .shift = s.shift } else {
        if (ctx.input.key) |k| {
            const cp: u21 = switch (k) {
                .enter => 13,
                .tab => 9,
                .left => 0xf702,
                .right => 0xf703,
                .up => 0xf700,
                .down => 0xf701,
                .page_up => 0xf72c,
                .page_down => 0xf72d,
                .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => 0xf704 + @as(u21, @backingInt(k) - @backingInt(@TypeOf(k).f1)),
                else => 0,
            };
            if (cp != 0) key = .{ .key = cp, .cmd = ctx.input.cmd, .ctrl = ctx.input.ctrl, .alt = ctx.input.alt, .shift = ctx.input.shift };
        } else if (ctx.input.chars.len > 0) {
            var iter = (std.unicode.Utf8View.init(ctx.input.chars) catch return null).iterator();
            const cp = iter.nextCodepoint() orelse return null;
            if (iter.nextCodepoint() == null) key = .{ .key = if (cp < 128) std.ascii.toLower(@intCast(cp)) else cp, .cmd = ctx.input.cmd, .ctrl = ctx.input.ctrl, .alt = ctx.input.alt, .shift = ctx.input.shift };
        }
    }
    if (key) |k| {
        const chord = actions.format(ctx.alloc(), k) catch return null;
        state.recording = null;
        ctx.shortcut_taken = true;
        return .{ .binding = .{ .id = actions.all[index].id, .chord = chord } };
    }
    return null;
}
pub fn view(state: *State, ctx: *ui.Context, bindings: []const []const u8) ?Event {
    if (state.tab == .environment) {
        ui.row(ctx, .{ .width = .fill, .height = .{ .px = 28 }, .gap = 8, .align_items = .center });
        if (C.button(ctx, .left, "Back to settings", 24)) {
            ui.end(ctx);
            return .close;
        }
        L.text(ctx, "Environment", .{ .size = 13.5, .weight = .semibold });
        ui.spacer(ctx);
        const edit = C.textControl(ctx, "Edit configuration", false);
        ui.end(ctx);
        if (edit) return .edit_config;
    }
    if (state.tab == .environment) {
        L.text(ctx, "One NAME=value per line. Applied to new terminals.", .{ .wrap = true });
        if (state.too_large) L.text(ctx, "This list exceeds the form limit. Use Edit configuration.", .{ .wrap = true }) else {
            ui.key(ctx, "environment-values");
            _ = L.field(ctx, &state.environment, .{ .multiline = true, .max_lines = 14, .width = .fill });
            if (L.button(ctx, "Save environment", .{ .variant = .primary }).clicked) return .{ .environment = state.environment.text() };
        }
    } else {
        L.text(ctx, if (state.recording != null) "Press a key combination; Escape cancels." else "Click a shortcut, then type the new one. Delete removes it; Escape keeps it.", .{ .size = 12, .color = ctx.theme.muted, .wrap = true });
        ui.row(ctx, .{ .width = .fill, .height = .{ .px = 28 }, .gap = 8, .padding = .xy(10, 0), .radius = 8, .background = ctx.theme.text.alpha(0.045), .align_items = .center });
        C.icon(ctx, .search, 14);
        _ = L.field(ctx, &state.query, .{ .placeholder = "Search actions or shortcuts", .width = .fill, .bare = true, .size = 13 });
        ui.end(ctx);
        ui.scroll(ctx, .{ .width = .fill, .height = .fill, .grow = 1 });
        var group: []const u8 = "";
        var order: std.ArrayList(usize) = .empty;
        for (actions.all, 0..) |candidate, i| {
            var seen = false;
            for (actions.all[0..i]) |previous| if (std.mem.eql(u8, previous.menu, candidate.menu)) {
                seen = true;
                break;
            };
            if (seen) continue;
            for (actions.all, 0..) |action, index| if (std.mem.eql(u8, action.menu, candidate.menu)) order.append(ctx.alloc(), index) catch return null;
        }
        for (order.items) |index| {
            const action = actions.all[index];
            const label = @import("locale.zig").t(action.title);
            if (actions.fuzzy(state.query.text(), label) < 0 and actions.fuzzy(state.query.text(), action.id) < 0) continue;
            if (!std.mem.eql(u8, group, action.menu)) {
                ui.column(ctx, .{ .padding = .{ .top = 14, .bottom = 6, .left = 4 } });
                L.text(ctx, action.menu, .{ .size = 12, .weight = .semibold, .color = ctx.theme.muted });
                ui.end(ctx);
                group = action.menu;
            }
            ui.key(ctx, action.id);
            ui.row(ctx, .{ .width = .fill, .height = .{ .px = 34 }, .gap = 8, .padding = .xy(4, 0), .align_items = .center });
            ui.text(ctx, C.ellipsize(ctx, label, @max(100, ctx.size.w - 420), 13), .{ .size = 13 });
            ui.spacer(ctx);
            const chord = actions.keys(index, bindings, @import("builtin").os.tag == .macos);
            const node = ctx.open(.{ .min_width = 56, .height = .{ .px = 24 }, .padding = .xy(8, 0), .radius = 6, .background = ctx.theme.text.alpha(0.045), .align_items = .center, .justify = .center, .control = true }, "shortcut");
            const hit = ctx.interact(node, .{ .focusable = true });
            ui.text(ctx, if (state.recording == index) "…" else if (chord.len > 0) C.shortcutLabel(ctx, chord) else "—", .{ .size = 12, .color = if (state.recording == index) ctx.theme.accent else ctx.theme.muted });
            ui.end(ctx);
            if (hit.clicked) {
                state.recording = index;
                ctx.changed = true;
            }
            if (C.button(ctx, .close, "Unbind", 24)) {
                ui.end(ctx);
                ui.end(ctx);
                return .{ .binding = .{ .id = action.id, .chord = "none" } };
            }
            if (C.button(ctx, .reset, "Use the default", 24)) {
                ui.end(ctx);
                ui.end(ctx);
                return .{ .binding = .{ .id = action.id, .chord = "" } };
            }
            ui.end(ctx);
        }
        ui.end(ctx);
    }
    return null;
}
