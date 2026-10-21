//! Offscreen fixtures: immutable documents, private clipboard and temporary files.
const std = @import("std");
const temporary_root = if (@import("builtin").os.tag == .macos) "/private/tmp" else "/tmp";
const ui = @import("nanoui").ui;
const panel = @import("panel.zig");
const text = @import("read_only_text.zig");
const model = @import("model.zig");
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn usleep(c_uint) c_int;
extern "c" fn lt_config_fixture_write([*:0]const u8, [*]const u8, usize, c_uint) c_int;
extern "c" fn symlink([*:0]const u8, [*:0]const u8) c_int;
var count: usize = 0;
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} preview {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.PreviewCheckFailed;
    count += 1;
}
fn write(path: [:0]const u8, bytes: []const u8) !void {
    if (lt_config_fixture_write(path, bytes.ptr, bytes.len, 0o600) != 0) return error.FixtureWrite;
}
const View = struct {
    panel: *panel.Panel,
    intent: panel.Intent = .none,
    fn draw(self: *View, ctx: *ui.Context) void {
        const rect: ui.Rect = .{ .w = ctx.size.w, .h = ctx.size.h };
        _ = self.panel.prepareInput(ctx, rect);
        self.intent = self.panel.draw(ctx, rect);
    }
};
pub fn clickControl(p: *panel.Panel, t: *ui.Tester, control: panel.Control) !void {
    for (p.ax_controls[0..p.ax_count]) |item| if (item.control == control) {
        const rect = t.ctx.rects.get(item.widget) orelse return error.PreviewMissingControl;
        t.click(rect.x + rect.w / 2, rect.y + rect.h / 2);
        return;
    };
    return error.PreviewMissingControl;
}
fn fixture(p: *panel.Panel, gpa: std.mem.Allocator, kind: model.Kind, bytes: []const u8) !void {
    p.model.kind = kind;
    p.model.status = .ready;
    p.model.revision += 1;
    p.opened = true;
    p.focused = true;
    p.mode = if (kind == .markdown) .rendered else .source;
    p.apply(try panel.Prepared.init(gpa, kind, bytes), p.model.revision);
}
fn loaded(s: *model.State, gpa: std.mem.Allocator) !void {
    for (0..1000) |_| {
        _ = try s.drain(gpa);
        if (s.status != .loading) return;
        _ = usleep(1000);
    }
    return error.PreviewLoadTimeout;
}
pub fn run(init: std.process.Init) !void {
    _ = init;
    const a = std.heap.page_allocator;
    var doc = try text.Document.init(a, "# title\n中👩‍💻é\ncode\n");
    defer doc.deinit();
    var selection: text.Selection = .{};
    selection.place(&doc, 11, false);
    selection.move(&doc, .right, true);
    try check(std.mem.eql(u8, selection.selected(&doc), "👩‍💻"), "ZWJ emoji selected as one grapheme");
    selection.move(&doc, .right, true);
    try check(std.mem.eql(u8, selection.selected(&doc), "👩‍💻é"), "combining mark remains attached");
    selection.all(&doc);
    try check(std.mem.eql(u8, selection.selected(&doc), doc.text) and doc.lines.len == 4, "selection spans block newlines with absolute offsets");
    var matches: [4]text.Match = undefined;
    try check(doc.find("e", &matches) == 2 and doc.find("é", &matches) == 1, "find excludes partial composed graphemes");
    _ = text.Document.init(a, "\xff") catch |err| {
        try check(err == error.InvalidUtf8, "invalid UTF-8 never reaches shaping");
    };
    const long_line = try a.alloc(u8, text.max_line_bytes + 1);
    defer a.free(long_line);
    @memset(long_line, 'x');
    _ = text.Document.init(a, long_line) catch |err| {
        try check(err == error.PreviewLongLineLimit, "oversized line is rejected before unbounded glyph shaping");
    };
    var p: panel.Panel = .{};
    defer p.deinit(a);
    const markdown = "# Preview 中文\n\nA **strong** and *emphasis* paragraph with 中👩‍💻é.\n\n> quoted text\n\n- task one\n- task two\n\n```zig\nconst answer = 42;\n```\n\n[Next](#second) and [Local](other.md)\n\n## Second\nA second paragraph.\n";
    try fixture(&p, a, .markdown, markdown);
    var view: View = .{ .panel = &p };
    var t: ui.Tester = undefined;
    try t.init(a, .init(&view, View.draw), .{ .width = 640, .height = 700, .scale = 1 });
    defer t.deinit();
    try check(!t.hasText("Browse") and !t.hasText("Rendered") and !t.hasText("Source") and p.ax_count == 5, "compact header exposes source toggle, search and more without secondary rows");
    const status_rect = t.ctx.rects.get(p.ax_readonly) orelse return error.PreviewMissingCompactToolbar;
    try check(!t.hasText("Read only") and p.ax_readonly != 0, "read-only footer uses an icon with semantic geometry");
    t.moveTo(status_rect.x + status_rect.w / 2, status_rect.y + status_rect.h / 2);
    try check(t.hasText("Unlock to edit"), "lock icon advertises unlocking on hover");
    t.moveTo(-1, -1);

    try check(p.body_rect.y < 60 and p.body_rect.y + p.body_rect.h <= status_rect.y, "reading body begins under header and ends above footer");
    try check(p.document().?.text.len < markdown.len and p.prepared.?.markdown.?.spans.len >= 2, "Markdown owns rendered flat text and semantic spans");
    try check(t.ctx.rects.get(p.ax_body) != null and p.ax_refresh == 0 and p.ax_path == 0, "collapsed actions do not expose stale accessibility nodes");
    try clickControl(&p, &t, .more);
    try check(p.show_actions and t.hasText("Browse") and t.ctx.rects.get(p.ax_path) != null, "More reveals real path and action controls");
    try clickControl(&p, &t, .more);
    try check(!p.show_actions and p.ax_path == 0 and p.ax_copy == 0 and p.ax_refresh == 0, "closing More removes hidden action routes");
    try t.screenshot((temporary_root ++ "/letty-preview-rendered.png"));
    try clickControl(&p, &t, .copy_code);
    try check(std.mem.eql(u8, t.clipboard.items, "const answer = 42;"), "code-block copy uses only current owned code bytes and private clipboard");
    // Canonical content and density for comparing the approved reading-room mock.
    {
        var sample: panel.Panel = .{};
        defer sample.deinit(a);
        try fixture(&sample, a, .markdown, "# Letty\n\nA lightweight terminal.\n\n## Getting started\n\nBuild the native application from the repository root.\n\n```sh\npython3 tools/build.py --native\n```\n\n## Workspace navigation\n\nChoose top tabs or a left sidebar in Settings.\n\n- Top tabs keep the terminal wide.\n- The sidebar keeps workspaces in view.\n\n## Local previews\n\nRead files beside your terminal without leaving your workspace.\n");
        sample.model.path.set("README.md");
        var sample_view: View = .{ .panel = &sample };
        var sample_test: ui.Tester = undefined;
        try sample_test.init(a, .init(&sample_view, View.draw), .{ .width = 368, .height = 770, .scale = 2, .theme = @import("../appearance.zig").theme(.{}) });
        defer sample_test.deinit();
        try sample_test.screenshot((temporary_root ++ "/letty-preview-fidelity.png"));
    }
    const paragraph_at = std.mem.indexOf(u8, p.document().?.text, "A strong").?;
    const paragraph_row = p.document().?.lineAt(paragraph_at);
    t.drag(p.body_rect.x + 8, p.body_rect.y + 3, p.body_rect.x + p.body_rect.w - 2, p.body_rect.y + p.row_y.items[paragraph_row] + 3);
    const mouse_selected = p.selection.selected(p.document().?);
    try check(std.mem.startsWith(u8, mouse_selected, "Preview") and std.mem.indexOf(u8, mouse_selected, "paragraph") != null and std.unicode.utf8ValidateSlice(mouse_selected), "real mouse drag selects across rendered blocks without splitting UTF-8");
    p.selection.all(p.document().?);
    p.copy(&t.ctx);
    try check(std.mem.eql(u8, t.clipboard.items, p.document().?.text), "copy rendered cross-block selection uses private clipboard");
    const before = try a.dupe(u8, p.document().?.text);
    defer a.free(before);
    p.field = .body;
    t.ctx.focus = 0;
    t.textOps(&.{ .{ .insert = "MUTATION" }, .{ .set_marked = .{ .text = "字", .sel_start = 3, .sel_len = 0 } }, .{ .command = .delete_backward } });
    try check(std.mem.eql(u8, before, p.document().?.text), "body insert delete and IME cannot edit document");
    p.query.set("paragraph");
    p.find(false);
    const first = p.selection.range().start;
    p.find(false);
    const second = p.selection.range().start;
    p.find(true);
    try check(p.match_count == 2 and first != second and p.selection.range().start == first, "find next previous wraps absolute rendered matches");
    try clickControl(&p, &t, .toggle_source);
    try check(p.mode == .source and std.mem.eql(u8, p.document().?.text, markdown), "source mode preserves Markdown whitespace verbatim");
    try check(t.hasText("1"), "source line numbers are separate from copied text");
    p.selection.all(p.document().?);
    p.copy(&t.ctx);
    try check(std.mem.eql(u8, t.clipboard.items, markdown), "source copy excludes gutter line numbers");
    try clickControl(&p, &t, .toggle_source);
    try check(p.anchor("#second") and !p.anchor("#missing"), "heading anchor resolves only current document");
    t.frame();
    try check(p.layout(.{ .w = 600, .h = 400 }).terminal.w == 0 and p.layout(.{ .w = 1200, .h = 400 }).terminal.w > 0, "narrow panel fills content without consuming a PTY slot");
    try clickControl(&p, &t, .find);
    t.frame();
    try check(p.show_find and p.ax_query != 0, "find field exposes its current real node ID");
    _ = p.handleAction(.select_all, &t.ctx);
    _ = p.handleAction(.copy, &t.ctx);
    try check(std.mem.eql(u8, t.clipboard.items, "paragraph"), "menu copy/select-all in Find edits query selection instead of body");
    t.textOps(&.{.{ .set_marked = .{ .text = "中", .sel_start = 3, .sel_len = 0 } }});
    t.key(.escape);
    try check(p.show_find and t.ctx.focus == p.ax_query and t.ctx.edits.getPtr(t.ctx.focus).?.marked != null, "Find Escape preserves active IME composition and field focus");
    t.textOps(&.{.unmark});
    t.key(.escape);
    try check(!p.show_find and p.opened, "Escape dismisses find without closing document");
    t.resize(400, 430);
    t.theme = ui.Theme.dark_theme;
    t.frame();
    try check(p.body_rect.y < 60 and p.body_rect.y + p.body_rect.h <= 430, "narrow dark body stays below toolbar inside content");
    try t.screenshot((temporary_root ++ "/letty-preview-dark-narrow.png"));
    t.resize(260, 430);
    try clickControl(&p, &t, .more);
    const copy_rect = t.findText("Copy") orelse return error.PreviewMissingCompactToolbar;
    const external_rect = t.findText("External") orelse return error.PreviewMissingCompactToolbar;
    try check(copy_rect.x + copy_rect.w <= 260 and external_rect.x + external_rect.w <= 260 and (external_rect.y >= copy_rect.y + copy_rect.h or external_rect.x >= copy_rect.x + copy_rect.w) and p.body_rect.y >= external_rect.y + external_rect.h, "expanded actions fit or wrap without overlap above body at sidebar width");
    t.resize(240, 430);
    var clipped = false;
    for ([_][]const u8{ "Copy", "Copy Path", "Refresh", "External" }) |label| {
        const r = t.findText(label) orelse return error.PreviewMissingCompactToolbar;
        if (r.x < 0 or r.x + r.w > 240 - 8 or r.y + r.h > p.body_rect.y) clipped = true;
    }
    try check(!clipped, "240 px dock keeps expanded actions inside the panel");
    t.resize(400, 430);
    const long_path = try a.alloc(u8, 1200);
    defer a.free(long_path);
    @memset(long_path, 'x');
    long_path[0] = '/';
    p.model.path.set(long_path);
    p.path.set(long_path);
    p.path_truncated = true;
    p.focus_path = true;
    t.frame();
    t.key(.enter);
    try check(view.intent == .none and p.path_truncated and t.containsText("Path shortened"), "truncated chooser path cannot be submitted as a different shortened path");
    try t.clickText("Copy Path");
    try check(std.mem.eql(u8, t.clipboard.items, long_path), "Copy Path retains full document path beyond input field capacity");
    p.focus_path = true;
    t.frame();
    t.textOps(&.{ .{ .command = .select_all }, .{ .insert = (temporary_root ++ "/edited.md") } });
    try check(!p.path_truncated and std.mem.eql(u8, p.path.text(), (temporary_root ++ "/edited.md")), "real path edit clears truncation guard for explicit new user input");
    t.textOps(&.{.{ .set_marked = .{ .text = "中", .sel_start = 3, .sel_len = 0 } }});
    t.key(.enter);
    try check(view.intent == .none and t.ctx.edits.getPtr(t.ctx.focus).?.marked != null, "path Enter cannot open a new file while an IME candidate is marked");
    t.textOps(&.{.unmark});
    p.model.path.set("");
    p.path.clear();
    p.field = .body;
    t.ctx.focus = 0;
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(a);
    for (0..5000) |_| try many.appendSlice(a, "bounded row 中文\n");
    try fixture(&p, a, .text, many.items);
    t.frame();
    try check(p.row_y.items.len == 5002 and t.ctx.nodes.items.len < 400, "5000 rows paint only visible row nodes");
    t.scroll(p.body_rect.x + 20, p.body_rect.y + 20, -600);
    try check(p.scroll_y > 0 and t.ctx.nodes.items.len < 400, "wheel scroll virtualizes document without frame scanning");
    const down_offset = p.scroll_y;
    t.scroll(p.body_rect.x + 20, p.body_rect.y + 20, 120);
    try check(p.scroll_y == down_offset - 120, "positive native wheel delta moves preview toward the top");
    t.scroll(p.body_rect.x + 20, p.body_rect.y + 20, -0.5);
    try check(p.scroll_y == down_offset - 119.5, "preview preserves subpixel native wheel displacement");
    p.focused = true;
    p.field = .body;
    try check(p.handleAction(.scroll_bottom, &t.ctx), "configured page and scroll actions route to preview");
    t.frame();
    try check(p.scroll_y > 50000, "scroll bottom uses cached row geometry");
    var other: panel.Panel = .{};
    defer other.deinit(a);
    try fixture(&other, a, .text, "Other window\n");
    other.model.id = 77;
    p.model.id = 76;
    other.selection.all(other.document().?);
    try check(other.model.id != p.model.id and p.scroll_y > 0 and other.scroll_y == 0 and std.mem.eql(u8, other.selection.selected(other.document().?), "Other window\n"), "document IDs selection and scroll stay per panel/window");
    try fixture(&p, a, .unsupported, "%PDF-1.7");
    t.frame();
    try check(t.containsText("Unsupported format") and t.hasText("External"), "unsupported formats have an explicit deliberate external action");
    try resourceChecks(a, &p, &t);
    try modelChecks(a);
    try auditRegression(a);
    try tableRegression(a);
    try horizontalRegression(a);
    count += try @import("markdown_extension_ui_check.zig").run(a);
    std.debug.print("PREVIEW checks={d}\n", .{count});
}
fn resourceChecks(a: std.mem.Allocator, p: *panel.Panel, t: *ui.Tester) !void {
    var dir_buf = (temporary_root ++ "/letty-preview-XXXXXX\x00").*;
    const dir = std.mem.span(mkdtemp(@ptrCast(&dir_buf)) orelse return error.FixtureDirectory);
    defer _ = std.c.rmdir(@ptrCast(dir.ptr));
    const path = try std.fmt.allocPrintSentinel(a, "{s}/image space.png", .{dir}, 0);
    defer a.free(path);
    defer _ = std.c.unlink(path);
    const docpath = try std.fmt.allocPrintSentinel(a, "{s}/doc.md", .{dir}, 0);
    defer a.free(docpath);
    var pixels: [64 * 32 * 4]u8 = undefined;
    for (0..64 * 32) |i| pixels[i * 4 ..][0..4].* = if (i % 64 < 32) .{ 0, 0, 255, 255 } else .{ 255, 0, 0, 255 };
    const png = try ui.png.encode(a, .{ .width = 64, .height = 32, .bytes = &pixels });
    defer a.free(png);
    try write(path, png);
    var image_state: model.State = .{ .id = 81, .hooks = @import("prepare_hooks.zig").hooks };
    defer image_state.deinit(a);
    try image_state.open(a, path);
    try loaded(&image_state, a);
    try check(image_state.status == .ready or image_state.status == .watch_error, "real worker hook prepares PNG before publishing ready snapshot");
    const image_revision = image_state.revision;
    const broken_png = try a.dupe(u8, png);
    defer a.free(broken_png);
    broken_png[29] ^= 1; // IHDR CRC: dimensions/signature remain valid to the reader.
    try write(path, broken_png);
    try image_state.refresh();
    try loaded(&image_state, a);
    try check(image_state.status == .invalid_image and image_state.stale and image_state.revision == image_revision and std.mem.eql(u8, image_state.bytes, png), "corrupt PNG update reports invalid_image 13 and retains prior successful snapshot");
    try write(path, png);
    const prepared = try panel.Prepared.initWithPath(a, .markdown, "# Local images\n\n![local](image%20space.png)\n\n![remote](https://example.invalid/a.png)\n\n![outside](../outside.png)\n", docpath);
    try check(prepared.image_count == 1 and prepared.image_errors.len >= prepared.image_error_count and prepared.image_error_count == 2, "worker preparation loads confined local PNG and rejects remote/traversal images");
    try check(prepared.images[0].?.width == 64 and prepared.images[0].?.height == 32 and std.mem.eql(u8, prepared.images[0].?.bgra[0..4], &.{ 0, 0, 255, 255 }), "PNG decode yields bounded premultiplied BGRA");
    p.model.kind = .markdown;
    p.mode = .rendered;
    p.apply(prepared, p.prepared_revision + 1);
    const image = p.imageAt(0).?;
    // Fixed key belongs to this one private Tester, never the shared app Store.
    const key: u64 = 9001;
    try t.text.images.putRaw(key, image.width, image.height, image.bgra);
    defer t.text.images.remove(key);
    p.image_keys[0] = key;
    t.frame();
    try check(t.text.images.rawInfo(key) != null and t.containsText("Image unavailable"), "native Markdown image resource and explicit rejected-image placeholders render");
    try t.screenshot((temporary_root ++ "/letty-preview-local-image.png"));
    t.text.images.remove(key);
    p.image_keys[0] = 0;
    try fixture(p, a, .image, png);
    const standalone = p.imageAt(0).?;
    try t.text.images.putRaw(key, standalone.width, standalone.height, standalone.bgra);
    p.image_keys[0] = key;
    t.frame();
    try t.clickText("Actual");
    try check(!p.fit_image and p.image_zoom == 1 and t.hasText("64×32"), "PNG actual size and dimensions are explicit");
    const actual_pixels = try t.render(a);
    defer actual_pixels.deinit(a);
    const ax: usize = @intFromFloat(p.body_rect.x + 16);
    const ay: usize = @intFromFloat(p.body_rect.y + 16);
    const red = actual_pixels.bytes[(ay * actual_pixels.width + ax) * 4 ..][0..4];
    const blue = actual_pixels.bytes[(ay * actual_pixels.width + ax + 32) * 4 ..][0..4];
    try check(std.mem.eql(u8, red, &.{ 0, 0, 255, 255 }) and std.mem.eql(u8, blue, &.{ 255, 0, 0, 255 }), "PNG Actual panel readback contains real red and blue source pixels");
    try pixelEvidence(a, standalone);
    p.model.status = .invalid_image;
    p.model.stale = true;
    t.frame();
    try check(t.containsText("PNG data is corrupt") and t.containsText("showing previous content"), "stale UI states the actual failure while keeping the previous image visible");
    try t.screenshot((temporary_root ++ "/letty-preview-stale-error.png"));
    p.model.status = .ready;
    p.model.stale = false;
    try t.clickText("Fit");
    try check(p.fit_image, "PNG fit mode can be restored");
    t.text.images.remove(key);
    p.image_keys[0] = 0;
    const alias = try std.fmt.allocPrintSentinel(a, "{s}/alias.png", .{dir}, 0);
    defer a.free(alias);
    defer _ = std.c.unlink(alias);
    if (symlink(path, alias) != 0) return error.FixtureSymlink;
    var rejected = try panel.Prepared.initWithPath(a, .markdown, "![symlink](alias.png)", docpath);
    defer rejected.deinit();
    try check(rejected.image_count == 0 and rejected.image_error_count == 1, "Markdown resources never follow a symlink");
    var corrupt = try panel.Prepared.init(a, .image, "not a PNG");
    defer corrupt.deinit();
    try check(corrupt.prepare_error != null and corrupt.image_count == 0, "malformed PNG gives explicit unavailable state");
}
fn modelChecks(a: std.mem.Allocator) !void {
    var dir_buf = (temporary_root ++ "/letty-preview-model-XXXXXX\x00").*;
    const dir = std.mem.span(mkdtemp(@ptrCast(&dir_buf)) orelse return error.FixtureDirectory);
    defer _ = std.c.rmdir(@ptrCast(dir.ptr));
    const path = try std.fmt.allocPrintSentinel(a, "{s}/doc.txt", .{dir}, 0);
    defer a.free(path);
    defer _ = std.c.unlink(path);
    try write(path, "\xef\xbb\xbffirst\r\nsecond\r\n");
    var state: model.State = .{ .id = 55 };
    defer state.deinit(a);
    try state.open(a, path);
    try loaded(&state, a);
    try check((state.status == .ready or state.status == .watch_error) and std.mem.eql(u8, state.bytes, "first\nsecond\n") and state.id == 55, "async loader normalizes BOM CRLF and retains document identity");
    const generation = state.generation;
    try write(path, "latest\n");
    try state.refresh();
    try loaded(&state, a);
    try check(state.generation > generation and std.mem.eql(u8, state.bytes, "latest\n"), "refresh applies latest generation bytes");
    _ = std.c.unlink(path);
    try state.refresh();
    try loaded(&state, a);
    try check(state.status == .missing and state.stale and std.mem.eql(u8, state.bytes, "latest\n"), "missing reload preserves previous snapshot visibly stale");
    const prior_generation = state.generation;
    state.deinit(a);
    try check(state.id == 55 and state.generation > prior_generation and state.bytes.len == 0, "close cancels worker invalidates generation and releases snapshot");
}

