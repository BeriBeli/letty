//! nanoui port of Kero's mygo palette, Rex wash and pane-card geometry.
//! Source: egoist/kero@4f6b7e04fb96b928441ca78d1eb35638b3af58ab.
//! Copyright (c) 2026 EGOIST, MIT; see assets/licenses/kero-MIT.txt.
const ui = @import("nanoui").ui;
const chrome = @import("chrome.zig");
const titles = @import("terminal_title.zig");

pub const card_gap: f32 = 8;
pub const header_height: f32 = 44;
pub const card_radius: f32 = 14;
pub const Pending = struct { window: u64, tab: u64, session: u64, action: @import("actions.zig").Action };

pub fn overlay(ctx: *const ui.Context) ui.Color {
    return if (light(ctx)) ui.Color.hex(0x0a0a1e).alpha(0.12) else ui.Color.black.alpha(0.35);
}
pub fn queue(s: anytype, session: u64, action: @import("actions.zig").Action) void {
    s.chrome_action = .{ .window = s.id, .tab = s.layout.tabs[s.layout.active_tab].id, .session = session, .action = action };
}
pub fn drain(s: anytype, ctx: *ui.Context) void {
    const pending = s.chrome_action orelse return;
    s.chrome_action = null;
    if (pending.window != s.id or s.closing or s.modalOpen() or @import("navigation/sidebar.zig").composing(s, ctx)) return;
    const tab = s.layout.tabIndex(pending.tab) orelse return;
    for (s.sessions, 0..) |entry, slot| if (entry) |session| if (session.id == pending.session and s.layout.contains(s.layout.roots[tab], slot)) {
        s.activateTab(tab);
        s.focusPane(slot);
        s.sidebar.focused = false;
        s.pending = .{ .action = pending.action };
        s.perform(ctx);
        return;
    };
}

pub fn light(ctx: *const ui.Context) bool {
    const bg = ctx.theme.background;
    return bg.r * 0.299 + bg.g * 0.587 + bg.b * 0.114 > 0.5;
}
pub fn chosen(ctx: *const ui.Context) ui.Color {
    return if (light(ctx)) .white else ui.Color.white.alpha(0.10);
}
pub fn edge(ctx: *const ui.Context) ui.Color {
    return if (light(ctx)) ui.Color.black.alpha(0.07) else ui.Color.white.alpha(0.08);
}
pub fn shadow(ctx: *const ui.Context) ui.Color {
    return ui.Color.black.alpha(if (light(ctx)) 0.07 else 0.35);
}
pub fn wash(ctx: *ui.Context, style: @import("config.zig").BackgroundStyle, width: f32, height: f32) void {
    const Asset = struct { key: []const u8, bytes: []const u8 };
    const asset: Asset = switch (style) {
        .rex => if (light(ctx)) .{ .key = "letty-rex-light", .bytes = @embedFile("ui_assets/rex-light.png") } else .{ .key = "letty-rex-dark", .bytes = @embedFile("ui_assets/rex-dark.png") },
        .mist => if (light(ctx)) .{ .key = "letty-mist-light", .bytes = @embedFile("ui_assets/rex-mist-light.png") } else .{ .key = "letty-mist-dark", .bytes = @embedFile("ui_assets/rex-mist-dark.png") },
        .meadow => if (light(ctx)) .{ .key = "letty-meadow-light", .bytes = @embedFile("ui_assets/rex-meadow-light.png") } else .{ .key = "letty-meadow-dark", .bytes = @embedFile("ui_assets/rex-meadow-dark.png") },
        .dusk => if (light(ctx)) .{ .key = "letty-dusk-light", .bytes = @embedFile("ui_assets/rex-dusk-light.png") } else .{ .key = "letty-dusk-dark", .bytes = @embedFile("ui_assets/rex-dusk-dark.png") },
        .plain => if (light(ctx)) .{ .key = "letty-plain-light", .bytes = @embedFile("ui_assets/rex-plain-light.png") } else .{ .key = "letty-plain-dark", .bytes = @embedFile("ui_assets/rex-plain-dark.png") },
    };
    const at: u32 = @intCast(ctx.nodes.items.len);
    if (ui.image(ctx, .{ .key = asset.key, .bytes = asset.bytes, .radius = 0 })) ctx.node(at).style = .{ .absolute = true, .width = .{ .px = width }, .height = .{ .px = height } };
}
pub fn backdrop(ctx: *ui.Context, style: @import("config.zig").BackgroundStyle) void {
    ui.key(ctx, "letty-backdrop");
    wash(ctx, style, ctx.size.w, ctx.size.h);
}

/// The terminal body is the sole rectangle used by cells, selection, images,
/// scrollbar, IME, accessibility and file-drop publication.
pub fn body(card: ui.Rect) ui.Rect {
    const inset = @min(1, @min(card.w, card.h) / 2);
    const title = @min(header_height, @max(0, card.h - 2 * inset));
    return .{ .x = card.x + inset, .y = card.y + inset + title, .w = @max(0, card.w - 2 * inset), .h = @max(0, card.h - title - 2 * inset) };
}

