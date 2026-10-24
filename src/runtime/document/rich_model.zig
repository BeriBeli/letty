//! Reversible rendered-text edits. A keystroke patches source bytes and shifts
//! the optimistic display IR; the existing bounded worker reparses later.
const std = @import("std");
const md = @import("markdown.zig");
const ro = @import("read_only_text.zig");
const text = @import("text_buffer.zig");
const A = std.mem.Allocator;
const Range = md.Origin;
pub const Projection = struct {
    arena: std.heap.ArenaAllocator,
    markdown: md.Document,
    rendered: ro.Document,
    revision: u64,
    // Only history navigation needs a synchronous pure parse. Ordinary typing
    // borrows immutable resources from Panel.prepared until its next apply.
    owned: ?md.Document = null,
    pub fn init(a: A, original: *const md.Document, source: *const text.Buffer) !Projection {
        var result = try initRaw(a, original, source);
        errdefer result.deinit();
        try result.caretWhitespace(a, source, source.caret);
        if (source.anchor != source.caret) try result.caretWhitespace(a, source, source.anchor);
        return result;
    }
    fn initRaw(a: A, original: *const md.Document, source: *const text.Buffer) !Projection {
        if (original.source_hash != std.hash.Wyhash.hash(0, source.text)) return error.PreviewUpdating;
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const g = arena.allocator();
        var markdown = try clone(g, original);
        const rendered = try ro.Document.init(g, original.text);
        if (rendered.lines.len > markdown.lines.len) {
            const lines = try g.alloc(md.Line, rendered.lines.len);
            @memcpy(lines[0..markdown.lines.len], markdown.lines);
            for (lines[markdown.lines.len..], rendered.lines[markdown.lines.len..]) |*line, raw| line.* = .{ .start = raw.start, .end = raw.end, .source_start = @intCast(source.text.len) };
            markdown.lines = lines;
        }
        return .{ .arena = arena, .markdown = markdown, .rendered = rendered, .revision = source.revision };
    }
    pub fn fromSource(a: A, source: *const text.Buffer) !Projection {
        var parsed = try md.Document.init(a, source.text);
        errdefer parsed.deinit();
        if (parsed.truncated) return error.PreviewMarkdownLimit;
        var result = try init(a, &parsed, source);
        result.owned = parsed;
        return result;
    }
    pub fn deinit(self: *Projection) void {
        self.arena.deinit();
        if (self.owned) |*owned| owned.deinit();
        self.* = undefined;
    }
    pub fn displayAt(self: *const Projection, source_at: usize) usize {
        var previous: usize = 0;
        for (self.markdown.origins, 0..) |origin, i| if (origin.start != md.unmapped) {
            if (source_at < origin.start) return previous;
            if (source_at < origin.end) return self.rendered.floor(i);
            previous = i + 1;
        };
        return self.rendered.floor(previous);
    }
    pub fn displayAtSource(self: *const Projection, source_at: usize, source: []const u8) usize {
        var previous: usize = 0;
        var raw_previous: usize = 0;
        for (self.markdown.origins, 0..) |origin, i| if (origin.start != md.unmapped and origin.end > origin.start) {
            if (source_at < origin.start) return self.gapAt(source_at, source, previous, i, raw_previous);
            if (source_at < origin.end) return self.rendered.floor(i);
            previous = i + 1;
            raw_previous = origin.end;
        };
        return self.gapAt(source_at, source, previous, self.rendered.text.len, raw_previous);
    }
    fn gapAt(self: *const Projection, at: usize, source: []const u8, previous: usize, following: usize, raw_previous: usize) usize {
        if (at <= raw_previous or at > source.len or std.mem.indexOfScalar(u8, source[raw_previous..at], '\n') == null) return self.rendered.floor(previous);
        var target: ?md.Line = null;
        for (self.markdown.lines) |line| if (line.start >= previous and line.source_start > raw_previous and line.source_start <= at) {
            if (line.start == line.end and line.source_start == source.len and !std.mem.endsWith(u8, source, "\n")) continue;
            target = line;
        };
        if (target) |line| return self.rendered.floor(if (following >= line.start and following <= line.end) following else line.end);
        return self.rendered.floor(following);
    }
    fn caretWhitespace(self: *Projection, a: A, source: *const text.Buffer, caret: usize) !void {
        var first = @min(caret, source.text.len);
        var last = first;
        while (first > 0 and horizontal(source.text[first - 1])) first -= 1;
        while (last < source.text.len and horizontal(source.text[last])) last += 1;
        if (first == last) return;
        for (self.markdown.origins) |origin| if (origin.start != md.unmapped and origin.end > first and origin.start < last) return;
        const at = self.displayAtSource(caret, source.text);
        for (self.markdown.formulas) |formula| if (at >= formula.start and at <= formula.end) return;
        for (self.markdown.links) |link| if (link.image and at >= link.start and at <= link.end) return;
        _ = self.bounds(at, at) catch return;
        const row = self.markdown.lines[self.rendered.lineAt(at)];
        if ((row.kind == .heading or row.kind == .list or row.kind == .table or row.kind == .quote) and last <= row.source_start) return;
        const origins = try a.alloc(Range, last - first);
        defer a.free(origins);
        for (origins, first..) |*origin, offset| origin.* = .{ .start = @intCast(offset), .end = @intCast(offset + 1) };
        var next = try self.splice(a, at, at, source.text[first..last], origins, null);
        next.repairStyles();
        next.owned = self.owned;
        self.owned = null;
        self.deinit();
        self.* = next;
    }
    pub fn sourceAt(self: *const Projection, at: usize) ?usize {
        if (at > 0 and at <= self.markdown.origins.len) {
            const previous = self.markdown.origins[at - 1];
            if (previous.end != md.unmapped) return previous.end;
        }
        if (at < self.markdown.origins.len and self.markdown.origins[at].start != md.unmapped) return self.markdown.origins[at].start;
        const row = self.rendered.lineAt(at);
        if (row < self.markdown.lines.len) {
            const line = self.markdown.lines[row];
            if (line.start == line.end) return line.source_start;
            if (line.kind == .list) {
                for (self.markdown.origins[line.start..line.end]) |origin| if (origin.start != md.unmapped) return null;
                return line.source_start;
            }
        }
        return null;
    }
    fn bounds(self: *const Projection, from: usize, to: usize) ![2]usize {
        if (from > to or to > self.rendered.text.len or !self.rendered.boundary(from) or !self.rendered.boundary(to)) return error.InvalidEditRange;
        const row_index = self.rendered.lineAt(from);
        if (row_index >= self.markdown.lines.len) return error.EditTextBlock;
        const row = self.markdown.lines[row_index];
        if (row.kind == .code or row.kind == .diagram or row.kind == .math or row.kind == .rule) return error.EditResourceInSource;
        var first = row.start;
        var last = row.end;
        if (row.kind == .table) {
            var found = false;
            for (row.cells) |cell| if (from >= cell.start and from <= cell.end) {
                first = cell.start;
                last = cell.end;
                found = true;
                break;
            };
            if (!found) return error.EditTableCell;
        }
        if (row.kind == .list) while (first < last and self.markdown.origins[first].start == md.unmapped) {
            first += 1;
        };
        const start = @max(from, first);
        if (to > last or start > to and from != to) return error.EditOneTextBlock;
        const end = @max(start, to);
        if (end > last) return error.EditOneTextBlock;
        for (self.markdown.origins[start..end]) |origin| if (origin.start == md.unmapped) return error.EditResourceInSource;
        if (start == end and self.sourceAt(start) == null) return error.EditResourceInSource;
        return .{ start, end };
    }
    pub fn checkRange(self: *const Projection, from: usize, to: usize) !void {
        _ = try self.bounds(from, to);
    }
    /// One atomic source-buffer edit, including all selected literal fragments.
    /// Unselected syntax remains byte-for-byte; emptied wrappers are removed.
    pub fn replace(self: *Projection, a: A, source: *text.Buffer, from_raw: usize, to_raw: usize, value: []const u8) !usize {
        if (self.revision != source.revision) return error.PreviewUpdating;
        if (!std.unicode.utf8ValidateSlice(value) or value.len > 65536) return error.EditLimit;
        const range = try self.bounds(from_raw, to_raw);
        const from = range[0];
        const to = range[1];
        if (from == to and value.len == 0) return from;
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const g = scratch.allocator();
        var removals: std.ArrayList(Range) = .empty;
        for (self.markdown.origins[from..to]) |origin| try removals.append(g, origin);
        var insertion: u32 = if (from < to) self.markdown.origins[from].start else @intCast(self.sourceAt(from) orelse return error.EditTextBlock);
        const newline = std.mem.indexOfScalar(u8, value, '\n') != null;
        const blank = std.mem.trim(u8, value, " \t\r\n").len == 0;
        var kept: std.ArrayList(md.Wrapper) = .empty;
        for (self.markdown.wrappers) |wrapper| {
            const whole = wrapper.start >= from and wrapper.end <= to;
            const style = emphasisWrapper(wrapper, source.text);
            if (whole and !(value.len > 0 and (!blank or (!style and !newline)) and from >= wrapper.start and from <= wrapper.end)) {
                try removals.append(g, wrapper.open);
                try removals.append(g, wrapper.close);
            } else {
                if (newline and ((from < wrapper.end and to > wrapper.start) or (from == to and from > wrapper.start and from < wrapper.end))) return error.EditFormattedBreakInSource;
                if (newline) {
                    if (from == wrapper.start) insertion = @min(insertion, wrapper.open.start);
                    if (from == wrapper.end) insertion = @max(insertion, wrapper.close.end);
                }
                try kept.append(g, wrapper);
            }
        }
        std.mem.sort(Range, removals.items, {}, less);
        var merged: std.ArrayList(Range) = .empty;
        for (removals.items) |item| {
            if (merged.items.len > 0 and item.start <= merged.items[merged.items.len - 1].end) merged.items[merged.items.len - 1].end = @max(merged.items[merged.items.len - 1].end, item.end) else try merged.append(g, item);
        }
        for (merged.items) |item| if (insertion > item.start and insertion < item.end) {
            insertion = item.start;
        };
        const row = self.markdown.lines[self.rendered.lineAt(from)];
        if (row.kind == .table and std.mem.indexOfScalar(u8, value, '\n') != null) return error.EditTableCell;
        const encoded = try encode(g, value, source.text, insertion, row, kept.items, from);
        const transform = Transform{ .removed = merged.items, .at = insertion, .added = @intCast(encoded.source.len) };
        const raw_start = if (merged.items.len > 0) @min(insertion, merged.items[0].start) else insertion;
        const raw_end = if (merged.items.len > 0) @max(insertion, merged.items[merged.items.len - 1].end) else insertion;
        var deleted: usize = 0;
        for (merged.items) |item| deleted += item.end - item.start;
        if (source.text.len - deleted + encoded.source.len > md.max_source) return error.PreviewMarkdownLimit;
        var replacement: std.ArrayList(u8) = .empty;
        var cursor: usize = raw_start;
        var emitted = false;
        while (cursor <= raw_end) {
            if (!emitted and cursor >= insertion) {
                try replacement.appendSlice(g, encoded.source);
                emitted = true;
            }
            if (cursor == raw_end) break;
            var skip: usize = cursor;
            for (merged.items) |item| if (cursor >= item.start and cursor < item.end) {
                skip = item.end;
                break;
            };
            if (skip > cursor) cursor = skip else {
                try replacement.append(g, source.text[cursor]);
                cursor += 1;
            }
        }
        const insert_base = transform.before(insertion);
        const inserted_origins = try g.dupe(md.Origin, encoded.origins);
        for (inserted_origins) |*origin| if (origin.start != md.unmapped) {
            origin.start += insert_base;
            origin.end += insert_base;
        };
        var next = try self.splice(a, from, to, encoded.display, inserted_origins, transform);
        errdefer next.deinit();
        const whole = try std.mem.concat(g, u8, &.{ source.text[0..raw_start], replacement.items, source.text[raw_end..] });
        var atomic_first: usize = raw_start;
        var atomic_last: usize = raw_end;
        if (next.normalizeSpaces(whole, from, from + encoded.display.len)) |changed| {
            atomic_first = @min(atomic_first, changed[0]);
            const new_end = raw_start + replacement.items.len;
            if (changed[1] > new_end) atomic_last = @max(atomic_last, raw_end + changed[1] - new_end);
        }
        if (newline) {
            var end_source = row.source_start;
            for (self.markdown.origins[row.start..row.end]) |origin| if (origin.end != md.unmapped) {
                end_source = @max(end_source, origin.end);
            };
            const first = transform.before(@intCast(text.lineStart(source.text, row.source_start)));
            const last = transform.after(@intCast(text.lineEnd(source.text, end_source)));
            try next.blockWrappers(whole, first, last);
        }
        // All projection allocations precede publication of either buffer.
        const new_last = whole.len - (source.text.len - atomic_last);
        try source.replace(a, atomic_first, atomic_last, whole[atomic_first..new_last]);
        const display_caret = from + encoded.display.len;
        source.caret = if (display_caret > 0 and next.markdown.origins[display_caret - 1].end != md.unmapped and next.markdown.origins[display_caret - 1].end > next.markdown.origins[display_caret - 1].start) next.markdown.origins[display_caret - 1].end else insert_base + encoded.source.len;
        source.anchor = source.caret;
        next.revision = source.revision;
        next.markdown.source_hash = std.hash.Wyhash.hash(0, source.text);
        next.owned = self.owned;
        self.owned = null;
        self.deinit();
        self.* = next;
        return display_caret;
    }
    fn normalizeSpaces(self: *Projection, source: []u8, from: usize, to: usize) ?[2]usize {
        var changed: ?[2]usize = null;
        for (0..self.markdown.wrappers.len) |index| {
            const wrapper = &@constCast(self.markdown.wrappers)[index];
            if (wrapper.end < from or wrapper.start > to or !emphasisWrapper(wrapper.*, source)) continue;
            var lead: usize = wrapper.open.end;
            while (lead < wrapper.close.start and horizontal(source[lead])) lead += 1;
            if (lead > wrapper.open.end) {
                const range = [2]usize{ wrapper.open.start, lead };
                self.rotateSource(source, wrapper.open.start, wrapper.open.end, lead, wrapper.start, wrapper.end);
                changed = unionRange(changed, range);
            }
            var tail: usize = wrapper.close.start;
            while (tail > wrapper.open.end and horizontal(source[tail - 1])) tail -= 1;
            if (tail < wrapper.close.start) {
                const range = [2]usize{ tail, wrapper.close.end };
                self.rotateSource(source, tail, wrapper.close.start, wrapper.close.end, wrapper.start, wrapper.end);
                changed = unionRange(changed, range);
            }
        }
        if (changed != null) self.repairStyles();
        return changed;
    }
    fn rotateSource(self: *Projection, source: []u8, first: usize, middle: usize, last: usize, display_first: usize, display_last: usize) void {
        std.mem.reverse(u8, source[first..middle]);
        std.mem.reverse(u8, source[middle..last]);
        std.mem.reverse(u8, source[first..last]);
        for (@constCast(self.markdown.origins)[display_first..display_last]) |*origin| origin.* = rotated(origin.*, first, middle, last);
        for (@constCast(self.markdown.wrappers)) |*wrapper| {
            wrapper.open = rotated(wrapper.open, first, middle, last);
            wrapper.close = rotated(wrapper.close, first, middle, last);
        }
    }
    fn repairStyles(self: *Projection) void {
        for (@constCast(self.markdown.wrappers)) |*wrapper| {
            var first: ?usize = null;
            var last: usize = 0;
            for (self.markdown.origins[wrapper.start..wrapper.end], wrapper.start..) |origin, i| if (origin.start != md.unmapped and origin.end > origin.start and origin.start >= wrapper.open.end and origin.end <= wrapper.close.start) {
                if (first == null) first = i;
                last = i + 1;
            };
            if (first) |at| {
                wrapper.start = at;
                wrapper.end = last;
            }
        }
        for (@constCast(self.markdown.spans)) |*span| if (span.flags & (md.strong | md.emphasis | md.strike) != 0 and span.flags & md.code == 0) {
            while (span.start < span.end and std.ascii.isWhitespace(self.markdown.text[span.start])) span.start += 1;
            while (span.end > span.start and std.ascii.isWhitespace(self.markdown.text[span.end - 1])) span.end -= 1;
        };
    }
    fn blockWrappers(self: *Projection, source: []const u8, first: usize, last: usize) !void {
        if (last - first > 128 * 1024) return error.EditLimit;
        const g = self.arena.allocator();
        // Only the affected block is parsed on structural Enter, never the
        // document on ordinary typing. Other syntax/resources remain borrowed.
        var local = try md.Document.init(g, source[first..last]);
        defer local.deinit();
        const Pair = struct { source: u32, display: usize };
        var pairs: std.ArrayList(Pair) = .empty;
        for (self.markdown.origins, 0..) |origin, i| if (origin.start != md.unmapped and origin.start >= first and origin.start < last and origin.end > origin.start) try pairs.append(g, .{ .source = origin.start, .display = i });
        var wrappers: std.ArrayList(md.Wrapper) = .empty;
        for (self.markdown.wrappers) |wrapper| if (wrapper.close.end <= first or wrapper.open.start >= last) try wrappers.append(g, wrapper);
        for (local.wrappers) |value| {
            var wrapper = value;
            wrapper.open.start += @intCast(first);
            wrapper.open.end += @intCast(first);
            wrapper.close.start += @intCast(first);
            wrapper.close.end += @intCast(first);
            var low: usize = 0;
            var high = pairs.items.len;
            while (low < high) {
                const mid = (low + high) / 2;
                if (pairs.items[mid].source < wrapper.open.end) low = mid + 1 else high = mid;
            }
            if (low == pairs.items.len or pairs.items[low].source >= wrapper.close.start) continue;
            wrapper.start = pairs.items[low].display;
            while (low < pairs.items.len and pairs.items[low].source < wrapper.close.start) : (low += 1) {}
            wrapper.end = pairs.items[low - 1].display + 1;
            try wrappers.append(g, wrapper);
        }
        self.markdown.wrappers = wrappers.items;
    }
    pub fn preedit(self: *const Projection, a: A, from: usize, to: usize, value: []const u8) !Projection {
        _ = try self.bounds(from, to);
        const origins = try a.alloc(md.Origin, value.len);
        defer a.free(origins);
        @memset(origins, .{});
        return self.splice(a, from, to, value, origins, null);
    }
    fn splice(self: *const Projection, a: A, from: usize, to: usize, value: []const u8, inserted: []const md.Origin, transform: ?Transform) !Projection {
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const g = arena.allocator();
        var result = try clone(g, &self.markdown);
        result.text = try std.mem.concat(g, u8, &.{ self.markdown.text[0..from], value, self.markdown.text[to..] });
        if (result.text.len > md.max_text) return error.PreviewMarkdownLimit;
        const origins = try g.alloc(md.Origin, result.text.len);
        @memcpy(origins[0..from], self.markdown.origins[0..from]);
        @memcpy(origins[from..][0..inserted.len], inserted);
        @memcpy(origins[from + inserted.len ..], self.markdown.origins[to..]);
        if (transform) |tr| {
            for (origins[0..from]) |*origin| origin.* = tr.origin(origin.*);
            for (origins[from + inserted.len ..]) |*origin| origin.* = tr.origin(origin.*);
        }
        result.origins = origins;
        const shift = Shift{ .from = from, .to = to, .added = value.len };
        for (@constCast(result.spans)) |*span| {
            span.start = shift.at(span.start, false);
            span.end = shift.at(span.end, true);
        }
        for (@constCast(result.links)) |*item| {
            item.start = shift.at(item.start, false);
            item.end = shift.at(item.end, true);
        }
        var wrappers: std.ArrayList(md.Wrapper) = .empty;
        for (result.wrappers) |old| {
            if (old.start >= from and old.end <= to and value.len == 0) continue;
            var item = old;
            item.start = shift.at(item.start, false);
            item.end = shift.at(item.end, true);
            if (transform) |tr| {
                item.open = tr.origin(item.open);
                item.close = tr.origin(item.close);
            }
            if (item.open.end > item.open.start and item.close.end > item.close.start) try wrappers.append(g, item);
        }
        result.wrappers = wrappers.items;
        for (@constCast(result.formulas)) |*item| {
            item.start = shift.at(item.start, false);
            item.end = shift.at(item.end, true);
        }
        for (@constCast(result.anchors)) |*item| {
            item.start = shift.at(item.start, false);
            item.end = shift.at(item.end, true);
        }
        var lines: std.ArrayList(md.Line) = .empty;
        var start: usize = 0;
        var old_row: usize = 0;
        var split = std.mem.splitScalar(u8, result.text, '\n');
        while (split.next()) |line| {
            const old_at = if (start <= from) start else if (start < from + value.len) from else start - value.len + to - from;
            while (old_row + 1 < self.markdown.lines.len and self.markdown.lines[old_row + 1].start <= old_at) old_row += 1;
            var row: md.Line = if (self.markdown.lines.len > 0) self.markdown.lines[old_row] else .{ .start = 0, .end = 0 };
            row.start = start;
            row.end = start + line.len;
            if (start > from and start <= from + value.len and row.kind == .heading) row.kind = .paragraph;
            if (start > from and start <= from + value.len and row.kind == .list) {
                if (row.ordered) row.ordinal += 1;
                if (row.task != null) row.task = false;
            }
            if (transform) |tr| row.source_start = tr.after(row.source_start);
            if (start > from and start <= from + value.len) {
                if (start > 0 and origins[start - 1].end != md.unmapped) row.source_start = origins[start - 1].end;
                for (origins[start..row.end]) |origin| if (origin.start != md.unmapped) {
                    row.source_start = origin.start;
                    break;
                };
            }
            const cells = try g.dupe(md.Cell, row.cells);
            for (cells) |*cell| {
                cell.start = shift.at(cell.start, false);
                cell.end = shift.at(cell.end, true);
            }
            row.cells = cells;
            try lines.append(g, row);
            start = row.end + 1;
        }
        if (lines.items.len > md.max_lines) return error.PreviewLineLimit;
        result.lines = lines.items;
        for (@constCast(result.links)) |*item| item.line = rowAt(result.lines, item.start);
        for (@constCast(result.anchors)) |*item| item.line = rowAt(result.lines, item.start);
        const rendered = try ro.Document.init(g, result.text);
        return .{ .arena = arena, .markdown = result, .rendered = rendered, .revision = self.revision };
    }
};
fn clone(a: A, original: *const md.Document) !md.Document {
    var result = original.*;
    result.arena = undefined; // borrowed resources; Projection owns only its arena.
    result.spans = try a.dupe(md.Span, original.spans);
    result.links = try a.dupe(md.Link, original.links);
    result.wrappers = try a.dupe(md.Wrapper, original.wrappers);
    result.formulas = try a.dupe(@import("markdown_extensions.zig").Formula, original.formulas);
    result.anchors = try a.dupe(md.Anchor, original.anchors);
    return result;
}
fn rowAt(lines: []const md.Line, at: usize) usize {
    var result: usize = 0;
    for (lines, 0..) |line, i| {
        if (line.start > at) break;
        result = i;
    }
    return result;
}
fn less(_: void, a: Range, b: Range) bool {
    return a.start < b.start;
}
fn horizontal(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}
fn emphasisWrapper(wrapper: md.Wrapper, source: []const u8) bool {
    return wrapper.open.start < source.len and std.mem.indexOfScalar(u8, "*_~", source[wrapper.open.start]) != null;
}
fn rotated(origin: Range, first: usize, middle: usize, last: usize) Range {
    if (origin.start == md.unmapped) return origin;
    if (origin.start >= first and origin.end <= middle) return .{ .start = @intCast(origin.start + last - middle), .end = @intCast(origin.end + last - middle) };
    if (origin.start >= middle and origin.end <= last) return .{ .start = @intCast(origin.start - (middle - first)), .end = @intCast(origin.end - (middle - first)) };
    return origin;
}
fn unionRange(old: ?[2]usize, next: [2]usize) [2]usize {
    return if (old) |range| .{ @min(range[0], next[0]), @max(range[1], next[1]) } else next;
}
const Transform = struct {
    removed: []const Range,
    at: u32,
    added: u32,
    fn before(self: Transform, offset: u32) u32 {
        var deleted: u32 = 0;
        for (self.removed) |item| if (offset > item.start) {
            deleted += @min(offset, item.end) - item.start;
        };
        return offset - deleted + (if (offset > self.at) self.added else 0);
    }
    fn after(self: Transform, offset: u32) u32 {
        return self.before(offset) + (if (offset == self.at) self.added else 0);
    }
    fn origin(self: Transform, value: Range) Range {
        if (value.start == md.unmapped) return value;
        return .{ .start = self.after(value.start), .end = self.before(value.end) };
    }
};
const Shift = struct {
    from: usize,
    to: usize,
    added: usize,
    fn at(self: Shift, value: usize, right: bool) usize {
        if (value < self.from) return value;
        if (value > self.to) return value - (self.to - self.from) + self.added;
        return self.from + (if (right) self.added else 0);
    }
};
const Encoded = struct { source: []const u8, display: []const u8, origins: []const Range };
fn encode(a: A, value: []const u8, source: []const u8, insertion: usize, row: md.Line, wrappers: []const md.Wrapper, display_at: usize) !Encoded {
    var raw: std.ArrayList(u8) = .empty;
    var display: std.ArrayList(u8) = .empty;
    var origins: std.ArrayList(Range) = .empty;
    const raw_line = source[text.lineStart(source, insertion)..insertion];
    var literal = false;
    for (wrappers) |wrapper| if (wrapper.literal and display_at >= wrapper.start and display_at <= wrapper.end) {
        literal = true;
    };
    var leading: usize = 0;
    while (leading < raw_line.len and (raw_line[leading] == ' ' or raw_line[leading] == '\t' or raw_line[leading] == '>')) leading += 1;
    for (value) |byte| {
        if (byte == '\r' or byte == 0 or (byte < 32 and byte != '\n' and byte != '\t')) return error.UnsupportedText;
        if (byte == '\n') {
            // Close and reopen only wrappers enclosing this insertion, so a
            // paragraph break never leaves emphasis/link syntax unbalanced.
            for (wrappers) |wrapper| if (display_at > wrapper.start and display_at < wrapper.end) try raw.appendSlice(a, source[wrapper.close.start..wrapper.close.end]);
            try raw.append(a, '\n');
            try display.append(a, '\n');
            try origins.append(a, .{ .start = @intCast(raw.items.len), .end = @intCast(raw.items.len) });
            var anchor = origins.items.len - 1;
            if (row.kind == .list) {
                try raw.appendSlice(a, raw_line[0..leading]);
                const prefix = if (row.ordered) try std.fmt.allocPrint(a, "{d}. ", .{row.ordinal + 1}) else "- ";
                try raw.appendSlice(a, prefix);
                if (row.task != null) try raw.appendSlice(a, "[ ] ");
                const shown = if (row.task != null) "☐ " else if (row.ordered) prefix else "• ";
                try display.appendSlice(a, shown);
                try origins.appendNTimes(a, .{}, shown.len);
            } else {
                if (row.quote_depth > 0) try raw.appendSlice(a, raw_line[0..leading]);
                try raw.append(a, '\n');
                try display.append(a, '\n');
                try origins.append(a, .{ .start = @intCast(raw.items.len), .end = @intCast(raw.items.len) });
                anchor = origins.items.len - 1;
                if (row.quote_depth > 0) try raw.appendSlice(a, raw_line[0..leading]);
            }
            var i = wrappers.len;
            while (i > 0) {
                i -= 1;
                const wrapper = wrappers[i];
                if (display_at > wrapper.start and display_at < wrapper.end) try raw.appendSlice(a, source[wrapper.open.start..wrapper.open.end]);
            }
            origins.items[anchor] = .{ .start = @intCast(raw.items.len), .end = @intCast(raw.items.len) };
        } else {
            const first: u32 = @intCast(raw.items.len);
            if (literal and byte == '`') return error.EditCodeDelimiterInSource;
            if (!literal and std.ascii.isPunctuation(byte)) try raw.append(a, '\\');
            try raw.append(a, byte);
            try display.append(a, byte);
            try origins.append(a, .{ .start = first, .end = @intCast(raw.items.len) });
        }
    }
    return .{ .source = raw.items, .display = display.items, .origins = origins.items };
}
