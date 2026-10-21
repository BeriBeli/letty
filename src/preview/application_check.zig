//! Actual application route checks with fresh Host, private Testers and owned PTYs.
const std = @import("std");
const temporary_root = if (@import("builtin").os.tag == .macos) "/private/tmp" else "/tmp";
const builtin = @import("builtin");
const nano = @import("nanoui");
const ui = nano.ui;
const config = @import("../config.zig");
const application = @import("../application_preview.zig");
const vt = @import("../vt.zig");
const actions = @import("../actions.zig");
const keys = @import("../keybindings.zig");
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn lt_config_fixture_write([*:0]const u8, [*]const u8, usize, c_uint) c_int;
var checks: usize = 0;
const idle_command = "exec /bin/sh -c 'sleep 90'";
const raw_command = "exec /bin/sh -c 'stty raw -echo || exit 90; printf \"\\r\\n__PREVIEW_READY__\\r\\n\"; output=$(od -An -tx1 -N 5); result=$?; printf \"\\r\\n__PREVIEW_RESULT__%s__PREVIEW_DONE__\\r\\n\" \"$output\"; sleep 90; exit \"$result\"'";
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI Preview {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.PreviewApplicationCheck;
    checks += 1;
}
fn action(w: anytype, t: *ui.Tester, request: actions.Request) void {
    w.menu_actions[0] = request;
    w.menu_action_count = 1;
    t.frame();
    t.frame();
}
fn step(t: *ui.Tester) void {
    nano.runFor(0.01);
    t.frame();
}
fn allText(session: anytype, gpa: std.mem.Allocator) ![]u8 {
    if (vt.lt_vt_select_all(session.vt) != 0) return error.PreviewNoOutput;
    defer vt.lt_vt_clear_selection(session.vt);
    var bytes: [65536]u8 = undefined;
    var len: usize = 0;
    if (vt.lt_vt_copy(session.vt, &bytes, bytes.len, &len) != 0) return error.PreviewCopyFailed;
    return gpa.dupe(u8, bytes[0..len]);
}
fn waitText(session: anytype, t: *ui.Tester, needle: []const u8) ![]u8 {
    for (0..600) |_| {
        step(t);
        const value = allText(session, session.gpa) catch |err| switch (err) {
            error.PreviewNoOutput => continue,
            else => return err,
        };
        if (std.mem.indexOf(u8, value, needle) != null) return value;
        session.gpa.free(value);
        if (session.fatal or session.eof) return error.PreviewPtyExitedEarly;
    }
    return error.PreviewPtyTimeout;
}
fn waitDocument(w: anytype, t: *ui.Tester, id: u64, needle: []const u8) !void {
    for (0..600) |_| {
        step(t);
        const d = w.preview.find(id) orelse return error.PreviewDocumentLost;
        if (d.panel.prepared != null and d.panel.model.status != .loading and std.mem.indexOf(u8, d.panel.model.bytes, needle) != null) return;
        if (d.panel.model.status != .loading and d.panel.model.status != .ready and d.panel.model.status != .watch_error) {
            std.debug.print("PREVIEW_LOAD status={s} path={s}\n", .{ @tagName(d.panel.model.status), d.panel.model.path.text() });
            return error.PreviewDocumentLoad;
        }
    }
    return error.PreviewDocumentTimeout;
}
fn write(path: [:0]const u8, bytes: []const u8) !void {
    if (lt_config_fixture_write(path, bytes.ptr, bytes.len, 0o600) != 0) return error.PreviewFixtureWrite;
}
pub fn run(s: anytype) !void {
    checks = 0;
    try check(s.app.flags.hidden, "fixture requires hidden app and private offscreen input");
    const Host = @TypeOf(s.host.*);
    const Window = @TypeOf(s.*);
    var arena = std.heap.ArenaAllocator.init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var dir_buffer = (temporary_root ++ "/letty-preview-app-XXXXXX\x00").*;
    const dir = std.mem.span(mkdtemp(@ptrCast(&dir_buffer)) orelse return error.PreviewFixtureDirectory);
    defer _ = std.c.rmdir(@ptrCast(dir.ptr));
    var paths: [5][:0]u8 = undefined;
    for (&paths, 0..) |*path, i| path.* = if (i == 0) try std.fmt.allocPrintSentinel(a, "{s}/README.md", .{dir}, 0) else try std.fmt.allocPrintSentinel(a, "{s}/{d} 文档.md", .{ dir, i }, 0);
    defer for (paths) |path| {
        _ = std.c.unlink(path);
    };
    for (paths, 0..) |path, i| try write(path, try std.fmt.allocPrint(a, "# Document {d}\n\nPreview 中文👩‍💻\n\nfind one\n\nfind two\n\n```sh\necho hello\n```\n", .{i}));
    const profiles = [_]config.Profile{.{}};
    const cfg: config.Config = .{ .shell = "/bin/sh", .shell_integration = .none, .profiles = &profiles, .command = idle_command, .copy_on_select = .none, .confirm_close = .always, .tab_bar = .always };
    var host: Host = .{ .gpa = s.gpa, .arena = a, .app = s.app, .cfg = cfg, .state_path = "/dev/null", .read_path = "/dev/null", .command_override = raw_command, .override_profile = profiles[0].name, .demo = true, .hold = true };
    host.services.init(&host);
    var host_alive = true;
    defer if (host_alive) {
        host.deinit();
        nano.runFor(0.025);
    };
    defer if (builtin.os.tag == .macos) s.macMenu() catch {};
    const first = try host.create(false);
    first.window_focused = true;
    const receiver = first.active().?;
    const pid = receiver.pid;
    const session_id = receiver.id;
    const tab_a = first.layout.tabs[first.layout.active_tab].id;
    host.command_override = idle_command;
    first.command_override = idle_command;
    try first.add(.horizontal);
    const original_ratio = first.layout.nodes[first.layout.roots[first.layout.active_tab]].ratio;
    try first.add(.tab);
    const tab_b = first.layout.tabs[first.layout.active_tab].id;
    first.activateTab(first.layout.tabIndex(tab_a).?);
    first.focusPane(0);
    const second = try host.create(false);
    second.window_focused = true;
    const second_pid = second.active().?.pid;
    const second_tab = second.layout.tabs[second.layout.active_tab].id;
    var t: ui.Tester = undefined;
    try t.init(s.gpa, .init(first, Window.view), .{ .width = 1100, .height = 720, .theme = @import("../appearance.zig").theme(cfg) });
    defer t.deinit();
    var other: ui.Tester = undefined;
    try other.init(s.gpa, .init(second, Window.view), .{ .width = 900, .height = 620, .theme = @import("../appearance.zig").theme(cfg) });
    defer other.deinit();
    defer {
        // Views/Store borrow these TextSystems. Discard the old paint tree,
        // retire every view/resource, then allow Testers to release their text.
        t.ctx.nodes.clearRetainingCapacity();
        t.instances.clearRetainingCapacity();
        other.ctx.nodes.clearRetainingCapacity();
        other.instances.clearRetainingCapacity();
        host.deinit();
        host_alive = false;
        nano.runFor(0.025);
    }
    first.window_focused = true;
    second.window_focused = true;
    host.active_id = first.id;
    const ready = try waitText(receiver, &t, "__PREVIEW_READY__");
    s.gpa.free(ready);
    const panes = host.paneCount();
    action(first, &t, .{ .action = .search });
    t.typeText("KEEP_TERMINAL_QUERY");
    first.preview.picker_override = paths[0];
    first.titlebar.enqueue(first, .preview);
    t.frame();
    const document = first.preview.active(tab_a) orelse return error.PreviewDidNotOpen;
    const id = document.id;
    try waitDocument(first, &t, id, "Document 0");
    try check(first.preview.count() == 1 and host.paneCount() == panes and receiver.pid == pid and receiver.id == session_id, "menu action opens owned document without creating/replacing a PTY");
    var copy_code_widget: u64 = 0;
    var copy_code_node: u64 = 0;
    for (first.ax.routes[0..first.ax.route_count]) |route| if (route.intent == .document_copy_code) {
        copy_code_widget = route.widget;
        copy_code_node = route.id;
        break;
    };
    try check(copy_code_node != 0 and first.ax.adapter.?.enqueue(copy_code_node, .press), "code block advertises a real accessible copy action");
    t.frame();
    try check(std.mem.eql(u8, t.clipboard.items, "echo hello"), "accessible code copy reads the current block into the private clipboard");
    t.clipboard.clearRetainingCapacity();
    t.ctx.focus = copy_code_widget;
    t.key(.enter);
    try check(std.mem.eql(u8, t.clipboard.items, "echo hello"), "focused code copy supports keyboard Enter");
    t.ctx.focus = 0;
    action(first, &t, .{ .action = .open_file_preview });
    try check(first.preview.count() == 1 and first.preview.active(tab_a).?.id == id, "same path open reuses stable workspace document ID");
    document.panel.path.set(paths[1]);
    application.openDraft(first, document);
    const opened_draft = first.preview.active(tab_a).?.id;
    try check(opened_draft != id and std.mem.eql(u8, document.panel.path.text(), document.panel.model.path.text()), "Open another path restores original document field to its own identity");
    first.preview.close(first, opened_draft);
    first.preview.dockFor(tab_a).active = id;
    document.panel.path.set((temporary_root ++ "/letty-no-such-audit-file-99127.txt"));
    application.openDraft(first, document);
    const missing_draft = first.preview.active(tab_a).?.id;
    try check(std.mem.eql(u8, document.panel.path.text(), document.panel.model.path.text()), "failed or missing path attempt cannot remain as original document identity");
    if (missing_draft != id) first.preview.close(first, missing_draft);
    first.preview.dockFor(tab_a).active = id;
    t.frame();

    try check(first.preview.rect.w > 0 and first.navigationGeometry(t.size.w, t.size.h).content.w < 1100 and document.panel.body_rect.x >= first.preview.rect.x, "actual pane geometry excludes dock and text hit area stays inside document");
    t.typeText("LEAK");
    t.key(.left);
    t.textOps(&.{ .{ .insert = "字" }, .{ .set_marked = .{ .text = "中", .sel_start = 3, .sel_len = 0 } }, .unmark });
    action(first, &t, .{ .action = .send_bytes, .args = .{ .bytes = try @import("../action_bytes.zig").parse("text:BAD") } });
    std.debug.print("PREVIEW_INPUT_DIAG after_doc_input focused={any} field={s} active_pane={d} active_session={d} receiver={d} tx={d} eof={any}\n", .{ application.focused(first), @tagName(document.panel.field), first.layout.active_pane, first.active().?.id, receiver.id, receiver.tx.len, receiver.eof });
    const terminal_font = first.cfg.font_size;
    action(first, &t, .{ .action = .font_up });
    try check(first.cfg.font_size == terminal_font and document.panel.zoom > 1 and receiver.pid == pid and !receiver.eof and std.mem.eql(u8, first.query.text(), "KEEP_TERMINAL_QUERY"), "focused preview consumes chars IME send_bytes arrows and zoom without changing existing terminal query");
    action(first, &t, .{ .action = .select_all });
    action(first, &t, .{ .action = .copy });
    try check(std.mem.eql(u8, t.clipboard.items, document.panel.document().?.text), "configured copy/select-all target rendered document private clipboard");
    action(first, &t, .{ .action = .search });
    t.typeText("find");
    action(first, &t, .{ .action = .search_next });
    try check(document.panel.show_find and document.panel.match_count == 2 and first.search_open and std.mem.eql(u8, first.query.text(), "KEEP_TERMINAL_QUERY"), "document Find routes away from terminal search");
    try @import("ui_check.zig").clickControl(&document.panel, &t, .toggle_source);
    action(first, &t, .{ .action = .search });
    imeDiagnostic(first, &t, "source_query_refocused");
    const composing_count = first.preview.count();
    const composing_zoom = document.panel.zoom;
    const ime_binding = try keys.parse("ctrl+alt+u=increase_font_size:1");
    first.cfg.keybinds = &.{ime_binding};
    first.preview.picker_override = paths[2];
    t.textOps(&.{.{ .set_marked = .{ .text = "预", .sel_start = 3, .sel_len = 0 } }});
    const composing_focus = t.ctx.focus;
    imeDiagnostic(first, &t, "marked");
    try check(t.ctx.focus == document.panel.ax_query and (if (t.ctx.edits.getPtr(t.ctx.focus)) |edit| edit.marked != null else false), "Source IME fixture contains an actual focused marked range");
    const window_count = host.count();
    for ([_]actions.Action{ .new_window, .toggle_quick_terminal, .open_settings }) |host_action| {
        const request: actions.Request = .{ .action = host_action };
        const rejected = reject: {
            host.services.enqueue(&request) catch |err| break :reject err == error.DocumentInputActive;
            break :reject false;
        };
        try check(rejected and host.services.count == 0 and host.count() == window_count and host.settings.window == null, switch (host_action) {
            .new_window => "marked document rejects queued host New Window without external action",
            .toggle_quick_terminal => "marked document rejects queued host Quick Terminal without external action",
            else => "marked document rejects queued host Settings without external action",
        });
    }
    _ = t.shortcut(.{ .key = 'u', .ctrl = true, .alt = true });
    imeDiagnostic(first, &t, "after_zoom");
    _ = t.shortcut(.{ .key = 'o', .cmd = builtin.os.tag == .macos, .ctrl = builtin.os.tag != .macos, .shift = builtin.os.tag != .macos });
    imeDiagnostic(first, &t, "after_open");
    _ = t.shortcut(.{ .key = 'w', .cmd = builtin.os.tag == .macos, .ctrl = builtin.os.tag != .macos, .shift = builtin.os.tag != .macos });
    imeDiagnostic(first, &t, "after_close");
    action(first, &t, .{ .action = .open_file_preview });
    imeDiagnostic(first, &t, "after_menu_open");
    try check(first.preview.count() == composing_count and first.preview.active(tab_a).?.id == id and document.panel.zoom == composing_zoom and t.ctx.focus == composing_focus, "marked Source Find IME rejects zoom Open and Close shortcuts and menu without focus loss");
    t.textOps(&.{.unmark});
    try check(!first.preview.composition_active, "IME commit clears persistent host-action gate without an idle frame");
    t.frame();
    first.cfg.keybinds = cfg.keybinds;
    first.preview.picker_override = paths[0];
    action(first, &t, .{ .action = .end_search });
    try @import("ui_check.zig").clickControl(&document.panel, &t, .toggle_source);
    try headerControls(first, &t, document);
    try axGeneration(first, &t, document, "Document 0");
    try documentDrop(first, &t, paths[4], paths[3]);
    for (first.ax.routes[0..first.ax.route_count]) |route| if (route.intent == .preview_toggle) {
        if (!first.ax.adapter.?.enqueue(route.id, .press)) return error.PreviewMissingAX;
        break;
    };
    first.activateTab(first.layout.tabIndex(tab_b).?);
    t.frame();
    try check(!first.preview.dockFor(tab_a).collapsed and first.preview.active(tab_b) == null, "queued preview toggle rejects workspace changes instead of opening or hiding another tab's document");
    first.activateTab(first.layout.tabIndex(tab_a).?);
    t.frame();
    const reading_before = document.panel.scroll_y;
    const reading_mode = document.panel.mode;
    _ = t.shortcut(if (builtin.os.tag == .macos) .{ .key = 'o', .cmd = true, .shift = true } else .{ .key = 'o', .ctrl = true, .alt = true });
    t.frame();
    try check(first.preview.dockFor(tab_a).collapsed and !application.focused(first), "collapse restores terminal focus without discarding document");
    try check(first.preview.rect.w == 0 and first.navigation_rects.content.w == first.preview.base.w, "collapsed preview gives full content width back without a Show rail");
    try t.screenshot(".cache/test-logs/preview-collapsed.png");
    first.titlebar.enqueue(first, .preview);
    first.activateTab(first.layout.tabIndex(tab_b).?);
    t.frame();
    try check(first.preview.dockFor(tab_a).collapsed and first.preview.active(tab_b) == null, "titlebar callback rejects stale workspace ownership");
    first.activateTab(first.layout.tabIndex(tab_a).?);
    action(first, &t, .{ .action = .end_search });
    first.titlebar.enqueue(first, .preview);
    t.frame();
    try check(!first.preview.dockFor(tab_a).collapsed and application.focused(first) and document.panel.scroll_y == reading_before and document.panel.mode == reading_mode and first.preview.active(tab_a).?.id == id, "restore keeps active document and reading state");
    t.typeText("LEAK");
    t.key(.left);
    action(first, &t, .{ .action = .send_bytes, .args = .{ .bytes = try @import("../action_bytes.zig").parse("text:BAD") } });
    try check(application.focused(first) and !first.search_open and first.active().?.id == session_id, "raw PTY leak probe runs with document focused and terminal Find closed");
    try resizeWorkspace(first, &t, tab_a, tab_b);
    first.activateTab(first.layout.tabIndex(tab_b).?);
    t.frame();
    try check(first.preview.active(tab_b) == null and first.preview.count() == 1, "workspace switch keeps old document owned and hides its dock");
    try application.open(first, paths[1]);
    const workspace_document = first.preview.active(tab_b).?.id;
    try waitDocument(first, &t, workspace_document, "Document 1");
    try application.open(second, paths[0]);
    const second_document = second.preview.active(second_tab).?.id;
    try waitDocument(second, &other, second_document, "Document 0");
    try check(second.preview.count() == 1 and first.preview.count() == 2 and second.active().?.pid == second_pid and first.preview.active(tab_b).?.id == workspace_document, "two windows and workspaces own independent document collections");
    try serviceQueue(first, &t, second, paths[2]);
    first.activateTab(first.layout.tabIndex(tab_a).?);
    t.frame();
    try check(first.preview.active(tab_a).?.id == id and document.panel.zoom > 1, "return to workspace restores same document and zoom");
    try narrowSidebar(first, &t);
    try write(paths[0], "# Latest generation\n\nwatch changed\n");
    try waitDocument(first, &t, id, "Latest generation");
    try check(document.panel.model.revision >= 2 and std.mem.indexOf(u8, document.panel.document().?.text, "watch changed") != null, "actual fdwatch publishes latest external file change and prepared render");
    try t.screenshot(".cache/test-logs/preview-application-light.png");
    try write(paths[0], "# Letty\n\nA lightweight terminal.\n\n## Getting started\n\nBuild the native application from the repository root.\n\n```sh\npython3 tools/build.py --native\n```\n\n## Workspace navigation\n\nChoose top tabs or a left sidebar in Settings.\n\n- Top tabs keep the terminal wide.\n- The sidebar keeps workspaces in view.\n\n## Local previews\n\nRead files beside your terminal without leaving your workspace.\n");
    try waitDocument(first, &t, id, "A lightweight terminal.");
    document.panel.zoom = 1;
    document.panel.scroll_y = 0;
    document.panel.show_find = false;
    document.panel.show_actions = false;
    t.frame();
    try t.screenshot(".cache/test-logs/preview-application-fidelity.png");
    const old_navigation = first.cfg.workspace_navigation;
    first.cfg.workspace_navigation = .sidebar;
    const old_collapsed = first.sidebar.collapsed;
    first.sidebar.collapsed = true;
    action(first, &t, .{ .action = .toggle_file_preview });
    t.frame();
    try t.screenshot(".cache/test-logs/workspace-collapsed-fidelity.png");
    try check(first.navigation_rects.navigation.w == 44 and first.preview.rect.w == 0, "collapsed workspace uses a 44-point icon rail and no right-hand rail");
    first.cfg.workspace_navigation = old_navigation;
    first.sidebar.collapsed = old_collapsed;
    action(first, &t, .{ .action = .toggle_file_preview });

    action(first, &t, .{ .action = .close_file_preview });
    try check(first.preview.active(tab_a) == null and first.preview.find(id) == null and receiver.pid == pid and first.layout.nodes[first.layout.roots[first.layout.tabIndex(tab_a).?]].ratio == original_ratio, "close removes document preserves PTY and pane tree ratio");
    action(first, &t, .{ .action = .end_search });
    first.preview.picker_override = paths[2];
    _ = t.shortcut(.{ .key = 'o', .cmd = builtin.os.tag == .macos, .ctrl = builtin.os.tag != .macos, .shift = builtin.os.tag != .macos });
    try check(first.layout.isDocument(first.layout.active_tab) and first.active() == null and first.preview.active(tab_a) == null, "platform default Open File binding opens an independent workspace without a PTY");
    try workspaceChecks(first, &t, paths[2], tab_a, receiver, session_id);
    action(first, &t, .{ .action = .close_file_preview });
    first.activateTab(first.layout.tabIndex(tab_a).?);
    const ignore = try keys.parse(if (builtin.os.tag == .macos) "super+o=ignore" else "ctrl+shift+o=ignore");
    first.cfg.keybinds = &.{ignore};
    _ = t.shortcut(.{ .key = 'o', .cmd = builtin.os.tag == .macos, .ctrl = builtin.os.tag != .macos, .shift = builtin.os.tag != .macos });
    try check(first.preview.active(tab_a) == null, "explicit ignore disables default preview shortcut");
    const custom = try keys.parse("ctrl+alt+o=open_file_preview");
    first.cfg.keybinds = &.{custom};
    _ = t.shortcut(.{ .key = 'o', .ctrl = true, .alt = true });
    try check(first.preview.active(tab_a) != null, "custom preview binding uses shared document opener");
    first.cfg.keybinds = cfg.keybinds;
    action(first, &t, .{ .action = .close_file_preview });
    first.focusPane(0);
    first.window_focused = true;
    t.ctx.focus = 0;
    t.frame();
    std.debug.print("PREVIEW_INPUT_DIAG before_final focused={any} active_pane={d} active_session={d} receiver={d} tx={d} eof={any} chars={s}\n", .{ application.focused(first), first.layout.active_pane, first.active().?.id, receiver.id, receiver.tx.len, receiver.eof, t.ctx.input.chars });
    t.typeText("ABCDE");
    const output = try waitText(receiver, &t, "__PREVIEW_DONE__");
    defer s.gpa.free(output);
    std.debug.print("PREVIEW_RAW_OUTPUT expected=41 42 43 44 45 actual={s}\n", .{output});
    try check(exactRawBytes(output), "real raw PTY receives exactly post-preview bytes with no document input leak");
    try @import("editor_application_check.zig").run(first, &t, a, dir);
    try boundaryChecks(first, &t, a, dir);
    try @import("terminal_path_check.zig").run(second, &other, a, dir, check);
    try @import("capacity_check.zig").run(first, &t, second, &other, paths, check, waitDocument);
    // Fill the actual global PTY pool, then open a fresh document at capacity.
    while (host.paneCount() < 16) {
        var first_count: usize = 0;
        for (first.sessions) |entry| if (entry != null) {
            first_count += 1;
        };
        const target = if (first_count < 8) first else second;
        target.add(.horizontal) catch return error.PreviewFixturePtyCapacity;
    }
    const capacity = host.paneCount();
    try application.open(first, paths[3]);
    try check(capacity == 16 and host.paneCount() == 16 and first.preview.active(tab_a) != null, "document opens beside sixteen live PTYs");
    try workspaceCapacity(first, &t, paths[4], tab_a);
    // Close while the asynchronous loader can still be pending; the next frames
    // must not receive a freed document or apply its stale result elsewhere.
    const closing = first.preview.active(tab_a).?.id;
    first.preview.close(first, closing);
    for (0..8) |_| step(&t);
    try check(first.preview.find(closing) == null and second.preview.active(second_tab).?.id == second_document, "close during read revokes fdwatch and late result without crossing windows");
    checks += try @import("markdown_extension_ui_check.zig").run(s.gpa);
    std.debug.print("PREVIEW_APPLICATION checks={d}\n", .{checks});
}
fn waitStatus(w: anytype, t: *ui.Tester, id: u64, status: @import("model.zig").Status) !void {
    for (0..600) |_| {
        step(t);
        const d = w.preview.find(id) orelse return error.PreviewDocumentLost;
        if (d.panel.model.status == status) return;
    }
    return error.PreviewStatusTimeout;
}
fn headerControls(w: anytype, t: *ui.Tester, d: anytype) !void {
    const source = for (w.ax.routes[0..w.ax.route_count]) |route| {
        if (route.intent == .document_toggle_source) break route;
    } else return error.PreviewMissingSourceToggle;
    t.ctx.focus = source.widget;
    t.frame();
    t.key(.enter);
    try check(d.panel.mode == .source, "keyboard Enter activates the source icon through its accessibility route");
    var selected = false;
    for (d.panel.ax_controls[0..d.panel.ax_count]) |item| if (item.control == .toggle_source) {
        selected = item.selected;
    };
    try check(selected, "source toggle advertises its selected state");
    t.key(.enter);
    try check(d.panel.mode == .rendered, "same keyboard toggle returns to rendered Markdown");
    const more = for (w.ax.routes[0..w.ax.route_count]) |route| {
        if (route.intent == .document_more) break route.id;
    } else return error.PreviewMissingMore;
    if (!w.ax.adapter.?.enqueue(more, .press)) return error.PreviewMissingMore;
    t.frame();
    try check(d.panel.show_actions and d.panel.ax_path != 0, "accessible More reveals path and document actions");
    if (!w.ax.adapter.?.enqueue(more, .press)) return error.PreviewMissingMore;
    t.frame();
    try check(!d.panel.show_actions and d.panel.ax_path == 0, "accessible More collapses and removes hidden path control");
    d.panel.field = .body;
    t.ctx.focus = 0;
    t.frame();
}
fn axGeneration(w: anytype, t: *ui.Tester, d: anytype, needle: []const u8) !void {
    const ax = @import("../accessibility.zig");
    const adapter = if (w.ax.adapter) |*value| value else return error.PreviewMissingAccessibility;
    var body: u64 = 0;
    var focused: usize = 0;
    for (adapter.snapshot.nodes[0..adapter.snapshot.count]) |node| {
        if (node.role == .document) {
            body = node.id;
            if (node.state & ax.State.read_only == 0) return error.PreviewEditableAccessibility;
        }
        if (node.state & ax.State.focused != 0) focused += 1;
    }
    try check(body != 0 and focused == 1, "AX exposes one read-only focused document with no terminal focus duplication");
    t.ctx.clipboard.write(t.ctx.clipboard.ctx, "AX private sentinel");
    if (!adapter.enqueue(body, .copy)) return error.PreviewAxQueueRejected;
    const generation = d.panel.model.generation;
    try d.panel.model.refresh();
    t.frame();
    try check(d.panel.model.generation > generation and std.mem.eql(u8, t.clipboard.items, "AX private sentinel"), "queued old-generation document AX copy is rejected before dispatch");
    try waitDocument(w, t, d.id, needle);
}
const FakeDrop = struct {
    fn attach(_: *anyopaque, _: @import("../application_drop.zig").Callback, _: ?*anyopaque, _: [*]u8, _: usize) ?*anyopaque {
        return @ptrFromInt(1);
    }
    fn detach(_: *anyopaque) void {}
    fn geometry(_: *anyopaque, _: f64, _: f64) void {}
    fn current(_: *anyopaque) bool {
        return true;
    }
    const adapter: @import("../application_drop.zig").Adapter = .{ .attach = attach, .detach = detach, .geometry = geometry, .current = current };
};
fn documentDrop(w: anytype, t: *ui.Tester, path: [:0]const u8, late_path: [:0]const u8) !void {
    const drop = @import("../application_drop.zig");
    const original = w.drop_bridge;
    w.drop_bridge = drop.Bridge.initWithAdapter(w.gpa, drop.hostFor(w), FakeDrop.adapter);
    defer {
        w.drop_bridge.?.deinit();
        w.drop_bridge = original;
    }
    const bridge = &w.drop_bridge.?;
    try bridge.attach(@ptrFromInt(1));
    t.frame();
    try bridge.publish(w.drop_panes[0..w.drop_pane_count], false);
    var rect: drop.Rect = undefined;
    var found = false;
    for (w.drop_panes[0..w.drop_pane_count]) |pane| if (pane.document != 0) {
        rect = pane.rect;
        found = true;
        break;
    };
    if (!found) return error.PreviewDropGeometryMissing;
    const x = rect.x + 8;
    const y = rect.y + 8;
    const entries = [_]?[*:0]const u8{path.ptr};
    const before = w.preview.count();
    if (!drop.Bridge.receive(bridge, @backingInt(drop.Phase.reserve), 81, null, 0, x, y, false) or !drop.Bridge.receive(bridge, @backingInt(drop.Phase.deliver), 81, &entries, 1, x, y, false)) return error.PreviewDropDelivery;
    try check(w.search_open and bridge.pending != null and bridge.pending.?.target.document != 0 and bridge.pending.?.target.session == 0 and w.preview.count() == before, "document drop remains routable while terminal Find is open and only queues the copied path");
    if (!bridge.drain()) return error.PreviewDropDrain;
    const tab = w.layout.tabs[w.layout.active_tab].id;
    const opened = w.preview.active(tab).?.id;
    t.frame();
    try check(w.preview.count() == before + 1 and bridge.pasted == 0, "main-thread document drop opens via real adapter and never PTY paste branch");
    try bridge.publish(w.drop_panes[0..w.drop_pane_count], false);
    const late = [_]?[*:0]const u8{late_path.ptr};
    if (!drop.Bridge.receive(bridge, @backingInt(drop.Phase.reserve), 82, null, 0, x, y, false) or !drop.Bridge.receive(bridge, @backingInt(drop.Phase.deliver), 82, &late, 1, x, y, false)) return error.PreviewDropDelivery;
    w.preview.close(w, opened);
    try check(!bridge.drain() and bridge.pasted == 0 and w.preview.count() == before, "closed-document pending drop is discarded instead of retargeted to active document or PTY");
    t.frame();
}
fn boundaryChecks(w: anytype, t: *ui.Tester, a: std.mem.Allocator, dir: []const u8) !void {
    const tab = w.layout.tabs[w.layout.active_tab].id;
    const literal = try std.fmt.allocPrintSentinel(a, "{s}/literal:12", .{dir}, 0);
    const fallback = try std.fmt.allocPrintSentinel(a, "{s}/literal", .{dir}, 0);
    const markdown = try std.fmt.allocPrintSentinel(a, "{s}/located.md", .{dir}, 0);
    const located = try std.fmt.allocPrint(a, "{s}:12", .{markdown});
    const png_path = try std.fmt.allocPrintSentinel(a, "{s}/corrupt.png", .{dir}, 0);
    defer for ([_][:0]const u8{ literal, fallback, markdown, png_path }) |path| {
        _ = std.c.unlink(path);
    };
    try write(literal, "literal colon path\n");
    try write(fallback, "WRONG fallback must not be read\n");
    try application.open(w, literal);
    const literal_id = w.preview.active(tab).?.id;
    try waitDocument(w, t, literal_id, "literal colon path");
    _ = std.c.unlink(literal);
    try w.preview.find(literal_id).?.panel.model.refresh();
    try waitStatus(w, t, literal_id, .missing);
    const literal_doc = w.preview.find(literal_id).?;
    try check(literal_doc.panel.model.stale and std.mem.indexOf(u8, literal_doc.panel.model.bytes, "literal colon path") != null, "successful literal colon filename never switches to numeric-location fallback after deletion");
    w.preview.close(w, literal_id);
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(a);
    try content.appendSlice(a, "# Located heading\n\n");
    for (0..24) |i| try content.appendSlice(a, try std.fmt.allocPrint(a, "line {d}\n", .{i + 1}));
    try write(markdown, content.items);
    try application.open(w, markdown);
    const markdown_id = w.preview.active(tab).?.id;
    try waitDocument(w, t, markdown_id, "Located heading");
    const before = w.preview.count();
    try application.open(w, located);
    const transient = w.preview.active(tab).?.id;
    const other_index: u8 = if (w.layout.active_tab == 0) 1 else 0;
    const other_tab = w.layout.tabs[other_index].id;
    const other_document = w.preview.active(other_tab).?.id;
    w.activateTab(other_index);
    var retired = false;
    for (0..600) |_| {
        step(t);
        if (w.preview.find(transient) == null) {
            retired = true;
            break;
        }
    }
    try check(retired and w.layout.tabs[w.layout.active_tab].id == other_tab and w.preview.active(other_tab).?.id == other_document and w.preview.find(markdown_id).?.panel.mode == .rendered, "late numeric fallback reuses hidden document without stealing workspace focus or source mode");
    w.activateTab(w.layout.tabIndex(tab).?);
    try application.open(w, markdown);
    t.frame();
    try application.open(w, located);
    var reused = false;
    for (0..600) |_| {
        step(t);
        const current = w.preview.active(tab) orelse continue;
        if (current.id == markdown_id and current.panel.mode == .source and current.panel.selection.caret > 0) {
            reused = true;
            break;
        }
    }
    try check(reused and w.preview.count() == before, "numeric source location fallback reuses existing Markdown document and stable ID");
    try @import("ui_check.zig").clickControl(&w.preview.find(markdown_id).?.panel, t, .toggle_source);
    try write(markdown, "# New heading\n\nchanged after location\n");
    try waitDocument(w, t, markdown_id, "changed after location");
    try check(w.preview.find(markdown_id).?.panel.mode == .rendered, "subsequent watcher update does not reapply old line location or force Source mode");
    w.preview.close(w, markdown_id);
    var pixels: [16 * 16 * 4]u8 = @splat(255);
    const png = try ui.png.encode(a, .{ .width = 16, .height = 16, .bytes = &pixels });
    try write(png_path, png);
    const live_before = if (w.graphics_store) |store| store.live_keys else 0;
    try application.open(w, png_path);
    const png_id = w.preview.active(tab).?.id;
    try waitDocument(w, t, png_id, "PNG");
    const image = w.preview.find(png_id).?;
    const revision = image.panel.model.revision;
    const key = image.panel.image_keys[0];
    const broken = try a.dupe(u8, png);
    broken[29] ^= 1;
    try write(png_path, broken);
    try image.panel.model.refresh();
    try waitStatus(w, t, png_id, .invalid_image);
    try check(w.graphics_store != null and image.panel.model.stale and image.panel.model.revision == revision and key != 0 and image.panel.image_keys[0] == key and std.mem.eql(u8, image.panel.model.bytes, png), "corrupt PNG update reports invalid_image while retaining last good CPU snapshot and shared image key");
    w.preview.close(w, png_id);
    try check(w.graphics_store.?.live_keys == live_before, "closing preview returns shared managed image accounting to its previous value");
}

