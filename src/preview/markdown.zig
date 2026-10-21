//! Bounded native Markdown/GFM display IR. This is an explicit readable subset,
//! not a complete CommonMark implementation: no reference-link resolution,
//! footnotes, full delimiter-flanking algorithm or HTML/entity interpretation.
//! Source text is inert; this module never loads images, opens URLs or does IO.
const std = @import("std");
pub const max_source = 1024 * 1024;
pub const max_text = 1024 * 1024;
pub const max_lines = 16384;
pub const max_spans = 32768;
pub const max_links = 2048;
pub const max_cells = 32768;
pub const max_depth = 16;
pub const Kind = enum { paragraph, heading, code, quote, list, rule, table };
pub const emphasis: u8 = 1;
pub const strong: u8 = 2;
pub const strike: u8 = 4;
pub const code: u8 = 8;
pub const link: u8 = 16;
pub const Span = struct { start: usize, end: usize, flags: u8 };
pub const Link = struct { start: usize, end: usize, target: []const u8, safe: bool, image: bool = false, line: usize = 0 };
pub const Anchor = struct { slug: []const u8, line: usize, start: usize, end: usize };
pub const Alignment = enum { left, center, right };
pub const Cell = struct { start: usize, end: usize, alignment: Alignment = .left };
pub const Line = struct {
    start: usize,
    end: usize,
    kind: Kind = .paragraph,
    level: u8 = 0,
    language: []const u8 = "",
    ordered: bool = false,
    ordinal: u32 = 0,
    task: ?bool = null,
    table_header: bool = false,
    cells: []const Cell = &.{},
    hard_break: bool = false,
};
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    text: []const u8,
    lines: []const Line,
    spans: []const Span,
    links: []const Link,
    anchors: []const Anchor,
    truncated: bool,
    pub fn init(gpa: std.mem.Allocator, source: []const u8) !Document {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        var b: Builder = .{ .a = arena.allocator(), .truncated = source.len > max_source };
        const input = try b.normalize(source[0..@min(source.len, max_source)]);
        try b.blocks(input);
        return .{ .arena = arena, .text = b.text.items, .lines = b.lines.items, .spans = b.spans.items, .links = b.links.items, .anchors = b.anchors.items, .truncated = b.truncated };
    }
    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub fn init(gpa: std.mem.Allocator, source: []const u8) !Document {
    return Document.init(gpa, source);
}
const SourceLine = struct { bytes: []const u8, next: usize };
fn lineAt(input: []const u8, at: usize) SourceLine {
    const end = std.mem.indexOfScalarPos(u8, input, at, '\n') orelse input.len;
    return .{ .bytes = input[at..end], .next = if (end < input.len) end + 1 else end };
}
fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}
fn spaces(s: []const u8) usize {
    var at: usize = 0;
    while (at < s.len and s[at] == ' ') : (at += 1) {}
    return at;
}
fn fence(s: []const u8) usize {
    if (s.len == 0 or (s[0] != '`' and s[0] != '~')) return 0;
    var n: usize = 0;
    while (n < s.len and s[n] == s[0]) : (n += 1) {}
    return if (n >= 3) n else 0;
}
fn rule(s: []const u8) bool {
    if (s.len == 0 or (s[0] != '-' and s[0] != '*' and s[0] != '_')) return false;
    var count: usize = 0;
    for (s) |ch| {
        if (ch == s[0]) count += 1 else if (ch != ' ' and ch != '\t') return false;
    }
    return count >= 3;
}
fn tableSeparator(s: []const u8) usize {
    const value = tableValue(s);
    var cells = std.mem.splitScalar(u8, value, '|');
    var count: usize = 0;
    while (cells.next()) |cell| {
        var content = trim(cell);
        if (content.len > 0 and content[0] == ':') content = content[1..];
        if (content.len > 0 and content[content.len - 1] == ':') content = content[0 .. content.len - 1];
        if (content.len == 0) return 0;
        for (content) |ch| if (ch != '-') return 0;
        count += 1;
    }
    return count;
}
fn tableColumns(header: []const u8, delimiter: []const u8) usize {
    // A header needs a real pipe; a bare "---" remains a setext underline.
    if (std.mem.indexOfScalar(u8, header, '|') == null) return 0;
    const columns = tableSeparator(delimiter);
    if (columns == 0) return 0;
    const value = tableValue(header);
    var count: usize = 1;
    var at: usize = 0;
    while (cellEnd(value, at) < value.len) {
        at = cellEnd(value, at) + 1;
        count += 1;
    }
    return if (count == columns) columns else 0;
}
const Marker = struct { end: usize, ordered: bool = false, ordinal: u32 = 0 };
fn listMarker(s: []const u8) ?Marker {
    if (s.len >= 2 and (s[0] == '-' or s[0] == '+' or s[0] == '*') and (s[1] == ' ' or s[1] == '\t')) return .{ .end = 2 };
    var end: usize = 0;
    while (end < @min(9, s.len) and std.ascii.isDigit(s[end])) : (end += 1) {}
    if (end == 0 or end + 1 >= s.len or (s[end] != '.' and s[end] != ')') or (s[end + 1] != ' ' and s[end + 1] != '\t')) return null;
    return .{ .end = end + 2, .ordered = true, .ordinal = std.fmt.parseInt(u32, s[0..end], 10) catch return null };
}
fn startsBlock(s: []const u8) bool {
    const value = trim(s);
    return value.len == 0 or fence(value) > 0 or rule(value) or value[0] == '#' or value[0] == '>' or listMarker(value) != null or spaces(s) >= 4;
}
const Builder = struct {
    a: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    lines: std.ArrayList(Line) = .empty,
    spans: std.ArrayList(Span) = .empty,
    links: std.ArrayList(Link) = .empty,
    anchors: std.ArrayList(Anchor) = .empty,
    table_alignments: []const Alignment = &.{},
    cell_count: usize = 0,
    work_left: usize = 32 * max_source,
    truncated: bool = false,
    full: bool = false,
    fn normalize(self: *Builder, source: []const u8) ![]const u8 {
        var output: std.ArrayList(u8) = .empty;
        var i: usize = if (std.mem.startsWith(u8, source, "\xef\xbb\xbf")) 3 else 0;
        while (i < source.len) {
            if (source[i] == '\r') {
                try output.append(self.a, '\n');
                i += if (i + 1 < source.len and source[i + 1] == '\n') @as(usize, 2) else 1;
                continue;
            }
            if (source[i] < 32 and source[i] != '\n' and source[i] != '\t') {
                try output.append(self.a, '?');
                i += 1;
                continue;
            }
            const n = std.unicode.utf8ByteSequenceLength(source[i]) catch 0;
            if (n == 0 or n > source.len - i or !std.unicode.utf8ValidateSlice(source[i..][0..n])) {
                try output.append(self.a, '?');
                i += 1;
                continue;
            }
            try output.appendSlice(self.a, source[i..][0..n]);
            i += n;
        }
        return output.items;
    }
    fn emit(self: *Builder, value: []const u8, flags: u8) !void {
        if (self.full or value.len == 0) return;
        var count = @min(value.len, max_text - self.text.items.len);
        while (count > 0 and count < value.len and value[count] & 0xc0 == 0x80) count -= 1;
        const start = self.text.items.len;
        if (flags != 0 and self.spans.items.len >= max_spans) {
            self.truncated = true;
            self.full = true;
            return;
        }
        try self.text.appendSlice(self.a, value[0..count]);
        if (flags != 0 and count > 0) {
            if (self.spans.items.len > 0 and self.spans.items[self.spans.items.len - 1].end == start and self.spans.items[self.spans.items.len - 1].flags == flags) {
                self.spans.items[self.spans.items.len - 1].end += count;
            } else try self.spans.append(self.a, .{ .start = start, .end = start + count, .flags = flags });
        }
        if (count != value.len) {
            self.full = true;
            self.truncated = true;
        }
    }
    fn finish(self: *Builder, value: Line) !void {
        var item = value;
        item.end = self.text.items.len;
        if (item.kind == .heading) try self.anchor(item);
        try self.lines.append(self.a, item);
        try self.emit("\n", 0);
        if (self.lines.items.len == max_lines) {
            self.full = true;
            self.truncated = true;
        }
    }
    fn blocks(self: *Builder, input: []const u8) !void {
        var pos: usize = 0;
        var fenced: u8 = 0;
        var fence_length: usize = 0;
        var language: []const u8 = "";
        var table = false;
        while (pos < input.len and !self.full) {
            const original = lineAt(input, pos);
            pos = original.next;
            const s = trim(original.bytes);
            var row: Line = .{ .start = self.text.items.len, .end = 0 };
            if (fenced != 0) {
                if (s.len > 0 and s[0] == fenced and fence(s) >= fence_length and trim(s[fence(s)..]).len == 0) {
                    fenced = 0;
                    continue;
                }
                row.kind = .code;
                row.language = language;
                try self.emit(original.bytes, code);
            } else if (fence(s) > 0) {
                fence_length = fence(s);
                fenced = s[0];
                const info = trim(s[fence_length..]);
                const end = std.mem.indexOfAny(u8, info, " \t") orelse info.len;
                var info_end = @min(end, 64);
                while (info_end > 0 and info_end < info.len and info[info_end] & 0xc0 == 0x80) info_end -= 1;
                language = try self.a.dupe(u8, info[0..info_end]);
                table = false;
                continue;
            } else if (s.len == 0) {
                table = false;
            } else if (table and !startsBlock(original.bytes)) {
                row.kind = .table;
                row.cells = try self.tableRow(s, false);
            } else if ((spaces(original.bytes) >= 4 or original.bytes[0] == '\t') and listMarker(s) == null) {
                row.kind = .code;
                try self.emit(original.bytes[if (original.bytes[0] == '\t') @as(usize, 1) else 4..], code);
            } else if (rule(s)) {
                row.kind = .rule;
                try self.emit("────────────────────────", 0);
                table = false;
            } else if (s[0] == '#') heading: {
                var n: usize = 0;
                while (n < s.len and s[n] == '#') : (n += 1) {}
                if (n > 6 or (n < s.len and s[n] != ' ' and s[n] != '\t')) break :heading try self.inlineText(original.bytes, 0, 0);
                row.kind = .heading;
                row.level = @intCast(n);
                var title = trim(s[n..]);
                if (std.mem.lastIndexOfScalar(u8, title, ' ')) |at| {
                    const tail = trim(title[at..]);
                    var closing = tail.len > 0;
                    for (tail) |ch| closing = closing and ch == '#';
                    if (closing) title = trim(title[0..at]);
                }
                try self.inlineText(title, strong, 0);
                table = false;
            } else if (s[0] == '>') {
                row.kind = .quote;
                var at: usize = 0;
                while (at < s.len and s[at] == '>') {
                    row.level +|= 1;
                    at += 1;
                    if (at < s.len and s[at] == ' ') at += 1;
                }
                for (0..row.level) |_| try self.emit("│ ", 0);
                try self.inlineText(s[at..], 0, 0);
                table = false;
            } else if (listMarker(s)) |marker| {
                row.kind = .list;
                row.level = @intCast(@min(16, spaces(original.bytes) / 2));
                row.ordered = marker.ordered;
                row.ordinal = marker.ordinal;
                var content = trim(s[marker.end..]);
                if (content.len >= 3 and content[0] == '[' and content[2] == ']' and (content[1] == ' ' or content[1] == 'x' or content[1] == 'X') and (content.len == 3 or content[3] == ' ')) {
                    row.task = content[1] != ' ';
                    content = trim(content[3..]);
                }
                for (0..row.level) |_| try self.emit("  ", 0);
                if (row.task) |checked| try self.emit(if (checked) "☑ " else "☐ ", 0) else if (marker.ordered) {
                    var number: [24]u8 = undefined;
                    try self.emit(try std.fmt.bufPrint(&number, "{d}. ", .{marker.ordinal}), 0);
                } else try self.emit("• ", 0);
                try self.inlineText(content, 0, 0);
                table = false;
            } else if (pos < input.len and setext(lineAt(input, pos).bytes) != 0) {
                row.kind = .heading;
                row.level = setext(lineAt(input, pos).bytes);
                pos = lineAt(input, pos).next;
                try self.inlineText(s, strong, 0);
                table = false;
            } else if (pos < input.len and tableColumns(s, trim(lineAt(input, pos).bytes)) > 0) {
                row.kind = .table;
                row.table_header = true;
                const delimiter = lineAt(input, pos);
                const columns = tableColumns(s, trim(delimiter.bytes));
                if (columns > max_cells - self.cell_count) {
                    self.truncated = true;
                    self.full = true;
                    break;
                }
                const alignments = try self.a.alloc(Alignment, columns);
                var cells = std.mem.splitScalar(u8, tableValue(delimiter.bytes), '|');
                for (alignments) |*alignment| {
                    const cell = trim(cells.next().?);
                    alignment.* = if (cell[cell.len - 1] == ':') (if (cell[0] == ':') .center else .right) else .left;
                }
                self.table_alignments = alignments;
                pos = delimiter.next;
                table = true;
                row.cells = try self.tableRow(s, true);
            } else {
                // Consecutive prose lines join with a space. Explicit Markdown
                // hard breaks end this IR row and preserve a rendered newline.
                var prose = original.bytes;
                while (true) {
                    var slashes: usize = 0;
                    while (slashes < prose.len and prose[prose.len - slashes - 1] == '\\') : (slashes += 1) {}
                    const hard_slash = slashes % 2 == 1;
                    const hard = std.mem.endsWith(u8, prose, "  ") or hard_slash;
                    const text = if (hard_slash) prose[0 .. prose.len - 1] else std.mem.trimEnd(u8, prose, " \t");
                    try self.inlineText(text, 0, 0);
                    row.hard_break = hard;
                    if (hard or pos >= input.len or self.full) break;
                    const next = lineAt(input, pos);
                    if (startsBlock(next.bytes) or (next.next < input.len and (setext(lineAt(input, next.next).bytes) != 0 or tableColumns(trim(next.bytes), trim(lineAt(input, next.next).bytes)) > 0))) break;
                    try self.emit(" ", 0);
                    prose = std.mem.trimStart(u8, next.bytes, " \t");
                    pos = next.next;
                }
                table = false;
            }
            try self.finish(row);
            if (row.kind != .table) table = false;
        }
    }
    fn tableRow(self: *Builder, source: []const u8, header: bool) ![]const Cell {
        const count = self.table_alignments.len;
        if (count > max_cells - self.cell_count) {
            self.truncated = true;
            self.full = true;
            return &.{};
        }
        const cells = try self.a.alloc(Cell, count);
        self.cell_count += count;
        const value = tableValue(source);
        var start: usize = 0;
        for (cells, self.table_alignments, 0..) |*cell, alignment, column| {
            if (column > 0) try self.emit("\t", 0);
            const end = cellEnd(value, start);
            cell.* = .{ .start = self.text.items.len, .end = 0, .alignment = alignment };
            try self.inlineText(trim(value[start..end]), if (header) strong else 0, 0);
            cell.end = self.text.items.len;
            start = if (end < value.len) end + 1 else value.len;
        }
        return cells;
    }
    fn inlineText(self: *Builder, source: []const u8, flags: u8, depth: usize) anyerror!void {
        if (depth == max_depth) return self.emit(source, flags);
        var i: usize = 0;
        while (i < source.len and !self.full) {
            if (!self.charge()) break;
            if (source[i] == '\\' and i + 1 < source.len and std.ascii.isPunctuation(source[i + 1])) {
                try self.emit(source[i + 1 .. i + 2], flags);
                i += 2;
                continue;
            }
            if (source[i] == '`') {
                var count: usize = 1;
                while (i + count < source.len and source[i + count] == '`') count += 1;
                if (closingRun(self, source, i + count, '`', count)) |end| {
                    var value = source[i + count .. end];
                    if (value.len >= 2 and value[0] == ' ' and value[value.len - 1] == ' ' and trim(value).len > 0) value = value[1 .. value.len - 1];
                    try self.emit(value, flags | code);
                    i = end + count;
                    continue;
                }
            }
            const image = source[i] == '!' and i + 1 < source.len and source[i + 1] == '[';
            if (source[i] == '[' or image) {
                const open = i + @intFromBool(image);
                if (linkEnd(self, source, open)) |parsed| {
                    const start = self.text.items.len;
                    if (image) try self.emit("[Image: ", flags);
                    try self.inlineText(source[open + 1 .. parsed.label_end], flags | (if (image) @as(u8, 0) else link), depth + 1);
                    if (image) {
                        try self.emit(" — ", flags);
                        try self.emit(parsed.target, flags);
                        try self.emit("]", flags);
                    }
                    try self.addLink(start, self.text.items.len, parsed.target, image);
                    i = parsed.end;
                    continue;
                }
            }
            if ((source[i] == '*' or source[i] == '_' or source[i] == '~') and (i == 0 or source[i - 1] != '\\')) {
                const ch = source[i];
                const double = i + 1 < source.len and source[i + 1] == ch;
                const count: usize = if (double) 2 else 1;
                const intraword = ch == '_' and i > 0 and std.ascii.isAlphanumeric(source[i - 1]);
                if (!intraword and (ch != '~' or double) and i + count < source.len and !std.ascii.isWhitespace(source[i + count])) {
                    if (closingRun(self, source, i + count, ch, count)) |end| {
                        if (end > i + count and !std.ascii.isWhitespace(source[end - 1])) {
                            const style = if (ch == '~') strike else if (double) strong else emphasis;
                            try self.inlineText(source[i + count .. end], flags | style, depth + 1);
                            i = end + count;
                            continue;
                        }
                    }
                }
            }
            const angle = source[i] == '<';
            const url_start = i + @intFromBool(angle);
            if ((angle or i == 0 or std.ascii.isWhitespace(source[i - 1])) and (std.mem.startsWith(u8, source[url_start..], "https://") or std.mem.startsWith(u8, source[url_start..], "http://"))) {
                var end = url_start;
                while (end < source.len and !std.ascii.isWhitespace(source[end]) and source[end] != '>') end += 1;
                if (!angle) while (end > url_start and std.mem.indexOfScalar(u8, ".,;:!?", source[end - 1]) != null) {
                    end -= 1;
                };
                if (!angle or (end < source.len and source[end] == '>')) {
                    const start = self.text.items.len;
                    try self.emit(source[url_start..end], flags | link);
                    try self.addLink(start, self.text.items.len, source[url_start..end], false);
                    i = end + @intFromBool(angle);
                    continue;
                }
            }
            const n = std.unicode.utf8ByteSequenceLength(source[i]) catch 1;
            try self.emit(source[i..][0..@min(n, source.len - i)], flags);
            i += n;
        }
    }
    fn addLink(self: *Builder, start: usize, end: usize, target: []const u8, image: bool) !void {
        if (self.links.items.len == max_links) {
            self.full = true;
            self.truncated = true;
            return;
        }
        const memory = try self.a.alloc(u8, target.len);
        var used: usize = 0;
        var at: usize = 0;
        while (at < target.len) : (at += 1) {
            if (target[at] == '\\' and at + 1 < target.len and std.ascii.isPunctuation(target[at + 1])) at += 1;
            memory[used] = target[at];
            used += 1;
        }
        const owned = memory[0..used];
        try self.links.append(self.a, .{ .start = start, .end = end, .target = owned, .safe = !image and safeTarget(owned), .image = image, .line = self.lines.items.len });
    }
    fn charge(self: *Builder) bool {
        if (self.work_left == 0) {
            self.full = true;
            self.truncated = true;
            return false;
        }
        self.work_left -= 1;
        return true;
    }
    fn anchor(self: *Builder, row: Line) !void {
        if (self.anchors.items.len == max_links) {
            self.truncated = true;
            return;
        }
        var slug: std.ArrayList(u8) = .empty;
        for (self.text.items[row.start..row.end]) |byte| {
            if (slug.items.len >= 480) break;
            if (byte >= 128 or std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-') try slug.append(self.a, std.ascii.toLower(byte)) else if (byte == ' ' and slug.items.len > 0 and slug.items[slug.items.len - 1] != '-') try slug.append(self.a, '-');
        }
        var valid = slug.items.len;
        while (valid > 0 and !std.unicode.utf8ValidateSlice(slug.items[0..valid])) valid -= 1;
        const base = std.mem.trim(u8, slug.items[0..valid], "-");
        var candidate = if (base.len == 0) @as([]const u8, "section") else base;
        var suffix: usize = 0;
        while (true) {
            var exists = false;
            for (self.anchors.items) |known| if (std.mem.eql(u8, known.slug, candidate)) {
                exists = true;
                break;
            };
            if (!exists) break;
            suffix += 1;
            candidate = try std.fmt.allocPrint(self.a, "{s}-{d}", .{ if (base.len == 0) "section" else base, suffix });
        }
        try self.anchors.append(self.a, .{ .slug = candidate, .line = self.lines.items.len, .start = row.start, .end = row.end });
    }
};
fn setext(source: []const u8) u8 {
    const s = trim(source);
    if (s.len == 0 or (s[0] != '=' and s[0] != '-')) return 0;
    for (s) |ch| if (ch != s[0]) return 0;
    return if (s[0] == '=') 1 else 2;
}
fn closingRun(b: *Builder, source: []const u8, begin: usize, ch: u8, count: usize) ?usize {
    var i = begin;
    while (i < source.len) {
        if (!b.charge()) return null;
        if (source[i] == '\\') {
            i += @min(2, source.len - i);
            continue;
        }
        if (source[i] != ch) {
            i += 1;
            continue;
        }
        var end = i;
        while (end < source.len and source[end] == ch) : (end += 1) {}
        const n = end - i;
        if (n == count or (ch != '`' and n > count and begin < source.len and source[begin] == ch)) return if (ch != '`' and n > count) end - count else i;
        i = end;
    }
    return null;
}
fn cellEnd(value: []const u8, start: usize) usize {
    var i = start;
    var ticks: usize = 0;
    while (i < value.len) : (i += 1) {
        if (value[i] == '\\' and i + 1 < value.len) {
            i += 1;
            continue;
        }
        if (value[i] == '`') {
            var end = i + 1;
            while (end < value.len and value[end] == '`') : (end += 1) {}
            if (ticks == 0) ticks = end - i else if (ticks == end - i) ticks = 0;
            i = end - 1;
        } else if (value[i] == '|' and ticks == 0) return i;
    }
    return value.len;
}
fn tableValue(source: []const u8) []const u8 {
    var value = trim(source);
    if (value.len > 0 and value[0] == '|') value = value[1..];
    if (value.len > 0 and value[value.len - 1] == '|') {
        var slashes: usize = 0;
        while (slashes + 1 < value.len and value[value.len - slashes - 2] == '\\') slashes += 1;
        if (slashes % 2 == 0) value = value[0 .. value.len - 1];
    }
    return value;
}
const ParsedLink = struct { label_end: usize, end: usize, target: []const u8 };
fn linkEnd(b: *Builder, source: []const u8, open: usize) ?ParsedLink {
    var at = open + 1;
    var brackets: usize = 1;
    while (at < source.len and brackets > 0) : (at += 1) {
        if (!b.charge()) return null;
        if (source[at] == '\\') {
            at += @min(1, source.len - at - 1);
            continue;
        }
        if (source[at] == '[') brackets += 1;
        if (source[at] == ']') brackets -= 1;
        if (brackets > max_depth) return null;
    }
    if (brackets != 0 or at >= source.len or source[at] != '(') return null;
    const label_end = at - 1;
    var end = at + 1;
    var parens: usize = 1;
    while (end < source.len and parens > 0) : (end += 1) {
        if (!b.charge()) return null;
        if (source[end] == '\\') {
            end += @min(1, source.len - end - 1);
            continue;
        }
        if (source[end] == '(') parens += 1;
        if (source[end] == ')') parens -= 1;
        if (parens > max_depth) return null;
    }
    if (parens != 0) return null;
    var target = trim(source[at + 1 .. end - 1]);
    if (target.len >= 2 and target[0] == '<') {
        const closing = std.mem.indexOfScalar(u8, target, '>') orelse return null;
        target = target[1..closing];
    } else if (std.mem.indexOfAny(u8, target, " \t")) |space| target = target[0..space];
    return .{ .label_end = label_end, .end = end, .target = target };
}
pub fn safeTarget(target: []const u8) bool {
    if (target.len == 0 or target.len > 4096 or !std.unicode.utf8ValidateSlice(target)) return false;
    for (target) |byte| if (byte <= 32 or byte == 127 or byte == '\\') return false;
    if (std.ascii.startsWithIgnoreCase(target, "https://") or std.ascii.startsWithIgnoreCase(target, "http://")) return true;
    if (target[0] == '#') return true;
    if (target[0] == '/' or std.mem.indexOfScalar(u8, target, ':') != null) return false;
    var decoded: [4096]u8 = undefined;
    var used: usize = 0;
    var at: usize = 0;
    while (at < target.len) : (at += 1) {
        var byte = target[at];
        if (byte == '%') {
            if (target.len - at < 3) return false;
            byte = std.fmt.parseInt(u8, target[at + 1 .. at + 3], 16) catch return false;
            at += 2;
        }
        if (byte < 32 or byte == 127 or byte == ':' or byte == '\\') return false;
        decoded[used] = byte;
        used += 1;
    }
    const path = decoded[0..used];
    if (path.len == 0 or path[0] == '/' or !std.unicode.utf8ValidateSlice(path)) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| if (std.mem.eql(u8, component, "..")) return false;
    return true;
}
