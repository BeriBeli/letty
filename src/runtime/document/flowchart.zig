//! Inert, bounded Mermaid flowchart subset. No directives, HTML, callbacks or IO.
const std = @import("std");
pub const Direction = enum { LR, RL, TB, BT };
pub const Shape = enum { rectangle, rounded, decision };
pub const Node = struct { id: []const u8, label: []const u8, shape: Shape = .rectangle, rank: usize = 0, lane: usize = 0 };
pub const Edge = struct { from: usize, to: usize, label: []const u8 = "", dotted: bool = false, arrow: bool = true };
pub const Graph = struct { source: []const u8, direction: Direction, nodes: []Node, edges: []Edge, ranks: usize, lanes: usize };
pub fn parse(a: std.mem.Allocator, source: []const u8) !Graph {
    if (source.len > 16384) return error.FlowchartLimit;
    var p: Parser = .{ .a = a, .source = source };
    var statements = std.mem.tokenizeAny(u8, source, "\n;");
    const header = trim(statements.next() orelse return error.InvalidFlowchart);
    var words = std.mem.tokenizeAny(u8, header, " \t");
    const kind = words.next() orelse return error.InvalidFlowchart;
    if (!std.mem.eql(u8, kind, "flowchart") and !std.mem.eql(u8, kind, "graph")) return error.UnsupportedFlowchart;
    const direction = words.next() orelse return error.InvalidFlowchart;
    const dir = if (std.mem.eql(u8, direction, "TD")) .TB else std.meta.stringToEnum(Direction, direction) orelse return error.UnsupportedFlowchart;
    if (words.next() != null) return error.InvalidFlowchart;
    while (statements.next()) |statement| {
        p.remaining = trim(statement);
        if (p.remaining.len == 0 or std.mem.startsWith(u8, p.remaining, "%%")) continue;
        var from = try p.node();
        while (p.remaining.len > 0) {
            var edge: Edge = .{ .from = from, .to = 0 };
            if (p.take("-.->")) {
                edge.dotted = true;
            } else if (p.take("-->")) {} else if (p.take("---")) {
                edge.arrow = false;
            } else if (p.take("-.")) {
                edge.dotted = true;
                const end = std.mem.indexOf(u8, p.remaining, ".->") orelse return error.InvalidFlowchart;
                edge.label = try label(trim(p.remaining[0..end]));
                p.remaining = trim(p.remaining[end + 3 ..]);
            } else if (p.take("--")) {
                const end = std.mem.indexOf(u8, p.remaining, "-->") orelse return error.InvalidFlowchart;
                edge.label = try label(trim(p.remaining[0..end]));
                p.remaining = trim(p.remaining[end + 3 ..]);
            } else return error.UnsupportedFlowchart;
            if (p.take("|")) {
                const end = std.mem.indexOfScalar(u8, p.remaining, '|') orelse return error.InvalidFlowchart;
                edge.label = try label(trim(p.remaining[0..end]));
                p.remaining = trim(p.remaining[end + 1 ..]);
            }
            edge.to = try p.node();
            if (p.edges.items.len >= 256) return error.FlowchartLimit;
            try p.edges.append(a, edge);
            from = edge.to;
        }
    }
    if (p.nodes.items.len == 0) return error.InvalidFlowchart;
    // DFS marks feedback edges, then longest paths through the remaining DAG
    // establish ranks. Back edges remain visible and use outside routing lanes.
    const state = try a.alloc(u8, p.nodes.items.len);
    @memset(state, 0);
    const feedback = try a.alloc(bool, p.edges.items.len);
    @memset(feedback, false);
    for (0..p.nodes.items.len) |i| visit(i, p.edges.items, state, feedback);
    const incoming = try a.alloc(usize, p.nodes.items.len);
    @memset(incoming, 0);
    for (p.edges.items, feedback) |edge, back| if (!back) {
        incoming[edge.to] += 1;
    };
    var queue: std.ArrayList(usize) = .empty;
    for (incoming, 0..) |count, i| if (count == 0) {
        try queue.append(a, i);
    };
    var cursor: usize = 0;
    while (cursor < queue.items.len) : (cursor += 1) {
        const from = queue.items[cursor];
        for (p.edges.items, feedback) |edge, back| if (!back and edge.from == from) {
            p.nodes.items[edge.to].rank = @max(p.nodes.items[edge.to].rank, p.nodes.items[from].rank + 1);
            incoming[edge.to] -= 1;
            if (incoming[edge.to] == 0) try queue.append(a, edge.to);
        };
    }
    var ranks: usize = 1;
    var lanes: usize = 1;
    for (p.nodes.items, 0..) |*node, i| {
        for (p.nodes.items[0..i]) |previous| if (previous.rank == node.rank) {
            node.lane += 1;
        };
        ranks = @max(ranks, node.rank + 1);
        lanes = @max(lanes, node.lane + 1);
    }
    return .{ .source = source, .direction = dir, .nodes = p.nodes.items, .edges = p.edges.items, .ranks = ranks, .lanes = lanes };
}
fn visit(index: usize, edges: []const Edge, state: []u8, feedback: []bool) void {
    if (state[index] != 0) return;
    state[index] = 1;
    for (edges, 0..) |edge, i| if (edge.from == index) {
        if (state[edge.to] == 1) feedback[i] = true else visit(edge.to, edges, state, feedback);
    };
    state[index] = 2;
}
fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r");
}
fn label(value: []const u8) ![]const u8 {
    if (value.len > 512 or std.mem.indexOfAny(u8, value, "<>\\") != null) return error.UnsupportedFlowchart;
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') return value[1 .. value.len - 1];
    return value;
}
const Parser = struct {
    a: std.mem.Allocator,
    source: []const u8,
    remaining: []const u8 = "",
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    fn take(self: *Parser, token: []const u8) bool {
        if (!std.mem.startsWith(u8, self.remaining, token)) return false;
        self.remaining = trim(self.remaining[token.len..]);
        return true;
    }
    fn node(self: *Parser) !usize {
        var end: usize = 0;
        while (end < self.remaining.len and (std.ascii.isAlphanumeric(self.remaining[end]) or self.remaining[end] == '_')) end += 1;
        if (end == 0) return error.InvalidFlowchart;
        const id = self.remaining[0..end];
        for ([_][]const u8{ "subgraph", "end", "click", "style", "classDef", "class", "linkStyle", "direction" }) |word| if (std.mem.eql(u8, id, word)) return error.UnsupportedFlowchart;
        self.remaining = trim(self.remaining[end..]);
        var value = id;
        var shape: Shape = .rectangle;
        var explicit = false;
        if (self.remaining.len > 0 and std.mem.indexOfScalar(u8, "[({", self.remaining[0]) != null) {
            const open = self.remaining[0];
            const close: u8 = switch (open) {
                '[' => ']',
                '(' => ')',
                else => '}',
            };
            shape = switch (open) {
                '[' => .rectangle,
                '(' => .rounded,
                else => .decision,
            };
            self.remaining = self.remaining[1..];
            const stop = std.mem.indexOfScalar(u8, self.remaining, close) orelse return error.InvalidFlowchart;
            value = try label(trim(self.remaining[0..stop]));
            if (std.mem.indexOfAny(u8, value, "[({})]") != null) return error.UnsupportedFlowchart;
            self.remaining = trim(self.remaining[stop + 1 ..]);
            explicit = true;
        }
        for (self.nodes.items, 0..) |*item, i| if (std.mem.eql(u8, id, item.id)) {
            if (explicit) {
                item.label = value;
                item.shape = shape;
            }
            return i;
        };
        if (self.nodes.items.len >= 128) return error.FlowchartLimit;
        try self.nodes.append(self.a, .{ .id = id, .label = value, .shape = shape });
        return self.nodes.items.len - 1;
    }
};