fn serviceQueue(w: anytype, t: *ui.Tester, other: anytype, next_path: []const u8) !void {
    const host = w.host;
    const tab = w.layout.tabs[w.layout.active_tab].id;
    const a = w.preview.active(tab).?;
    const request: actions.Request = .{ .action = .font_up };
    host.active_id = w.id;
    a.panel.focused = true;
    a.panel.field = .body;
    const zoom_a = a.panel.zoom;
    const dropped_a = host.services.dropped;
    try host.services.enqueue(&request);
    try application.open(w, next_path);
    const b = w.preview.active(tab).?;
    const zoom_b = b.panel.zoom;
    t.frame();
    try check(host.services.dropped == dropped_a + 1 and a.panel.zoom == zoom_a and b.panel.zoom == zoom_b, "service queue captures document identity and rejects A to B retarget before execution");
    w.preview.close(w, b.id);
    a.panel.focused = false;
    w.syncFocus();
    host.active_id = w.id;
    const size = w.cfg.font_size;
    const dropped_terminal = host.services.dropped;
    try host.services.enqueue(&request);
    a.panel.focused = true;
    w.syncFocus();
    t.frame();
    try check(host.services.dropped == dropped_terminal + 1 and w.cfg.font_size == size and a.panel.zoom == zoom_a, "service terminal request is revoked when target window enters document focus");
    a.panel.focused = false;
    w.syncFocus();
    host.active_id = w.id;
    const dropped_other = host.services.dropped;
    try host.services.enqueue(&request);
    host.active_id = other.id;
    // Exercise timer screening before the destination window's normal drain.
    nano.runFor(0.005);
    t.frame();
    try check(host.services.dropped == dropped_other and w.cfg.font_size > size and application.focused(other), "queued terminal A action stays valid when another window B has document focus");
    w.cfg.font_size = size;
    host.active_id = w.id;
    a.panel.focused = true;
    a.panel.field = .body;
    w.syncFocus();
    t.frame();
}

