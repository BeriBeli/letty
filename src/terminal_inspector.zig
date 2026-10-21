//! Read-only, bounded current-viewport diagnostics. No key, paste or PTY input
//! recorder; no history mirror. Freeze holds this snapshot, not the terminal.
const std = @import("std");
const ui = @import("nanoui").ui;
const chrome = @import("chrome.zig");
const semantic = @import("ui_semantics.zig");
const vt = @import("vt.zig");
const Session = @import("session.zig").Session;
const Config = @import("config.zig").Config;
const Text = @import("fixed_text.zig").Text;
pub const Snapshot = struct {
    window: u64 = 0,
    session: u64 = 0,
    pid: c_int = 0,
    cwd: Text(4096) = .{},
    authority: Text(256) = .{},
    history_lines: usize = 0,
    history_bytes: usize = 0,
    recent_events: Text(1024) = .{},
    services: @import("application_service_diagnostics.zig").Snapshot = .{},
    cols: u16 = 0,
    rows: u16 = 0,
    cursor: vt.Cursor = .{},
    scroll: vt.Scroll = .{},
    bracketed: bool = false,
    mouse: bool = false,
    focus: bool = false,
    tx_bytes: usize = 0,
    cell_present: bool = false,
    cell_x: u32 = 0,
    cell_y: u32 = 0,
    cell_width: u32 = 0,
    flags: u32 = 0,
    fg: u32 = 0,
    bg: u32 = 0,
    underline: u8 = 0,
    sample: Text(256) = .{},
    configured_font: Text(256) = .{},
    actual_font: Text(512) = .{},
    glyphs: Text(512) = .{},
    feature_hash: u64 = 0,
    graphics: ?vt.GraphicsInfo = null,
    nodes: usize = 0,
    instances: usize = 0,
    build_ms: f64 = 0,
    layout_ms: f64 = 0,
    paint_ms: f64 = 0,
    shape_error: Text(128) = .{},
};
pub const Inspector = struct {
    open: bool = false,
    generation: u64 = 0,
    semantic_geometry: semantic.Geometry = .{},
    ax_pending: ?struct { generation: u64, control: u32 } = null,
    frozen: bool = false,
    show_cell_text: bool = false,
    last_events: vt.Events = .{},
    events: [8]Text(96) = @splat(.{}),
    event_count: usize = 0,
    event_next: usize = 0,
    target: u64 = 0,
    x: u32 = 0,
    y: u32 = 0,
    snapshot: Snapshot = .{},
    geometry: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    pub fn requestAx(self: *Inspector, generation: u64, control: u32) bool {
        if (!self.open or self.generation != generation or control > 6) return false;
        self.ax_pending = .{ .generation = generation, .control = control };
        return true;
    }
    pub fn show(self: *Inspector, ctx: *ui.Context, session: *Session) void {
        self.invalidate();
        self.open = true;
        self.target = session.id;
        ctx.focus = 0;
        ctx.active = 0;
        ctx.input.clearEdges();
        ctx.changed = true;
    }
    /// Also used when a source Session exits without a current UI Context.
    /// Clears opted-in body data and revokes queued actions/old semantic IDs.
    pub fn invalidate(self: *Inspector) void {
        @memset(&self.snapshot.sample.buf, 0);
        self.* = .{ .generation = self.generation +% 1 };
    }
    pub fn close(self: *Inspector, ctx: *ui.Context) void {
        self.invalidate();
        ctx.focus = 0;
        ctx.active = 0;
        ctx.input.clearEdges();
        ctx.changed = true;
    }
    /// Call after the target pane has built its nodes and closed its VT frame.
    /// start bounds actual font lookup to THIS pane's current frame nodes.
    pub fn capture(self: *Inspector, s: *Session, ctx: *ui.Context, cfg: Config, cw: f32, ch: f32, start: usize, window: u64) void {
        if (!self.open or self.frozen or self.target != s.id) return;
        self.x = @min(self.x, s.cols - 1);
        self.y = @min(self.y, s.rows - 1);
        var next: Snapshot = .{ .window = window, .pid = s.pid, .history_lines = cfg.scrollback_lines, .history_bytes = cfg.scrollback_bytes, .services = self.snapshot.services, .session = s.id, .cols = s.cols, .rows = s.rows, .tx_bytes = s.tx.len, .bracketed = vt.lt_vt_bracketed(s.vt), .mouse = vt.lt_vt_mouse_tracking(s.vt), .focus = vt.lt_vt_focus_enabled(s.vt), .graphics = vt.graphicsInfo(s.vt), .nodes = ctx.stats.nodes, .instances = ctx.stats.instances, .build_ms = ctx.stats.build_ms, .layout_ms = ctx.stats.layout_ms, .paint_ms = ctx.stats.paint_ms };
        next.cwd.set(s.cwd.text());
        var pwd: [8192]u8 = undefined;
        const pwd_len = vt.lt_vt_pwd(s.vt, &pwd, pwd.len);
        if (pwd_len > 0 and pwd_len <= pwd.len) if (@import("cwd.zig").decode(pwd[0..pwd_len])) |decoded| {
            const host = std.mem.sliceTo(&decoded.host, 0);
            var valid_authority = true;
            for (host) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, ".-:[]", byte) == null) {
                valid_authority = false;
            };
            next.authority.set(if (valid_authority) host else "[invalid authority]");
            // The raw URI is never displayed: userinfo/query/credential-like
            // authority components cannot enter diagnostic copies.
        };
        inline for (.{ "bells", "pwd", "prompts", "starts", "ends" }) |field| {
            const count = @field(s.events, field);
            if (count != @field(self.last_events, field)) {
                self.events[self.event_next].set(ctx.print("{s}={d}", .{ field, count }));
                self.event_next = (self.event_next + 1) % self.events.len;
                self.event_count = @min(self.event_count + 1, self.events.len);
            }
        }
        self.last_events = s.events;
        var recent: std.ArrayList(u8) = .empty;
        for (0..self.event_count) |i| {
            const index = (self.event_next + self.events.len - self.event_count + i) % self.events.len;
            recent.appendSlice(ctx.alloc(), ctx.print("{s}{s}", .{ if (i == 0) "" else "; ", self.events[index].text() })) catch {};
        }
        next.recent_events.set(recent.items);
        next.configured_font.set(cfg.font);
        if (cfg.effectiveFontFeatures()) |features| next.feature_hash = features.hash() else |_| {}
        if (ctx.text.last_shape_error) |reason| next.shape_error.set(reason);
        vt.lt_vt_scroll_info(s.vt, &next.scroll);
        if (vt.lt_vt_frame(s.vt, &next.cursor) == 0) {
            defer vt.lt_vt_frame_end(s.vt);
            var cell: vt.Cell = undefined;
            while (vt.lt_vt_next(s.vt, &cell)) {
                if (cell.y != self.y or cell.width == 0 or self.x < cell.x or self.x >= cell.x + cell.width) continue;
                next.cell_present = true;
                next.cell_x = cell.x;
                next.cell_y = cell.y;
                next.cell_width = cell.width;
                next.flags = cell.flags;
                next.fg = cell.fg;
                next.bg = cell.bg;
                next.underline = cell.underline;
                if (self.show_cell_text) if (cell.text) |bytes| next.sample.set(bytes[0..cell.len]);
                break;
            }
        }
        const px = cfg.padding_x[0] + @as(f32, @floatFromInt(self.x)) * cw;
        const py = cfg.padding_y[0] + @as(f32, @floatFromInt(self.y)) * ch;
        for (ctx.nodes.items[@min(start, ctx.nodes.items.len)..]) |node| switch (node.content) {
            .glyph_run => |run| {
                if (@abs(node.style.offset.y - py) > 0.1 or px < node.style.offset.x or px >= node.style.offset.x + node.style.width.px) continue;
                const col: u32 = @intFromFloat(@floor((px - node.style.offset.x) / cw));
                var byte: ?u32 = null;
                for (run.cells) |span| if (col >= span.col and col < span.col + span.width) {
                    byte = span.byte_start;
                    break;
                };
                const at = byte orelse continue;
                var cluster: ?u32 = null;
                for (run.glyphs) |glyph| if (glyph.index <= at and (cluster == null or glyph.index > cluster.?)) {
                    cluster = glyph.index;
                };
                var description: std.ArrayList(u8) = .empty;
                var count: usize = 0;
                for (run.glyphs) |glyph| if (cluster != null and glyph.index == cluster.?) {
                    if (count == 16) break;
                    if (count == 0) describeFont(ctx, glyph.font, &next.actual_font);
                    description.appendSlice(ctx.alloc(), ctx.print("{s}{d}@font{d}", .{ if (count == 0) "" else ", ", glyph.glyph, glyph.font })) catch {};
                    count += 1;
                };
                next.glyphs.set(description.items);
                break;
            },
            else => {},
        };
        self.snapshot = next;
    }
    fn toggleCellText(self: *Inspector) void {
        self.show_cell_text = !self.show_cell_text;
        if (!self.show_cell_text) {
            @memset(&self.snapshot.sample.buf, 0);
            self.snapshot.sample.len = 0;
        }
    }
    pub fn draw(self: *Inspector, ctx: *ui.Context) void {
        if (!self.open) return;
        self.semantic_geometry.begin(self.generation, ctx.frame);
        if (self.ax_pending) |pending| {
            self.ax_pending = null;
            if (pending.generation == self.generation) switch (pending.control) {
                0 => self.frozen = !self.frozen,
                1 => self.x -|= 1,
                2 => self.x +|= 1,
                3 => self.y -|= 1,
                4 => self.y +|= 1,
                5 => ctx.clipboard.write(ctx.clipboard.ctx, details(ctx, self.snapshot, false)),
                6 => self.toggleCellText(),
                else => {},
            };
        }
        var cancel = ctx.shortcut(.{ .key = ui.Shortcut.escape }) or ctx.input.key == .escape;
        for (ctx.input.ops) |op| if (op == .command and op.command == .cancel) {
            cancel = true;
        };
        const w = @max(1, @min(620, ctx.size.w - 24));
        const h = @max(1, @min(500, ctx.size.h - 24));
        self.geometry = .{ .x = (ctx.size.w - w) / 2, .y = (ctx.size.h - h) / 2, .w = w, .h = h };
        if (ctx.input.pressed and !self.geometry.contains(ctx.input.mouse)) cancel = true;
        if (cancel) {
            self.close(ctx);
            return;
        }
        ui.key(ctx, "inspector-modal");
        const modal = ctx.open(.{ .absolute = true, .width = .fill, .height = .fill }, null);
        _ = ctx.interact(modal, .{});
        defer ctx.end();
        self.semantic_geometry.add(ctx, .panel, 0, "Terminal Inspector", "", true, false, null);
        ui.column(ctx, .{ .absolute = true, .offset = .{ .x = self.geometry.x, .y = self.geometry.y }, .width = .{ .px = w }, .height = .{ .px = h }, .padding = .all(12), .gap = 8, .radius = 8, .clip = true, .background = ctx.theme.surface, .border = ctx.theme.border });
        defer ui.end(ctx);
        ui.text(ctx, "Terminal Inspector", .{ .size = 15 });
        ui.row(ctx, .{ .width = .fill, .gap = 6 });
        self.semantic_geometry.add(ctx, .command, 0, if (self.frozen) "Resume" else "Freeze", "", true, false, null);
        if (chrome.button(ctx, if (self.frozen) "Resume" else "Freeze", .{ .size = 12 }).clicked) {
            self.frozen = !self.frozen;
            ctx.changed = true;
        }
        self.semantic_geometry.add(ctx, .command, 1, "←", "", true, false, null);
        if (chrome.button(ctx, "←", .{ .size = 12 }).clicked) self.x -|= 1;
        self.semantic_geometry.add(ctx, .command, 2, "→", "", true, false, null);
        if (chrome.button(ctx, "→", .{ .size = 12 }).clicked) self.x +|= 1;
        self.semantic_geometry.add(ctx, .command, 3, "↑", "", true, false, null);
        if (chrome.button(ctx, "↑", .{ .size = 12 }).clicked) self.y -|= 1;
        self.semantic_geometry.add(ctx, .command, 4, "↓", "", true, false, null);
        if (chrome.button(ctx, "↓", .{ .size = 12 }).clicked) self.y +|= 1;
        self.semantic_geometry.add(ctx, .command, 6, if (self.show_cell_text) "Hide Cell Text" else "Show Cell Text", "", true, false, null);
        if (chrome.button(ctx, if (self.show_cell_text) "Hide Cell Text" else "Show Cell Text", .{ .size = 12 }).clicked) {
            self.toggleCellText();
            ctx.changed = true;
        }
        ui.end(ctx);
        ui.key(ctx, "inspector-details");
        ui.scroll(ctx, .{ .width = .fill, .height = .fill, .clip = true });
        const body = details(ctx, self.snapshot, true);
        ui.text(ctx, body, .{ .size = 12, .wrap = true });
        ui.end(ctx);
        ui.row(ctx, .{ .width = .fill, .gap = 8 });
        self.semantic_geometry.add(ctx, .command, 5, "Copy Diagnostics", "", true, false, null);
        if (chrome.button(ctx, "Copy Diagnostics", .{ .variant = .secondary, .size = 12 }).clicked) ctx.clipboard.write(ctx.clipboard.ctx, details(ctx, self.snapshot, false));
        ui.spacer(ctx);
        self.semantic_geometry.add(ctx, .cancel, 0, "Close", "", true, false, null);
        if (chrome.button(ctx, "Close", .{ .size = 12 }).clicked) self.close(ctx);
        ui.end(ctx);
    }
};
fn details(ctx: *ui.Context, s: Snapshot, include_cell_text: bool) []const u8 {
    const g = s.graphics;
    const service = s.services;
    const service_line = ctx.print("Services: global={d}; Quick={d} visible={any}; monitor events={any}; AX native={any} nodes={d}; queue={d} dropped={d}; cross-desktop=unsupported; diagnostic={s}\n", .{ service.hotkeys_registered, service.quick_window, service.quick_visible, service.screen_observer, service.ax_native, service.ax_nodes, service.queued, service.dropped, service.last_error.text() });
    const cell = ctx.print("Session {d}; grid {d}×{d}; cursor {d},{d} visible={any}\nHistory offset {d}/{d}; alternate={any}\nBracketed paste={any}; mouse={any}; focus reports={any}; queued input bytes={d}\n\nCell {d},{d}; width={d}; flags=0x{x}; underline={d}; fg=#{x:0>6}; bg=#{x:0>6}\nVisible cell: {s}\nConfigured font: {s}\nActual glyph source: {s}\nGlyph IDs: {s}\nEffective feature hash: {x}\nLast font diagnostic: {s}\n", .{ s.session, s.cols, s.rows, s.cursor.x, s.cursor.y, s.cursor.visible, s.scroll.offset, s.scroll.total, s.scroll.alternate, s.bracketed, s.mouse, s.focus, s.tx_bytes, s.cell_x, s.cell_y, s.cell_width, s.flags, s.underline, s.fg, s.bg, if (include_cell_text) s.sample.text() else "[omitted]", s.configured_font.text(), s.actual_font.text(), s.glyphs.text(), s.feature_hash, s.shape_error.text() });
    const renderer = ctx.print("\nPrevious completed frame: nodes={d}, instances={d}, build/layout/paint={d:.3}/{d:.3}/{d:.3} ms\nKitty enabled={any}; storage={d}; core/graphics heap={d}/{d}; image rejections={d}\n", .{ s.nodes, s.instances, s.build_ms, s.layout_ms, s.paint_ms, if (g) |v| v.enabled else false, if (g) |v| v.storage_used_bytes else 0, if (g) |v| v.core_used else 0, if (g) |v| v.graphics_used else 0, if (g) |v| v.rejections else 0 });
    const source = ctx.print("Window {d}; PID {d}\nLocal CWD: {s}; reported authority: {s}\nHistory budget: {d} lines / {d} bytes\nRecent metadata events (max 8): {s}\n", .{ s.window, s.pid, s.cwd.text(), s.authority.text(), s.history_lines, s.history_bytes, s.recent_events.text() });
    return ctx.print("{s}{s}{s}{s}\nRead-only viewport snapshot. Cell text capture is opt-in. No input or paste bodies recorded. Copy omits visible cell text.", .{ source, service_line, cell, renderer });
}
extern "c" fn CTFontCopyPostScriptName(*const anyopaque) ?*anyopaque;
extern "c" fn CFStringGetCString(*const anyopaque, [*]u8, isize, u32) u8;
extern "c" fn CFRelease(*const anyopaque) void;
fn describeFont(ctx: *ui.Context, id: u32, out: *Text(512)) void {
    if (id >= ctx.text.run_fonts.items.len) return;
    if (comptime @hasField(@typeInfo(@TypeOf(ctx.text)).pointer.child, "db")) {
        const face_id = ctx.text.run_faces.items[id];
        if (face_id >= ctx.text.db.faces.items.len) return;
        const face = ctx.text.db.faces.items[face_id];
        out.set(ctx.print("{s}, TTC face {d}", .{ std.fs.path.basename(face.path), face.index }));
    } else {
        const name = CTFontCopyPostScriptName(@ptrCast(ctx.text.run_fonts.items[id])) orelse return;
        defer CFRelease(name);
        var buffer: [512]u8 = undefined;
        if (CFStringGetCString(name, &buffer, buffer.len, 0x08000100) != 0) out.set(std.mem.sliceTo(&buffer, 0));
    }
}
