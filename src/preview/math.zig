//! Small, bounded TeX expression parser. Unsupported commands fail as a whole;
//! callers retain the original source instead of inventing mathematical meaning.
const std = @import("std");
pub const Node = union(enum) {
    text: []const u8,
    sequence: []const *const Node,
    fraction: Pair,
    root: *const Node,
    scripts: struct { base: *const Node, sub: ?*const Node, sup: ?*const Node },
    pub const Pair = struct { top: *const Node, bottom: *const Node };
};
pub fn parse(a: std.mem.Allocator, source: []const u8) !*const Node {
    if (source.len > 4096) return error.MathLimit;
    var p: Parser = .{ .a = a, .source = source };
    const result = try p.sequence(0, false);
    if (p.at != source.len) return error.InvalidMath;
    return result;
}
const Parser = struct {
    a: std.mem.Allocator,
    source: []const u8,
    at: usize = 0,
    nodes: usize = 0,
    fn node(self: *Parser, value: Node) !*const Node {
        if (self.nodes >= 512) return error.MathLimit;
        self.nodes += 1;
        const out = try self.a.create(Node);
        out.* = value;
        return out;
    }
    fn whitespace(self: *Parser) void {
        while (self.at < self.source.len and std.ascii.isWhitespace(self.source[self.at])) self.at += 1;
    }
    fn sequence(self: *Parser, depth: usize, group: bool) anyerror!*const Node {
        if (depth > 24) return error.MathLimit;
        var children: std.ArrayList(*const Node) = .empty;
        while (true) {
            self.whitespace();
            if (self.at >= self.source.len) {
                if (group) return error.InvalidMath;
                break;
            }
            if (self.source[self.at] == '}') {
                if (!group) return error.InvalidMath;
                self.at += 1;
                break;
            }
            var base = try self.atom(depth + 1);
            var sub: ?*const Node = null;
            var sup: ?*const Node = null;
            self.whitespace();
            while (self.at < self.source.len and (self.source[self.at] == '_' or self.source[self.at] == '^')) {
                const is_sub = self.source[self.at] == '_';
                self.at += 1;
                if ((is_sub and sub != null) or (!is_sub and sup != null)) return error.InvalidMath;
                const value = try self.atom(depth + 1);
                if (is_sub) sub = value else sup = value;
                self.whitespace();
            }
            if (sub != null or sup != null) base = try self.node(.{ .scripts = .{ .base = base, .sub = sub, .sup = sup } });
            try children.append(self.a, base);
        }
        return self.node(.{ .sequence = children.items });
    }
    fn atom(self: *Parser, depth: usize) anyerror!*const Node {
        if (depth > 24) return error.MathLimit;
        self.whitespace();
        if (self.at == self.source.len) return error.InvalidMath;
        const start = self.at;
        const ch = self.source[self.at];
        self.at += 1;
        if (ch == '{') return self.sequence(depth, true);
        if (ch == '}' or ch == '^' or ch == '_' or ch == '&' or ch == '$') return error.InvalidMath;
        if (ch != '\\') {
            const len = std.unicode.utf8ByteSequenceLength(ch) catch return error.InvalidMath;
            if (start + len > self.source.len) return error.InvalidMath;
            self.at = start + len;
            return self.node(.{ .text = self.source[start..self.at] });
        }
        const name_start = self.at;
        while (self.at < self.source.len and std.ascii.isAlphabetic(self.source[self.at])) self.at += 1;
        const name = self.source[name_start..self.at];
        if (name.len == 0) {
            if (self.at == self.source.len) return error.InvalidMath;
            self.at += 1;
            const escaped = self.source[name_start..self.at];
            if (std.mem.indexOfScalar(u8, "{}_%$# ", escaped[0]) != null) return self.node(.{ .text = escaped });
            if (std.mem.indexOfScalar(u8, ",;:", escaped[0]) != null) return self.node(.{ .text = " " });
            if (escaped[0] == '!') return self.node(.{ .text = "" });
            return error.UnsupportedMath;
        }
        if (std.mem.eql(u8, name, "frac") or std.mem.eql(u8, name, "dfrac") or std.mem.eql(u8, name, "tfrac")) {
            const top = try self.atom(depth + 1);
            const bottom = try self.atom(depth + 1);
            return self.node(.{ .fraction = .{ .top = top, .bottom = bottom } });
        }
        if (std.mem.eql(u8, name, "sqrt")) {
            self.whitespace();
            if (self.at < self.source.len and self.source[self.at] == '[') return error.UnsupportedMath;
            return self.node(.{ .root = try self.atom(depth + 1) });
        }
        if (std.mem.eql(u8, name, "text") or std.mem.eql(u8, name, "mathrm") or std.mem.eql(u8, name, "operatorname")) {
            self.whitespace();
            if (self.at == self.source.len or self.source[self.at] != '{') return error.InvalidMath;
            self.at += 1;
            const begin = self.at;
            while (self.at < self.source.len and self.source[self.at] != '}') : (self.at += 1) {
                if (self.source[self.at] == '{' or self.source[self.at] == '\\') return error.UnsupportedMath;
            }
            if (self.at == self.source.len) return error.InvalidMath;
            const value = self.source[begin..self.at];
            self.at += 1;
            return self.node(.{ .text = value });
        }
        for (symbols) |entry| if (std.mem.eql(u8, name, entry[0])) return self.node(.{ .text = entry[1] });
        return error.UnsupportedMath;
    }
};
const symbols = [_][2][]const u8{
    .{ "alpha", "α" },
    .{ "beta", "β" },
    .{ "gamma", "γ" },
    .{ "delta", "δ" },
    .{ "epsilon", "ε" },
    .{ "theta", "θ" },
    .{ "lambda", "λ" },
    .{ "mu", "μ" },
    .{ "nu", "ν" },
    .{ "xi", "ξ" },
    .{ "pi", "π" },
    .{ "rho", "ρ" },
    .{ "sigma", "σ" },
    .{ "tau", "τ" },
    .{ "phi", "φ" },
    .{ "chi", "χ" },
    .{ "psi", "ψ" },
    .{ "omega", "ω" },
    .{ "Gamma", "Γ" },
    .{ "Delta", "Δ" },
    .{ "Theta", "Θ" },
    .{ "Lambda", "Λ" },
    .{ "Pi", "Π" },
    .{ "Sigma", "Σ" },
    .{ "Phi", "Φ" },
    .{ "Psi", "Ψ" },
    .{ "Omega", "Ω" },
    .{ "sum", "∑" },
    .{ "prod", "∏" },
    .{ "int", "∫" },
    .{ "infty", "∞" },
    .{ "partial", "∂" },
    .{ "nabla", "∇" },
    .{ "times", "×" },
    .{ "cdot", "·" },
    .{ "div", "÷" },
    .{ "pm", "±" },
    .{ "mp", "∓" },
    .{ "le", "≤" },
    .{ "leq", "≤" },
    .{ "ge", "≥" },
    .{ "geq", "≥" },
    .{ "ne", "≠" },
    .{ "neq", "≠" },
    .{ "approx", "≈" },
    .{ "equiv", "≡" },
    .{ "to", "→" },
    .{ "rightarrow", "→" },
    .{ "leftarrow", "←" },
    .{ "Rightarrow", "⇒" },
    .{ "in", "∈" },
    .{ "notin", "∉" },
    .{ "subset", "⊂" },
    .{ "cup", "∪" },
    .{ "cap", "∩" },
    .{ "forall", "∀" },
    .{ "exists", "∃" },
    .{ "ldots", "…" },
    .{ "cdots", "⋯" },
    .{ "sin", "sin" },
    .{ "cos", "cos" },
    .{ "tan", "tan" },
    .{ "log", "log" },
    .{ "ln", "ln" },
    .{ "exp", "exp" },
    .{ "lim", "lim" },
    .{ "min", "min" },
    .{ "max", "max" },
    .{ "quad", "  " },
    .{ "qquad", "    " },
};
