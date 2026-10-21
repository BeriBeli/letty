//! nanoui adapter over the existing WindowState/Layout. input() runs before
//! terminal input; draw() only emits controls and semantic notes. No providers.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("nanoui").ui;
const chrome = @import("../chrome.zig");
pub const geometry = @import("geometry.zig");
pub const State = @import("state.zig").State;
const metrics = @import("state.zig");
const Key = @typeInfo(@FieldType(@FieldType(ui.Context, "input"), "key")).optional.child;
pub const Control = enum { collapse, new, palette };
pub const RowAction = enum { pin, close };
pub fn controlRect(nav: geometry.Rect, which: Control) geometry.Rect {
    if (nav.w <= geometry.compact_width and which != .collapse) return .{
        .x = nav.x + 6,
        .y = nav.y + @max(0, nav.h - (if (which == .new) @as(f32, 72) else 38)),
        .w = @max(0, nav.w - 12),
        .h = 32,
    };
    return switch (which) {
        .collapse => .{ .x = nav.x + 6, .y = nav.y + 7, .w = 26, .h = 28 },
        .new => .{ .x = nav.x + nav.w - 36, .y = nav.y + 7, .w = 26, .h = 28 },
        .palette => .{ .x = nav.x + 6, .y = nav.y + @max(0, nav.h - metrics.footer_height), .w = @max(0, nav.w - 16), .h = metrics.footer_height },
    };
}
pub fn rowActionRect(row: geometry.Rect, action: RowAction) geometry.Rect {
    return .{ .x = row.x + row.w - (if (action == .pin) @as(f32, 50) else 26), .y = row.y + 4, .w = 23, .h = 24 };
}
fn updateRects(s: anytype, ctx: *ui.Context) void {
    // Keep the shared content rectangle (including the preview dock) current.
    s.navigation_rects = s.navigationGeometry(ctx.size.w, ctx.size.h);
    const compact_now = s.navigation_rects.compact != null;
    if (s.sidebar.compact != compact_now) {
        s.sidebar.compact = compact_now;
        s.sidebar.reveal(s.layout.active_tab, s.navigation_rects.navigation);
    }
}
fn activate(s: anytype, tab: usize) void {
    if (tab != s.layout.active_tab) s.activateTab(tab);
    s.sidebar.acknowledge(s, tab);
    s.sidebar.selected = s.layout.tabs[tab].id;
    s.sidebar.last_active = s.layout.tabs[tab].id;
    s.sidebar.last_active_index = tab;
    s.sidebar.reveal(tab, s.navigation_rects.navigation);
    _ = s.sidebar.refresh(s);
}
fn composing(s: anytype, ctx: *const ui.Context) bool {
    if (ctx.marked_text_id != 0) return true;
    if (s.layout.tab_count > 0 and s.views[s.layout.active_pane].preedit.items.len > 0) return true;
    for (ctx.input.ops) |op| if (op == .set_marked or op == .unmark) return true;
    return false;
}
fn consume(ctx: *ui.Context) bool {
    ctx.input.clearEdges();
    return true;
}
fn plainKey(ctx: *const ui.Context) ?Key {
    if (ctx.input.key) |key| return key;
    if (ctx.input.shortcut) |sc| return switch (sc.key) {
        ui.Shortcut.up => .up,
        ui.Shortcut.down => .down,
        ui.Shortcut.escape => .escape,
        ui.Shortcut.enter => .enter,
        ui.Shortcut.tab => .tab,
        else => null,
    };
    for (ctx.input.ops) |op| if (op == .command) return switch (op.command) {
        .cancel => .escape,
        .insert_newline => .enter,
        .insert_tab => .tab,
        else => null,
    };
    return null;
}
/// true means this event belongs to navigation and must not reach VT/split
/// selection. Caller computes shared Rects first; resize/toggle update them.
pub fn input(s: anytype, ctx: *ui.Context) bool {
    const st = &s.sidebar;
    if (s.cfg.workspace_navigation != .sidebar or !s.window_focused or s.modalOpen()) {
        const interacting = st.dragging != null or st.resizing != null or st.focused;
        st.cancel();
        if (s.cfg.workspace_navigation == .sidebar) updateRects(s, ctx);
        if (interacting) ctx.changed = true;
        return false;
    }
    // nanoui may rebuild a changed frame up to four times. A pointer event,
    // edge autoscroll tick and release commit each run only once per frame.
    if (st.input_frame == ctx.frame) return st.focused or st.dragging != null or st.resizing != null;
    st.input_frame = ctx.frame;
    _ = st.refresh(s);
    const nav = s.navigation_rects.navigation;
    const compact_now = s.navigation_rects.compact != null;
    if (st.compact != compact_now) {
        st.compact = compact_now;
        st.reveal(s.layout.active_tab, nav);
    }
    if (st.have_rects and !std.meta.eql(st.last_rects, s.navigation_rects) and st.resizing == null) {
        // A resize/mode transition invalidates old drag coordinates.
        st.dragging = null;
    }
    st.last_rects = s.navigation_rects;
    st.have_rects = true;
    if (s.layout.tab_count > 0) {
        const active = s.layout.tabs[s.layout.active_tab].id;
        if (st.last_active != active or st.last_active_index != s.layout.active_tab) {
            const changed_tab = st.last_active != active;
            st.last_active = active;
            st.last_active_index = s.layout.active_tab;
            st.selected = active;
            if (changed_tab) st.acknowledge(s, s.layout.active_tab);
            st.reveal(s.layout.active_tab, nav);
            _ = st.refresh(s);
        }
    }
    st.clampScroll(nav);
    const over = nav.contains(ctx.input.mouse);
    const ime = composing(s, ctx);
    if (ime and (st.focused or st.dragging != null or st.resizing != null or (over and (ctx.input.pressed or ctx.input.released)))) {
        st.dragging = null;
        if (st.resizing) |r| st.width = r.original_width;
        st.resizing = null;
        updateRects(s, ctx);
        return consume(ctx);
    }
    if ((st.dragging != null or st.resizing != null or st.focused) and plainKey(ctx) == .escape) {
        st.cancel();
        updateRects(s, ctx);
        ctx.changed = true;
        return consume(ctx);
    }
    if (st.resizing) |r| {
        ctx.cursor = .resize_left_right;
        if (ctx.input.released) {
            const changed = st.width != r.original_width;
            st.resizing = null;
            if (changed) s.save();
        } else if (!ctx.input.down) {
            st.width = r.original_width;
            st.resizing = null;
        } else {
            st.width = geometry.sanitizedWidth(r.original_width + ctx.input.mouse.x - r.origin_x);
        }
        updateRects(s, ctx);
        ctx.changed = true;
        return consume(ctx);
    }
    if (st.dragging) |*drag| {
        if (s.layout.tabIndex(drag.id) == null) {
            st.dragging = null;
            return consume(ctx);
        }
        drag.moved = drag.moved or @abs(ctx.input.mouse.y - drag.origin_y) > 6;
        drag.target = st.dropAt(ctx.input.mouse, nav);
        if (drag.target) |target| if (s.layout.tabIndex(drag.id)) |from| {
            if (s.layout.tabs[target].pinned != s.layout.tabs[from].pinned) drag.target = null;
        };
        if (ctx.input.released) {
            const pending = drag.*;
            st.dragging = null; // Commit/click decision can happen only once.
            if (pending.moved) {
                if (pending.target) |target| if (s.layout.tabIndex(pending.id)) |from| if (from != target) {
                    s.layout.move(from, target);
                    s.save();
                };
            } else if (pending.target) |target| if (s.layout.tabs[target].id == pending.id) {
                activate(s, target);
                if (ctx.input.click_count >= 2) s.pending = .{ .action = .rename_tab };
            };
        } else if (!ctx.input.down or !over) {
            // Leaving the navigation rectangle cancels, never clamps to a tab.
            st.dragging = null;
        } else if (drag.moved) {
            const list = st.listRect(nav);
            if (ctx.input.mouse.y < list.y + 12) st.scroll -= 12;
            if (ctx.input.mouse.y > list.y + list.h - 12) st.scroll += 12;
            st.clampScroll(nav);
            ctx.frameIn(0.016);
        }
        ctx.changed = true;
        return consume(ctx);
    }
    if (over and ctx.input.scroll.y != 0) {
        st.scroll -= ctx.input.scroll.y;
        st.clampScroll(nav);
        ctx.changed = true;
        return consume(ctx);
    }
    if (ctx.input.pressed) {
        if (!over) {
            st.focused = false;
            return false;
        }
        st.focused = true;
        ctx.focus = 0;
        s.drag_split = null;
        s.drag_tab = null;
        if (s.layout.tab_count > 0) s.views[s.layout.active_pane].selecting = false;
        if (ctx.input.mouse_button == 1) {
            if (s.navigation_rects.compact) |compact| {
                if (compact.contains(ctx.input.mouse)) {
                    st.collapsed = false;
                    st.focused = false;
                    updateRects(s, ctx);
                    s.save();
                } else if (controlRect(nav, .new).contains(ctx.input.mouse) or controlRect(nav, .palette).contains(ctx.input.mouse)) {
                    s.pending = .{ .action = if (controlRect(nav, .new).contains(ctx.input.mouse)) .tab else .palette };
                    st.focused = false;
                } else if (st.rowAt(ctx.input.mouse, nav)) |index| {
                    activate(s, index);
                    st.focused = false;
                    if (s.preview.active(s.layout.tabs[index].id)) |doc| doc.panel.focused = false;
                    s.syncFocus();
                }
            } else if (s.navigation_rects.resize.contains(ctx.input.mouse)) {
                st.resizing = .{ .origin_x = ctx.input.mouse.x, .original_width = st.width };
            } else if (controlRect(nav, .collapse).contains(ctx.input.mouse)) {
                st.toggle();
                updateRects(s, ctx);
                s.save();
            } else if (controlRect(nav, .new).contains(ctx.input.mouse)) {
                s.pending = .{ .action = .tab };
            } else if (controlRect(nav, .palette).contains(ctx.input.mouse)) {
                s.pending = .{ .action = .palette };
            } else if (st.rowAt(ctx.input.mouse, nav)) |tab| {
                const row = st.rowRect(tab, nav);
                if (rowActionRect(row, .close).contains(ctx.input.mouse)) {
                    activate(s, tab);
                    s.pending = .{ .action = .close_tab };
                } else if (rowActionRect(row, .pin).contains(ctx.input.mouse)) {
                    activate(s, tab);
                    s.pending = .{ .action = .toggle_tab_pin };
                } else st.dragging = .{ .id = s.layout.tabs[tab].id, .origin_y = ctx.input.mouse.y };
            }
        } else if (ctx.input.mouse_button == 2) {
            if (st.rowAt(ctx.input.mouse, nav)) |tab| {
                activate(s, tab);
                s.openContext(ctx, .tab, s.layout.tabs[tab].id);
            }
        }
        ctx.changed = true;
        return consume(ctx);
    }
    if (st.focused) {
        const key = plainKey(ctx);
        if (key == .tab or key == .right) {
            st.focused = false;
            ctx.focus = 0;
        } else if (s.layout.tab_count > 0) {
            const at = s.layout.tabIndex(st.selected) orelse s.layout.active_tab;
            var target = at;
            if (key == .up) target -|= 1;
            if (key == .down) target = @min(s.layout.tab_count - 1, at + 1);
            if (key == .home) target = 0;
            if (key == .end) target = s.layout.tab_count - 1;
            if (target != at or key == .enter) activate(s, target);
        }
        if (key != null or ctx.input.chars.len > 0 or ctx.input.ops.len > 0 or ctx.input.shortcut != null) {
            ctx.changed = true;
            return consume(ctx);
        }
    }
    // A pointer parked in navigation does not own terminal keystrokes or IME.
    return if (over and ctx.input.released) consume(ctx) else false;
}

