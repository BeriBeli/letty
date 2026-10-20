//! Portable floating terminal find bar.
const ui = @import("nanoui").ui;
const std = @import("std");
const vt_api = @import("vt.zig");
const chrome = @import("chrome.zig");
pub fn draw(s: anytype, ctx: *ui.Context, top: f32) void {
    const content = s.navigation_rects.content;
    const area: ui.Rect = if (content.w > 0) .{ .x = content.x, .y = content.y, .w = content.w, .h = content.h } else .{ .x = 0, .y = top, .w = ctx.size.w, .h = ctx.size.h - top };
    const placement = bounds(area);
    const width = placement.w;
    ui.key(ctx, "search-overlay");
    ui.row(ctx, .{ .absolute = true, .offset = .{ .x = placement.x, .y = placement.y }, .width = .{ .px = width }, .padding = .all(8), .gap = 4, .radius = 8, .border = ctx.theme.border.alpha(0.5), .background = ui.Color.hex(s.cfg.background), .shadow = .{ .color = ui.Color.black.alpha(0.12), .blur = 8, .y = 2 }, .align_items = .center });
    defer ui.end(ctx);
    ui.row(ctx, .{ .width = .{ .px = @max(1, width - 104) }, .height = .{ .px = 28 }, .padding = .xy(8, 0), .radius = 6, .background = ctx.theme.text.alpha(0.06), .align_items = .center });
    ui.key(ctx, "find-query");
    const ax_target = @import("application_accessibility.zig").Target{ .window = s.id, .session = if (s.active()) |p| p.id else 0, .tab = s.layout.tabs[s.layout.active_tab].id };
    s.ax.note(.{ .widget = ctx.peekId(null), .role = .search, .target = ax_target, .intent = .query, .label = "Find Text" });
    if (s.search_focus) {
        ctx.focus = ctx.peekId(null);
        s.search_focus = false;
    }
    const result = ui.textField(ctx, &s.query, .{ .placeholder = "Search", .width = .{ .px = @max(1, width - 210) }, .size = 12, .bare = true });
    ui.spacer(ctx);
    const count = if (s.search_failed) "Search failed" else if (s.total == 0 and s.query.len > 0) (if (s.search_info.running) "Searching…" else "No results") else ctx.print("{d}/{d}{s}", .{ s.search_info.current, s.total, if (s.search_info.running) "…" else "" });
    ui.text(ctx, count, .{ .size = 10, .color = ctx.theme.muted });
    ui.end(ctx);
    if (s.active() != null) {
        ui.key(ctx, "search-previous");
        s.ax.note(.{ .widget = ctx.peekId(null), .role = .button, .target = ax_target, .intent = .search_previous, .label = "Previous Match" });
        if (chrome.iconButton(ctx, .up, 24)) s.pending = .{ .action = .search_previous };
        ui.key(ctx, "search-next");
        s.ax.note(.{ .widget = ctx.peekId(null), .role = .button, .target = ax_target, .intent = .search_next, .label = "Next Match" });
        if (chrome.iconButton(ctx, .down, 24) or result.submitted) s.pending = .{ .action = if (result.submitted and ctx.input.shift) .search_previous else .search_next };
    }
    ui.key(ctx, "search-close");
    s.ax.note(.{ .widget = ctx.peekId(null), .role = .button, .target = ax_target, .intent = .search_close, .label = "Close Find" });
    if (chrome.iconButton(ctx, .close, 24)) s.pending = .{ .action = .search };
}

pub fn update(s: anytype, ctx: *ui.Context) void {
    if (s.active()) |session| {
        if (!std.mem.eql(u8, s.last_query.items, s.query.text())) {
            s.search_failed = false;
            s.last_query.clearRetainingCapacity();
            s.last_query.appendSlice(s.gpa, s.query.text()) catch {
                s.status = "Cannot allocate search query";
                s.search_failed = true;
                return;
            };
            if (vt_api.lt_vt_search(session.vt, s.last_query.items.ptr, s.last_query.items.len) != 0) {
                s.status = "Search failed";
                s.search_failed = true;
            }
        }
        const pending = vt_api.lt_vt_search_tick(session.vt, &s.total);
        vt_api.lt_vt_search_info(session.vt, &s.search_info);
        if (pending < 0) {
            s.status = "Search failed";
            s.search_failed = true;
        }
        if (pending > 0 or s.search_info.running) ctx.frameIn(0.016);
    }
}

pub fn hit(ctx: *ui.Context, top: f32) bool {
    return hitContent(ctx, .{ .x = 0, .y = top, .w = ctx.size.w, .h = ctx.size.h - top });
}
pub fn bounds(content: ui.Rect) ui.Rect {
    const width = @max(1, @min(368, content.w - 16));
    return .{ .x = content.x + @max(0, content.w - width - 8), .y = content.y + 8, .w = width, .h = 44 };
}
pub fn hitContent(ctx: *ui.Context, content: ui.Rect) bool {
    return bounds(content).contains(ctx.input.mouse);
}
