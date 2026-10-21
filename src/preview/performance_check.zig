//! Explicit offscreen measurements of the production file worker and reader.
//! No OS window/PTY/clipboard. Payload accounting is not process RSS or PSS;
//! idle measures an unregistered Tester, not a real window's frame scheduler.
const std = @import("std");
const temporary_root = if (@import("builtin").os.tag == .macos) "/private/tmp" else "/tmp";
const nano = @import("nanoui");
const ui = nano.ui;
const model = @import("model.zig");
const panel = @import("panel.zig");
const hooks = @import("prepare_hooks.zig");
const text = @import("read_only_text.zig");
extern "c" fn lt_micros() u64;
extern "c" fn lt_cpu_micros() u64;
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn usleep(c_uint) c_int;
extern "c" fn lt_config_fixture_write([*:0]const u8, [*]const u8, usize, c_uint) c_int;

// Instrument the production callback without substituting preparation logic.
// The worker owns calls; acquire/release makes the published duration explicit.
const Timing = struct {
    prepare_us: std.atomic.Value(u64) = .init(0),
    calls: std.atomic.Value(u32) = .init(0),
    fn prepare(raw: ?*anyopaque, path: [*:0]const u8, bytes: [*]const u8, length: usize, kind: c_int, out: *?*anyopaque) callconv(.c) c_int {
        const self: *Timing = @ptrCast(@alignCast(raw.?));
        const start = lt_micros();
        const result = hooks.hooks.prepare.?(hooks.hooks.context, path, bytes, length, kind, out);
        self.prepare_us.store(lt_micros() - start, .release);
        _ = self.calls.fetchAdd(1, .release);
        return result;
    }
    fn release(_: ?*anyopaque, value: *anyopaque) callconv(.c) void {
        hooks.hooks.release.?(hooks.hooks.context, value);
    }
    fn loaderHooks(self: *Timing) model.Hooks {
        return .{ .context = self, .prepare = prepare, .release = release };
    }
};
const View = struct {
    reader: *panel.Panel,
    draws: u64 = 0,
    fn draw(self: *View, ctx: *ui.Context) void {
        self.draws += 1; // Includes interaction rebuild passes, not just frames.
        const rect: ui.Rect = .{ .w = ctx.size.w, .h = ctx.size.h };
        _ = self.reader.prepareInput(ctx, rect);
        _ = self.reader.draw(ctx, rect);
    }
};
const Samples = struct {
    total: u64 = 0,
    max: u64 = 0,
    fn add(self: *Samples, value: u64) void {
        self.total += value;
        self.max = @max(self.max, value);
    }
};
pub fn run(init: std.process.Init) !void {
    _ = init;
    const a = std.heap.page_allocator;
    var directory_buf = (temporary_root ++ "/letty-preview-perf-XXXXXX\x00").*;
    const directory = mkdtemp(@ptrCast(&directory_buf)) orelse return error.PreviewPerfDirectory;
    defer _ = std.c.rmdir(directory);
    // Each fixture is released before the next case, including its file worker.
    try runCase(a, std.mem.span(directory), .text, "plain_utf8_10000");
    try runCase(a, std.mem.span(directory), .markdown, "markdown_gfm_1000");
}
fn source(a: std.mem.Allocator, kind: model.Kind) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(a);
    var numbered: [256]u8 = undefined;
    if (kind == .text) {
        for (0..10000) |index| try bytes.appendSlice(a, try std.fmt.bufPrint(&numbered, "{d:0>5} Read-only UTF-8 中文 👩‍💻 é — a bounded document row with words for native shaping.\n", .{index}));
    } else {
        for (0..1000) |index| {
            try bytes.appendSlice(a, try std.fmt.bufPrint(&numbered, "# Section {d} 中文\n\n", .{index}));
            try bytes.appendSlice(a, "Readable **strong**, *emphasis*, ~~removed~~ and `inline code` with 中文 👩‍💻 é. " ++
                "The document remains selectable across headings, prose, lists, quotations and code. " ++
                "This longer paragraph exercises real glyph shaping and width-aware prose wrapping. " ++
                "A [local anchor](#section-0-中文) preserves the current owned document.\n\n" ++
                "> Quoted UTF-8 content keeps its readable block prefix.\n\n" ++
                "- [x] Completed task\n- [ ] Pending task\n\n" ++
                "```zig\nconst answer = 42;\n    // preserved indentation\n```\n\n" ++
                "| Name | Value |\n| --- | --- |\n| 中文 | **42** |\n\n");
        }
    }
    return bytes.toOwnedSlice(a);
}
fn waitReady(state: *model.State, a: std.mem.Allocator) !void {
    const deadline = lt_micros() + 15_000_000;
    while (lt_micros() < deadline) {
        while (try state.drain(a)) {}
        if (state.status != .loading) {
            if (state.status != .ready and state.status != .watch_error) {
                std.debug.print("PREVIEW_PERF_ERROR status={s}\n", .{@tagName(state.status)});
                return error.PreviewPerfLoad;
            }
            if (state.prepared == null) return error.PreviewPerfMissingPrepared;
            return;
        }
        _ = usleep(1000);
    }
    return error.PreviewPerfTimeout;
}
fn textBytes(doc: *const text.Document) usize {
    return doc.text.len + doc.lines.len * @sizeOf(text.Line) + doc.boundaries.len;
}
fn runCase(a: std.mem.Allocator, directory: []const u8, kind: model.Kind, name: []const u8) !void {
    const path = try std.fmt.allocPrintSentinel(a, "{s}/document.{s}", .{ directory, if (kind == .markdown) "md" else "txt" }, 0);
    defer a.free(path);
    defer _ = std.c.unlink(path);
    // Source generation and fixture IO are deliberately outside open timings.
    const file_bytes = block: {
        const bytes = try source(a, kind);
        defer a.free(bytes);
        if (lt_config_fixture_write(path, bytes.ptr, bytes.len, 0o600) != 0) return error.PreviewPerfWrite;
        break :block bytes.len;
    };
    var timing: Timing = .{};
    var reader: panel.Panel = .{ .opened = true, .focused = false, .mode = if (kind == .markdown) .rendered else .source };
    reader.model = .{ .id = 1, .hooks = timing.loaderHooks() };
    // The completed prepare result is consumed before leaving this scope. The
    // fixture is not changed until cancellation; release never uses Timing.
    defer reader.deinit(a);
    const open_start = lt_micros();
    try reader.model.open(a, path);
    try waitReady(&reader.model, a);
    const open_ready_us = lt_micros() - open_start;
    if (reader.model.kind != kind or reader.model.bytes.len != file_bytes) return error.PreviewPerfUnexpectedContent;
    const source_lines = reader.model.lines;
    const loader_bytes = reader.model.owned.?.raw.allocation;
    const apply_start = lt_micros();
    reader.apply(hooks.take(reader.model.takePrepared().?), reader.model.revision);
    reader.path.set(path);
    const apply_us = lt_micros() - apply_start;
    const prepared = &reader.prepared.?;
    if (prepared.prepare_error != null or prepared.image_count != 0) return error.PreviewPerfInvalidPrepared;
    if (kind == .markdown and (prepared.markdown == null or prepared.markdown.?.truncated)) return error.PreviewPerfMarkdown;
    const prepared_text_bytes = textBytes(&prepared.source) + if (prepared.rendered) |*doc| textBytes(doc) else @as(usize, 0);
    const markdown_arena_capacity = if (prepared.markdown) |doc| doc.arena.queryCapacity() else @as(usize, 0);
    var view: View = .{ .reader = &reader };
    var tester: ui.Tester = undefined;
    const tester_start = lt_micros();
    try tester.init(a, .init(&view, View.draw), .{ .width = 960, .height = 700, .scale = 1, .theme = ui.Theme.light });
    defer tester.deinit();
    const tester_init_first_frame_us = lt_micros() - tester_start;
    if (reader.row_y.items.len != reader.document().?.lines.len + 1) return error.PreviewPerfLayout;
    var warm: Samples = .{};
    var node_max: usize = tester.ctx.nodes.items.len;
    const warm_frame_start = tester.ctx.frame;
    for (0..100) |_| {
        const start = lt_micros();
        tester.frame();
        warm.add(lt_micros() - start);
        node_max = @max(node_max, tester.ctx.nodes.items.len);
    }
    const warm_frames = tester.ctx.frame - warm_frame_start;
    const scroll_before = reader.scroll_y;
    const scroll_frame_start = tester.ctx.frame;
    var scroll: Samples = .{};
    for (0..60) |_| {
        const start = lt_micros();
        tester.scroll(reader.body_rect.x + 24, reader.body_rect.y + 24, -180);
        scroll.add(lt_micros() - start);
        node_max = @max(node_max, tester.ctx.nodes.items.len);
    }
    const scroll_frames = tester.ctx.frame - scroll_frame_start;
    if (reader.scroll_y <= scroll_before or scroll_frames != 60) return error.PreviewPerfScroll;
    const idle_frames_before = tester.ctx.frame;
    const idle_draws_before = view.draws;
    const cpu_before = lt_cpu_micros();
    const wall_before = lt_micros();
    // An empty native run loop may return immediately. Keep servicing it until
    // two actual monotonic seconds pass, with a bounded sleep preventing spin.
    while (lt_micros() - wall_before < 2_000_000) {
        nano.runFor(0.05);
        _ = usleep(1000);
    }
    const idle_wall_us = lt_micros() - wall_before;
    const idle_cpu_us = lt_cpu_micros() - cpu_before;
    const idle_frames = tester.ctx.frame - idle_frames_before;
    const idle_draws = view.draws - idle_draws_before;
    std.debug.print("PREVIEW_PERF {{\"case\":\"{s}\",\"scope\":\"tester_without_window\",\"images\":false,\"file_bytes\":{d},\"source_bytes\":{d},\"source_lines\":{d},\"display_lines\":{d},\"open_ready_us\":{d},\"prepare_us\":{d},\"prepare_calls\":{d},\"apply_us\":{d},\"tester_init_first_frame_us\":{d},\"loader_retained_bytes\":{d},\"prepared_text_payload_bytes\":{d},\"markdown_arena_capacity_bytes\":{d},\"row_geometry_capacity_bytes\":{d},\"managed_image_bytes\":{d},\"visible_node_count\":{d},\"visible_node_max\":{d},\"warm_frames\":{d},\"frame_mean_us\":{d},\"frame_max_us\":{d},\"scroll_frames\":{d},\"scroll_60_frames_us\":{d},\"scroll_mean_us\":{d},\"scroll_max_us\":{d},\"scroll_y\":{d},\"idle_wall_us\":{d},\"idle_cpu_us\":{d},\"idle_frame_count\":{d},\"idle_draw_count\":{d}}}\n", .{
        name,                       file_bytes,                       reader.model.bytes.len,      source_lines,                                                                                  reader.document().?.lines.len,
        open_ready_us,              timing.prepare_us.load(.acquire), timing.calls.load(.acquire), apply_us,                                                                                      tester_init_first_frame_us,
        loader_bytes,               prepared_text_bytes,              markdown_arena_capacity,     reader.row_y.capacity * @sizeOf(f32) + reader.visual_rows.capacity * @sizeOf(panel.VisualRow), tester.text.images.managed_bytes,
        tester.ctx.nodes.items.len, node_max,                         warm_frames,                 warm.total / 100,                                                                              warm.max,
        scroll_frames,              scroll.total,                     scroll.total / 60,           scroll.max,                                                                                    reader.scroll_y,
        idle_wall_us,               idle_cpu_us,                      idle_frames,                 idle_draws,
    });
}
