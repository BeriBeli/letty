//! Heap-stable ownership for the native engine. Only this backend imports
//! upstream terminal values; UI callers receive Letty-owned vt_types instead.
const std = @import("std");
const ghostty = @import("ghostty-vt");
const types = @import("../vt_types.zig");
const effects = @import("effects.zig");
const fixed = @import("../fixed_text.zig");
const selection = @import("selection.zig");
const search = @import("search.zig");
const quota_mod = @import("../vt_native_graphics/soft_quota.zig");
const guarded = @import("../vt_native_graphics/guarded_stream.zig");
const graphics = @import("graphics.zig");
pub const max_history_bytes = 128 * 1024 * 1024;
pub const AllocatorAudit = @import("allocator_audit.zig").Audit;

pub const Context = struct {
    backing_gpa: std.mem.Allocator,
    allocation_audit: AllocatorAudit,
    operation_allocation_epoch: u64 = 0,
    quota: quota_mod.Quota,
    operation_quota_checkpoint: quota_mod.Checkpoint = .{ .soft = 0, .hard = 0, .host = 0 },
    graphics_rejection_epoch: u64 = 0,
    graphics_rejections: u64 = 0,
    graphics_enabled: bool = false,
    clipboard_state: @import("../osc52_model.zig").State = .{},
    graphics_epoch: u64 = 0,
    gpa: std.mem.Allocator,
    io: std.Io,
    terminal: ghostty.Terminal,
    stream: guarded.Stream,
    render: ghostty.RenderState = .empty,
    selection_state: selection.State = .{},
    search_state: search.State = .{},
    reply: types.Reply,
    reply_context: ?*anyopaque,
    event_snapshot: types.Events = .{},
    title: fixed.Text(4096) = .{},
    pwd: fixed.Text(4095) = .{},
    title_truncated: bool = false,
    pwd_overflow: bool = false,
    text: std.ArrayList(u8) = .empty,
    fatal: ?anyerror = null,
    busy: bool = false,
    frame_open: bool = false,
    frame_x: usize = 0,
    frame_y: usize = 0,
    revision: u64 = 0,
    cell_width: u32 = 8,
    cell_height: u32 = 18,
    mouse_last_cell: ?ghostty.point.Coordinate = null,

    pub fn fail(self: *Context, err: anyerror) void {
        if (self.fatal == null) self.fatal = err;
        self.frame_open = false;
    }
    /// Mutations invalidate any borrowed frame. Reentry from a PTY callback is
    /// a fatal contract violation; subsequent feed never silently recovers.
    pub fn enter(self: *Context) bool {
        if (self.fatal != null) return false;
        if (self.busy) {
            self.fail(error.ReentrantVt);
            return false;
        }
        self.busy = true;
        self.operation_allocation_epoch = self.allocation_audit.failure_epoch;
        self.operation_quota_checkpoint = self.quota.checkpoint();
        self.frame_open = false;
        self.text.clearRetainingCapacity();
        return true;
    }
    pub fn leave(self: *Context) void {
        _ = self.status();
        self.busy = false;
    }
    /// Evaluate failures before returning a status to the PTY/renderer caller;
    /// a deferred leave alone would run after a success value was selected.
    pub fn status(self: *Context) c_int {
        if (self.allocation_audit.failure_epoch != self.operation_allocation_epoch) self.fail(error.OutOfMemory);
        // Account each soft rejection exactly once, even when callers evaluate
        // status before deferred leave, or hard/host failure co-occurs.
        const rejected = self.quota.soft_epoch -% self.graphics_rejection_epoch;
        self.graphics_rejections +|= rejected;
        self.graphics_rejection_epoch = self.quota.soft_epoch;
        if (self.quota.outcome(self.operation_quota_checkpoint) == .fatal) self.fail(error.OutOfMemory);
        if (self.stream.handler.core.semantic_failure) self.fail(error.SemanticFailure);
        return if (self.fatal == null) 0 else -1;
    }
    pub fn changed(self: *Context) void {
        self.revision +%= 1;
        self.frame_open = false;
    }
    pub fn copyMetadata(self: *Context, kind: enum { title, pwd }, text: []const u8) void {
        switch (kind) {
            .title => {
                self.title.set(text);
                self.title_truncated = self.title.len != text.len;
            },
            .pwd => {
                self.pwd_overflow = text.len > self.pwd.buf.len;
                if (self.pwd_overflow) self.pwd.len = 0 else self.pwd.set(text);
            },
        }
    }
};
pub fn create(gpa: std.mem.Allocator, io: std.Io, cols: u16, rows: u16, lines: usize, bytes: usize, reply: types.Reply, callback_context: ?*anyopaque) !*Context {
    if (cols == 0 or rows == 0) return error.InvalidSize;
    if (bytes > max_history_bytes) return error.InvalidHistoryLimit;
    graphics.installPngDecoder();
    const self = try gpa.create(Context);
    errdefer gpa.destroy(self);
    self.* = .{
        .backing_gpa = gpa,
        .allocation_audit = .init(gpa),
        .gpa = undefined,
        .quota = undefined,
        .io = io,
        .terminal = undefined,
        .stream = undefined,
        .reply = reply,
        .reply_context = callback_context,
    };
    // The allocator's userdata also points inside Context: initialize it only
    // after the owner reaches its permanent heap address, before the terminal.
    // Fixed legal history maximum avoids lowering a live quota during reload.
    // 160MiB core + 48MiB APC pool = 208MiB charged requested engine heap.
    // Snapshot/renderer/atlas allowances remain separate; this is not RSS.
    self.quota = try .init(self.allocation_audit.allocator(), try quota_mod.Limits.fromHistory(max_history_bytes));
    self.gpa = self.quota.allocator();
    self.terminal = try ghostty.Terminal.init(io, self.gpa, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback_lines = lines,
        .max_scrollback_bytes = bytes,
        .kitty_image_storage_limit = 0,
    });
    // Build the stream AFTER terminal storage has reached its permanent address.
    errdefer self.terminal.deinit(self.gpa);
    self.stream = try guarded.init(&self.terminal, &self.quota);
    self.stream.parser.osc_parser.max_allocating_bytes = 88 * 1024;
    errdefer self.stream.deinit();
    effects.install(self);
    try guarded.configure(&self.stream, false);
    if (self.status() != 0) return self.fatal orelse error.VtUnavailable;
    return self;
}
pub fn destroy(self: *Context) void {
    // Parser effects can contain terminal-owned resources, so order matters.
    self.stream.deinit();
    self.clipboard_state.deinit(self.gpa);
    self.selection_state.deinit(&self.terminal);
    self.search_state.deinit(&self.terminal);
    self.render.deinit(self.gpa);
    self.terminal.deinit(self.gpa);
    self.text.deinit(self.gpa);
    std.debug.assert(self.quota.used() == 0);
    const backing_gpa = self.backing_gpa;
    backing_gpa.destroy(self);
}
pub fn feed(self: *Context, bytes: []const u8) void {
    if (!self.enter()) return;
    defer self.leave();
    self.stream.nextSlice(bytes);
    selection.validateLocked(self);
    self.changed();
}
pub fn resize(self: *Context, cols: c_uint, rows: c_uint, cw: c_uint, ch: c_uint) c_int {
    if (cols == 0 or rows == 0 or cols > std.math.maxInt(u16) or rows > std.math.maxInt(u16) or cw == 0 or ch == 0) return -2;
    if (!self.enter()) return -7;
    defer self.leave();
    self.stream.handler.core.resize(.{ .cols = @intCast(cols), .rows = @intCast(rows), .cell_size_px = .{ .width = cw, .height = ch } }) catch |err| {
        if (err == error.OutOfMemory) self.fail(err);
        return -1;
    };
    self.cell_width = cw;
    self.cell_height = ch;
    self.mouse_last_cell = null;
    self.changed();
    selection.validateLocked(self);
    return self.status();
}
pub fn settings(self: *Context, style: c_uint, blink: bool, lines: usize, bytes: usize) c_int {
    if (style > 3 or bytes > max_history_bytes) return -2;
    if (!self.enter()) return -7;
    defer self.leave();
    const shape: ghostty.CursorStyle = switch (style) {
        0 => .bar,
        1 => .block,
        2 => .underline,
        3 => .block_hollow,
        else => unreachable,
    };
    self.terminal.setDefaultCursorStyle(shape);
    self.terminal.setDefaultCursorBlink(blink);
    self.terminal.setScrollbackMaxLines(lines);
    self.terminal.setScrollbackMaxBytes(bytes);
    // Match the old wrapper: host config applies now; later DECSCUSR wins.
    self.terminal.setCursorStyle(.default);
    self.changed();
    selection.validateLocked(self);
    return self.status();
}
pub fn rgb(value: u32) ghostty.color.RGB {
    return .{ .r = @truncate(value >> 16), .g = @truncate(value >> 8), .b = @truncate(value) };
}
pub fn packRgb(value: ghostty.color.RGB) u32 {
    return (@as(u32, value.r) << 16) | (@as(u32, value.g) << 8) | value.b;
}
pub fn colors(self: *Context, foreground: u32, background: u32) void {
    if (!self.enter()) return;
    defer self.leave();
    self.terminal.colors.foreground.default = rgb(foreground);
    self.terminal.colors.background.default = rgb(background);
    self.terminal.flags.dirty.palette = true;
    self.changed();
}
pub fn palette(self: *Context, values: [*]const u32, cursor: u32) void {
    if (!self.enter()) return;
    defer self.leave();
    var result = self.terminal.colors.palette.original.*;
    for (0..16) |i| result[i] = rgb(values[i]);
    self.terminal.colors.palette.changeDefault(self.gpa, result) catch |err| return self.fail(err);
    self.terminal.colors.cursor.default = rgb(cursor);
    self.terminal.flags.dirty.palette = true;
    self.changed();
}
