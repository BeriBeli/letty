//! Compact repository summary in a terminal header; data comes from owned jobs.
const nano = @import("nanoui");
const ui = nano.ui;
const C = @import("presentation.zig");
const L = @import("locale.zig");
const Vcs = @import("vcs.zig");
pub fn visible(state: *const Vcs.State) bool {
    return state.initialized and state.backend != .none and !state.pending and !state.discovery_failed;
}
pub fn description(ctx: *ui.Context, state: *const Vcs.State) []const u8 {
    var added: usize = 0;
    var removed: usize = 0;
    for (state.files()) |file| {
        added +|= file.added;
        removed +|= file.removed;
    }
    const summary = ctx.print("{s}{s} · {d} {s}", .{ if (state.backend == .git) "Git " else "", state.label(), state.files().len, L.t(if (state.files().len == 1) "file" else "files") });
    return if (added > 0 or removed > 0) ctx.print("{s} +{d} −{d}", .{ summary, added, removed }) else summary;
}
pub fn draw(ctx: *ui.Context, state: *const Vcs.State, maximum: f32) ?ui.Interaction {
    if (!visible(state) or maximum < 60) return null;
    const files = state.files();
    var added: usize = 0;
    var removed: usize = 0;
    for (files) |file| {
        added +|= file.added;
        removed +|= file.removed;
    }
    const counts = if (state.hasData()) ctx.print(" · {d} {s}", .{ files.len, L.t(if (files.len == 1) "file" else "files") }) else if (state.busy()) " …" else if (state.message().len > 0) ctx.print(" · {s}", .{L.t("Unavailable")}) else "";
    const plus = if (added > 0) ctx.print("+{d}", .{added}) else "";
    const minus = if (removed > 0) ctx.print("−{d}", .{removed}) else "";
    const detailed = maximum >= 180;
    const count_width = if (detailed) ctx.text.layout(counts, .{ .size = 12 }).width else 0;
    const delta_width = if (detailed) ctx.text.layout(plus, .{ .size = 12 }).width + ctx.text.layout(minus, .{ .size = 12 }).width + (if (added > 0) @as(f32, 5) else 0) + (if (removed > 0) @as(f32, 5) else 0) else 0;
    const prefix = if (state.backend == .git) "Git " else "";
    const name = C.ellipsize(ctx, ctx.print("{s}{s}", .{ prefix, state.label() }), @max(24, maximum - 12 - count_width - delta_width), 12);
    const node = ctx.open(.{ .direction = .row, .height = .{ .px = 26 }, .max_width = maximum, .padding = .xy(6, 0), .gap = 0, .radius = 6, .align_items = .center, .control = true }, "vcs-badge");
    const hit = ctx.interact(node, .{ .focusable = true });
    if (hit.hovered) ctx.node(node).style.background = ctx.theme.text.alpha(0.045);
    ui.text(ctx, name, .{ .size = 12, .weight = .medium, .color = ctx.theme.muted });
    if (detailed) {
        ui.text(ctx, counts, .{ .size = 12, .color = ctx.theme.muted });
        if (added > 0) ui.text(ctx, ctx.print(" {s}", .{plus}), .{ .size = 12, .color = .hex(if (ctx.theme.dark) 0x88e3a2 else 0x22863a) });
        if (removed > 0) ui.text(ctx, ctx.print(" {s}", .{minus}), .{ .size = 12, .color = .hex(if (ctx.theme.dark) 0xff8585 else 0xd93a35) });
    }
    ui.end(ctx);
    nano.kit.tooltip(ctx, hit, L.t("Show Changes"), .{});
    return hit;
}