fn resizeWorkspace(w: anytype, t: *ui.Tester, original_tab: u64, other_tab: u64) !void {
    const initial = w.preview.dockFor(original_tab).width;
    const rect = w.preview.rect;
    t.moveTo(rect.x + 1, rect.y + 64);
    t.ctx.pointerDown();
    t.frame();
    t.ctx.input.mouse.x -= 42;
    t.frame();
    try check(w.preview.resizing and w.preview.dockFor(original_tab).width > initial, "real pointer drag captures document dock resize origin");
    w.activateTab(w.layout.tabIndex(other_tab).?);
    t.frame();
    try check(!w.preview.resizing and w.preview.dockFor(original_tab).width == initial, "workspace change cancels resize and restores captured dock width");
    t.ctx.pointerUp();
    t.frame();
    w.activateTab(w.layout.tabIndex(original_tab).?);
    t.frame();
}

fn narrowSidebar(w: anytype, t: *ui.Tester) !void {
    const mode = w.cfg.workspace_navigation;
    const width = t.size.w;
    const height = t.size.h;
    w.cfg.workspace_navigation = .sidebar;
    t.resize(480, 540);
    const tab = w.layout.tabs[w.layout.active_tab].id;
    const d = w.preview.active(tab).?;
    const nav = w.navigation_rects.navigation;
    try check(w.navigation_rects.content.w == 0 and w.preview.rect.x >= nav.x + nav.w - 0.1 and d.panel.body_rect.x >= w.preview.rect.x and d.panel.body_rect.x + d.panel.body_rect.w <= 480, "sidebar narrow mode shares one bounded document rectangle and no overlapping terminal area");
    try t.screenshot(".cache/test-logs/preview-application-sidebar-narrow.png");
    w.cfg.workspace_navigation = mode;
    t.resize(width, height);
}

