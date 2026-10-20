//! Contract with M10 Browser.Geometry: actual node IDs, lease token, keyboard.
//! No theme IO here. Intents are drained by application_theme_browser.process.
const ui = @import("nanoui").ui;
const semantic = @import("ui_semantics.zig");
pub fn collect(w: anytype, ctx: *ui.Context, out: *semantic.Geometry) bool {
    const W = @typeInfo(@TypeOf(w)).pointer.child;
    if (comptime @hasField(W, "theme_browser")) {
        if (!w.theme_browser.open) return false;
        const b = &w.theme_browser;
        const lease = b.lease orelse return false;
        if (lease.window != w.id or lease.token != w.theme_lease_generation) return false;
        out.begin(lease.token, ctx.frame);
        add(out, b.geometry.dialog_node, .panel, 0, "Themes", "", true, false);
        add(out, b.geometry.query_node, .query, 0, "Find Theme", b.query.text(), true, b.keyboard == .query);
        for (b.geometry.rows[0..b.geometry.row_count]) |row| {
            const catalog = if (b.catalog) |*value| value else continue;
            if (row.catalog_index >= catalog.entries.len) continue;
            add(out, row.widget, .command, @intCast(row.catalog_index), catalog.entries[row.catalog_index].name, "", true, b.preview_index == row.catalog_index);
        }
        add(out, b.geometry.cancel_node, .cancel, 0, "Cancel", "", true, b.keyboard == .cancel);
        add(out, b.geometry.apply_node, .accept, 0, "Apply", "", b.canApply(), b.keyboard == .apply);
        add(out, b.geometry.save_node, .accept, 1, "Save", "", b.canApply(), b.keyboard == .save);
        return true;
    } else return false;
}
fn add(out: *semantic.Geometry, widget: u64, control: semantic.Control, ordinal: u32, label: []const u8, value: []const u8, enabled: bool, selected: bool) void {
    if (widget == 0) return;
    if (out.count == out.entries.len) {
        out.overflow = true;
        return;
    }
    var entry: semantic.Entry = .{ .widget = widget, .control = control, .ordinal = ordinal, .enabled = enabled, .selected = selected };
    entry.label.set(label);
    entry.value.set(value);
    out.entries[out.count] = entry;
    out.count += 1;
}