const PixelScene = struct {
    fn draw(_: *PixelScene, ctx: *ui.Context) void {
        ctx.imageRegion(.{ .key = 9002, .destination = .{ .x = 8, .y = 8, .w = 64, .h = 32 }, .source_pixels = .{ .x = 0, .y = 0, .w = 64, .h = 32 }, .clip = .{ .x = 0, .y = 0, .w = 80, .h = 48 } }) catch {};
    }
};
fn pixelEvidence(a: std.mem.Allocator, image: *const panel.Image) !void {
    var scene: PixelScene = .{};
    var pixels: ui.Tester = undefined;
    var theme = ui.Theme.dark_theme;
    theme.background = ui.Color.black;
    try pixels.init(a, .init(&scene, PixelScene.draw), .{ .width = 80, .height = 48, .scale = 1, .theme = theme });
    defer pixels.deinit();
    try pixels.text.images.putRaw(9002, image.width, image.height, image.bgra);
    pixels.frame();
    const rendered = try pixels.render(a);
    defer rendered.deinit(a);
    const red = rendered.bytes[(16 * rendered.width + 16) * 4 ..][0..4];
    const blue = rendered.bytes[(16 * rendered.width + 56) * 4 ..][0..4];
    try check(std.mem.eql(u8, red, &.{ 0, 0, 255, 255 }) and std.mem.eql(u8, blue, &.{ 255, 0, 0, 255 }), "font-free PNG managed resource renders through actual CPU or Metal readback");
    std.debug.print("PREVIEW_PIXEL {{\"scene\":\"opaque-png-64x32\",\"width\":{d},\"height\":{d},\"hash\":\"{x:0>16}\"}}\n", .{ rendered.width, rendered.height, std.hash.Wyhash.hash(0, rendered.bytes) });
    pixels.text.images.remove(9002);
    try check(pixels.text.images.rawInfo(9002) == null and pixels.text.images.managed_bytes == 0, "managed preview image removal releases owned pixel accounting");
}

