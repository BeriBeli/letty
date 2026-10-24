//! Bounded lexical coloring shared by the native review surfaces.
const std = @import("std");
pub const Kind = enum { keyword, string, comment, number };
pub const Token = struct { start: u32, end: u32, kind: Kind };
pub const Language = enum { plain, c_like, hash, shell };
pub fn language(path: []const u8) Language {
    const ext = std.fs.path.extension(path);
    for ([_][]const u8{ ".zig", ".c", ".h", ".cpp", ".hpp", ".cc", ".go", ".rs", ".js", ".jsx", ".ts", ".tsx", ".java", ".swift", ".css", ".json", ".sv", ".v" }) |value| if (std.ascii.eqlIgnoreCase(ext, value)) return .c_like;
    for ([_][]const u8{ ".py", ".rb", ".yaml", ".yml", ".toml", ".conf" }) |value| if (std.ascii.eqlIgnoreCase(ext, value)) return .hash;
    if (std.mem.eql(u8, std.fs.path.basename(path), "Dockerfile") or std.mem.eql(u8, std.fs.path.basename(path), "Makefile")) return .hash;
    for ([_][]const u8{ ".sh", ".bash", ".zsh", ".fish" }) |value| if (std.ascii.eqlIgnoreCase(ext, value)) return .shell;
    return .plain;
}
pub const State = struct { block_comment: bool = false };
/// Caller-owned token storage bounds allocations even for adversarial source.
/// Scanning continues after it fills so the next line receives correct state.
pub fn scan(state: *State, lang: Language, text: []const u8, output: []Token) []Token {
    if (lang == .plain) return output[0..0];
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const start = i;
        var kind: ?Kind = null;
        if (state.block_comment) {
            if (std.mem.indexOf(u8, text[i..], "*/")) |end| {
                i += end + 2;
                state.block_comment = false;
            } else i = text.len;
            kind = .comment;
        } else if (lang == .c_like and i + 1 < text.len and std.mem.eql(u8, text[i..][0..2], "/*")) {
            state.block_comment = true;
            i += 2;
            if (std.mem.indexOf(u8, text[i..], "*/")) |end| {
                i += end + 2;
                state.block_comment = false;
            } else i = text.len;
            kind = .comment;
        } else if ((lang != .c_like and text[i] == '#') or (lang == .c_like and std.mem.startsWith(u8, text[i..], "//"))) {
            i = text.len;
            kind = .comment;
        } else if (text[i] == '"' or text[i] == '\'' or (lang == .c_like and text[i] == '`')) {
            const quote = text[i];
            i += 1;
            while (i < text.len) {
                const ch = text[i];
                i += 1;
                if (ch == '\\' and i < text.len) i += 1 else if (ch == quote) break;
            }
            kind = .string;
        } else if (std.ascii.isDigit(text[i]) and (i == 0 or !word(text[i - 1]))) {
            i += 1;
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_' or text[i] == '.')) : (i += 1) {}
            kind = .number;
        } else if (word(text[i])) {
            i += 1;
            while (i < text.len and word(text[i])) : (i += 1) {}
            if (output.len > 0 and keyword(text[start..i])) kind = .keyword;
        } else i += 1;
        if (kind) |value| if (count < output.len) {
            output[count] = .{ .start = @intCast(start), .end = @intCast(i), .kind = value };
            count += 1;
        };
    }
    return output[0..count];
}
fn word(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 128;
}
fn keyword(value: []const u8) bool {
    const words = " const var let fn func def class struct enum union pub public private protected static extern export import from package module use using return if else switch case default match for while do break continue try catch except finally throw throws error defer errdefer async await yield new delete true false null nil None True False self this super sizeof comptime inline volatile mut impl trait type alias interface extends implements function begin end always wire reg logic assign input output in is not and or as with lambda pass raise fi then done esac local select ";
    var it = std.mem.tokenizeScalar(u8, words, ' ');
    while (it.next()) |item| if (std.mem.eql(u8, value, item)) return true;
    return false;
}
test "review lexer preserves UTF-8 byte ranges and bounded multiline state" {
    var state: State = .{};
    var tokens: [16]Token = undefined;
    const first = scan(&state, .c_like, "const 名 = 42; /* start", &tokens);
    try std.testing.expectEqual(@as(usize, 3), first.len);
    try std.testing.expect(first[0].kind == .keyword and first[1].kind == .number and state.block_comment);
    var tiny: [1]Token = undefined;
    _ = scan(&state, .c_like, "end */ const x = \"// string\"; /* open", &tiny);
    try std.testing.expect(state.block_comment);
    const last = scan(&state, .c_like, "*/ return 'x'; // tail", &tokens);
    try std.testing.expect(!state.block_comment and last.len == 4 and last[3].kind == .comment);
    try std.testing.expectEqual(Language.shell, language("/tmp/你好.sh"));
    try std.testing.expectEqual(Language.plain, language("file.unknown"));
}
