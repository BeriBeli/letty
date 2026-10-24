//! Bounded XML reader for SVN CLI output. No DTD, external entities or I/O.
//! Tokens borrow names from the source; decoded text/attributes live in the
//! caller's arena. Reject malformed/truncated documents before publishing data.
const std = @import("std");
const A = std.mem.Allocator;
const invalid = error.InvalidSvnXml;
pub const limit = 4 << 20;
pub const Token = struct {
    kind: enum { start, end, text },
    name: []const u8 = "",
    value: []const u8 = "",
    depth: usize,
    attrs: [24]Attribute = undefined,
    count: usize = 0,
    const Attribute = struct { name: []const u8, value: []const u8 };
    pub fn attr(self: *const Token, name: []const u8) ?[]const u8 {
        for (self.attrs[0..self.count]) |pair| if (std.mem.eql(u8, pair.name, name)) return pair.value;
        return null;
    }
};
pub const Reader = struct {
    source: []const u8,
    at: usize = 0,
    stack: [32][]const u8 = undefined,
    depth: usize = 0,
    root: bool = false,
    pending_end: bool = false,
    pub fn init(source: []const u8) !Reader {
        if (source.len > limit) return error.SvnOutputLimit;
        if (!std.unicode.utf8ValidateSlice(source)) return invalid;
        return .{ .source = source };
    }
    pub fn next(self: *Reader, a: A) !?Token {
        if (self.pending_end) {
            self.pending_end = false;
            self.depth -= 1;
            return .{ .kind = .end, .name = self.stack[self.depth], .depth = self.depth };
        }
        while (self.at < self.source.len) {
            if (self.source[self.at] != '<') {
                const start = self.at;
                self.at += std.mem.indexOfScalar(u8, self.source[start..], '<') orelse self.source.len - start;
                const value = try decode(a, self.source[start..self.at]);
                if (self.depth == 0 and std.mem.trim(u8, value, " \r\n\t").len != 0) return invalid;
                return .{ .kind = .text, .value = value, .depth = self.depth };
            }
            if (std.mem.startsWith(u8, self.source[self.at..], "<!--")) {
                self.at += 4;
                const end = self.at + (std.mem.indexOf(u8, self.source[self.at..], "-->") orelse return invalid);
                if (std.mem.indexOf(u8, self.source[self.at..end], "--") != null) return invalid;
                self.at = end + 3;
                continue;
            }
            if (std.mem.startsWith(u8, self.source[self.at..], "<?xml ")) {
                if (self.at != 0) return invalid;
                self.at += (std.mem.indexOf(u8, self.source, "?>") orelse return invalid) + 2;
                continue;
            }
            self.at += 1;
            const ending = self.eat('/');
            const tag_name = try self.name();
            if (ending) {
                self.space();
                if (!self.eat('>') or self.depth == 0) return invalid;
                self.depth -= 1;
                if (!std.mem.eql(u8, self.stack[self.depth], tag_name)) return invalid;
                return .{ .kind = .end, .name = tag_name, .depth = self.depth };
            }
            if (self.depth == self.stack.len or (self.depth == 0 and self.root)) return invalid;
            var token: Token = .{ .kind = .start, .name = tag_name, .depth = self.depth };
            while (true) {
                const before = self.at;
                self.space();
                if (self.eat('>')) break;
                if (self.eat('/')) {
                    if (!self.eat('>')) return invalid;
                    self.pending_end = true;
                    break;
                }
                if (before == self.at or token.count == token.attrs.len) return invalid;
                const key = try self.name();
                if (token.attr(key) != null) return invalid;
                self.space();
                if (!self.eat('=')) return invalid;
                self.space();
                if (self.at == self.source.len) return invalid;
                const quote = self.source[self.at];
                if (quote != '\'' and quote != '"') return invalid;
                self.at += 1;
                const start = self.at;
                self.at += std.mem.indexOfScalar(u8, self.source[start..], quote) orelse return invalid;
                if (std.mem.indexOfScalar(u8, self.source[start..self.at], '<') != null) return invalid;
                token.attrs[token.count] = .{ .name = key, .value = try decode(a, self.source[start..self.at]) };
                token.count += 1;
                self.at += 1;
            }
            self.root = true;
            self.stack[self.depth] = tag_name;
            self.depth += 1;
            return token;
        }
        if (!self.root or self.depth != 0) return invalid;
        return null;
    }
    fn eat(self: *Reader, ch: u8) bool {
        if (self.at == self.source.len or self.source[self.at] != ch) return false;
        self.at += 1;
        return true;
    }
    fn space(self: *Reader) void {
        while (self.at < self.source.len and std.mem.indexOfScalar(u8, " \r\n\t", self.source[self.at]) != null) self.at += 1;
    }
    fn name(self: *Reader) ![]const u8 {
        const start = self.at;
        while (self.at < self.source.len) : (self.at += 1) {
            const ch = self.source[self.at];
            if (!std.ascii.isAlphabetic(ch) and ch != '_' and ch != ':' and !(self.at > start and (std.ascii.isDigit(ch) or ch == '-' or ch == '.'))) break;
        }
        if (start == self.at) return invalid;
        return self.source[start..self.at];
    }
};
fn decode(a: A, source: []const u8) ![]const u8 {
    const out = try a.alloc(u8, source.len);
    var length: usize = 0;
    var at: usize = 0;
    while (at < source.len) {
        const ch = source[at];
        if (ch < 0x20 and ch != '\n' and ch != '\r' and ch != '\t') return invalid;
        if (ch != '&') {
            out[length] = ch;
            length += 1;
            at += 1;
            continue;
        }
        const end = at + (std.mem.indexOfScalar(u8, source[at..], ';') orelse return invalid);
        const entity = source[at + 1 .. end];
        const cp: u21 = if (std.mem.eql(u8, entity, "amp")) '&' else if (std.mem.eql(u8, entity, "lt")) '<' else if (std.mem.eql(u8, entity, "gt")) '>' else if (std.mem.eql(u8, entity, "quot")) '"' else if (std.mem.eql(u8, entity, "apos")) '\'' else blk: {
            if (entity.len < 2 or entity[0] != '#') return invalid;
            const hex = entity[1] == 'x';
            const number = entity[if (hex) @as(usize, 2) else 1..];
            for (number) |digit| if (!(if (hex) std.ascii.isHex(digit) else std.ascii.isDigit(digit))) return invalid;
            break :blk std.fmt.parseInt(u21, number, if (hex) 16 else 10) catch return invalid;
        };
        if ((cp < 0x20 and cp != 9 and cp != 10 and cp != 13) or cp == 0xfffe or cp == 0xffff) return invalid;
        const n = std.unicode.utf8Encode(cp, out[length..]) catch return invalid;
        length += n;
        at = end + 1;
    }
    return out[0..length];
}
