//! Document geometry/input adapter. Runtime remains the only workspace and
//! action owner; this module returns stable intents to that owner.
const std = @import("std");
const ui = @import("nanoui").ui;
const documents = @import("document-native");
pub const Placement = struct { terminal: ui.Rect, document: ui.Rect, divider: ui.Rect = .{} };
pub fn place(bounds: ui.Rect, visible: bool, standalone: bool, desired_width: f32) Placement {
    if (standalone) return .{ .terminal = .{}, .document = bounds };
    if (!visible) return .{ .terminal = bounds, .document = .{} };
    if (bounds.w < 740) return .{ .terminal = .{}, .document = bounds };
    const width = std.math.clamp(desired_width, 320, @max(320, bounds.w * 0.62));
    const terminal_width = @max(0, bounds.w - width - 8);
    return .{
        .terminal = .{ .x = bounds.x, .y = bounds.y, .w = terminal_width, .h = bounds.h },
        .document = .{ .x = bounds.x + terminal_width + 8, .y = bounds.y, .w = width, .h = bounds.h },
        .divider = .{ .x = bounds.x + terminal_width, .y = bounds.y, .w = 8, .h = bounds.h },
    };
}
/// Called before shortcuts or terminal input. An active document's key/IME
/// ownership survives a hover over terminals, until click/Escape changes it.
pub fn prepare(collection: *documents.Collection, ctx: *ui.Context, placement: Placement) bool {
    if (!collection.visible or placement.document.w <= 0) return false;
    const document = collection.selected() orelse return false;
    return document.panel.prepareInput(ctx, placement.document);
}
pub fn draw(collection: *documents.Collection, ctx: *ui.Context, placement: Placement, native_header_padding: f32) ?documents.Collection.Event {
    if (!collection.visible or placement.document.w <= 0) return null;
    if (collection.selected()) |document| document.panel.header_inset = native_header_padding;
    return collection.draw(ctx, placement.document);
}
test "file workspaces and narrow previews allocate the document area without a terminal" {
    const full: ui.Rect = .{ .x = 276, .y = 8, .w = 1000, .h = 700 };
    const file = place(full, true, true, 440);
    try std.testing.expectEqual(@as(f32, 0), file.terminal.w);
    try std.testing.expectEqual(full, file.document);
    const side = place(full, true, false, 440);
    try std.testing.expectEqual(full.w, side.terminal.w + side.divider.w + side.document.w);
    const hidden = place(full, false, false, 440);
    try std.testing.expectEqual(full, hidden.terminal);
    const narrow = place(.{ .w = 600, .h = 500 }, true, false, 440);
    try std.testing.expectEqual(@as(f32, 0), narrow.terminal.w);
    try std.testing.expectEqual(@as(f32, 600), narrow.document.w);
}
