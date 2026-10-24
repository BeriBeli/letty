const std = @import("std");
const md = @import("markdown.zig");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
pub const workflow =
    \\flowchart LR
    \\    A[统一格式的 Excel 定义] --> B[自动校验]
    \\    B -->|失败| C[定位到工作表和单元格]
    \\    C --> A
    \\    B -->|通过| D[结构化寄存器模型]
    \\    D --> E[RALF]
    \\    D --> F[离线 HTML 文档]
    \\    D -. 后续接入生成器 .-> G[Header / RTL / 其他模型]
;
pub const fixture =
    \\# Markdown extensions
    \\
    \\> 引用内容有清楚的边线，换行后保持缩进。 **重点** 和 `代码` 仍然保留样式。
    \\> 这一行与上一行组成同一个段落。
    \\>
    \\> ## 引用中的标题
    \\> > 嵌套引用
    \\> - 引用中的列表
    \\
    \\行内公式 $E=mc^2$，以及 $x_i^2 + \frac{a}{b}$，在窄窗口中也能正确换行。
    \\
    \\$$
    \\x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}
    \\$$
    \\
    \\\[ \sum_{i=1}^{n} i = \frac{n(n+1)}{2} \]
    \\
    \\| Formula | Meaning |
    \\| --- | --- |
    \\| $\frac{a_1}{\sqrt{b}}$ | Fraction and root |
    \\
    \\```mermaid
++ workflow ++ "\n```\n";
test "quoted blocks retain nested structure and merge lazy paragraph continuation" {
    var doc = try md.init(std.testing.allocator, "> first\ncontinued\n> third\n>\n> # Heading\n> > nested\n> - item\n\noutside\n");
    defer doc.deinit();
    try std.testing.expectEqualStrings("first continued third\n\nHeading\nnested\n• item\n\noutside\n", doc.text);
    try equal(@as(u8, 1), doc.lines[0].quote_depth);
    try equal(md.Kind.heading, doc.lines[2].kind);
    try equal(@as(u8, 2), doc.lines[3].quote_depth);
    try equal(md.Kind.list, doc.lines[4].kind);
    try equal(@as(u8, 0), doc.lines[6].quote_depth);
    try expect(std.mem.indexOf(u8, doc.text, "│") == null);
}
test "user workflow includes labels feedback edge and dotted edge" {
    var doc = try md.init(std.testing.allocator, "```mermaid\n" ++ workflow ++ "\n```\n");
    defer doc.deinit();
    try equal(@as(usize, 1), doc.lines.len);
    const graph = doc.lines[0].diagram.?;
    try equal(@as(usize, 7), graph.nodes.len);
    try equal(@as(usize, 7), graph.edges.len);
    try equal(@import("flowchart.zig").Direction.LR, graph.direction);
    try expect(graph.edges[6].dotted);
    try std.testing.expectEqualStrings("后续接入生成器", graph.edges[6].label);
    try expect(graph.nodes[2].rank > graph.nodes[0].rank);
    try std.testing.expectEqualStrings(workflow ++ "\n", graph.source);
}
test "flowchart directions chains and unsupported input have explicit fallback" {
    for ([_][]const u8{ "LR", "RL", "TD", "TB", "BT" }) |direction| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "```mermaid\ngraph {s}; A(Start) --> B{{Decision}} -->|yes| C[End]; C --> C\n```", .{direction});
        defer std.testing.allocator.free(source);
        var doc = try md.init(std.testing.allocator, source);
        defer doc.deinit();
        try expect(doc.lines[0].diagram != null);
        try equal(@as(usize, 3), doc.lines[0].diagram.?.edges.len);
    }
    for ([_][]const u8{ "sequenceDiagram\nA->>B: hi", "flowchart LR\nA --> B\nclick A evil", "flowchart LR\nA[<script>] --> B", "flowchart LR\nsubgraph X\nA-->B\nend", "flowchart LR\nA -->" }) |body| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "```mermaid\n{s}\n```", .{body});
        defer std.testing.allocator.free(source);
        var doc = try md.init(std.testing.allocator, source);
        defer doc.deinit();
        try equal(md.Kind.code, doc.lines[0].kind);
        try expect(std.mem.startsWith(u8, doc.lines[0].language, "Unsupported Mermaid"));
        try expect(std.mem.startsWith(u8, doc.text, body));
    }
}
test "math delimiters preserve raw TeX and exclude code escapes and prices" {
    var doc = try md.init(std.testing.allocator, fixture);
    defer doc.deinit();
    try equal(@as(usize, 5), doc.formulas.len);
    try expect(std.mem.indexOf(u8, doc.text, "\\frac{-b") != null);
    for (doc.formulas) |formula| try expect(formula.start < formula.end and formula.end <= doc.text.len);
    var literal = try md.init(std.testing.allocator, "`$x^2$` and \\$5 and $5 and $10.\n\n```tex\n$x^2$\n```\n\n\\(x_1\\)\n");
    defer literal.deinit();
    try equal(@as(usize, 1), literal.formulas.len);
    try std.testing.expectEqualStrings("x_1", literal.text[literal.formulas[0].start..literal.formulas[0].end]);
}
test "unsupported malformed and oversized formulas retain their source" {
    for ([_][]const u8{ "\\unknown{x}", "\\frac{x}", "x^{y", "\\begin{matrix}a&b\\end{matrix}" }) |formula| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "$$\n{s}\n$$", .{formula});
        defer std.testing.allocator.free(source);
        var doc = try md.init(std.testing.allocator, source);
        defer doc.deinit();
        try equal(@as(usize, 0), doc.formulas.len);
        try expect(std.mem.indexOf(u8, doc.text, formula) != null);
        try expect(std.mem.startsWith(u8, doc.text, "[Unsupported math]"));
    }
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "$$");
    for (0..30) |_| try source.appendSlice(std.testing.allocator, "\\sqrt{");
    try source.appendSlice(std.testing.allocator, "x");
    for (0..30) |_| try source.append(std.testing.allocator, '}');
    try source.appendSlice(std.testing.allocator, "$$");
    var doc = try md.init(std.testing.allocator, source.items);
    defer doc.deinit();
    try equal(@as(usize, 0), doc.formulas.len);
}
test "extension allocation failures free their complete candidate arena" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(a: std.mem.Allocator) !void {
            var doc = try md.init(a, fixture);
            defer doc.deinit();
        }
    }.run, .{});
}

test "quotes preserve hard breaks and extension truncation remains UTF8" {
    var quote = try md.init(std.testing.allocator, "> first  \n> second\n");
    defer quote.deinit();
    try equal(@as(usize, 2), quote.lines.len);
    try expect(quote.lines[0].hard_break and quote.lines[1].quote_depth == 1);
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    // Display expands unsupported inline math. Trigger the display byte limit
    // immediately before a CJK formula/diagram without splitting its encoding.
    for (0..8000) |_| try source.appendSlice(std.testing.allocator, "$\\unknown{中文中文中文中文中文中文中文中文中文中文中文中文中文中文中文中文中文中文中文中文中文中文中文中文}$\n\n");
    try source.appendSlice(std.testing.allocator, "```mermaid\nflowchart LR\nA[中文] --> B[中文]\n```\n");
    var doc = try md.init(std.testing.allocator, source.items);
    defer doc.deinit();
    try expect(doc.truncated and std.unicode.utf8ValidateSlice(doc.text));
}