fn auditRegression(a: std.mem.Allocator) !void {
    var p: panel.Panel = .{};
    defer p.deinit(a);
    var view: View = .{ .panel = &p };
    const prose = "# A heading that must wrap across several narrow visual lines 中文\n\nA paragraph with **strong words** and é👩‍💻中文 repeated text for a narrow viewport. More words before [wrapped link](other.md) and a final sentence.\n\n- A long list item with 中文 and é repeated several times until it wraps to another visual row.\n\n```text\nA code row intentionally remains one long source-style line with horizontal scrolling.\n```\n";
    try fixture(&p, a, .markdown, prose);
    var t: ui.Tester = undefined;
    try t.init(a, .init(&view, View.draw), .{ .width = 280, .height = 800 });
    defer t.deinit();
    const narrow_count = p.visual_rows.items.len;
    var boundaries = true;
    var prose_fits = true;
    const rendered = p.document().?;
    const md = &p.prepared.?.markdown.?;
    for (p.visual_rows.items) |row| {
        boundaries = boundaries and rendered.boundary(row.start) and rendered.boundary(row.end);
        if (row.row >= md.lines.len) continue;
        var block = md.lines[row.row];
        if (block.kind == .code or block.kind == .table or block.kind == .rule) continue;
        block.start = row.start;
        block.end = row.end;
        const bytes = std.mem.trimEnd(u8, md.text[row.start..row.end], " ");
        const width = ui.rich.layout(&t.text, bytes, @import("markdown_render.zig").textStyle(block, 14), @import("markdown_render.zig").lineSpans(&t.ctx, md, block), 0).width;
        prose_fits = prose_fits and width <= p.body_rect.w - 52 + 2;
    }
    try check(boundaries and prose_fits and narrow_count > rendered.lines.len, "wrapped heading paragraph and list fit the dock without splitting CJK combining or emoji graphemes");
    p.selection.all(rendered);
    p.copy(&t.ctx);
    try check(std.mem.eql(u8, t.clipboard.items, rendered.text), "copy wrapped content preserves original rendered bytes without soft newlines");
    const link = md.links[0];
    var clicked = false;
    for (p.visual_rows.items) |row| if (row.start <= link.start and row.end > link.start) {
        var block = md.lines[row.row];
        block.start = row.start;
        block.end = row.end;
        const x = @import("markdown_render.zig").xAt(&t.ctx, md, block, link.start - row.start, 14);
        t.click(p.body_rect.x + 24 + x + 2, p.body_rect.y + row.y + 5);
        clicked = view.intent == .link and std.mem.eql(u8, p.link_target.text(), "other.md");
        break;
    };
    try check(clicked, "click on a wrapped rich-text link resolves its original target");
    t.resize(680, 800);
    try check(p.visual_rows.items.len < narrow_count, "width changes rebuild visual rows and paragraph heights");
    const wide_count = p.visual_rows.items.len;
    _ = p.handleAction(.font_up, &t.ctx);
    t.frame();
    try check(p.layout_zoom == p.zoom and p.visual_rows.items.len >= wide_count, "zoom invalidates wrapped geometry");
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    for (0..4000) |_| try bytes.appendSlice(a, "01234567890123456789\n");
    try bytes.appendSlice(a, "prefix prefix prefix prefix prefix prefix prefix prefix prefix 中文 Linux é end\n");
    try fixture(&p, a, .text, bytes.items);
    p.query.clear();
    p.show_find = true;
    p.focus_query = true;
    t.resize(280, 500);
    t.typeText("Linux");
    try check(p.searching or p.match_count == 1, "editing Find begins a bounded scan without Enter");
    for (0..10) |_| t.frame();
    try check(!p.searching and p.match_count == 1 and p.scroll_x > 0 and p.scroll_y > 0, "late long-line search result reveals both axes after incremental scan");
    const selected = p.selection.selected(p.document().?);
    try check(std.mem.eql(u8, selected, "Linux"), "incremental search selects complete UTF-8 match");
    p.find(false);
    p.find(true);
    try check(p.match_current == 0, "single result next and previous wrap to itself");
    t.textOps(&.{ .{ .command = .select_all }, .{ .insert = "absent-query" } });
    for (0..10) |_| t.frame();
    try check(p.match_count == 0 and p.selection.range().start == p.selection.range().end and !p.searching, "query edits invalidate old highlights and distinguish completed no-match results");
    t.textOps(&.{ .{ .command = .select_all }, .{ .insert = "" } });
    t.frame();
    try check(p.match_count == 0 and !p.searching, "empty query clears results without scanning");
    p.query.set("Linux");
    t.frame();
    t.textOps(&.{.{ .set_marked = .{ .text = "中", .sel_start = 3, .sel_len = 0 } }});
    try check(p.match_count == 0 and !p.search_valid, "marked query hides stale results until composition commits");
    t.textOps(&.{.unmark});
    t.frame();
    try check(p.search_valid, "committed composition resumes document search without PTY input");
}

