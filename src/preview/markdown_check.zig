//! Actual parser fixtures over owned native IR. No web renderer, OS or files.
const std = @import("std");
const md = @import("markdown.zig");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const strings = std.testing.expectEqualStrings;
fn hasStyle(doc: *const md.Document, text: []const u8, flags: u8) bool {
    for (doc.spans) |span| if (span.flags & flags == flags and std.mem.indexOf(u8, doc.text[span.start..span.end], text) != null) return true;
    return false;
}
fn valid(doc: *const md.Document) !void {
    try expect(std.unicode.utf8ValidateSlice(doc.text));
    for (doc.lines) |line| {
        try expect(line.start <= line.end and line.end <= doc.text.len);
        try expect(std.unicode.utf8ValidateSlice(doc.text[line.start..line.end]));
        for (line.cells) |cell| {
            try expect(cell.start >= line.start and cell.end <= line.end and cell.start <= cell.end);
            try expect(std.unicode.utf8ValidateSlice(doc.text[cell.start..cell.end]));
        }
    }
    for (doc.spans) |span| {
        try expect(span.start < span.end and span.end <= doc.text.len);
        try expect(std.unicode.utf8ValidateSlice(doc.text[span.start..span.end]));
    }
    for (doc.links) |link| {
        try expect(link.start <= link.end and link.end <= doc.text.len and link.line < doc.lines.len);
        try expect(std.unicode.utf8ValidateSlice(link.target));
    }
    for (doc.anchors) |anchor| try expect(anchor.line < doc.lines.len and std.unicode.utf8ValidateSlice(anchor.slug));
}
test "Markdown headings setext and unique native anchor ranges" {
    var doc = try md.init(std.testing.allocator, "# Hello 世界\n\nHello 世界\n=====\n\n## Hello 世界\n### *Nested* ###");
    defer doc.deinit();
    try valid(&doc);
    try equal(@as(usize, 4), doc.anchors.len);
    try strings("hello-世界", doc.anchors[0].slug);
    try strings("hello-世界-1", doc.anchors[1].slug);
    try strings("hello-世界-2", doc.anchors[2].slug);
    try strings("nested", doc.anchors[3].slug);
    try equal(md.Kind.heading, doc.lines[doc.anchors[1].line].kind);
    try equal(@as(u8, 1), doc.lines[doc.anchors[1].line].level);
    try strings("Nested", doc.text[doc.anchors[3].start..doc.anchors[3].end]);
}
test "Markdown nested emphasis strong strike and code retain disjoint style flags" {
    var doc = try md.init(std.testing.allocator, "*one **two** three* and **bold *inner* end** ~~gone~~ `**literal**` ***both*** \\*visible\\* snake_case");
    defer doc.deinit();
    try valid(&doc);
    try expect(std.mem.indexOf(u8, doc.text, "one two three and bold inner end gone **literal** both *visible* snake_case") != null);
    try expect(hasStyle(&doc, "two", md.emphasis | md.strong));
    try expect(hasStyle(&doc, "inner", md.emphasis | md.strong));
    try expect(hasStyle(&doc, "gone", md.strike));
    try expect(hasStyle(&doc, "**literal**", md.code));
    try expect(hasStyle(&doc, "both", md.emphasis | md.strong));
}
test "Markdown fenced and indented code preserve whitespace language and inert markup" {
    var doc = try md.init(std.testing.allocator, "```zig\n  const x = `**`;\t\n\tkeep  \n```\n\n    indented *code*\n~~~text\nunclosed <script>\n");
    defer doc.deinit();
    try valid(&doc);
    try equal(md.Kind.code, doc.lines[0].kind);
    try strings("zig", doc.lines[0].language);
    try strings("  const x = `**`;\t", doc.text[doc.lines[0].start..doc.lines[0].end]);
    try strings("\tkeep  ", doc.text[doc.lines[1].start..doc.lines[1].end]);
    try expect(std.mem.indexOf(u8, doc.text, "indented *code*") != null);
    try expect(std.mem.indexOf(u8, doc.text, "unclosed <script>") != null);
    try equal(@as(usize, 0), doc.links.len);
    var escaped = try md.init(std.testing.allocator, "\\``` literal fence\n\n````zig\n```\n**still code**\n````\n");
    defer escaped.deinit();
    try valid(&escaped);
    try equal(md.Kind.paragraph, escaped.lines[0].kind);
    try strings("``` literal fence", escaped.text[escaped.lines[0].start..escaped.lines[0].end]);
    try equal(md.Kind.code, escaped.lines[2].kind);
    try strings("```", escaped.text[escaped.lines[2].start..escaped.lines[2].end]);
    try strings("**still code**", escaped.text[escaped.lines[3].start..escaped.lines[3].end]);
}
test "Markdown quote lists ordered task and nested list use owned display prefixes" {
    var doc = try md.init(std.testing.allocator, "> > **quote**\n- item\n  - nested\n    - deep\n7. ordered\n- [x] done\n- [ ] pending\n\n---\n");
    defer doc.deinit();
    try valid(&doc);
    try equal(md.Kind.quote, doc.lines[0].kind);
    try equal(@as(u8, 2), doc.lines[0].level);
    try equal(md.Kind.list, doc.lines[3].kind);
    try equal(@as(u8, 2), doc.lines[3].level);
    try expect(doc.lines[4].ordered and doc.lines[4].ordinal == 7);
    try equal(@as(?bool, true), doc.lines[5].task);
    try equal(@as(?bool, false), doc.lines[6].task);
    try equal(md.Kind.rule, doc.lines[8].kind);
    try expect(std.mem.indexOf(u8, doc.text, "☑ done") != null);
}
test "GFM table rows keep code escaped pipes headers and semantic cell ranges" {
    var doc = try md.init(std.testing.allocator, "| Name | Value |\n| :--- | ---: |\n| **世界** | `a|b` |\n| x\\|y | ``code|pipe`` |\n| [文档](docs/%E4%B8%AD.md#标题) | [x](https://e.test/a\\(b\\)?q=1%202) |\n");
    defer doc.deinit();
    try valid(&doc);
    try equal(@as(usize, 4), doc.lines.len);
    for (doc.lines) |line| try equal(md.Kind.table, line.kind);
    try expect(doc.lines[0].table_header and !doc.lines[1].table_header);
    try expect(std.mem.indexOf(u8, doc.text, "a|b") != null and std.mem.indexOf(u8, doc.text, "x|y") != null);
    try expect(hasStyle(&doc, "code|pipe", md.code));
    try equal(@as(usize, 2), doc.links.len);
    try strings("docs/%E4%B8%AD.md#标题", doc.links[0].target);
    try strings("https://e.test/a(b)?q=1%202", doc.links[1].target);
    try expect(doc.links[0].safe and doc.links[1].safe and doc.links[0].line == 3);
    // Source destinations are long; columns are sized to visible labels, not
    // the hidden URL/escape syntax. This prevents a tiny table spanning screens.
    for (doc.lines) |line| try expect(line.end - line.start < 64);
    for (doc.lines) |line| {
        try equal(@as(usize, 2), line.cells.len);
        try equal(md.Alignment.left, line.cells[0].alignment);
        try equal(md.Alignment.right, line.cells[1].alignment);
        try strings("\t", doc.text[line.cells[0].end..line.cells[1].start]);
    }
}
test "Markdown links images and raw HTML never execute or fetch resources" {
    var doc = try md.init(std.testing.allocator, "[**safe**](https://example.com/a_(b)) [bad](javascript:alert(1)) [relative](guide.md#part)\n\n![图](assets/a.png)\n\n<script>alert('x')</script> <b>literal</b>\n\n<https://example.com> https://example.com/end.");
    defer doc.deinit();
    try valid(&doc);
    try equal(@as(usize, 6), doc.links.len);
    try strings("https://example.com/a_(b)", doc.links[0].target);
    try expect(doc.links[0].safe and !doc.links[1].safe and doc.links[2].safe);
    try expect(doc.links[3].image and !doc.links[3].safe);
    try expect(std.mem.indexOf(u8, doc.text, "[Image: 图 — assets/a.png]") != null);
    try expect(std.mem.indexOf(u8, doc.text, "<script>alert('x')</script> <b>literal</b>") != null);
    try strings("https://example.com/end", doc.links[5].target);
    try expect(hasStyle(&doc, "safe", md.strong | md.link));
}
test "Markdown soft and hard breaks CRLF BOM and UTF8 keep stable display offsets" {
    var doc = try md.init(std.testing.allocator, "\xef\xbb\xbf# 标题\r\n\r\none\r\ntwo  \r\nthree\\\r\nfour 中👩‍💻\r\n");
    defer doc.deinit();
    try valid(&doc);
    try equal(md.Kind.heading, doc.lines[0].kind);
    try strings("标题\n\none two\nthree\nfour 中👩‍💻\n", doc.text);
    try expect(doc.lines[2].hard_break and doc.lines[3].hard_break);
}
test "Markdown unmatched delimiters stay literal and escaped backslashes do not hard-break" {
    var doc = try md.init(std.testing.allocator, "[unclosed * text\nnext **\n\ncode ` never closes\n\nbackslash\\\\\njoined");
    defer doc.deinit();
    try valid(&doc);
    try expect(std.mem.indexOf(u8, doc.text, "[unclosed * text next **") != null);
    try expect(std.mem.indexOf(u8, doc.text, "code ` never closes") != null);
    try expect(std.mem.indexOf(u8, doc.text, "backslash\\ joined") != null);
}
test "Markdown link eligibility rejects dangerous schemes authorities traversal and control bytes" {
    for ([_][]const u8{ "javascript:x", "data:text/html,x", "file:///etc/passwd", "//example.com", "../secret", "x/../../y", "https://ex\nample.com", "c:\\path", "", "javascript%3Aalert(1)", "%2f%2fhost/x", "%2e%2e/secret", "x/%00y", "x/%5cy", "mailto:user@example.com" }) |target| try expect(!md.safeTarget(target));
    for ([_][]const u8{ "HTTPS://example.com", "https://example.com/a", "http://example.com", "guide.md", "docs/guide.md#x", "#标题", "docs/%E4%B8%AD%20文.md" }) |target| try expect(md.safeTarget(target));
}
test "Markdown source line and inline work limits are explicit and preserve valid IR" {
    const source = try std.testing.allocator.alloc(u8, md.max_source + 16);
    defer std.testing.allocator.free(source);
    @memset(source, 'x');
    var large = try md.init(std.testing.allocator, source);
    defer large.deinit();
    try expect(large.truncated and large.text.len <= md.max_text);
    try valid(&large);
    @memset(source, '\n');
    var lines = try md.init(std.testing.allocator, source[0 .. md.max_lines + 10]);
    defer lines.deinit();
    try expect(lines.truncated and lines.lines.len == md.max_lines);
    try valid(&lines);
    // A repeated malformed link makes a naive repeated suffix search quadratic.
    for (0..source.len / 6) |i| @memcpy(source[i * 6 ..][0..6], "[a](x ");
    var hostile = try md.init(std.testing.allocator, source);
    defer hostile.deinit();
    try expect(hostile.text.len <= md.max_text and hostile.spans.len <= md.max_spans and hostile.links.len <= md.max_links);
    try valid(&hostile);
}
test "Markdown allocation failures free the complete candidate arena" {
    for (0..20) |index| {
        var failure = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = index });
        if (md.init(failure.allocator(), "# Hello\n\n*body* [link](https://example.com)\n\n| A | B |\n| --- | --- |\n| x | y |")) |result| {
            var doc = result;
            doc.deinit();
        } else |err| try equal(error.OutOfMemory, err);
        try equal(failure.allocated_bytes, failure.freed_bytes);
    }
}

