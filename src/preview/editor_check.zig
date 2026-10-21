//! Private temporary files and offscreen text-input checks; never user documents.
const std = @import("std");
const ui = @import("nanoui").ui;
const panel = @import("panel.zig");
const Editor = @import("editor.zig").Editor;
const Job = @import("edit_job.zig").Job;
const disk = @import("../config_edit.zig");
const a = std.heap.page_allocator;
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn usleep(c_uint) c_int;
extern "c" fn lt_config_fixture_write([*:0]const u8, [*]const u8, usize, c_uint) c_int;
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} editor {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.EditorCheckFailed;
}
fn write(path: [:0]const u8, bytes: []const u8) !void {
    if (lt_config_fixture_write(path, bytes.ptr, bytes.len, 0o600) != 0) return error.FixtureWrite;
}
fn wait(job: *Job) !void {
    for (0..5000) |_| {
        if (job.done.load(.acquire)) return;
        _ = usleep(1000);
    }
    return error.EditorJobTimeout;
}
const View = struct {
    p: *panel.Panel,
    fn draw(self: *View, ctx: *ui.Context) void {
        _ = self.p.prepareInput(ctx, .{ .w = ctx.size.w, .h = ctx.size.h });
        _ = self.p.draw(ctx, .{ .w = ctx.size.w, .h = ctx.size.h });
    }
};
pub fn run() !void {
    const root = if (@import("builtin").os.tag == .macos) "/private/tmp/letty-editor-XXXXXX" else "/tmp/letty-editor-XXXXXX";
    var temp: [root.len:0]u8 = root.*;
    const dir = mkdtemp(&temp) orelse return error.FixtureDirectory;
    defer _ = std.c.rmdir(dir);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/document.md", .{std.mem.span(dir)}, 0);
    defer a.free(path);
    defer _ = std.c.unlink(path);
    try write(path, "\xef\xbb\xbf# Title\r\n中文\r\n");
    const editor = try Editor.capture(path);
    defer editor.release();
    try check(std.mem.eql(u8, editor.buffer.text(), "# Title\n中文\n"), "normalizes BOM and CRLF only in draft");
    editor.buffer.set("# Edited\n你好\n");
    try editor.record();
    const encoded = try editor.encoded();
    defer a.free(encoded);
    try check(std.mem.eql(u8, encoded, "\xef\xbb\xbf# Edited\r\n你好\r\n"), "preserves BOM, CRLF and UTF-8 on save");
    editor.undo(false);
    try check(!editor.dirty and std.mem.eql(u8, editor.buffer.text(), editor.baseline), "undo restores clean baseline");
    editor.undo(true);
    try check(editor.dirty, "redo restores edited draft");
    const job = try Job.start(path, editor);
    defer job.release();
    try wait(job);
    try check(job.failure == null, "background save commits without blocking UI");
    var saved = try disk.Native.captureWithLimit(a, path, @import("editor.zig").limit);
    defer saved.deinit();
    try check(std.mem.eql(u8, saved.bytes, encoded) and saved.identity.mode & 0o777 == 0o600, "saved bytes and file permissions preserved");
    const conflict = try Job.start(path, editor);
    defer conflict.release();
    try wait(conflict);
    try check(conflict.failure != null and conflict.failure.? == error.ConcurrentChange and editor.dirty, "stale snapshot cannot overwrite file and retains draft");
    const big = try a.alloc(u8, 40 * 1024);
    defer a.free(big);
    @memset(big, 'x');
    for (big, 0..) |*ch, i| if (i % 80 == 79) {
        ch.* = '\n';
    };
    try write(path, big);
    const large = try Editor.capture(path);
    defer large.release();
    try check(large.buffer.len == big.len, "caller-owned text buffer edits files larger than 16 KiB");
    const full = try a.alloc(u8, @import("editor.zig").limit);
    defer a.free(full);
    @memset(full, 'a');
    large.buffer.set(full);
    _ = large.buffer.replace(1, 2, "too large");
    try check(large.buffer.overflow and std.mem.eql(u8, large.buffer.text(), full), "oversize replacement leaves all original bytes intact");
    try write(path, "# Hello\n");
    var p: panel.Panel = .{};
    defer p.deinit(a);
    p.opened = true;
    p.focused = true;
    p.model.status = .ready;
    p.model.kind = .markdown;
    p.apply(try panel.Prepared.init(a, .markdown, "# Hello\n"), 1);
    p.editor = try Editor.capture(path);
    var view: View = .{ .p = &p };
    var t: ui.Tester = undefined;
    try t.init(a, .init(&view, View.draw), .{ .width = 640, .height = 480, .scale = 1 });
    defer t.deinit();
    t.typeText("中文");
    t.key(.enter);
    try check(std.mem.startsWith(u8, p.editor.?.buffer.text(), "中文\n"), "native editor inserts Unicode and Return newline");
    t.textOps(&.{.{ .set_marked = .{ .text = "に", .sel_start = 3, .sel_len = 0 } }});
    t.textOps(&.{.{ .insert = "日本" }});
    try check(std.mem.indexOf(u8, p.editor.?.buffer.text(), "日本") != null, "IME composition commits to draft");
    try check(p.hasUnsaved(), "dirty draft blocks destructive close");
    const draft = try a.dupe(u8, p.editor.?.buffer.text());
    defer a.free(draft);
    p.apply(try panel.Prepared.init(a, .markdown, "external update\n"), 2);
    try check(std.mem.eql(u8, p.editor.?.buffer.text(), draft), "watch refresh never replaces editor draft");
    try @import("ui_check.zig").clickControl(&p, &t, .save);
    try check(p.edit_request == .save, "footer Save produces explicit save request");
    try t.screenshot(if (@import("builtin").os.tag == .macos) "/private/tmp/letty-editor.png" else "/tmp/letty-editor.png");
}