pub fn pane(s: anytype, ctx: *ui.Context, slot: usize, area: ui.Rect) ui.Rect {
    const session = s.sessions[slot] orelse return area;
    const inset = @min(card_gap / 2, @min(area.w, area.h) / 2);
    const card: ui.Rect = .{ .x = area.x + inset, .y = area.y + inset, .w = @max(0, area.w - 2 * inset), .h = @max(0, area.h - 2 * inset) };
    ui.key(ctx, ctx.print("pane-card-{d}", .{session.id}));
    _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = card.x, .y = card.y }, .width = .{ .px = card.w }, .height = .{ .px = card.h }, .radius = card_radius, .background = .hex(s.cfg.background), .border = edge(ctx), .shadow = .{ .color = shadow(ctx), .blur = 6, .y = 2 } }, .none, null);
    const header: ui.Rect = .{ .x = card.x + 1, .y = card.y + 1, .w = @max(0, card.w - 2), .h = @min(header_height, @max(0, card.h - 2)) };
    const enabled = !s.modalOpen() and !@import("navigation/sidebar.zig").composing(s, ctx);
    if (header.contains(ctx.input.mouse) and ctx.input.pressed and enabled) {
        s.focusPane(slot);
        s.sidebar.focused = false;
        ctx.focus = 0;
        if (ctx.input.mouse_button == 2) openMenu(s, ctx, session.id);
        ctx.changed = true;
    }
    ui.key(ctx, ctx.print("pane-header-{d}", .{session.id}));
    // Zoom changes the visible geometry, not the session's pane count. Keep
    // multi-pane controls available so the zoomed pane can show all panes again.
    const single = s.layout.nodes[s.layout.roots[s.layout.active_tab]].kind == .pane;
    const first = card.y < 16 and card.x < 16;
    const leading: f32 = if (first and s.navigation_rects.compact != null) (if (@import("builtin").os.tag == .macos) @as(f32, 158) else 78) else 16;
    const show_controls = enabled and (area.contains(ctx.input.mouse) or (!single and s.layout.active_pane == slot));
    const reserve: f32 = if (show_controls) (if (single) @as(f32, 56) else 112) else 0;
    _ = ctx.open(.{ .absolute = true, .offset = .{ .x = header.x, .y = header.y }, .width = .{ .px = header.w }, .height = .{ .px = header.h }, .direction = .row, .padding = .{ .left = leading, .right = 10 }, .gap = 8, .align_items = .center, .clip = true }, null);
    defer ctx.end();
    if (!single) chrome.icon(ctx, .terminal, 14);
    const title = if (single) s.tabLabel(s.layout.active_tab) else s.label(slot);
    const available = @max(0, header.w - leading - reserve - 32);
    const show_path = available > 320 and session.cwd.len > 0 and !@import("std").mem.eql(u8, title, session.cwd.text());
    const title_width = if (show_path) available * 0.5 else available;
    ui.text(ctx, chrome.ellipsize(ctx, bounded(title), title_width, if (single) 14 else 13.5), .{ .size = if (single) 14 else 13.5, .weight = .semibold, .color = if (s.layout.active_pane == slot) ctx.theme.text else ctx.theme.muted });
    if (show_path) ui.text(ctx, chrome.ellipsize(ctx, bounded(session.cwd.text()), available * 0.5 - 8, 13), .{ .size = 13, .color = ctx.theme.muted });
    ui.key(ctx, "pane-window-drag");
    const gap_node = ctx.open(.{ .width = .fill, .height = .fill }, null);
    _ = ctx.interact(gap_node, .{});
    ctx.end();
    if (ctx.rects.get(ctx.node(gap_node).id)) |gap_rect| @import("window_chrome.zig").drag(s.window, ctx, gap_rect);
    if (show_controls) {
        ui.key(ctx, "pane-controls");
        _ = ctx.open(.{ .direction = .row, .gap = 0, .align_items = .center, .height = .{ .px = 28 } }, null);
        paneButton(s, ctx, session.id, .split_right, .pane_split_right, "Split right", .horizontal);
        paneButton(s, ctx, session.id, .split_down, .pane_split_down, "Split down", .vertical);
        if (!single) {
            paneButton(s, ctx, session.id, if (s.zoom == session.id) .unzoom else .zoom, .pane_zoom, if (s.zoom == session.id) "Show all panes" else "Zoom pane", .toggle_zoom);
            paneButton(s, ctx, session.id, .close, .pane_close, "Close pane", .close);
        }
        ctx.end();
    }
    if (s.preview.rect.w <= 0 and card.y < 16 and card.x + card.w >= s.navigation_rects.content.x + s.navigation_rects.content.w - 12 and @import("window_chrome.zig").controls(ctx, s.window)) s.pending = .{ .action = .close_window };
    return body(card);
}

pub fn openMenu(s: anytype, ctx: *ui.Context, session: u64) void {
    s.link_target.set("");
    s.link_session = session;
    s.openContext(ctx, .terminal, session);
}

fn bounded(text: []const u8) []const u8 {
    return titles.validPrefix(text[0..@min(256, text.len)]);
}

fn paneButton(s: anytype, ctx: *ui.Context, session: u64, icon: chrome.Icon, intent: @import("application_ax_lifecycle.zig").Intent, title: []const u8, action: @import("actions.zig").Action) void {
    ui.key(ctx, title);
    s.ax.note(.{ .widget = ctx.peekId(null), .role = .button, .target = .{ .window = s.id, .session = session, .tab = s.layout.tabs[s.layout.active_tab].id }, .intent = intent, .label = title });
    if (chrome.iconButton(ctx, icon, 28)) queue(s, session, action);
}

pub fn status(ctx: *ui.Context, row: anytype, size: f32) void {
    const icon: chrome.Icon = if (row.failed > 0 or row.progress_error) .status_failed else if (row.unread_bells > 0) .status_waiting else if (row.running > 0 or row.progress_count > 0) working: {
        const frames = [_]chrome.Icon{ .status_working_0, .status_working_1, .status_working_2, .status_working_3, .status_working_4, .status_working_5, .status_working_6, .status_working_7 };
        const frame: usize = @intFromFloat(@mod(ui.clock.now() * 8, 8));
        ctx.frameIn(0.125);
        break :working frames[frame];
    } else if (row.done > 0) .status_done else .status_idle;
    chrome.icon(ctx, icon, size);
}
