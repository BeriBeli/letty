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
pub const Control = enum { collapse, new, palette, settings, files };
pub const RowAction = enum { pin, close };
pub fn controlRect(nav: geometry.Rect, which: Control) geometry.Rect {
    return switch (which) {
        .collapse => .{ .x = nav.x + (if (builtin.os.tag == .macos) nav.w - 72 else 12), .y = nav.y + 16, .w = 28, .h = 28 },
        .new => .{ .x = nav.x + (if (builtin.os.tag == .macos) nav.w - 40 else 44), .y = nav.y + 16, .w = 28, .h = 28 },
        .palette => .{ .x = nav.x + 44, .y = nav.y + @max(0, nav.h - metrics.footer_height), .w = 28, .h = 28 },
        .files => .{ .x = nav.x + 12, .y = nav.y + @max(0, nav.h - metrics.footer_height), .w = 28, .h = 28 },
        .settings => .{ .x = nav.x + 76, .y = nav.y + @max(0, nav.h - metrics.footer_height), .w = 28, .h = 28 },
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
pub fn composing(s: anytype, ctx: *const ui.Context) bool {
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
    if (!s.window_focused or s.modalOpen()) {
        const interacting = st.dragging != null or st.resizing != null or st.focused;
        st.cancel();
        updateRects(s, ctx);
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
    if (s.navigation_rects.compact) |entry| {
        if (ctx.input.pressed and ctx.input.mouse_button == 1 and entry.contains(ctx.input.mouse) and !composing(s, ctx)) {
            st.collapsed = false;
            st.focused = false;
            updateRects(s, ctx);
            s.save();
            return consume(ctx);
        }
        var add = entry;
        add.x += 32;
        if (ctx.input.pressed and ctx.input.mouse_button == 1 and add.contains(ctx.input.mouse) and !composing(s, ctx)) {
            s.pending = .{ .action = .tab };
            return consume(ctx);
        }
    }
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
    if (ctx.input.pressed and ctx.input.mouse_button == 1 and !ime and s.navigation_rects.compact == null) {
        for (0..if (nav.w >= 238) @as(usize, 3) else 0) |kind| if (summaryRect(nav, kind).contains(ctx.input.mouse)) {
            for (1..st.snapshot.count + 1) |offset| {
                const index = (s.layout.active_tab + offset) % st.snapshot.count;
                if (summaryMatch(&st.snapshot.rows[index], kind)) {
                    activate(s, index);
                    st.focused = false;
                    return consume(ctx);
                }
            }
        };
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
            for (0..st.snapshot.count) |i| if (st.sectionStart(i) and st.projectRect(i, nav).contains(ctx.input.mouse)) {
                const project = st.projectRect(i, nav);
                if (ctx.input.mouse.x >= project.x + project.w - 28) {
                    activate(s, i);
                    s.pending = .{ .action = .tab };
                } else st.toggleProject(i);
                st.clampScroll(nav);
                ctx.changed = true;
                return consume(ctx);
            };
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
            } else if (controlRect(nav, .files).contains(ctx.input.mouse)) {
                s.pending = .{ .action = .open_file_workspace };
                st.focused = false;
            } else if (controlRect(nav, .settings).contains(ctx.input.mouse)) {
                s.pending = .{ .action = .open_settings };
                st.focused = false;
            } else if (st.rowAt(ctx.input.mouse, nav)) |tab| {
                st.dragging = .{ .id = s.layout.tabs[tab].id, .origin_y = ctx.input.mouse.y };
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
            // Home/End also reveal the selected row after a viewport resize,
            // even when its stable workspace identity is already selected.
            if (target != at or key == .enter or key == .home or key == .end) activate(s, target);
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
    const at = box(ctx, r, if (r.contains(ctx.input.mouse)) ctx.theme.surface_hover else ui.Color.transparent);
    _ = ctx.interact(at, .{ .focusable = true });
    _ = ctx.open(.{ .absolute = true, .offset = .{ .x = if (r.w <= geometry.compact_width) (r.w - 16) / 2 else 5, .y = (r.h - 16) / 2 } }, null);
    chrome.icon(ctx, if (std.mem.eql(u8, key, "sidebar-new")) .plus else if (std.mem.eql(u8, key, "sidebar-files")) .folder else if (std.mem.eql(u8, key, "sidebar-settings")) .settings else if (std.mem.eql(u8, key, "sidebar-commands")) .search else .panel, 16);
    ctx.end();
    if (std.mem.eql(u8, key, "sidebar-commands") and r.w > 80) label(ctx, 29, 7, "Commands", 11, ctx.theme.muted);
    if (std.mem.eql(u8, key, "sidebar-commands") and r.w > 180) label(ctx, r.w - 68, 7, if (builtin.os.tag == .macos) "⌘ ⇧ P" else "Ctrl ⇧ P", 10, ctx.theme.muted);
    _ = text;
    ctx.end();
}
pub fn draw(s: anytype, ctx: *ui.Context) void {
    const st = &s.sidebar;
    _ = st.refresh(s);
    const nav = s.navigation_rects.navigation;
    if (nav.h <= 0) return;
    ctx.wants_moves = true;
    ctx.wants_wheel = true;
    ui.key(ctx, "sidebar");
    s.ax.note(.{ .widget = ctx.peekId(null), .role = .tab_group, .target = .{ .window = s.id }, .label = "Workspaces" });
    _ = box(ctx, nav, ui.Color.transparent);
    // Children below use surface coordinates through an offsetting wrapper.
    ctx.end();
    if (s.navigation_rects.compact) |compact| {
        control(s, ctx, compact, "sidebar-expand", "Show sidebar", "", .sidebar_toggle);
        var add = compact;
        add.x += 32;
        control(s, ctx, add, "sidebar-new", "New session", "", .new_tab);
        return;
    }
    control(s, ctx, controlRect(nav, .collapse), "sidebar-collapse", "Collapse workspace sidebar", "‹", .sidebar_toggle);
    control(s, ctx, controlRect(nav, .new), "sidebar-new", "New Workspace", "+", .new_tab);
    control(s, ctx, controlRect(nav, .files), "sidebar-files", "Open file", "", .open_file_workspace);
    control(s, ctx, controlRect(nav, .palette), "sidebar-commands", "Commands", "Commands  ·  ⌘/Ctrl Shift P", .palette);
    control(s, ctx, controlRect(nav, .settings), "sidebar-settings", "Settings", "", .open_settings);
    for (0..if (nav.w >= 238) @as(usize, 3) else 0) |kind| {
        var count: usize = 0;
        var target: u64 = 0;
        for (st.snapshot.rows[0..st.snapshot.count]) |*row| if (summaryMatch(row, kind)) {
            count += 1;
            if (target == 0) target = row.id;
        };
        if (count == 0) continue;
        const r = summaryRect(nav, kind);
        ui.key(ctx, ctx.print("sidebar-summary-{d}", .{kind}));
        s.ax.note(.{ .widget = ctx.peekId(null), .role = .button, .target = .{ .window = s.id, .tab = target }, .intent = .tab, .label = ctx.print("{d} {s} sessions", .{ count, ([_][]const u8{ "waiting", "working", "completed" })[kind] }) });
        const node = box(ctx, r, if (r.contains(ctx.input.mouse)) ctx.theme.surface_hover else .transparent);
        ctx.node(node).style.radius = 7;
        _ = ctx.interact(node, .{});
        _ = ctx.open(.{ .absolute = true, .offset = .{ .x = 3, .y = 7 } }, null);
        chrome.icon(ctx, ([_]chrome.Icon{ .status_waiting, .status_working_0, .status_done })[kind], 13);
        ctx.end();
        label(ctx, 19, 7, ctx.print("{d}", .{count}), 12, ctx.theme.muted);
        ctx.end();
    }
    const list = st.listRect(nav);
    ui.key(ctx, "sidebar-list");
    _ = ctx.open(.{ .absolute = true, .offset = .{ .x = list.x, .y = list.y }, .width = .{ .px = list.w }, .height = .{ .px = list.h }, .clip = true }, null);
    var hovered: ?usize = null;
    for (st.snapshot.rows[0..st.snapshot.count], 0..) |*row, index| {
        const surface = st.rowRect(index, nav);
        if (surface.y + surface.h <= list.y or surface.y - metrics.section_height >= list.y + list.h) continue;
        if (st.sectionStart(index)) {
            const group = st.projectRect(index, nav);
            const over_group = group.contains(ctx.input.mouse);
            ui.key(ctx, ctx.print("project-{d}", .{row.id}));
            s.ax.note(.{ .widget = ctx.peekId(null), .role = .button, .target = .{ .window = s.id, .tab = row.id }, .intent = .project_toggle, .label = projectName(row), .value = if (st.projectClosed(index)) "Collapsed" else "Expanded" });
            const group_node = box(ctx, .{ .x = group.x - list.x, .y = group.y - list.y, .w = group.w, .h = group.h }, if (over_group) ctx.theme.surface_hover else .transparent);
            ctx.node(group_node).style.radius = 6;
            _ = ctx.interact(group_node, .{});
            label(ctx, 12, 7, chrome.ellipsize(ctx, projectName(row), @max(1, group.w - 80), 12.5), 12.5, ctx.theme.muted);
            var count: usize = 0;
            for (index..st.snapshot.count) |i| {
                if (i > index and st.sectionStart(i)) break;
                count += 1;
            }
            label(ctx, @max(0, group.w - 62), 7, ctx.print("{d}", .{count}), 12, ctx.theme.muted);
            if (over_group or st.projectClosed(index)) {
                _ = ctx.open(.{ .absolute = true, .offset = .{ .x = group.w - 43, .y = 7 } }, null);
                chrome.icon(ctx, if (st.projectClosed(index)) .right else .down, 12);
                ctx.end();
            }
            if (over_group) {
                _ = ctx.open(.{ .absolute = true, .offset = .{ .x = group.w - 22, .y = 7 } }, null);
                chrome.icon(ctx, .plus, 13);
                ctx.end();
            }
            ctx.end();
        }
        if (surface.h <= 0 or surface.y >= list.y + list.h) continue;
        const local: geometry.Rect = .{ .x = surface.x - list.x, .y = surface.y - list.y, .w = surface.w, .h = surface.h };
        ui.key(ctx, ctx.print("sidebar-tab-{d}", .{row.id}));
        const semantic = if (row.document) ctx.print("{s}, read-only file workspace", .{row.title.text()}) else ctx.print("{s}, {d} splits, {d} running, {d} unread bells{s}", .{ row.title.text(), row.panes, row.running, row.unread_bells, if (row.pinned) ", pinned" else "" });
        s.ax.note(.{ .widget = ctx.peekId(null), .role = .tab, .target = .{ .window = s.id, .tab = row.id }, .intent = .tab, .label = boundedLabel(semantic), .value = boundedLabel(row.cwd.text()), .selected = row.active, .focused = row.active and st.focused and s.window_focused });
        const over = surface.contains(ctx.input.mouse) and list.contains(ctx.input.mouse);
        const at = box(ctx, local, if (row.active) @import("../rex_chrome.zig").chosen(ctx) else if (over) ctx.theme.surface_hover else ui.Color.transparent);
        ctx.node(at).style.radius = 8;
        if (row.active) {
            ctx.node(at).style.border = @import("../rex_chrome.zig").edge(ctx);
            ctx.node(at).style.shadow = .{ .color = @import("../rex_chrome.zig").shadow(ctx), .blur = 3, .y = 1 };
        }
        _ = ctx.interact(at, .{ .focusable = true });
        if (over) hovered = index;

        if (row.document) {
            _ = ctx.open(.{ .absolute = true, .offset = .{ .x = 12, .y = 9 } }, null);
            chrome.icon(ctx, @import("../ui_icons/icons.zig").file(row.cwd.text()), 15);
            ctx.end();
        }
        const text_x: f32 = if (row.document) 34 else 12;
        label(ctx, text_x, 9, chrome.ellipsize(ctx, row.title.text(), @max(1, local.w - text_x - 34), 13.5), 13.5, ctx.theme.text);
        _ = ctx.open(.{ .absolute = true, .offset = .{ .x = local.w - 25, .y = 9 } }, null);
        @import("../rex_chrome.zig").status(ctx, row, 15);
        ctx.end();
        var metadata_y: f32 = 34;
        if (row.git.len > 0) {
            label(ctx, 12, metadata_y, chrome.ellipsize(ctx, ctx.print("Git: {s}", .{row.git.text()}), @max(1, local.w - 24), 10), 10, ctx.theme.muted);
            metadata_y += 16;
        }
        if (row.ports.len > 0) label(ctx, 12, metadata_y, chrome.ellipsize(ctx, ctx.print("Ports: {s}{s}", .{ row.ports.text(), if (row.provider_partial) " (partial)" else "" }), @max(1, local.w - 24), 10), 10, ctx.theme.muted);
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

    if (s.navigation_rects.resize.contains(ctx.input.mouse) or st.resizing != null) ctx.cursor = .resize_left_right;
    if (hovered) |index| {
        const id = st.snapshot.rows[index].id;
        if (st.hover_id != id) {
            st.hover_id = id;
            st.hover_since = ui.clock.now();
        }
        if (st.dragging == null and st.resizing == null and !s.modalOpen()) {
            const remaining = 0.6 - (ui.clock.now() - st.hover_since);
            if (remaining <= 0) tooltip(ctx, &st.snapshot.rows[index], nav) else ctx.frameIn(@floatCast(remaining));
        }
    } else st.hover_id = 0;
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
    _ = ctx.open(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = .{ .px = width }, .max_height = maximum, .padding = .all(8), .gap = 6, .background = ctx.theme.surface, .border = ctx.theme.border, .border_width = 1, .radius = 10, .clip = true }, null);
    ui.text(ctx, row.title.text(), .{ .size = 12, .color = ctx.theme.text, .wrap = true });
    if (!row.document) ui.text(ctx, ctx.print("{d} splits · {d} running · {d} done · {d} failed · {d} unread bells", .{ row.panes, row.running, row.done, row.failed, row.unread_bells }), .{ .size = 11, .color = ctx.theme.muted, .wrap = true });
    if (row.progress_count > 0) ui.text(ctx, if (row.progress >= 0) ctx.print("Progress: {d}% · {d} reporting{s}", .{ row.progress, row.progress_count, if (row.progress_error) " · error" else "" }) else ctx.print("Working · {d} reporting{s}", .{ row.progress_count, if (row.progress_error) " · error" else "" }), .{ .size = 11, .color = ctx.theme.muted, .wrap = true });
    ui.text(ctx, if (row.cwd.len > 0) row.cwd.text() else "No trusted local directory reported", .{ .size = 10, .color = ctx.theme.muted, .wrap = true });
    ui.text(ctx, "Source: local OSC 7 · all split paths:", .{ .size = 10, .color = ctx.theme.muted, .wrap = true });
    ui.text(ctx, row.split_paths.text(), .{ .size = 10, .color = ctx.theme.muted, .wrap = true });
    if (row.provider_sources.len > 0) {
        ui.text(ctx, if (row.provider_partial) "Local provider results (partial):" else "Local provider results:", .{ .size = 10, .color = ctx.theme.muted, .wrap = true });
        ui.text(ctx, row.provider_sources.text(), .{ .size = 10, .color = ctx.theme.muted, .wrap = true });
    }
    ctx.end();
}

fn projectName(row: anytype) []const u8 {
    const path = row.cwd.text();
    if (path.len == 0) return "Sessions";
    const directory = if (row.document) std.fs.path.dirname(path) orelse path else path;
    const name = std.fs.path.basename(directory);
    return if (name.len > 0) name else directory;
}

fn summaryRect(nav: geometry.Rect, kind: usize) geometry.Rect {
    return .{ .x = nav.x + nav.w - 126 + @as(f32, @floatFromInt(kind)) * 38, .y = nav.y + nav.h - metrics.footer_height, .w = 36, .h = 28 };
}
fn summaryMatch(row: anytype, kind: usize) bool {
    return switch (kind) {
        0 => row.unread_bells > 0 or row.failed > 0 or row.progress_error,
        1 => row.running > 0 or row.progress_count > 0,
        else => row.done > 0 and row.running == 0,
    };
}
