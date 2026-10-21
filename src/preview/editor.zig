//! Owned UTF-8 draft with bounded undo. The original disk snapshot never changes.
const std = @import("std");
const ui = @import("nanoui").ui;
const disk = @import("../config_edit.zig");
const a = std.heap.page_allocator;
pub const limit = @import("loader.zig").max_text_bytes;
pub const Editor = struct {
    refs: std.atomic.Value(usize) = .init(1),
    original: disk.Snapshot,
    buffer: ui.TextBuffer = .{},
    baseline: []u8,
    bom: bool,
    crlf: bool,
    dirty: bool = false,
    focus: bool = true,
    history: std.ArrayList([]u8) = .empty,
    history_bytes: usize = 0,
    position: usize = 0,
    pub fn capture(path: []const u8) !*Editor {
        var snapshot = try disk.Native.captureWithLimit(a, path, limit);
        errdefer snapshot.deinit();
        // Preview paths reject symlinks; don't weaken that when unlocking.
        if (!std.mem.eql(u8, path, snapshot.path)) return error.SymlinkNotEditable;
        const source = snapshot.bytes;
        if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidUtf8;
        const bom = std.mem.startsWith(u8, source, "\xef\xbb\xbf");
        var normalized: std.ArrayList(u8) = .empty;
        defer normalized.deinit(a);
        var i: usize = if (bom) 3 else 0;
        var crlf: usize = 0;
        var lf: usize = 0;
        while (i < source.len) : (i += 1) {
            const ch = source[i];
            if (ch == '\r') {
                if (i + 1 == source.len or source[i + 1] != '\n') return error.UnsupportedNewlines;
                crlf += 1;
                continue;
            }
            if (ch == '\n' and (i == 0 or source[i - 1] != '\r')) lf += 1;
            if ((ch < 32 and ch != '\n' and ch != '\t') or ch == 127) return error.UnsupportedText;
            try normalized.append(a, ch);
        }
        if (crlf > 0 and lf > 0) return error.MixedNewlines;
        const baseline = try a.dupe(u8, normalized.items);
        errdefer a.free(baseline);
        const storage = try a.alloc(u8, limit);
        errdefer a.free(storage);
        const self = try a.create(Editor);
        self.* = .{ .original = snapshot, .baseline = baseline, .bom = bom, .crlf = crlf > 0, .buffer = .{ .external = storage } };
        self.buffer.set(baseline);
        self.buffer.want_caret = 0;
        self.record() catch {};
        return self;
    }
    pub fn retain(self: *Editor) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    pub fn release(self: *Editor) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        for (self.history.items) |bytes| a.free(bytes);
        self.history.deinit(a);
        a.free(self.buffer.external.?);
        a.free(self.baseline);
        self.original.deinit();
        a.destroy(self);
    }
    pub fn update(self: *Editor) void {
        self.dirty = !std.mem.eql(u8, self.baseline, self.buffer.text());
    }
    pub fn record(self: *Editor) !void {
        self.update();
        if (self.history.items.len > 0 and std.mem.eql(u8, self.history.items[self.position], self.buffer.text())) return;
        const copy = try a.dupe(u8, self.buffer.text());
        errdefer a.free(copy);
        try self.history.ensureUnusedCapacity(a, 1);
        while (self.history.items.len > self.position + 1) {
            const old = self.history.pop().?;
            self.history_bytes -= old.len;
            a.free(old);
        }
        while (self.history.items.len > 0 and (self.history.items.len >= 64 or self.history_bytes + copy.len > 8 * 1024 * 1024)) {
            const old = self.history.orderedRemove(0);
            self.history_bytes -= old.len;
            a.free(old);
        }
        self.history.appendAssumeCapacity(copy);
        self.history_bytes += copy.len;
        self.position = self.history.items.len - 1;
    }
    pub fn undo(self: *Editor, redo: bool) void {
        if (self.history.items.len == 0) return;
        if (redo) {
            if (self.position + 1 < self.history.items.len) self.position += 1;
        } else {
            self.position -|= 1;
        }
        self.buffer.set(self.history.items[self.position]);
        self.update();
    }
    pub fn encoded(self: *Editor) ![]u8 {
        const text = self.buffer.text();
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        for (text) |ch| if ((ch < 32 and ch != '\n' and ch != '\t') or ch == 127) return error.UnsupportedText;
        if (std.mem.count(u8, text, "\n") >= @import("loader.zig").max_lines) return error.TooManyLines;
        const count = if (self.crlf) std.mem.count(u8, text, "\n") else 0;
        const length = text.len + count + @as(usize, if (self.bom) 3 else 0);
        if (length > limit) return error.FileSize;
        const out = try a.alloc(u8, length);
        var i: usize = 0;
        if (self.bom) {
            @memcpy(out[0..3], "\xef\xbb\xbf");
            i = 3;
        }
        for (text) |ch| {
            if (self.crlf and ch == '\n') {
                out[i] = '\r';
                i += 1;
            }
            out[i] = ch;
            i += 1;
        }
        return out;
    }
};
