//! Block quotes, fenced flowcharts and TeX delimiters, kept out of the core parser.
const std = @import("std");
const md = @import("markdown.zig");
pub const Formula = struct { start: usize, end: usize, node: *const @import("math.zig").Node };
fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}
fn endLine(input: []const u8, at: usize) usize {
    return std.mem.indexOfScalarPos(u8, input, at, '\n') orelse input.len;
}
pub fn quote(b: anytype, input: []const u8, first: usize, pos: *usize) !void {
    var quoted: std.ArrayList(u8) = .empty;
    var origins: std.ArrayList(u32) = .empty;
    var at = first;
    var lazy = false;
    while (at < input.len) {
        const end = endLine(input, at);
        var line = std.mem.trimStart(u8, input[at..end], " \t\r");
        if (line.len > 0 and line[0] == '>') {
            line = line[1..];
            if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) line = line[1..];
            lazy = trim(line).len > 0 and std.mem.indexOfScalar(u8, "#>-*+`~", line[0]) == null;
        } else if (!lazy or line.len == 0 or md.startsBlock(line)) break;
        if (line.len > b.work_left) {
            b.truncated = true;
            b.full = true;
            break;
        }
        b.work_left -= line.len;
        try quoted.appendSlice(b.a, line);
        const offset = @intFromPtr(line.ptr) - @intFromPtr(input.ptr);
        for (0..line.len) |i| try origins.append(b.a, b.sourceAt(offset + i));
        try quoted.append(b.a, '\n');
        try origins.append(b.a, b.sourceAt(end));
        at = if (end < input.len) end + 1 else end;
    }
    pos.* = at;
    if (b.quote_depth >= md.max_depth) {
        try b.emit(trim(input[first..at]), 0);
        return;
    }
    b.quote_depth += 1;
    defer b.quote_depth -= 1;
    try origins.append(b.a, b.sourceAt(at));
    const previous_input = b.input;
    const previous_origins = b.input_origins;
    b.input = quoted.items;
    b.input_origins = origins.items;
    defer {
        b.input = previous_input;
        b.input_origins = previous_origins;
    }
    try b.blocks(quoted.items);
}
/// Called after the opening fence. Returns true only when the whole block has a
/// native representation; invalid/unsupported Mermaid remains a code block.
pub fn diagram(b: anytype, input: []const u8, pos: *usize, marker: u8, count: usize, row: *md.Line) !bool {
    var at = pos.*;
    while (at < input.len) {
        const end = endLine(input, at);
        const line = trim(input[at..end]);
        var n: usize = 0;
        while (n < line.len and line[n] == marker) n += 1;
        if (n >= count and trim(line[n..]).len == 0) {
            const source = input[pos.*..at];
            const graph = @import("flowchart.zig").parse(b.a, source) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return false,
            };
            row.kind = .diagram;
            const owned = try b.a.create(@import("flowchart.zig").Graph);
            owned.* = graph;
            row.diagram = owned;
            // One logical selectable row; exact multiline source remains in Graph.
            try flattened(b, source, 0);
            pos.* = if (end < input.len) end + 1 else end;
            return true;
        }
        at = if (end < input.len) end + 1 else end;
        if (at - pos.* > 16384) return false;
    }
    return false;
}
pub fn formula(b: anytype, raw: []const u8, is_display: bool) !bool {
    if (b.formulas.items.len >= 256) return false;
    const node = @import("math.zig").parse(b.a, raw) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    const start = b.text.items.len;
    try flattened(b, raw, 0);
    if (!b.full and b.text.items.len > start) try b.formulas.append(b.a, .{ .start = start, .end = b.text.items.len, .node = node });
    _ = is_display;
    return true;
}
pub fn display(b: anytype, input: []const u8, original: []const u8, pos: *usize, row: *md.Line) !bool {
    const line = trim(original);
    const dollar = std.mem.startsWith(u8, line, "$$");
    const bracket = std.mem.startsWith(u8, line, "\\[");
    if (!dollar and !bracket) return false;
    const close = if (dollar) "$$" else "\\]";
    const rest = line[2..];
    var source: []const u8 = undefined;
    var next = pos.*;
    if (std.mem.endsWith(u8, rest, close)) source = rest[0 .. rest.len - 2] else {
        if (trim(rest).len != 0) return false;
        var at = pos.*;
        while (at < input.len and at - pos.* <= 4096) {
            const end = endLine(input, at);
            if (std.mem.eql(u8, trim(input[at..end]), close)) break;
            at = if (end < input.len) end + 1 else end;
        }
        if (at == input.len or at - pos.* > 4096) return false;
        source = input[pos.*..at];
        const end = endLine(input, at);
        next = if (end < input.len) end + 1 else end;
    }
    row.kind = .math;
    if (!try formula(b, source, true)) {
        row.kind = .code;
        row.language = "Unsupported math · source";
        try b.emit("[Unsupported math] ", md.code);
        try flattened(b, source, md.code);
    }
    pos.* = next;
    return true;
}
pub fn inlineFormula(b: anytype, source: []const u8, at: *usize, flags: u8) !bool {
    const previous_inert = b.inert;
    b.inert = true;
    defer b.inert = previous_inert;
    const i = at.*;
    const dollar = source[i] == '$' and (i + 1 == source.len or source[i + 1] != '$');
    const paren = std.mem.startsWith(u8, source[i..], "\\(");
    if (!dollar and !paren) return false;
    const n: usize = if (dollar) 1 else 2;
    if (i + n >= source.len or std.ascii.isWhitespace(source[i + n])) return false;
    const closing = if (dollar) "$" else "\\)";
    var end = i + n;
    while (end < source.len and end - i <= 4096) : (end += 1) {
        if (!b.charge()) return false;
        if (!std.mem.startsWith(u8, source[end..], closing) or (end > 0 and source[end - 1] == '\\')) continue;
        if (end == i + n or std.ascii.isWhitespace(source[end - 1])) return false;
        // Avoid treating ordinary prices as a formula.
        if (dollar and end + 1 < source.len and std.ascii.isDigit(source[end + 1])) return false;
        if (!try formula(b, source[i + n .. end], false)) {
            try b.emit("[Unsupported math: ", flags | md.code);
            try b.emit(source[i + n .. end], flags | md.code);
            try b.emit("]", flags | md.code);
        }
        at.* = end + n;
        return true;
    }
    return false;
}

fn flattened(b: anytype, source: []const u8, flags: u8) !void {
    const value = try b.a.dupe(u8, source);
    for (value) |*ch| if (ch.* == '\n' or ch.* == '\r') {
        ch.* = ' ';
    };
    try b.emit(value, flags);
}
