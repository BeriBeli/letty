//! M11 modal route validation. Every route binds an exact surface
//! generation, pending-operation fingerprint and stable session/tab target.
const std = @import("std");
const ui = @import("nanoui").ui;
const semantic = @import("ui_semantics.zig");
const bridge = @import("application_accessibility.zig");
pub const Surface = enum(u8) { none, message, rename, palette, context, inspector, theme };
pub const Ref = struct {
    surface: Surface = .none,
    generation: u64 = 0,
    stamp: u64 = 0,
    control: semantic.Control = .panel,
    ordinal: u32 = 0,
    widget: u64 = 0,
    command: ?semantic.Command = null,
};
pub const Current = struct {
    surface: Surface,
    generation: u64,
    stamp: u64,
    target: bridge.Target,
    geometry: ?*const semantic.Geometry,
};
fn add(hash: *std.hash.Wyhash, value: u64) void {
    hash.update(std.mem.asBytes(&value));
}
fn stamp(w: anytype, surface: Surface) u64 {
    var hash = std.hash.Wyhash.init(0);
    add(&hash, w.id);
    add(&hash, @backingInt(surface));
    switch (surface) {
        .message => {
            add(&hash, @backingInt(w.confirmation.kind));
            add(&hash, @backingInt(w.close_pending.scope));
            for (w.close_pending.ids[0..w.close_pending.count]) |id| add(&hash, id);
            // Reject changed host/session membership before accepting a close.
            if (w.confirmation.kind == .close_sessions) for (w.host.windows) |opt| if (opt) |other| {
                add(&hash, other.id);
                for (other.sessions) |entry| if (entry) |s| add(&hash, s.id);
            };
            if (w.config_create_path) |path| hash.update(path);
            if (w.paste_transaction) |pending| {
                add(&hash, pending.target);
                add(&hash, pending.bytes.len);
                add(&hash, @intFromPtr(pending.bytes.ptr));
            }
            if (comptime @hasField(@typeInfo(@TypeOf(w)).pointer.child, "osc52_pending")) if (w.osc52_pending) |pending| {
                add(&hash, pending.target);
                add(&hash, @backingInt(pending.request.policy));
                add(&hash, pending.request.bytes.len);
                add(&hash, @intFromPtr(pending.request.bytes.ptr));
            };
            hash.update(w.link_target.text());
        },
        .rename => add(&hash, w.rename_id orelse 0),
        .context => {
            add(&hash, @backingInt(w.context_menu.kind));
            add(&hash, w.context_menu.target);
            hash.update(w.context_menu.link.text());
        },
        else => {},
    }
    return hash.final();
}
fn target(w: anytype) bridge.Target {
    return .{ .window = w.id, .session = if (w.active()) |s| s.id else 0, .tab = if (w.layout.tab_count > 0) w.layout.tabs[w.layout.active_tab].id else 0 };
}
pub fn current(w: anytype) ?Current {
    if (w.confirmation.open) return .{ .surface = .message, .generation = w.confirmation.generation, .stamp = stamp(w, .message), .target = .{ .window = w.id }, .geometry = &w.confirmation.geometry };
    if (w.context_menu.open) {
        var t: bridge.Target = .{ .window = w.id };
        if (w.context_menu.kind == .tab) t.tab = w.context_menu.target else {
            t.session = w.context_menu.target;
            for (w.sessions, 0..) |opt, slot| if (opt) |s| if (s.id == t.session) {
                for (w.layout.roots[0..w.layout.tab_count], 0..) |root, at| if (w.layout.contains(root, @intCast(slot))) {
                    t.tab = w.layout.tabs[at].id;
                    break;
                };
            };
        }
        return .{ .surface = .context, .generation = w.context_menu.generation, .stamp = stamp(w, .context), .target = t, .geometry = &w.context_menu.geometry };
    }
    if (w.rename_dialog.open) return .{ .surface = .rename, .generation = w.rename_dialog.generation, .stamp = stamp(w, .rename), .target = .{ .window = w.id, .tab = w.rename_id orelse 0 }, .geometry = &w.rename_dialog.geometry };
    if (w.palette.open) return .{ .surface = .palette, .generation = w.palette.generation, .stamp = stamp(w, .palette), .target = target(w), .geometry = &w.palette.geometry };
    const W = @typeInfo(@TypeOf(w)).pointer.child;
    if (comptime @hasField(W, "theme_browser")) if (w.theme_browser.open) {
        const lease = w.theme_browser.lease orelse return null;
        if (lease.window != w.id or lease.token != w.theme_lease_generation) return null;
        return .{ .surface = .theme, .generation = lease.token, .stamp = lease.token, .target = .{ .window = w.id }, .geometry = null };
    };
    if (comptime @hasField(W, "inspector")) if (w.inspector.open) return .{ .surface = .inspector, .generation = w.inspector.generation, .stamp = w.inspector.target, .target = .{ .window = w.id }, .geometry = &w.inspector.semantic_geometry };
    return null;
}
// Browser.geometry is the last completed draw's bounded row list. Combined
// with the current filter and exact widget/catalog pair, this refuses a queued
// row whose query changed before the next frame drains the native request.
fn themeRow(w: anytype, ref: Ref) ?usize {
    const W = @typeInfo(@TypeOf(w)).pointer.child;
    if (comptime @hasField(W, "theme_browser")) {
        const b = &w.theme_browser;
        const catalog = if (b.catalog) |*value| value else return null;
        if (ref.ordinal >= catalog.entries.len or ref.widget == 0) return null;
        if (!std.mem.eql(u8, b.previous.text(), b.query.text())) return null;
        var visible = false;
        for (b.geometry.rows[0..b.geometry.row_count]) |row| {
            if (row.widget == ref.widget and row.catalog_index == ref.ordinal) {
                visible = true;
                break;
            }
        }
        if (!visible) return null;
        for (b.filtered[0..b.filtered_count], 0..) |index, at| if (index == ref.ordinal) return at;
    }
    return null;
}
fn themeVisible(w: anytype, ref: Ref) bool {
    const W = @typeInfo(@TypeOf(w)).pointer.child;
    if (comptime @hasField(W, "theme_browser")) {
        const g = w.theme_browser.geometry;
        if (ref.widget == 0) return false;
        return switch (ref.control) {
            .panel => ref.ordinal == 0 and ref.widget == g.dialog_node,
            .query => ref.ordinal == 0 and ref.widget == g.query_node,
            .cancel => ref.ordinal == 0 and ref.widget == g.cancel_node,
            .accept => if (ref.ordinal == 0) ref.widget == g.apply_node else if (ref.ordinal == 1) ref.widget == g.save_node else false,
            .command => themeRow(w, ref) != null,
            else => false,
        };
    }
    return false;
}
pub fn valid(w: anytype, ref: Ref) bool {
    const active = current(w) orelse return false;
    if (active.surface != ref.surface or active.generation != ref.generation or active.stamp != ref.stamp) return false;
    return ref.surface != .theme or themeVisible(w, ref);
}
pub fn focus(w: anytype, ref: Ref, ctx: *ui.Context) bool {
    if (!valid(w, ref)) return false;
    ctx.focus = ref.widget;
    switch (ref.surface) {
        .message => {
            w.confirmation.ax_focus = ref.widget;
            w.confirmation.primary_selected = ref.control == .accept;
        },
        .rename => w.rename_dialog.ax_focus = ref.widget,
        .palette => {
            w.palette.ax_focus = ref.widget;
            if (ref.control == .command) {
                const list = @import("command_catalogue.zig").filter(w.palette.query.text());
                for (list.indices[0..list.len], 0..) |at, index| if (at == ref.ordinal) {
                    w.palette.selected = index;
                    break;
                };
            }
        },
        .context => {
            w.context_menu.ax_focus = ref.widget;
            if (ref.control == .command) w.context_menu.selected = ref.ordinal;
        },
        .theme => if (comptime @hasField(@typeInfo(@TypeOf(w)).pointer.child, "theme_browser")) {
            w.theme_browser.keyboard = switch (ref.control) {
                .cancel => .cancel,
                .accept => if (ref.ordinal == 1) .save else .apply,
                else => .query,
            };
            w.theme_browser.focus_query = ref.control == .query;
            if (ref.control == .command) {
                // AX focus highlights the same filtered row as pointer/arrow
                // navigation; it does not perform IO or invent a preview.
                w.theme_browser.selected = themeRow(w, ref) orelse return false;
            }
        },
        else => {},
    }
    ctx.changed = true;
    return true;
}
pub fn dispatch(w: anytype, ref: Ref, action: bridge.ax.Action, ctx: *ui.Context) !void {
    if (!valid(w, ref)) return error.AccessibilityStaleSurface;
    if (action == .focus) {
        if (!focus(w, ref, ctx)) return error.AccessibilityStaleSurface;
        return;
    }
    var accepted = false;
    switch (ref.surface) {
        .message => accepted = w.confirmation.requestAx(ref.generation, switch (ref.control) {
            .accept => .accept,
            .copy => .copy,
            .cancel, .panel => .cancel,
            else => return error.AccessibilityUnsupportedControl,
        }),
        .rename => accepted = w.rename_dialog.requestAx(ref.generation, switch (ref.control) {
            .accept => .submit,
            .cancel, .panel => .cancel,
            else => return error.AccessibilityUnsupportedControl,
        }),
        .palette => {
            if (ref.control == .panel or ref.control == .cancel) {
                w.palette.dismiss(ctx);
                accepted = true;
            } else if (ref.command) |command| accepted = w.palette.requestAx(ref.generation, command);
        },
        .context => {
            if (ref.control == .panel or ref.control == .cancel) {
                w.context_menu.dismiss(ctx);
                accepted = true;
            } else if (ref.command) |command| accepted = w.context_menu.requestAx(ref.generation, command);
        },
        .theme => if (comptime @hasField(@typeInfo(@TypeOf(w)).pointer.child, "theme_browser")) {
            // All callbacks in one Adapter batch see the previous snapshot.
            // Once cancellation is queued, later row/accept actions must not
            // turn the close into a preview, Apply or a filesystem write.
            if (w.theme_pending == .cancel) {
                accepted = true;
            } else if (ref.control == .panel or ref.control == .cancel) {
                w.theme_pending = .cancel;
                accepted = true;
            } else if (ref.control == .accept and w.theme_browser.canApply()) {
                w.theme_pending = if (ref.ordinal == 1) .save else .apply;
                accepted = true;
            } else if (ref.control == .command) {
                const selected = themeRow(w, ref) orelse return error.AccessibilityStaleSurface;
                w.theme_browser.selected = selected;
                w.theme_browser.keyboard = .query;
                w.theme_browser.focus_query = false;
                ctx.focus = ref.widget;
                w.theme_pending = .{ .preview = ref.ordinal };
                accepted = true;
            }
            if (accepted) {
                w.theme_browser.intent_frame = ctx.frame;
                ctx.frameIn(0.001);
            }
        },
        .inspector => if (comptime @hasField(@typeInfo(@TypeOf(w)).pointer.child, "inspector")) {
            if (ref.control == .panel or ref.control == .cancel) {
                w.inspector.close(ctx);
                accepted = true;
            } else accepted = w.inspector.requestAx(ref.generation, ref.ordinal);
        },
        else => {},
    }
    if (!accepted) return error.AccessibilityControlRejected;
    ctx.changed = true;
}
