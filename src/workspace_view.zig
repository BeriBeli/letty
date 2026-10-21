//! Pane tree presentation, geometry and input routing.
const std = @import("std");
const ui = @import("nanoui").ui;
const chrome = @import("chrome.zig");
const vt_api = @import("vt.zig");
pub fn draw(s: anytype, ctx: *ui.Context, index: usize, rect: ui.Rect) void {
    if (index == @import("layout.zig").document_root) return;
    const Frame = struct { index: usize, rect: ui.Rect, divider: bool = false };
    const pending = ctx.alloc().alloc(Frame, s.layout.nodes.len) catch {
        s.status = "Cannot allocate split geometry";
        s.drop_geometry_fault = true;
        return;
    };
    pending[0] = .{ .index = index, .rect = rect };
    var count: usize = 1;
    while (count > 0) {
        count -= 1;
        const entry = pending[count];
        const current = entry.index;
        const area = entry.rect;
        if (entry.divider) {
            chrome.box(ctx, area.x, area.y, area.w, area.h, if (s.cfg.split_divider_color) |color| ui.Color.hex(color) else ctx.theme.border);
            continue;
        }
        const node = s.layout.nodes[current];
        if (node.kind == .horizontal or node.kind == .vertical) {
            const horizontal = node.kind == .horizontal;
            const extent = if (horizontal) area.w else area.h;
            const origin = if (horizontal) area.x else area.y;
            const pointer = if (horizontal) ctx.input.mouse.x else ctx.input.mouse.y;
            var ratio = node.ratio;
            var divider = area;
            if (horizontal) {
                divider.x += @floor((extent - 1) * ratio) - 3;
                divider.w = 7;
            } else {
                divider.y += @floor((extent - 1) * ratio) - 3;
                divider.h = 7;
            }
            const hovered = divider.contains(ctx.input.mouse) and !s.search_open;
            if (hovered or s.drag_split == current) ctx.cursor = if (horizontal) .resize_left_right else .resize_up_down;
            if (hovered and ctx.input.pressed) {
                if (ctx.input.click_count == 2) {
                    ratio = 0.5;
                    s.layout.nodes[current].ratio = ratio;
                    s.save();
                } else s.drag_split = current;
            }
            if (s.drag_split == current) {
                if (ctx.input.down) {
                    ratio = std.math.clamp((pointer - origin) / @max(1, extent - 1), 0.1, 0.9);
                    s.layout.nodes[current].ratio = ratio;
                } else {
                    s.drag_split = null;
                    s.save();
                }
            }
            var a = area;
            var b = area;
            if (horizontal) {
                a.w = @floor((area.w - 1) * ratio);
                b.x += a.w + 1;
                b.w = @max(1, area.w - a.w - 1);
            } else {
                a.h = @floor((area.h - 1) * ratio);
                b.y += a.h + 1;
                b.h = @max(1, area.h - a.h - 1);
            }
            pending[count] = .{ .index = current, .rect = .{ .x = if (horizontal) b.x - 1 else area.x, .y = if (horizontal) area.y else b.y - 1, .w = if (horizontal) 1 else area.w, .h = if (horizontal) area.h else 1 }, .divider = true };
            pending[count + 1] = .{ .index = node.second, .rect = b };
            pending[count + 2] = .{ .index = node.first, .rect = a };
            count += 3;
            continue;
        }
        if (node.kind == .pane) drawPane(s, ctx, node.pane, area);
    }
}
fn drawPane(s: anytype, ctx: *ui.Context, pane: usize, rect: ui.Rect) void {
    const session = s.sessions[pane] orelse return;
    const v = &s.views[pane];
    ui.key(ctx, ctx.print("pane-{d}", .{session.id}));
    const at = ctx.open(.{ .absolute = true, .offset = .{ .x = rect.x, .y = rect.y }, .width = .{ .px = rect.w }, .height = .{ .px = rect.h }, .clip = true, .background = ui.Color.hex(s.cfg.background) }, null);
    defer ctx.end();
    const ax_target = @import("application_accessibility.zig").Target{ .window = s.id, .session = session.id, .tab = s.layout.tabs[s.layout.active_tab].id };
    s.ax.note(.{ .widget = ctx.node(at).id, .role = .pane, .target = ax_target, .intent = .pane, .label = "Terminal Pane" });
    s.ax.note(.{ .widget = ctx.node(at).id, .role = .terminal, .target = ax_target, .intent = .copy, .label = "Terminal", .inset = .{ s.cfg.padding_x[0], s.cfg.padding_y[0], s.cfg.padding_x[1] + 10, s.cfg.padding_y[1] } });
    if (ctx.input.pressed and !s.search_open and s.drag_split == null and rect.contains(ctx.input.mouse) and s.layout.active_pane != pane) {
        s.focusPane(pane);
        ctx.focus = 0;
    }
    const is_active = s.layout.active_pane == pane;
    const text_style = @import("terminal_runs.zig").configure(ctx, s.cfg) catch |err| failed: {
        ctx.text.last_shape_error = @errorName(err);
        break :failed ui.TextStyle{ .size = @import("terminal_runs.zig").fontSize(ctx, s.cfg), .mono = true };
    };
    const font = ctx.text.font(text_style);
    // Ghostty Metrics.zig rounds the grid in physical pixels. Rounding in
    // points adds tracking on Retina, and +2pt leading inflated every row.
    const scale = @max(1, ctx.scale);
    const cw = @max(1, @round(s.cfg.adjust_cell_width.apply(ctx.text.layout("M", text_style).width) * scale) / scale);
    const ch = @max(1, @round(s.cfg.adjust_cell_height.apply(font.ascent + font.descent + font.leading) * scale) / scale);
    const cols: u16 = @intFromFloat(std.math.clamp(@floor((rect.w - s.cfg.padding_x[0] - s.cfg.padding_x[1] - 10) / cw), 2, 512));
    const rows: u16 = @intFromFloat(std.math.clamp(@floor((rect.h - s.cfg.padding_y[0] - s.cfg.padding_y[1]) / ch), 1, 256));
    session.resize(cols, rows, @intFromFloat(@round(cw * scale)), @intFromFloat(@round(ch * scale)));
    // Publish only terminal cells: exclude tabs, divider/scrollbar and padding.
    if (s.drop_pane_count < s.drop_panes.len) {
        s.drop_panes[s.drop_pane_count] = .{ .session = session.id, .rect = .{
            .x = rect.x + s.cfg.padding_x[0],
            .y = rect.y + s.cfg.padding_y[0],
            .width = @min(@as(f32, @floatFromInt(cols)) * cw, @max(0, rect.w - s.cfg.padding_x[0] - s.cfg.padding_x[1] - 10)),
            .height = @min(@as(f32, @floatFromInt(rows)) * ch, @max(0, rect.h - s.cfg.padding_y[0] - s.cfg.padding_y[1])),
        } };
        s.drop_pane_count += 1;
    } else s.drop_geometry_fault = true;
    if (!s.modalOpen()) v.link.update(session, ctx, s.cfg, rect, cw, ch, ctx.input.pressed and ctx.input.mouse_button == 2) else {
        v.link.visible = false;
        v.link.refused = false;
    }
    // Modified click on a recognised link/path wins over selection, multi-click
    // and mouse reporting. Repeat clicks of one gesture never reopen the target.
    if (!s.modalOpen() and v.link.visible and ctx.input.pressed and ctx.input.mouse_button == 1) {
        s.focusPane(pane);
        if (ctx.input.click_count <= 1) {
            s.link_target.set(v.link.target.text());
            s.link_session = session.id;
            s.pending = .{ .action = .open_link };
        }
        ctx.input.clearEdges();
        ctx.changed = true;
    }
    if (!s.modalOpen() and ctx.input.pressed and ctx.input.mouse_button == 2 and rect.contains(ctx.input.mouse) and (!vt_api.lt_vt_mouse_tracking(session.vt) or ctx.input.shift)) {
        s.focusPane(pane);
        s.link_target.set(if (v.link.visible) v.link.target.text() else "");
        s.link_session = session.id;
        s.openContext(ctx, .terminal, session.id);
    }
    if (!s.modalOpen() and ctx.input.pressed and ctx.input.mouse_button == 3 and (@import("builtin").os.tag == .linux or s.clipboard_read_override != null) and rect.contains(ctx.input.mouse) and (!vt_api.lt_vt_mouse_tracking(session.vt) or ctx.input.shift)) {
        s.focusPane(pane);
        @import("clipboard.zig").request(s, ctx, true);
        ctx.input.clearEdges();
        ctx.changed = true;
    }
    const was_selecting = v.selecting;
    const bar_input = !s.modalOpen() and v.scrollbar.input(ctx, session.vt, rect);
    const content = s.navigation_rects.content;
    const find_hit = if (s.search_open) @import("search_overlay.zig").hitContent(ctx, .{ .x = content.x, .y = content.y, .w = content.w, .h = content.h }) else false;
    if (!bar_input and !find_hit and !s.modalOpen() and !v.input(session, ctx, rect, cw, ch, s.cfg, is_active and s.window_focused and !s.search_open and !s.sidebar.focused and !@import("application_preview.zig").focused(s) and s.drag_split == null)) s.status = "Input queue busy; retry after drain";
    if (was_selecting and !v.selecting and ctx.input.released and (!vt_api.lt_vt_mouse_tracking(session.vt) or ctx.input.shift)) @import("clipboard.zig").copySelection(s, ctx, session);
    if (s.search_open and is_active) @import("search_overlay.zig").update(s, ctx);
    if (s.cfg.kitty_graphics) {
        if (s.graphics_store == null) s.graphics_store = @import("nanoui_graphics_resources.zig").Store.init(ctx.text);
        v.graphics.prepare(session, ctx, s.cfg, cw, ch, rect, &s.graphics_store.?) catch |err| {
            v.graphics.error_name = @errorName(err);
            v.graphics.deactivate();
            if (err == error.OutOfMemory) session.renderFailed();
        };
    } else v.graphics.deactivate();
    const inspector_nodes = ctx.nodes.items.len;
    v.draw(session, ctx, s.cfg, cw, ch, is_active and s.window_focused and !s.search_open and !s.modalOpen() and !@import("application_preview.zig").focused(s), rect);
    if (s.cfg.kitty_graphics and s.status.len == 0) {
        const atlas = ctx.text.images.stats; // previous completed paint
        if (atlas.prepare_failed) s.status = "Image atlas preparation failed" else if (atlas.atlas_skipped > 0 or atlas.reference_limit > 0) s.status = "Kitty image skipped: shared atlas or visible-reference limit";
    }
    if (v.graphics.error_name) |reason| if (s.status.len == 0) {
        s.status = reason;
    };
    if (v.graphics.skipped > 0 and s.status.len == 0) s.status = "Kitty image skipped: renderer or placement limit";
    if (v.graphics.rejection_count > 0 and s.status.len == 0) s.status = "Kitty image rejected: storage budget exceeded";
    s.inspector.capture(session, ctx, s.cfg, cw, ch, inspector_nodes, s.id);
    const ax_bar_first = ctx.nodes.items.len;
    v.scrollbar.draw(ctx, session.vt, rect);
    if (ctx.nodes.items.len > ax_bar_first) s.ax.note(.{ .widget = ctx.nodes.items[ax_bar_first].id, .role = .scrollbar, .target = ax_target, .intent = .scrollbar, .label = "History Scrollbar" });
    if (!is_active) chrome.box(ctx, 0, 0, rect.w, rect.h, ui.Color.hex(s.cfg.background).alpha(1 - s.cfg.unfocused_split_opacity));
    if (ctx.text.last_shape_error) |reason| {
        const seen = s.shape_notice_seen;
        if ((seen == null or !std.mem.eql(u8, seen.?, reason)) and s.status.len == 0 and !session.fatal) {
            s.status = reason;
            s.shape_notice_seen = reason;
        }
    }
    if (session.fatal) s.status = "Session failed: collect stderr and close this pane";
}