fn tableRegression(a: std.mem.Allocator) !void {
    const md_render = @import("markdown_render.zig");
    var p: panel.Panel = .{};
    defer p.deinit(a);
    var view: View = .{ .panel = &p };
    try fixture(&p, a, .markdown, "| 文件 | 内容 | 数量 |\n| :--- | :---: | ---: |\n| `model.json` | 分层模型：寄存器字段和存储区记录，中文 é👩‍💻与 **粗体** 说明。继续换行后打开 [文档链接](other.md)。 | 3147 |\n| `issues.csv` | 问题跟踪 | 149 |\n");
    var t: ui.Tester = undefined;
    try t.init(a, .init(&view, View.draw), .{ .width = 440, .height = 700 });
    defer t.deinit();
    const md = &p.prepared.?.markdown.?;
    const row = p.tables.rows.items[1];
    const cell = p.tables.cells.items[row.first + 1];
    try check(cell.end - cell.first > 1 and row.height > md_render.lineHeight(md.lines[1], 14) + 12, "long Chinese table cells wrap and determine their complete row height");
    var bounded = true;
    for (p.tables.cells.items) |box| for (p.tables.fragments.items[box.first..box.end]) |fragment| {
        bounded = bounded and fragment.x >= box.x and fragment.x + fragment.width <= box.x + box.width + 1;
        bounded = bounded and p.document().?.boundary(fragment.block.start) and p.document().?.boundary(fragment.block.end);
    };
    try check(bounded, "table fragments fit measured columns and preserve CJK emoji and combining boundaries");
    const number = p.tables.cells.items[row.end - 1];
    const number_fragment = p.tables.fragments.items[number.first];
    const header_number = p.tables.cells.items[p.tables.rows.items[0].end - 1];
    const header_fragment = p.tables.fragments.items[header_number.first];
    try check(@abs(number_fragment.x + number_fragment.width - header_fragment.x - header_fragment.width) < 1, "right-aligned header and data share an actual shaped right edge");
    const first_fragment = p.tables.fragments.items[cell.first];
    const next_fragment = p.tables.fragments.items[cell.first + 1];
    p.selection.place(p.document().?, first_fragment.block.start, false);
    t.key(.down);
    try check(p.selection.caret >= next_fragment.block.start and p.selection.caret < next_fragment.block.end, "Down moves within a wrapped table cell before advancing to another row");
    t.key(.up);
    try check(p.selection.caret >= first_fragment.block.start and p.selection.caret < first_fragment.block.end, "Up returns to the previous visual line inside the same table cell");
    const link = md.links[0];
    const point = p.tables.pointAt(&t.ctx, md, 1, link.start, 14);
    t.click(p.body_rect.x + 24 + point.x + 2, p.body_rect.y + p.row_y.items[1] + point.y + 5);
    try check(view.intent == .link and std.mem.eql(u8, p.link_target.text(), "other.md"), "wrapped table link uses its cell and visual line for hit testing");
    p.selection.all(p.document().?);
    p.copy(&t.ctx);
    try check(std.mem.indexOf(u8, t.clipboard.items, "model.json\t分层模型") != null and std.mem.indexOf(u8, t.clipboard.items, "\t3147") != null, "table copy retains complete content with tab-separated columns and no visual-wrap newlines");
    p.selection = .{};
    try t.screenshot(temporary_root ++ "/letty-preview-table.png");
    const old_height = row.height;
    t.resize(720, 700);
    try check(p.tables.rows.items[1].height < old_height, "resizing rebuilds table widths and wrapped row heights");
    const wide_height = p.tables.rows.items[1].height;
    _ = p.handleAction(.font_up, &t.ctx);
    t.frame();
    try check(p.layout_zoom == p.zoom and p.tables.rows.items[1].height >= wide_height, "preview zoom rebuilds shaped table geometry");
    try fixture(&p, a, .markdown, "| A | B | C | D | E | F | G | H | I | J | K |\n|-|-|-|-|-|-|-|-|-|-|-|\n|1|2|3|4|5|6|7|8|9|10|needle|\n");
    t.resize(280, 180);
    try check(p.tables.rows.items[0].width > p.body_rect.w, "many-column tables retain readable column widths and horizontal overflow");
    p.show_find = true;
    p.query.set("needle");
    for (0..4) |_| t.frame();
    try check(p.match_count == 1 and p.scroll_x > 0 and std.mem.eql(u8, p.selection.selected(p.document().?), "needle"), "search reveals and selects a table cell beyond the horizontal viewport");
    const found_md = &p.prepared.?.markdown.?;
    const found = p.tables.pointAt(&t.ctx, found_md, 1, p.selection.range().start, 14 * p.zoom);
    try check(found.x >= p.scroll_x and found.x < p.scroll_x + p.body_rect.w and p.row_y.items[1] + found.y >= p.scroll_y and p.row_y.items[1] + found.y < p.scroll_y + p.body_rect.h, "table search result is visible on both axes");
    horizontalWheel(&p, &t, -100000);
    try check(p.scroll_x > 0 and p.scroll_x == p.scroll_x_max, "table horizontal wheel stops at measured right edge");
    horizontalWheel(&p, &t, 100000);
    try check(p.scroll_x == 0, "table horizontal wheel stops at left edge");
}