test "GFM tables accept short delimiters optional outer pipes and ragged body rows" {
    var doc = try md.init(std.testing.allocator, "Left | Center | Right\n:-|:-:|-:\none | two\nthree\nfour | five | six | ignored\n\n# After\n");
    defer doc.deinit();
    try valid(&doc);
    try strings("Left\tCenter\tRight\none\ttwo\t\nthree\t\t\nfour\tfive\tsix\n\nAfter\n", doc.text);
    try equal(md.Alignment.center, doc.lines[0].cells[1].alignment);
    try equal(md.Alignment.right, doc.lines[0].cells[2].alignment);
    try equal(md.Kind.heading, doc.lines[5].kind);
    for ([_][]const u8{ "a | b\n| --- |\n", "a | b\n| ::--- | --- |\n", "a | b\n| --- | --- | --- |\n", "a | b\n| --- || --- |\n" }) |source| {
        var invalid = try md.init(std.testing.allocator, source);
        defer invalid.deinit();
        for (invalid.lines) |line| try expect(line.kind != .table);
    }
}
test "GFM table cell budget is explicit and columns are not silently capped at 32" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    for (0..40) |_| try source.appendSlice(std.testing.allocator, "| H ");
    try source.appendSlice(std.testing.allocator, "|\n");
    for (0..40) |_| try source.appendSlice(std.testing.allocator, "| - ");
    try source.appendSlice(std.testing.allocator, "|\n");
    for (0..900) |_| try source.appendSlice(std.testing.allocator, "| body |\n");
    var doc = try md.init(std.testing.allocator, source.items);
    defer doc.deinit();
    try valid(&doc);
    try expect(doc.truncated);
    try equal(@as(usize, 40), doc.lines[0].cells.len);
    var total: usize = 0;
    for (doc.lines) |line| total += line.cells.len;
    try expect(total <= md.max_cells);
}

test {
    _ = @import("markdown_extension_check.zig");
}
