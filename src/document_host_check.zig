//! Fresh checks for the migrated document module, without the old application.
const std = @import("std");
const docs = @import("document_host.zig");
const ui = @import("nanoui").ui;
comptime {
    _ = @import("runtime/document/markdown_check.zig");
    _ = @import("runtime/document/markdown_extension_check.zig");
    _ = docs.path;
    _ = docs.terminal_paths;
    _ = docs.path_token;
    _ = docs.read_only_text;
}
// Force current nanoui view/editor APIs through semantic analysis, even in a
// pure test runner. Integrated hidden-window checks exercise actual painting.
export fn documentViewCompile(document: *docs.Document, ctx: *ui.Context) void {
    _ = document.draw(ctx, .{ .w = 600, .h = 800 });
}
export fn documentTabsCompile(collection: *docs.Collection, ctx: *ui.Context) void {
    _ = collection.draw(ctx, .{ .w = 600, .h = 800 });
}
test "dynamic documents use independent ownership and refuse dirty close" {
    const a = std.testing.allocator;
    var collection: docs.Collection = .{};
    defer collection.deinit(a);
    const doc = try collection.open(a, 17, "/private/nonexistent/letty-document-check.md", .{});
    const duplicate = try collection.open(a, 18, "/private/nonexistent/letty-document-check.md", .{});
    try std.testing.expectEqual(doc, duplicate);
    try std.testing.expectEqual(@as(usize, 1), collection.documents.items.len);
    try std.testing.expectEqual(@as(u64, 17), collection.active);
    doc.panel.edit_busy = true;
    try std.testing.expectError(error.UnsavedDocumentChooseSaveOrDiscard, collection.close(17));
    try std.testing.expect(collection.get(17) != null);
    doc.panel.edit_busy = false;
    try collection.close(17);
    try std.testing.expect(collection.selected() == null and !collection.visible);
}
test "new Markdown panel retains source math mermaid table and grapheme copy" {
    const a = std.testing.allocator;
    var p: docs.panel.Panel = .{};
    defer p.deinit(a);
    const source = "# Local report\n\n你好 é 👩‍💻 **native** $\\frac{1}{2}$\n\n| A | B |\n|---|---|\n| one | two |\n\n```mermaid\nflowchart LR\nA[Open] --> B{Read}\n```\n";
    p.apply(try docs.panel.Prepared.init(a, .markdown, source), 1);
    try std.testing.expect(p.prepared.?.markdown != null);
    const md = &p.prepared.?.markdown.?;
    var diagram = false;
    var table = false;
    for (md.lines) |line| {
        diagram = diagram or line.diagram != null;
        table = table or line.kind == .table;
    }
    try std.testing.expect(diagram and table and md.formulas.len > 0);
    p.mode = .source;
    const text = p.document().?;
    try std.testing.expectEqualStrings(source, text.text);
    const emoji = std.mem.indexOf(u8, text.text, "👩‍💻").?;
    try std.testing.expectEqual(emoji + "👩‍💻".len, text.next(emoji));
    p.query.set("native");
    p.updateSearch();
    try std.testing.expectEqual(@as(usize, 1), p.match_count);
    try std.testing.expectEqualStrings("native", p.selection.selected(text));
}
test "moving documents preserves stable identity reading state and generation" {
    const a = std.testing.allocator;
    var side: docs.Collection = .{};
    defer side.deinit(a);
    var workspace: docs.Collection = .{};
    defer workspace.deinit(a);
    const document = try side.open(a, 31, "/private/nonexistent/document-move.md", .{});
    document.panel.scroll_y = 123;
    document.panel.zoom = 1.4;
    const generation = document.panel.model.generation;
    try side.moveTo(a, &workspace, 31);
    try std.testing.expect(side.selected() == null and !side.visible);
    try std.testing.expectEqual(document, workspace.selected().?);
    try std.testing.expectEqual(generation, document.panel.model.generation);
    try std.testing.expectEqual(@as(f32, 123), document.panel.scroll_y);
    try std.testing.expectEqual(@as(f32, 1.4), document.panel.zoom);
}
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn rmdir([*:0]const u8) c_int;
extern "c" fn unlink([*:0]const u8) c_int;
extern "c" fn usleep(c_uint) c_int;
extern "c" fn realpath([*:0]const u8, [*]u8) ?[*:0]u8;
extern "c" fn lt_config_no_xattr_fixture([*:0]const u8, c_int) c_int;
extern "c" fn lt_config_fixture_write([*:0]const u8, [*]const u8, usize, c_uint) c_int;
fn settle(doc: *docs.Document, editing: bool) !void {
    for (0..500) |_| {
        try doc.drain();
        if (if (editing) doc.job == null else doc.panel.model.status != .loading) return;
        _ = usleep(10000);
    }
    return error.DocumentFixtureTimeout;
}
fn settleDraft(doc: *docs.Document) !void {
    for (0..500) |_| {
        try doc.drain();
        if (doc.draft_job == null) return;
        _ = usleep(10000);
    }
    return error.DraftFixtureTimeout;
}
test "migrated worker refresh save conflict and dirty close use private files" {
    const a = std.testing.allocator;
    var template: [64:0]u8 = @splat(0);
    const name = "/tmp/letty-document-current-XXXXXX";
    @memcpy(template[0..name.len], name);
    const temp = mkdtemp(&template) orelse return error.PrivateFixture;
    defer _ = rmdir(temp);
    var physical: [4096]u8 = undefined;
    const root = realpath(temp, &physical) orelse return error.PhysicalFixture;
    // Simulates NFS-style ENOTSUP only inside this owned 0700 directory.
    try std.testing.expectEqual(@as(c_int, 0), lt_config_no_xattr_fixture(root, 1));
    defer _ = lt_config_no_xattr_fixture(root, 0);
    const file = try std.fmt.allocPrintSentinel(a, "{s}/report.md", .{std.mem.span(root)}, 0);
    defer a.free(file);
    defer _ = unlink(file);
    const initial = "# Initial\r\n\r\n你好\r\n";
    try std.testing.expectEqual(@as(c_int, 0), lt_config_fixture_write(file, initial, initial.len, 0o640));
    var collection: docs.Collection = .{};
    defer collection.deinit(a);
    const doc = try collection.open(a, 29, file, .{});
    doc.panel.inline_edit = false; // Explicit source-editor lifecycle fixture.
    try settle(doc, false);
    try std.testing.expectEqual(docs.loader.Status.ready, doc.panel.model.status);
    try std.testing.expect(doc.panel.prepared.?.markdown != null);
    doc.panel.edit_request = .unlock;
    try doc.edit();
    try settle(doc, true);
    const editor = doc.panel.editor orelse return error.EditDidNotUnlock;
    try std.testing.expect(editor.crlf);
    try editor.buffer.replace(std.heap.page_allocator, 0, editor.buffer.text.len, "# Edited\n");
    editor.update();
    try std.testing.expectError(error.UnsavedDocumentChooseSaveOrDiscard, collection.close(doc.id));
    const external = "# External\n";
    try std.testing.expectEqual(@as(c_int, 0), lt_config_fixture_write(file, external, external.len, 0o640));
    doc.panel.edit_request = .save;
    try doc.edit();
    try settle(doc, true);
    try std.testing.expect(doc.panel.editor != null and doc.hasUnsaved());
    try std.testing.expectEqualStrings("# Edited\n", doc.panel.editor.?.buffer.text);
    try std.testing.expect(doc.panel.notice.len > 0);
    doc.panel.edit_request = .discard;
    try doc.edit();
    try settle(doc, false);
    try std.testing.expectEqualStrings(external, doc.panel.prepared.?.source.text);
    doc.panel.edit_request = .unlock;
    try doc.edit();
    try settle(doc, true);
    try doc.panel.editor.?.buffer.replace(std.heap.page_allocator, 0, doc.panel.editor.?.buffer.text.len, "# Saved\n");
    doc.panel.editor.?.update();
    try doc.startDraft();
    const draft_editor = doc.panel.editor.?;
    try draft_editor.buffer.insert(std.heap.page_allocator, "new ");
    draft_editor.update();
    try settleDraft(doc);
    try std.testing.expect(doc.draft_revision == null);
    try doc.startDraft();
    try settleDraft(doc);
    try std.testing.expectEqual(draft_editor.buffer.revision, doc.draft_revision.?);
    try std.testing.expectEqualStrings(draft_editor.buffer.text, doc.panel.prepared.?.source.text);
    const committed = try a.dupe(u8, doc.panel.prepared.?.source.text);
    defer a.free(committed);
    try draft_editor.composition.set(std.heap.page_allocator, &draft_editor.buffer, "预编辑", 3, 0);
    try doc.startDraft();
    try std.testing.expect(doc.draft_job == null);
    try std.testing.expectEqualStrings(committed, doc.panel.prepared.?.source.text);
    draft_editor.composition.clear(std.heap.page_allocator);
    doc.panel.edit_request = .save;
    try doc.edit();
    try settle(doc, true);
    try settle(doc, false);
    try std.testing.expect(doc.panel.editor != null and !doc.hasUnsaved());
    const kept_editor = doc.panel.editor.?;
    const undo_count = kept_editor.buffer.undo.items.len;
    const caret = kept_editor.buffer.caret;
    // A save snapshots the submitted bytes, while later input remains dirty.
    try kept_editor.buffer.insert(std.heap.page_allocator, "next ");
    kept_editor.update();
    doc.panel.edit_request = .save;
    try doc.edit();
    const submitted = try a.dupe(u8, kept_editor.buffer.text);
    defer a.free(submitted);
    try kept_editor.buffer.insert(std.heap.page_allocator, "during save");
    kept_editor.update();
    try settle(doc, true);
    try std.testing.expectEqual(kept_editor, doc.panel.editor.?);
    try std.testing.expect(doc.hasUnsaved());
    try std.testing.expectEqualStrings(submitted, kept_editor.baseline);
    try std.testing.expect(kept_editor.buffer.undo.items.len > undo_count);
    try std.testing.expect(kept_editor.buffer.caret > caret);
    doc.panel.edit_request = .save;
    try doc.edit();
    try settle(doc, true);
    try std.testing.expect(!doc.hasUnsaved());
    const expected = try a.dupe(u8, kept_editor.buffer.text);
    defer a.free(expected);
    // Clean locking ends edit mode explicitly; saves themselves never do.
    doc.panel.edit_request = .unlock;
    try doc.edit();
    try settle(doc, false);
    try std.testing.expect(doc.panel.editor == null);
    try std.testing.expectEqualStrings(expected, doc.panel.prepared.?.source.text);
    const revision = doc.panel.model.revision;
    try std.testing.expectEqual(@as(c_int, 0), unlink(file));
    try doc.refresh();
    try settle(doc, false);
    try std.testing.expect(doc.panel.model.stale and doc.panel.model.revision == revision);
    try std.testing.expectEqualStrings(expected, doc.panel.prepared.?.source.text);
}