fn horizontalWheel(p: *panel.Panel, t: *ui.Tester, dx: f32) void {
    t.ctx.input.mouse = .{ .x = p.body_rect.x + 20, .y = p.body_rect.y + 20 };
    t.ctx.input.scroll = .{ .x = dx };
    t.frame();
}
fn horizontalRegression(a: std.mem.Allocator) !void {
    var p: panel.Panel = .{};
    defer p.deinit(a);
    try fixture(&p, a, .text, "Short text\n");
    var view: View = .{ .panel = &p };
    var t: ui.Tester = undefined;
    try t.init(a, .init(&view, View.draw), .{ .width = 320, .height = 400 });
    defer t.deinit();
    horizontalWheel(&p, &t, -100000);
    try check(p.scroll_x == 0 and p.scroll_x_max == 0, "short source text cannot scroll horizontally into blank space");
    const long = "abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij";
    try fixture(&p, a, .text, long ++ "\n");
    t.frame();
    horizontalWheel(&p, &t, -100000);
    try check(p.scroll_x_max > 0 and p.scroll_x == p.scroll_x_max, "long source text clamps at its measured right edge");
    horizontalWheel(&p, &t, 100000);
    try check(p.scroll_x == 0, "source text clamps at its left edge");
    horizontalWheel(&p, &t, -100000);
    t.resize(2000, 400);
    try check(p.scroll_x == 0 and p.scroll_x_max == 0, "wider viewport removes obsolete horizontal overflow");
    t.resize(320, 400);
    try fixture(&p, a, .markdown, "```\n" ++ long ++ "\n```\n");
    t.frame();
    horizontalWheel(&p, &t, -100000);
    try check(p.scroll_x_max > 0 and p.scroll_x == p.scroll_x_max, "rendered code clamps at its shaped right edge");
    const before_zoom = p.scroll_x_max;
    _ = p.handleAction(.font_down, &t.ctx);
    t.frame();
    try check(p.scroll_x_max < before_zoom and p.scroll_x <= p.scroll_x_max, "zoom recomputes the horizontal bound and clamps the offset");
    try fixture(&p, a, .markdown, "Ordinary wrapped prose stays within its viewport.\n");
    t.frame();
    horizontalWheel(&p, &t, -100000);
    try check(p.scroll_x == 0 and p.scroll_x_max == 0, "wrapped prose does not create horizontal overflow");
}