fn imeDiagnostic(w: anytype, t: *ui.Tester, stage: []const u8) void {
    const d = w.preview.active(w.layout.tabs[w.layout.active_tab].id);
    const edit_marked = if (t.ctx.edits.getPtr(t.ctx.focus)) |edit| edit.marked != null else false;
    const field_marked = if (t.ctx.focused_text) |field| field.marked != null else false;
    std.debug.print("PREVIEW_IME_DIAG stage={s} focused={any} field={s} ctxfocus={d} marked_id={d} edit_marked={any} field_marked={any} zoom={d} count={d} doc={d} pending_focus={d}\n", .{ stage, application.focused(w), if (d) |doc| @tagName(doc.panel.field) else "closed", t.ctx.focus, t.ctx.marked_text_id, edit_marked, field_marked, if (d) |doc| doc.panel.zoom else 0, w.preview.count(), if (d) |doc| doc.id else 0, w.preview.pending_focus });
}

fn exactRawBytes(output: []const u8) bool {
    const begin = "__PREVIEW_RESULT__";
    const finish = "__PREVIEW_DONE__";
    const start = (std.mem.indexOf(u8, output, begin) orelse return false) + begin.len;
    const end = std.mem.indexOf(u8, output, finish) orelse return false;
    if (end < start or std.mem.indexOfPos(u8, output, start, begin) != null or std.mem.indexOfPos(u8, output, end + finish.len, finish) != null) return false;
    var tokens = std.mem.tokenizeAny(u8, output[start..end], " \t\r\n\x0b\x0c");
    for ([_][]const u8{ "41", "42", "43", "44", "45" }) |expected| {
        if (!std.mem.eql(u8, tokens.next() orelse return false, expected)) return false;
    }
    return tokens.next() == null;
}

