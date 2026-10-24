const std = @import("std");
const md = @import("markdown.zig");
const Model = @import("rich_model.zig").Projection;
const Buffer = @import("text_buffer.zig").Buffer;
const a = std.testing.allocator;
test "rendered edits retain source wrappers link destinations quotes and UTF8" {
    var source = try Buffer.init(a, "# Heading\n\n> Hello **bold** [label](file%20name.md) 中文 é 👩‍💻.\n");
    defer source.deinit(a);
    var parsed = try md.Document.init(a, source.text);
    defer parsed.deinit();
    var model = try Model.init(a, &parsed, &source);
    defer model.deinit();
    var at = std.mem.indexOf(u8, model.rendered.text, "bold").?;
    _ = try model.replace(a, &source, at, at + 4, "醒目");
    try std.testing.expect(std.mem.indexOf(u8, source.text, "**醒目**") != null);
    at = std.mem.indexOf(u8, model.rendered.text, "label").?;
    _ = try model.replace(a, &source, at, at + 5, "new label");
    try std.testing.expect(std.mem.indexOf(u8, source.text, "[new label](file%20name.md)") != null);
    at = std.mem.indexOf(u8, model.rendered.text, "👩‍💻").?;
    _ = try model.replace(a, &source, at, at + "👩‍💻".len, "👨‍💻");
    try std.testing.expect(std.mem.startsWith(u8, source.text, "# Heading\n\n> Hello **醒目**"));
    var again = try md.Document.init(a, source.text);
    defer again.deinit();
    try std.testing.expectEqualStrings(model.rendered.text, again.text);
}
test "rendered deletion across emphasis preserves balanced syntax and literal punctuation" {
    var source = try Buffer.init(a, "before **bold** after and `a*b`.\n");
    defer source.deinit(a);
    var parsed = try md.Document.init(a, source.text);
    defer parsed.deinit();
    var model = try Model.init(a, &parsed, &source);
    defer model.deinit();
    const from = std.mem.indexOf(u8, model.rendered.text, "old").?;
    const to = std.mem.indexOf(u8, model.rendered.text, "after").? + 2;
    _ = try model.replace(a, &source, from, to, "*");
    try std.testing.expectEqualStrings("before **b\\***ter and `a*b`.\n", source.text);
    var again = try md.Document.init(a, source.text);
    defer again.deinit();
    try std.testing.expectEqualStrings(model.rendered.text, again.text);
    const escaped = std.mem.indexOfScalar(u8, model.rendered.text, '*').?;
    _ = try model.replace(a, &source, escaped, escaped + 1, "");
    try std.testing.expect(std.mem.indexOf(u8, source.text, "\\") == null);
}
test "rendered empty wrappers are removed and resource selections reject transactionally" {
    var source = try Buffer.init(a, "**erase**\n\nInline $x^2$ preserved.\n\n| A | B |\n|---|---|\n| one | two |\n");
    defer source.deinit(a);
    var parsed = try md.Document.init(a, source.text);
    defer parsed.deinit();
    var model = try Model.init(a, &parsed, &source);
    defer model.deinit();
    _ = try model.replace(a, &source, 0, 5, "");
    try std.testing.expect(std.mem.startsWith(u8, source.text, "\n\nInline"));
    const revision = source.revision;
    const at = std.mem.indexOf(u8, model.rendered.text, "x^2").?;
    try std.testing.expectError(error.EditResourceInSource, model.replace(a, &source, at + 1, at + 1, "y"));
    try std.testing.expectError(error.EditResourceInSource, model.replace(a, &source, at, at + 1, "y"));
    try std.testing.expectEqual(revision, source.revision);
    const cell = std.mem.indexOf(u8, model.rendered.text, "one").?;
    _ = try model.replace(a, &source, cell, cell + 3, "first");
    try std.testing.expect(std.mem.indexOf(u8, source.text, "| first | two |") != null);
}
test "empty rendered list items accept typing after Enter without changing their marker" {
    var source = try Buffer.init(a, "- item\n");
    defer source.deinit(a);
    var parsed = try md.Document.init(a, source.text);
    defer parsed.deinit();
    var model = try Model.init(a, &parsed, &source);
    defer model.deinit();
    const at = std.mem.indexOf(u8, model.rendered.text, "item").? + 4;
    _ = try model.replace(a, &source, at, at, "\n");
    var refreshed = try Model.fromSource(a, &source);
    defer refreshed.deinit();
    const next_row = refreshed.markdown.lines[1];
    _ = try refreshed.replace(a, &source, next_row.end, next_row.end, "next");
    try std.testing.expectEqualStrings("- item\n- next\n", source.text);
}
test "rendered paragraph breaks retain heading quote list and wrapper structure" {
    for ([_][]const u8{ "# A title\n", "> A **bold** word\n", "- A list item\n", "- [x] A task\n", "A paragraph\n" }) |initial| {
        var source = try Buffer.init(a, initial);
        defer source.deinit(a);
        var parsed = try md.Document.init(a, source.text);
        defer parsed.deinit();
        var model = try Model.init(a, &parsed, &source);
        defer model.deinit();
        const at = std.mem.indexOf(u8, model.rendered.text, "A ").? + 1;
        const after = try model.replace(a, &source, at, at, "\n");
        _ = try model.replace(a, &source, after, after, "new");
        var again = try md.Document.init(a, source.text);
        defer again.deinit();
        try std.testing.expectEqualStrings(model.rendered.text, again.text);
    }
}
fn allocationCase(allocator: std.mem.Allocator) !void {
    const initial = "# Heading\n\nA **bold** and [link](file.md).\n";
    var source = try Buffer.init(allocator, initial);
    defer source.deinit(allocator);
    var parsed = try md.Document.init(allocator, source.text);
    defer parsed.deinit();
    var model = try Model.init(allocator, &parsed, &source);
    defer model.deinit();
    const at = std.mem.indexOf(u8, model.rendered.text, "bold").?;
    errdefer std.debug.assert(std.mem.eql(u8, source.text, initial));
    _ = try model.replace(allocator, &source, at, at + 4, "changed");
    try std.testing.expect(std.mem.indexOf(u8, source.text, "**changed**") != null);
}
test "rendered edits publish source and projection transactionally on allocation failure" {
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{});
}
fn refresh(model: *Model, source: *const Buffer) !void {
    const rebuilt = try Model.fromSource(a, source);
    model.deinit();
    model.* = rebuilt;
}
test "spaces at formatting boundaries remain editable after asynchronous-style reconciliation" {
    for ([_][]const u8{ "word\n", "**word**\n", "*word*\n", "~~word~~\n" }) |initial| {
        var source = try Buffer.init(a, initial);
        defer source.deinit(a);
        var parsed = try md.Document.init(a, source.text);
        defer parsed.deinit();
        var model = try Model.init(a, &parsed, &source);
        defer model.deinit();
        _ = try model.replace(a, &source, 4, 4, " ");
        try refresh(&model, &source);
        try std.testing.expectEqualStrings("word \n", model.rendered.text);
        const caret = model.displayAtSource(source.caret, source.text);
        _ = try model.replace(a, &source, caret, caret, "tail");
        try refresh(&model, &source);
        try std.testing.expectEqualStrings("word tail\n", model.rendered.text);
        const prefix = initial[0 .. initial.len - 1];
        const expected = try std.fmt.allocPrint(a, "{s} tail\n", .{prefix});
        defer a.free(expected);
        try std.testing.expectEqualStrings(expected, source.text);
    }
}
test "replacement whitespace moves outside emphasis and empty formatting disappears" {
    for ([_][]const u8{ " a ", " ", " a", "a " }) |value| {
        var source = try Buffer.init(a, "**word**\n");
        defer source.deinit(a);
        var parsed = try md.Document.init(a, source.text);
        defer parsed.deinit();
        var model = try Model.init(a, &parsed, &source);
        defer model.deinit();
        _ = try model.replace(a, &source, 0, 4, value);
        try refresh(&model, &source);
        const expected = try std.mem.concat(a, u8, &.{ value, "\n" });
        defer a.free(expected);
        try std.testing.expectEqualStrings(expected, model.rendered.text);
        if (std.mem.trim(u8, value, " ").len == 0) try std.testing.expect(std.mem.indexOf(u8, source.text, "**") == null);
    }
}
test "Enter next to formatted text preserves the span and partial span splitting is explicit" {
    var source = try Buffer.init(a, "**word**\n");
    defer source.deinit(a);
    var parsed = try md.Document.init(a, source.text);
    defer parsed.deinit();
    var model = try Model.init(a, &parsed, &source);
    defer model.deinit();
    try std.testing.expectError(error.EditFormattedBreakInSource, model.replace(a, &source, 2, 2, "\n"));
    _ = try model.replace(a, &source, 4, 4, "\n");
    try std.testing.expect(std.mem.startsWith(u8, source.text, "**word**\n\n"));
    try refresh(&model, &source);
    const caret = model.displayAtSource(source.caret, source.text);
    _ = try model.replace(a, &source, caret, caret, "next");
    try std.testing.expect(std.mem.indexOf(u8, source.text, "**word**\n\nnext") != null);
}
