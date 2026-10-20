//! On-demand link targets copied from the fixed VT API, keyed by cell and VT revision.
//! Web links open externally; local file paths open the in-app preview.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("nanoui").ui;
const vt_api = @import("vt.zig");
const terminal_paths = @import("terminal_paths.zig");
const Text = @import("fixed_text.zig").Text;
pub const Kind = terminal_paths.Kind;
pub const Hover = struct {
    target: Text(2048) = .{},
    /// Resolved absolute path shown for file targets; execution re-resolves.
    resolved: Text(4096) = .{},
    /// Why a path-like target cannot be previewed from this terminal.
    reason: []const u8 = "",
    kind: Kind = .none,
    span: vt_api.Link = .{},
    revision: u64 = std.math.maxInt(u64),
    x: u32 = std.math.maxInt(u32),
    y: u32 = std.math.maxInt(u32),
    visible: bool = false,
    /// Modifier hover over a recognised path that this terminal cannot open.
    refused: bool = false,
    pub fn modifier(ctx: *const ui.Context) bool {
        return if (builtin.os.tag == .macos) ctx.input.cmd else ctx.input.ctrl;
    }
    pub fn update(h: *Hover, session: anytype, ctx: *ui.Context, cfg: anytype, rect: ui.Rect, cw: f32, ch: f32, force: bool) void {
        const held = modifier(ctx);
        if ((!held and !force) or !rect.contains(ctx.input.mouse)) {
            h.visible = false;
            h.refused = false;
            return;
        }
        const x: u32 = @intFromFloat(std.math.clamp(@floor((ctx.input.mouse.x - rect.x - cfg.padding_x[0]) / cw), 0, @as(f32, @floatFromInt(session.cols - 1))));
        const y: u32 = @intFromFloat(std.math.clamp(@floor((ctx.input.mouse.y - rect.y - cfg.padding_y[0]) / ch), 0, @as(f32, @floatFromInt(session.rows - 1))));
        const revision = vt_api.lt_vt_revision(session.vt);
        if (h.x != x or h.y != y or h.revision != revision) {
            h.x = x;
            h.y = y;
            h.revision = revision;
            h.classify(session);
        }
        h.visible = (held or force) and h.kind != .none and h.reason.len == 0;
        h.refused = held and h.kind == .file and h.reason.len > 0;
        if (h.visible) ctx.cursor_hand = true;
    }
    fn classify(h: *Hover, session: anytype) void {
        h.kind = .none;
        h.reason = "";
        h.target.set("");
        h.resolved.set("");
        var buffer: [2048]u8 = undefined;
        var len: usize = 0;
        // Web/OSC 8 links first; otherwise the visible token may be a path.
        if (vt_api.lt_vt_link_at(session.vt, h.x, h.y, &buffer, buffer.len, &len, &h.span) != 0 and
            vt_api.lt_vt_token_at(session.vt, h.x, h.y, &buffer, buffer.len, &len, &h.span) != 0) return;
        var value: []const u8 = buffer[0..len];
        if (!h.span.osc8) {
            const trimmed = terminal_paths.trimPlain(value);
            // Plain-text tokens are ASCII cells, so one byte is one column.
            h.span.last -|= @intCast(value.len - trimmed.len);
            value = trimmed;
        }
        h.kind = terminal_paths.classify(value, h.span.osc8);
        if (h.kind == .none) return;
        h.target.set(value);
        if (h.kind != .file) return;
        switch (terminal_paths.resolveFor(session, value)) {
            .path => |resolved| h.resolved.set(resolved.path.text()),
            .refused => |reason| h.reason = reason.message(),
            .invalid => |err| h.reason = terminal_paths.invalidMessage(err),
        }
    }
    /// Tooltip text for the current hover, if any.
    pub fn label(h: *const Hover, ctx: *ui.Context) ?[]const u8 {
        if (h.visible) return if (h.kind == .file) ctx.print("Open Preview  {s}", .{h.resolved.text()}) else h.target.text();
        if (h.refused) return h.reason;
        return null;
    }
    pub fn contains(h: Hover, cols: u32, x: u32, y: u32) bool {
        const point = y * cols + x;
        return h.visible and point >= h.span.first and point <= h.span.last;
    }
};