/// Manual regression capture for a user-supplied Markdown document. Owns only
/// an offscreen Tester and reads the original file without copying it into Git.
pub fn captureMarkdown(init: std.process.Init, path: []const u8, output: []const u8, table_index: usize, width: f32, kind: enum { table, diagram, row }) !void {
    const a = std.heap.page_allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, a, .limited(@import("markdown.zig").max_source));
    defer a.free(bytes);
    var p: panel.Panel = .{};
    defer p.deinit(a);
    try fixture(&p, a, .markdown, bytes);
    p.model.path.set(path);
    var view: View = .{ .panel = &p };
    var t: ui.Tester = undefined;
    try t.init(a, .init(&view, View.draw), .{ .width = width, .height = 900, .theme = @import("../appearance.zig").theme(.{}) });
    defer t.deinit();
    const md = p.prepared.?.markdown orelse return error.MarkdownUnavailable;
    var tables: usize = 0;
    var selected: ?usize = null;
    for (md.lines, 0..) |line, index| if ((kind == .table and line.table_header) or (kind == .diagram and line.kind == .diagram) or kind == .row) {
        if (tables == table_index) selected = index;
        tables += 1;
    };
    const row = selected orelse return error.TableNotFound;
    p.scroll_y = p.row_y.items[row];
    t.frame();
    try t.screenshot(output);
    std.debug.print("MARKDOWN_CAPTURE tables={d} selected={d} columns={d} fragments={d}\n", .{ tables, table_index, md.lines[row].cells.len, p.tables.fragments.items.len });
}