fn workspaceChecks(w: anytype, t: *ui.Tester, path: []const u8, terminal: u64, receiver: anytype, session_id: u64) !void {
    const file_tab = w.layout.tabs[w.layout.active_tab].id;
    const d = w.preview.active(file_tab).?;
    const document_id = d.id;
    try waitDocument(w, t, document_id, "Document 2");
    const count = w.layout.tab_count;
    const panes = w.host.paneCount();
    try application.openWorkspace(w, path);
    try check(w.layout.tab_count == count and w.preview.active(file_tab).?.id == document_id, "reopening a file workspace reuses its identity and tab");
    t.frame();
    const geometry = w.navigationGeometry(t.size.w, t.size.h);
    try check(w.preview.rect.w > 1000 and geometry.content.w == 0 and !w.layout.visible(0), "file workspace occupies the main content with no terminal hit area");
    t.typeText("WORKSPACE_LEAK");
    action(w, t, .{ .action = .send_bytes, .args = .{ .bytes = try @import("../action_bytes.zig").parse("text:HIDDEN_PTY_LEAK") } });
    action(w, t, .{ .action = .horizontal });
    try check(w.active() == null and w.host.paneCount() == panes and receiver.id == session_id, "file input send and split actions cannot reach or replace a hidden terminal");
    w.activateTab(w.layout.tabIndex(terminal).?);
    try application.open(w, path);
    const side = w.preview.active(terminal).?;
    side.panel.zoom = 1.3;
    const side_id = side.id;
    action(w, t, .{ .action = .move_preview_to_workspace });
    const moved_tab = w.layout.tabs[w.layout.active_tab].id;
    try check(w.layout.isDocument(w.layout.active_tab) and w.preview.active(moved_tab).?.id == side_id and side.panel.zoom == 1.3 and w.preview.active(terminal) == null and w.host.paneCount() == panes, "moving side preview to workspace preserves document identity and reading state without a PTY");
    w.preview.close(w, side_id);
    w.activateTab(w.layout.tabIndex(file_tab).?);
    w.layout.togglePin(file_tab);
    t.frame();
    try check(w.layout.tabs[w.layout.active_tab].id == file_tab and w.preview.active(file_tab).?.id == document_id, "pinning file workspace preserves document ownership");
    w.layout.togglePin(file_tab);
    try filesOnlyRestore(w, path);
    const mode = w.cfg.workspace_navigation;
    w.cfg.workspace_navigation = .sidebar;
    w.sidebar.collapsed = false;
    w.sidebar.focused = false;
    t.frame();
    try t.screenshot(".cache/test-logs/file-workspace-fidelity.png");
    w.cfg.workspace_navigation = mode;
}
fn workspaceCapacity(w: anytype, t: *ui.Tester, path: []const u8, terminal: u64) !void {
    const panes = w.host.paneCount();
    try application.openWorkspace(w, path);
    const id = w.preview.active(w.layout.tabs[w.layout.active_tab].id).?.id;
    try check(panes == 16 and w.active() == null and w.host.paneCount() == 16, "independent file workspace opens beside sixteen live PTYs");
    action(w, t, .{ .action = .close_tab });
    try check(w.preview.find(id) == null and w.host.paneCount() == 16, "closing file workspace removes only its document and preserves all PTYs");
    w.activateTab(w.layout.tabIndex(terminal).?);
}
fn filesOnlyRestore(w: anytype, path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(w.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const persistence = @import("../workspace_layout.zig");
    var layout: @import("../layout.zig").Layout = .{};
    defer layout.deinit();
    const first = try layout.newDocument();
    const missing = try layout.newDocument();
    layout.activate(0);
    const missing_path = try std.fmt.allocPrint(a, "{s}/missing-file.md", .{std.fs.path.dirname(path).?});
    const files = [_]persistence.File{ .{ .tab = first, .path = path }, .{ .tab = missing, .path = missing_path } };
    const records = [_]persistence.Record{.{ .id = 4, .layout = layout, .files = &files }};
    const fixture = try std.fmt.allocPrintSentinel(a, "{s}/file-workspaces.json", .{std.fs.path.dirname(path).?}, 0);
    defer _ = std.c.unlink(fixture);
    try write(fixture, try std.json.Stringify.valueAlloc(a, persistence.Document{ .active = 4, .next_window_id = 5, .windows = &records }, .{}));
    var restored: @TypeOf(w.host.*) = .{ .gpa = w.gpa, .arena = a, .app = w.app, .cfg = w.cfg, .state_path = fixture, .read_path = fixture, .demo = true, .hold = true };
    restored.services.init(&restored);
    defer {
        restored.deinit();
        nano.runFor(0.025);
    }
    try check(try restored.restore(), "files-only persisted window restores without a terminal");
    const file_window = restored.active().?;
    try check(restored.paneCount() == 0 and file_window.active() == null and file_window.layout.tabs[file_window.layout.active_tab].id == first and file_window.preview.count() == 2, "restored file paths and active workspace survive including a missing file without spawning a shell");
    restored.demo = false;
    restored.save();
    restored.demo = true;
    const saved = (try config.read(a, fixture, 512 * 1024)).?;
    const decoded = try persistence.decode(a, saved, w.cfg.profiles.len);
    try check(decoded.windows.len == 1 and decoded.windows[0].files.len == 2 and decoded.windows[0].layout.isDocument(0), "files-only save roundtrips both file records and no terminal nodes");
}
