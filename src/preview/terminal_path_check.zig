//! Actual application checks for modified-click terminal paths with an owned
//! hidden window, private temporary files and a real local PTY: hover feedback,
//! trust, file states, multi-click, mouse-report isolation and pointer routing.
const std = @import("std");
const builtin = @import("builtin");
const nano = @import("nanoui");
const ui = nano.ui;
const vt = @import("../vt.zig");
const application = @import("../application_preview.zig");
const terminal_paths = @import("../terminal_paths.zig");
extern "c" fn lt_config_fixture_write([*:0]const u8, [*]const u8, usize, c_uint) c_int;
extern "c" fn mkdir([*:0]const u8, c_uint) c_int;
fn write(path: [:0]const u8, bytes: []const u8) !void {
    if (lt_config_fixture_write(path, bytes.ptr, bytes.len, 0o600) != 0) return error.PathFixtureWrite;
}
fn step(t: *ui.Tester) void {
    nano.runFor(0.01);
    t.frame();
}
fn modifier(t: *ui.Tester, held: bool) void {
    t.ctx.input.cmd = held and builtin.os.tag == .macos;
    t.ctx.input.ctrl = held and builtin.os.tag != .macos;
}
/// Terminal grid cell of `needle`, ignoring document text right of the dock edge.
fn cell(w: anytype, t: *ui.Tester, needle: []const u8) !ui.Rect {
    const limit = w.preview.rect.x;
    for (t.ctx.nodes.items) |n| if (n.content == .glyph_run and n.rect.x < limit) {
        const glyphs = n.content.glyph_run;
        const at = std.mem.indexOf(u8, glyphs.str, needle) orelse continue;
        const index = ui.gridText.owner(glyphs.cells, @intCast(at)) catch continue;
        const last = glyphs.cells[glyphs.cells.len - 1];
        const cw = n.rect.w / @as(f32, @floatFromInt(last.col + last.width));
        const found = glyphs.cells[index];
        return .{ .x = n.rect.x + @as(f32, @floatFromInt(found.col)) * cw + cw / 2, .y = n.rect.y + n.rect.h / 2, .w = cw, .h = n.rect.h };
    };
    std.debug.print("PATH_CHECK missing terminal text {s}\n", .{needle});
    return error.PathCellMissing;
}
fn hover(w: anytype, t: *ui.Tester, needle: []const u8) !ui.Rect {
    modifier(t, false);
    t.frame();
    const r = try cell(w, t, needle);
    w.views[w.layout.active_pane].link.revision = std.math.maxInt(u64);
    modifier(t, true);
    t.moveTo(r.x, r.y);
    t.frame();
    return r;
}
fn settle(w: anytype, t: *ui.Tester, tab: u64, path: []const u8) !*@TypeOf(w.preview).Document {
    for (0..600) |_| {
        step(t);
        const d = w.preview.active(tab) orelse continue;
        if (!std.mem.eql(u8, d.panel.model.path.text(), path) or d.panel.model.status == .loading) continue;
        return d;
    }
    std.debug.print("PATH_CHECK document did not settle: {s}\n", .{path});
    return error.PathDocumentTimeout;
}
pub fn run(w: anytype, t: *ui.Tester, a: std.mem.Allocator, dir: []const u8, comptime check: anytype) !void {
    const notes = try std.fmt.allocPrintSentinel(a, "{s}/notes.md", .{dir}, 0);
    const code = try std.fmt.allocPrintSentinel(a, "{s}/code.txt", .{dir}, 0);
    const blob = try std.fmt.allocPrintSentinel(a, "{s}/blob.bin", .{dir}, 0);
    const big = try std.fmt.allocPrintSentinel(a, "{s}/big.txt", .{dir}, 0);
    const sub = try std.fmt.allocPrintSentinel(a, "{s}/sub", .{dir}, 0);
    const gone = try std.fmt.allocPrint(a, "{s}/gone.md", .{dir});
    const chinese = try std.fmt.allocPrintSentinel(a, "{s}/中文.md", .{dir}, 0);
    const spaced = try std.fmt.allocPrintSentinel(a, "{s}/two words.txt", .{dir}, 0);
    const quoted = try std.fmt.allocPrintSentinel(a, "{s}/中文  文档.md", .{dir}, 0);
    defer for ([_][:0]const u8{ chinese, spaced, quoted }) |path| {
        _ = std.c.unlink(path);
    };
    try write(chinese, "# Chinese filename\n");
    try write(spaced, "A filename containing a space.\n");
    try write(quoted, "# Quoted filename\n");
    defer for ([_][:0]const u8{ notes, code, blob, big }) |path| {
        _ = std.c.unlink(path);
    };
    defer _ = std.c.rmdir(sub);
    try write(notes, "# Clicked notes\n\nOpened from terminal output.\n");
    try write(code, "alpha\nbeta\ngamma\n");
    try write(blob, "\x7fELF\x00\x01\x02binary");
    const large = try a.alloc(u8, 2 * 1024 * 1024 + 4096);
    for (large, 0..) |*byte, i| byte.* = if (i % 64 == 63) '\n' else 'x';
    try write(big, large);
    if (mkdir(sub, 0o700) != 0) return error.PathFixtureDirectory;

    const width = t.size.w;
    const height = t.size.h;
    t.resize(1100, 620);
    defer t.resize(width, height);
    const original_tab = w.layout.tabs[w.layout.active_tab].id;
    defer {
        w.activateTab(w.layout.tabIndex(original_tab).?);
        modifier(t, false);
        t.frame();
    }
    // A new tab inherits the reported directory, so its real child process
    // runs in the fixture directory and supplies the kernel working directory.
    w.active().?.cwd.set(dir);
    try w.add(.tab);
    const tab = w.layout.tabs[w.layout.active_tab].id;
    const session = w.active().?;
    const explicit = session.explicit_command;
    defer session.explicit_command = explicit;
    session.explicit_command = false;
    var origin = terminal_paths.origin(session);
    for (0..300) |_| {
        // fork() initially exposes the parent executable before exec(). Wait
        // for the owned shell, so hover trust is not sampled during that gap.
        if (origin.refusal == null and !std.mem.eql(u8, origin.program.text(), "letty") and std.mem.eql(u8, origin.cwd.text(), dir)) break;
        step(t);
        origin = terminal_paths.origin(session);
    }
    std.debug.print("PATH_CHECK origin program={s} cwd={s} refusal={any} group={d} pid={d} fd={d}\n", .{ origin.program.text(), origin.cwd.text(), origin.refusal, @import("../platform_ffi.zig").lt_foreground_group(session.fd), session.pid, session.fd });
    try check(origin.refusal == null and std.mem.eql(u8, origin.cwd.text(), dir), "local PTY foreground process supplies the trusted kernel working directory");

    const screen = try std.fmt.allocPrint(a, "\x1b[2J\x1b[H\x1b[?1000hABS {s}\r\nREL code.txt:2:1 tail\r\nDIR ./sub\r\nBIN blob.bin\r\nBIG big.txt\r\nMISS gone.md\r\nURL https://example.com/x.md\r\nWORD and/or\r\n中文.md  two words.txt  '中文  文档.md'\r\n", .{notes});
    vt.lt_vt_feed(session.vt, screen.ptr, screen.len);
    t.frame();
    const view = &w.views[w.layout.active_pane];
    const sent = session.admitted_bytes;

    const plain = try cell(w, t, "notes.md");
    modifier(t, false);
    t.moveTo(plain.x, plain.y);
    try check(!view.link.visible and !view.link.refused and !t.containsText("Open Preview"), "path without the platform modifier shows no link feedback");
    const notes_cell = try hover(w, t, "notes.md");
    std.debug.print("PATH_CHECK hover visible={any} kind={s} target={s} resolved={s} reason={s} hand={any} tip={any} at={d},{d}\n", .{ view.link.visible, @tagName(view.link.kind), view.link.target.text(), view.link.resolved.text(), view.link.reason, t.ctx.cursor_hand, t.containsText("Open Preview"), notes_cell.x, notes_cell.y });
    try check(view.link.visible and view.link.kind == .file and std.mem.eql(u8, view.link.resolved.text(), notes) and t.ctx.cursor_hand and t.containsText("Open Preview"), "modifier hover underlines a local path, shows a hand cursor and its resolved preview target");
    try t.screenshot(".cache/test-logs/terminal-path-hover.png");
    t.click(notes_cell.x, notes_cell.y);
    const md = try settle(w, t, tab, notes);
    try check(md.panel.model.kind == .markdown and md.panel.mode == .rendered and application.focused(w), "modified click opens a Markdown path in rendered preview with document focus");
    try check(session.admitted_bytes == sent and !vt.lt_vt_has_selection(session.vt), "modified click on a path sends no mouse report and starts no selection while tracking is on");
    const count = w.preview.count();
    t.doubleClick(notes_cell.x, notes_cell.y);
    t.frame();
    try check(w.preview.count() == count and session.admitted_bytes == sent and !vt.lt_vt_has_selection(session.vt), "modified double click reuses the document without word selection or a PTY report");

    // Document keyboard focus: the pane under the pointer still gets hover
    // feedback, but keys never reach the PTY.
    _ = try cell(w, t, "code.txt");
    md.panel.focused = true;
    md.panel.field = .body;
    w.syncFocus();
    const rel = try hover(w, t, "code.txt");
    try check(application.focused(w) and view.link.visible and std.mem.eql(u8, view.link.resolved.text(), try std.fmt.allocPrint(a, "{s}:2:1", .{code})), "terminal hover feedback works while a document keeps keyboard focus");
    t.typeText("zz");
    try check(session.admitted_bytes == sent and application.focused(w), "typing while the document is focused writes nothing to the PTY");
    t.click(rel.x, rel.y);
    const text_doc = try settle(w, t, tab, code);
    for (0..20) |_| step(t);
    try check(text_doc.panel.model.kind == .text and text_doc.panel.mode == .source and text_doc.panel.selection.caret == 6 and w.preview.find(md.id) != null, "relative path:line:column resolves against the trusted directory and opens text at that line");

    const PathCase = struct { needle: []const u8, path: []const u8 };
    for ([_]PathCase{
        .{ .needle = "中文.md", .path = chinese },
        .{ .needle = "words.txt", .path = spaced },
        .{ .needle = "文档.md", .path = quoted },
    }) |case| {
        const r = try hover(w, t, case.needle);
        try check(view.link.visible and std.mem.eql(u8, view.link.resolved.text(), case.path), "Unicode and space-containing terminal filenames hover as complete local paths");
        t.click(r.x, r.y);
        const d = try settle(w, t, tab, case.path);
        try check(d.panel.model.status == .ready, "modified click loads the complete Unicode or space-containing filename");
        w.preview.close(w, d.id);
    }

    const States = struct { needle: []const u8, path: []const u8, status: @import("model.zig").Status, message: []const u8 };
    for ([_]States{
        .{ .needle = "./sub", .path = sub, .status = .not_regular, .message = "Not a regular file" },
        .{ .needle = "blob.bin", .path = blob, .status = .unsupported, .message = "Binary or unsupported file" },
        .{ .needle = "big.txt", .path = big, .status = .too_large, .message = "File exceeds the preview size limit" },
        .{ .needle = "gone.md", .path = gone, .status = .missing, .message = "File not found" },
    }) |case| {
        const r = try hover(w, t, case.needle);
        t.click(r.x, r.y);
        const d = try settle(w, t, tab, case.path);
        t.frame();
        if (d.panel.model.status != case.status) std.debug.print("PATH_CHECK {s} status={s}\n", .{ case.needle, @tagName(d.panel.model.status) });
        try check(d.panel.model.status == case.status and d.panel.prepared == null and t.containsText(case.message), switch (case.status) {
            .not_regular => "directory path opens an explicit not-a-regular-file state",
            .unsupported => "binary file opens an explicit unsupported state without content",
            .too_large => "oversized file opens an explicit size-limit state without truncation",
            else => "missing path opens an explicit file-not-found state",
        });
        if (case.status == .missing) try t.screenshot(".cache/test-logs/terminal-path-missing.png");
        w.preview.close(w, d.id);
    }
    try check(session.admitted_bytes == sent, "every modified path click kept mouse reports out of the PTY");

    _ = try hover(w, t, "example.com");
    try check(view.link.visible and view.link.kind == .url and t.containsText("https://example.com/x.md"), "web URL keeps URL priority over path detection");
    _ = try hover(w, t, "and/or");
    try check(!view.link.visible and view.link.kind == .none, "prose with a slash is not treated as a path");

    // A drag that starts in the terminal must receive its release over the dock.
    modifier(t, false);
    const drag = try cell(w, t, "BIN");
    t.moveTo(drag.x, drag.y);
    t.ctx.pointerDown();
    t.frame();
    try check(view.selecting, "terminal press with mouse tracking begins a terminal gesture");
    t.ctx.input.mouse = .{ .x = w.preview.rect.x + 40, .y = w.preview.rect.y + 120 };
    t.frame();
    t.ctx.pointerUp();
    t.frame();
    try check(!view.selecting and session.admitted_bytes > sent, "terminal drag released over the document dock ends the gesture and reports the release");
    vt.lt_vt_feed(session.vt, "\x1b[?1000l", 8);

    // Right-click keeps a modifier-free, menu/keyboard-reachable route.
    modifier(t, false);
    const menu_cell = try cell(w, t, "blob.bin");
    t.moveTo(menu_cell.x, menu_cell.y);
    t.ctx.input.mouse_button = 2;
    t.ctx.pointerDown();
    t.frame();
    t.ctx.pointerUp();
    t.frame();
    t.ctx.input.mouse_button = 1;
    try check(w.context_menu.open and t.hasText("Preview File") and t.hasText("Copy Path"), "right-click on a local path offers Preview File and Copy Path menu commands");
    try t.screenshot(".cache/test-logs/terminal-path-context-menu.png");
    try t.clickText("Preview File");
    const via_menu = try settle(w, t, tab, blob);
    try check(!w.context_menu.open and via_menu.panel.model.status == .unsupported, "context menu Preview File opens through the same trusted path opener");
    w.preview.close(w, via_menu.id);

    for (w.preview.documents) |opt| if (opt) |d| if (d.tab_id == tab) w.preview.close(w, d.id);
    session.explicit_command = true;
    const refused = try hover(w, t, "notes.md");
    try check(!view.link.visible and view.link.refused and t.containsText("SSH profile"), "explicit-command or SSH-profile terminal shows why a path is not opened, without underline");
    try t.screenshot(".cache/test-logs/terminal-path-refused.png");
    t.click(refused.x, refused.y);
    t.frame();
    try check(w.preview.active(tab) == null, "untrusted terminal path click opens no local document");
    w.status = "";
    application.openTerminalPath(w, notes, session.id);
    try check(w.preview.active(tab) == null and std.mem.indexOf(u8, w.status, "SSH profile") != null, "execution revalidates trust instead of reusing hover state");
    session.explicit_command = false;
    application.openTerminalPath(w, notes, session.id + 1000);
    try check(w.preview.active(tab) == null and std.mem.indexOf(u8, w.status, "closed") != null, "stale source session ID is rejected before resolving the path");
    w.status = "";
}