test "automatic Markdown saves coalesce cancel preedit and retain conflicted drafts" {
    const a = std.testing.allocator;
    var template: [64:0]u8 = @splat(0);
    const name = "/tmp/letty-document-autosave-XXXXXX";
    @memcpy(template[0..name.len], name);
    const temp = mkdtemp(&template) orelse return error.PrivateFixture;
    defer _ = rmdir(temp);
    var physical: [4096]u8 = undefined;
    const root = realpath(temp, &physical) orelse return error.PhysicalFixture;
    const file = try std.fmt.allocPrintSentinel(a, "{s}/note.md", .{std.mem.span(root)}, 0);
    defer a.free(file);
    defer _ = unlink(file);
    const initial = "# Automatic\r\n";
    try std.testing.expectEqual(@as(c_int, 0), lt_config_fixture_write(file, initial, initial.len, 0o640));
    var collection: docs.Collection = .{};
    defer collection.deinit(a);
    const doc = try collection.open(a, 37, file, .{});
    try settle(doc, false);
    try settle(doc, true);
    const editor = doc.panel.editor.?;
    try editor.buffer.insert(std.heap.page_allocator, "first ");
    editor.update();
    try doc.noteAutosave();
    try std.testing.expect(doc.autosave_timer != null);
    try std.testing.expectEqual(editor.buffer.revision, doc.autosave_revision.?);
    try editor.buffer.insert(std.heap.page_allocator, "second ");
    editor.update();
    try doc.noteAutosave();
    try std.testing.expectEqual(editor.buffer.revision, doc.autosave_revision.?);
    try editor.composition.set(std.heap.page_allocator, &editor.buffer, "候选", 0, 0);
    try doc.noteAutosave();
    try doc.flushAutosave();
    try std.testing.expect(doc.autosave_timer == null and doc.job == null);
    try std.testing.expectEqualStrings(initial, editor.original.bytes);
    editor.composition.clear(std.heap.page_allocator);
    editor.update();
    try doc.noteAutosave();
    doc.stopPresentation();
    try std.testing.expect(doc.autosave_timer != null);
    try doc.flushAutosave();
    const submitted = try a.dupe(u8, editor.buffer.text);
    defer a.free(submitted);
    try editor.buffer.insert(std.heap.page_allocator, "during ");
    editor.update();
    try settle(doc, true);
    try std.testing.expectEqualStrings(submitted, editor.baseline);
    try std.testing.expect(editor.dirty and doc.autosave_timer != null);
    try doc.flushAutosave();
    try settle(doc, true);
    try std.testing.expect(!editor.dirty and doc.autosave_timer == null and editor.crlf);
    const disk = @import("config_edit.zig");
    var saved = try disk.Native.capture(a, file);
    defer saved.deinit();
    const encoded = try editor.encoded();
    defer std.heap.page_allocator.free(encoded);
    try std.testing.expectEqualStrings(encoded, saved.bytes);
    try editor.buffer.insert(std.heap.page_allocator, "conflict ");
    editor.update();
    const external = "# External\r\n";
    try std.testing.expectEqual(@as(c_int, 0), lt_config_fixture_write(file, external, external.len, 0o640));
    try doc.flushAutosave();
    try settle(doc, true);
    try std.testing.expect(doc.edit_failed and doc.panel.external_changed and editor.dirty);
    try editor.buffer.insert(std.heap.page_allocator, "kept ");
    editor.update();
    try doc.noteAutosave();
    try std.testing.expect(doc.autosave_timer == null and doc.job == null);
    var latest = try disk.Native.capture(a, file);
    defer latest.deinit();
    try std.testing.expectEqualStrings(external, latest.bytes);
    doc.discardDraft();
    try std.testing.expect(doc.autosave_timer == null and doc.panel.editor == null);
}