fn box(ctx: *ui.Context, r: geometry.Rect, color: ui.Color) u32 {
    return ctx.open(.{ .absolute = true, .offset = .{ .x = r.x, .y = r.y }, .width = .{ .px = r.w }, .height = .{ .px = r.h }, .background = color, .clip = true, .control = true }, null);
}
fn label(ctx: *ui.Context, x: f32, y: f32, text: []const u8, size: f32, color: ui.Color) void {
    _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y } }, .{ .text = .{ .str = text, .style = .{ .size = size }, .color = color } }, null);
}
fn control(s: anytype, ctx: *ui.Context, r: geometry.Rect, key: []const u8, title: []const u8, text: []const u8, intent: anytype) void {
    ui.key(ctx, key);
    s.ax.note(.{ .widget = ctx.peekId(null), .role = .button, .target = .{ .window = s.id }, .intent = intent, .label = title });
    const at = box(ctx, r, if (r.contains(ctx.input.mouse)) ctx.theme.surface_hover else ctx.theme.surface);
    _ = ctx.interact(at, .{ .focusable = true });
    _ = ctx.open(.{ .absolute = true, .offset = .{ .x = if (r.w <= geometry.compact_width) (r.w - 16) / 2 else 5, .y = (r.h - 16) / 2 } }, null);
    chrome.icon(ctx, if (std.mem.eql(u8, key, "sidebar-new")) .plus else if (std.mem.eql(u8, key, "sidebar-commands")) .search else if (std.mem.eql(u8, key, "sidebar-expand")) .right else .left, 16);
    ctx.end();
    if (std.mem.eql(u8, key, "sidebar-commands") and r.w > 80) label(ctx, 29, 7, "Commands", 11, ctx.theme.muted);
    if (std.mem.eql(u8, key, "sidebar-commands") and r.w > 180) label(ctx, r.w - 68, 7, if (builtin.os.tag == .macos) "⌘ ⇧ P" else "Ctrl ⇧ P", 10, ctx.theme.muted);
    _ = text;
    ctx.end();
}
fn rowControl(s: anytype, ctx: *ui.Context, row: anytype, bounds: geometry.Rect, action: RowAction) void {
    const r = rowActionRect(bounds, action);
    ui.key(ctx, if (action == .pin) "sidebar-pin" else "sidebar-close");
    s.ax.note(.{ .widget = ctx.peekId(null), .role = .button, .target = .{ .window = s.id, .tab = row.id }, .intent = if (action == .pin) .tab_pin else .tab_close, .label = if (action == .pin) (if (row.pinned) "Unpin Workspace" else "Pin Workspace") else "Close Workspace" });
    const surface = s.sidebar.rowRect(s.layout.tabIndex(row.id).?, s.navigation_rects.navigation);
    const pointer: ui.Point = .{ .x = ctx.input.mouse.x - surface.x, .y = ctx.input.mouse.y - surface.y };
    const at = box(ctx, r, if (r.contains(pointer)) ctx.theme.surface_hover else ctx.theme.surface.alpha(0));
    _ = ctx.interact(at, .{});
    _ = ctx.open(.{ .absolute = true, .offset = .{ .x = 4, .y = 4 } }, null);
    chrome.icon(ctx, if (action == .pin) .pin else .close, 14);
    ctx.end();
    ctx.end();
}
pub fn draw(s: anytype, ctx: *ui.Context) void {
    if (s.cfg.workspace_navigation != .sidebar) return;
    const st = &s.sidebar;
    _ = st.refresh(s);
    const nav = s.navigation_rects.navigation;
    if (nav.w <= 0 or nav.h <= 0) return;
    ctx.wants_moves = true;
    ctx.wants_wheel = true;
    ui.key(ctx, "sidebar");
    s.ax.note(.{ .widget = ctx.peekId(null), .role = .tab_group, .target = .{ .window = s.id }, .label = "Workspaces" });
    _ = box(ctx, nav, ctx.theme.surface);
    // Children below use surface coordinates through an offsetting wrapper.
    ctx.end();
    if (s.navigation_rects.compact) |compact| {
        control(s, ctx, compact, "sidebar-expand", ctx.print("Expand workspace sidebar, {d} workspaces", .{s.layout.tab_count}), ctx.print("›  {d}", .{s.layout.tab_count}), .sidebar_toggle);
        control(s, ctx, controlRect(nav, .new), "sidebar-new", "New Workspace", "+", .new_tab);
        control(s, ctx, controlRect(nav, .palette), "sidebar-commands", "Commands", "…", .palette);
        const list = st.listRect(nav);
        _ = ctx.open(.{ .absolute = true, .offset = .{ .x = list.x, .y = list.y }, .width = .{ .px = list.w }, .height = .{ .px = list.h }, .clip = true }, null);
        for (st.snapshot.rows[0..st.snapshot.count], 0..) |*row, index| {
            const r = st.rowRect(index, nav);
            if (r.y + r.h <= list.y or r.y >= list.y + list.h) continue;
            ui.key(ctx, ctx.print("sidebar-compact-{d}", .{row.id}));
            s.ax.note(.{ .widget = ctx.peekId(null), .role = .tab, .target = .{ .window = s.id, .tab = row.id }, .intent = .tab, .label = boundedLabel(ctx.print("{d}: {s}", .{ index + 1, row.title.text() })), .selected = row.active });
            const at = box(ctx, .{ .x = r.x - list.x, .y = r.y - list.y, .w = r.w, .h = r.h }, if (row.active) chrome.selected(ctx) else ctx.theme.surface);
            ctx.node(at).style.radius = 6;
            _ = ctx.interact(at, .{ .focusable = true });
            if (row.active) chrome.box(ctx, 0, 4, 2, r.h - 8, ctx.theme.accent);
            _ = ctx.open(.{ .absolute = true, .offset = .{ .x = @max(0, (r.w - 16) / 2), .y = (r.h - 16) / 2 } }, null);
            chrome.icon(ctx, if (row.document) @import("../ui_icons/icons.zig").file(row.cwd.text()) else .folder, 16);
            ctx.end();
            if (row.unread_bells > 0 or row.failed > 0) label(ctx, r.w - 9, 1, if (row.failed > 0) "!" else "•", 10, ctx.theme.text);
            ctx.end();
        }
        const total = st.fullHeight();
        if (total > list.h and list.h > 0) {
            const thumb = @max(12, list.h * list.h / total);
            chrome.box(ctx, list.w - 5, st.scroll / @max(1, total - list.h) * @max(0, list.h - thumb), 2, thumb, ctx.theme.muted.alpha(0.6));
        }
        ctx.end();
        if (st.rowAt(ctx.input.mouse, nav)) |index| tooltip(ctx, &st.snapshot.rows[index], nav);
        return;
    }
    control(s, ctx, controlRect(nav, .collapse), "sidebar-collapse", "Collapse workspace sidebar", "‹", .sidebar_toggle);
    label(ctx, nav.x + 40, nav.y + 13, "Workspaces", 12, ctx.theme.text);
    control(s, ctx, controlRect(nav, .new), "sidebar-new", "New Workspace", "+", .new_tab);
    control(s, ctx, controlRect(nav, .palette), "sidebar-commands", "Commands", "Commands  ·  ⌘/Ctrl Shift P", .palette);
    const list = st.listRect(nav);
    ui.key(ctx, "sidebar-list");
    _ = ctx.open(.{ .absolute = true, .offset = .{ .x = list.x, .y = list.y }, .width = .{ .px = list.w }, .height = .{ .px = list.h }, .clip = true }, null);
    var hovered: ?usize = null;
    for (st.snapshot.rows[0..st.snapshot.count], 0..) |*row, index| {
        const surface = st.rowRect(index, nav);
        if (surface.y + surface.h <= list.y or surface.y >= list.y + list.h) continue;
        if (st.sectionStart(index)) label(ctx, 12, surface.y - list.y - metrics.section_height + 5, if (row.pinned) "PINNED" else "WORKSPACES", 9, ctx.theme.muted);
        const local: geometry.Rect = .{ .x = surface.x - list.x, .y = surface.y - list.y, .w = surface.w, .h = surface.h };
        ui.key(ctx, ctx.print("sidebar-tab-{d}", .{row.id}));
        const semantic = if (row.document) ctx.print("{s}, read-only file workspace", .{row.title.text()}) else ctx.print("{s}, {d} splits, {d} running, {d} unread bells{s}", .{ row.title.text(), row.panes, row.running, row.unread_bells, if (row.pinned) ", pinned" else "" });
        s.ax.note(.{ .widget = ctx.peekId(null), .role = .tab, .target = .{ .window = s.id, .tab = row.id }, .intent = .tab, .label = boundedLabel(semantic), .value = boundedLabel(row.cwd.text()), .selected = row.active, .focused = row.active and st.focused and s.window_focused });
        const over = surface.contains(ctx.input.mouse) and list.contains(ctx.input.mouse);
        const at = box(ctx, local, if (row.active) chrome.selected(ctx) else if (over) ctx.theme.surface_hover else ctx.theme.surface);
        ctx.node(at).style.radius = 6;
        _ = ctx.interact(at, .{ .focusable = true });
        if (over) hovered = index;
        if (row.active) chrome.box(ctx, 0, 6, 2, local.h - 12, ctx.theme.accent);
        const show_actions = over or (st.focused and row.active);
        _ = ctx.open(.{ .absolute = true, .offset = .{ .x = 10, .y = 9 } }, null);
        chrome.icon(ctx, if (row.document) @import("../ui_icons/icons.zig").file(row.cwd.text()) else .folder, 15);
        ctx.end();
        label(ctx, 34, 8, chrome.ellipsize(ctx, row.title.text(), @max(1, local.w - (if (show_actions) @as(f32, 90) else 44)), 13), 13, ctx.theme.text);
        if (show_actions) {
            rowControl(s, ctx, row, .{ .w = local.w, .h = local.h }, .pin);
            rowControl(s, ctx, row, .{ .w = local.w, .h = local.h }, .close);
        } else if (row.pinned) {
            _ = ctx.open(.{ .absolute = true, .offset = .{ .x = local.w - 22, .y = 9 } }, null);
            chrome.icon(ctx, .pin, 12);
            ctx.end();
        }
        if (row.cwd.len > 0) label(ctx, 34, 29, chrome.ellipsize(ctx, row.cwd.text(), @max(1, local.w - 44), 11), 11, ctx.theme.muted);
        const detail = if (row.progress_count > 0)
            (if (row.progress >= 0) ctx.print("{d}% · {d} progress · {d} splits{s}", .{ row.progress, row.progress_count, row.panes, if (row.progress_error) " · error" else "" }) else ctx.print("Working · {d} progress · {d} splits", .{ row.progress_count, row.panes }))
        else if (row.unread_bells > 0)
            ctx.print("Bell {d} · {d} splits · {d} running", .{ row.unread_bells, row.panes, row.running })
        else if (row.failed > 0)
            ctx.print("Failed {d} · {d} splits", .{ row.failed, row.panes })
        else if (row.done > 0)
            ctx.print("Done {d} · {d} splits", .{ row.done, row.panes })
        else
            ctx.print("{d} splits · {d} running", .{ row.panes, row.running });
        if (metrics.hasStatus(row)) label(ctx, 34, 50, chrome.ellipsize(ctx, detail, @max(1, local.w - 44), 10), 10, ctx.theme.muted);
        // Bell and failure indicators remain visible even while progress wins
        // the descriptive line; neither relies on color alone.
        if (row.unread_bells > 0 or row.failed > 0) label(ctx, local.w - 80, 28, ctx.print("{s}{d}", .{ if (row.failed > 0) "! " else "Bell ", if (row.failed > 0) @as(u64, row.failed) else row.unread_bells }), 10, ctx.theme.text);
        var metadata_y: f32 = if (metrics.hasStatus(row)) 68 else 50;
        if (row.git.len > 0) {
            label(ctx, 10, metadata_y, chrome.ellipsize(ctx, ctx.print("Git: {s}", .{row.git.text()}), @max(1, local.w - 20), 10), 10, ctx.theme.muted);
            metadata_y += 16;
        }
        if (row.ports.len > 0) label(ctx, 10, metadata_y, chrome.ellipsize(ctx, ctx.print("Ports: {s}{s}", .{ row.ports.text(), if (row.provider_partial) " (partial)" else "" }), @max(1, local.w - 20), 10), 10, ctx.theme.muted);
        ctx.end();
    }
    if (st.dragging) |drag| if (drag.moved) if (drag.target) |target| {
        const destination = st.rowRect(target, nav);
        const from = s.layout.tabIndex(drag.id) orelse target;
        const insertion_y = if (target > from) destination.y + destination.h + 2 else destination.y;
        chrome.box(ctx, 6, insertion_y - list.y, @max(0, nav.w - 16), 2, ctx.theme.accent);
    };
    const total = st.fullHeight();
    if (total > list.h and list.h > 0) {
        const thumb = @max(12, list.h * list.h / total);
        const y = st.scroll / @max(1, total - list.h) * @max(0, list.h - thumb);
        chrome.box(ctx, list.w - 5, y, 2, thumb, ctx.theme.muted.alpha(0.6));
    }
    ctx.end();
    chrome.box(ctx, nav.x + nav.w - 1, nav.y, 1, nav.h, ctx.theme.border);
    if (s.navigation_rects.resize.contains(ctx.input.mouse) or st.resizing != null) ctx.cursor = .resize_left_right;
    if (hovered) |index| if (st.dragging == null and st.resizing == null) tooltip(ctx, &st.snapshot.rows[index], nav);
}
fn boundedLabel(text: []const u8) []const u8 {
    return @import("../terminal_title.zig").validPrefix(text[0..@min(256, text.len)]);
}
fn tooltip(ctx: *ui.Context, row: anytype, nav: geometry.Rect) void {
    // Full owned strings wrap within a bounded popup. Huge protocol labels
    // remain clipped to the window instead of growing an unbounded UI surface.
    const width = @min(520, @max(1, ctx.size.w - 16));
    const x = std.math.clamp(nav.x + nav.w + 8, 0, @max(0, ctx.size.w - width));
    const maximum = @min(320, @max(0, ctx.size.h - 16));
    const y = std.math.clamp(ctx.input.mouse.y + 16, 0, @max(0, ctx.size.h - maximum - 8));
    _ = ctx.open(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = .{ .px = width }, .max_height = maximum, .padding = .all(8), .gap = 6, .background = ctx.theme.surface, .border = ctx.theme.border, .border_width = 1, .radius = 4, .clip = true }, null);
    ui.text(ctx, row.title.text(), .{ .size = 12, .color = ctx.theme.text, .wrap = true });
    ui.text(ctx, if (row.cwd.len > 0) row.cwd.text() else "No trusted local directory reported", .{ .size = 10, .color = ctx.theme.muted, .wrap = true });
    ui.text(ctx, "Source: local OSC 7 · all split paths:", .{ .size = 10, .color = ctx.theme.muted, .wrap = true });
    ui.text(ctx, row.split_paths.text(), .{ .size = 10, .color = ctx.theme.muted, .wrap = true });
    if (row.provider_sources.len > 0) {
        ui.text(ctx, if (row.provider_partial) "Local provider results (partial):" else "Local provider results:", .{ .size = 10, .color = ctx.theme.muted, .wrap = true });
        ui.text(ctx, row.provider_sources.text(), .{ .size = 10, .color = ctx.theme.muted, .wrap = true });
    }
    ctx.end();
}
