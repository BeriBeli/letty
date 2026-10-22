//! Opt-in owned PTYs and offscreen portable frames. No GUI/clipboard polling.
const std = @import("std");
const nano = @import("nanoui");
const ui = nano.ui;
const c = @import("platform_ffi.zig");
const vt = @import("vt.zig");
const damage = ui.CpuDamage;
extern "c" fn lt_micros() u64;
extern "c" fn lt_shape_memory(*usize, *usize) void;
const Snapshot = struct {
    phase: []const u8,
    rss: u64 = 0,
    pss: ?u64 = null,
    peak_rss: u64 = 0,
    sessions: usize = 0,
    vt_heap: usize = 0,
    vt_graphics_heap: usize = 0,
    vt_page_virtual: usize = 0,
    vt_page_resident_estimate: usize = 0,
    tx_capacity: usize = 0,
    font_logical_bytes: usize = 0,
    font_unique_bytes: usize = 0,
    font_loaded_faces: usize = 0,
    shaper_owned_source_bytes: usize = 0,
    shaper_borrowed_source_bytes: usize = 0,
    glyph_pixels: usize = 0,
    image_pixels: usize = 0,
    frame_arena_capacity: usize = 0,
    shaped_glyph_bytes: usize = 0,
    instance_capacity: usize = 0,
    cpu_pixels: usize = 0,
};
fn emit(gpa: std.mem.Allocator, comptime tag: []const u8, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(gpa, value, .{});
    defer gpa.free(json);
    std.debug.print(tag ++ " {s}\n", .{json});
}
fn addTester(out: *Snapshot, t: *ui.Tester, pixels: *damage.Surface) void {
    const stats = t.text.db.stats();
    out.font_logical_bytes += stats.loaded_bytes;
    out.font_loaded_faces += stats.loaded_faces;
    out.glyph_pixels += t.text.atlas.pixels.len;
    out.image_pixels += t.text.images.pixels.len + t.text.images.managed_bytes + t.text.images.kept_bytes;
    out.frame_arena_capacity += t.ctx.arena.queryCapacity();
    inline for (.{ &t.text.layouts, &t.text.previous }) |map| {
        var iterator = map.valueIterator();
        while (iterator.next()) |layout| out.shaped_glyph_bytes += layout.glyphs.len * @sizeOf(@TypeOf(layout.glyphs[0]));
    }
    out.instance_capacity += t.instances.capacity * @sizeOf(@TypeOf(t.instances.items[0]));
    out.cpu_pixels += pixels.bytes.len;
}
fn snapshot(s: anytype, phase: []const u8, testers: []const *ui.Tester, pixels: []damage.Surface) !void {
    var out: Snapshot = .{ .phase = phase };
    for (s.host.windows) |opt| if (opt) |window| {
        for (window.sessions) |entry| if (entry) |session| {
            const memory = vt.memoryInfo(session.vt);
            out.sessions += 1;
            out.vt_heap += memory.heap_core;
            out.vt_graphics_heap += memory.heap_graphics;
            out.vt_page_virtual += memory.page_virtual;
            out.vt_page_resident_estimate += memory.page_resident_estimate;
            out.tx_capacity += session.tx.bytes.len;
        };
    };
    for (testers, pixels) |tester, *backing| addTester(&out, tester, backing);
    out.font_unique_bytes = out.font_logical_bytes;
    if (comptime @hasDecl(@TypeOf(testers[0].text.db), "sharedSourceBytes")) out.font_unique_bytes = testers[0].text.db.sharedSourceBytes();
    var pss: u64 = 0;
    c.lt_memory_usage(&out.rss, &pss, &out.peak_rss);
    if (out.rss == 0 or out.peak_rss == 0) return error.MemorySnapshotUnavailable;
    if (@import("builtin").os.tag == .linux) out.pss = pss;
    lt_shape_memory(&out.shaper_owned_source_bytes, &out.shaper_borrowed_source_bytes);
    try emit(s.gpa, "MEMORY", out);
}
fn render(t: *ui.Tester, backing: *damage.Surface) !void {
    var pictures = t.text.images.pictures();
    pictures.textures = t.ctx.textures.items;
    _ = try backing.render(t.gpa, t.instances.items, t.text.atlas.mask(), pictures, .{
        .width = @intFromFloat(t.size.w),
        .height = @intFromFloat(t.size.h),
        .scale = 1,
        .clear = ui.gpu.color4(t.theme.background),
        .glyph_generation = t.text.atlas.generation,
        .image_generation = t.text.images.generation,
    });
}
fn action(s: anytype, t: *ui.Tester, backing: *damage.Surface, value: @import("actions.zig").Action) !u64 {
    const start = lt_micros();
    s.menu_actions[0] = .{ .action = value };
    s.menu_action_count = 1;
    t.frame();
    try render(t, backing);
    return lt_micros() - start;
}
fn timing(gpa: std.mem.Allocator, name: []const u8, times: []u64) !void {
    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    try emit(gpa, "MEMORY_TIMING", .{ .operation = name, .samples = times.len, .median_us = times[times.len / 2], .p95_us = times[(times.len - 1) * 95 / 100], .max_us = times[times.len - 1] });
}
pub fn run(s: anytype, view: ui.View, theme: ui.Theme) !void {
    s.cfg.confirm_close = .never;
    s.cfg.cursor_blink = false;
    s.window_focused = true;
    var main: ui.Tester = undefined;
    try main.init(s.gpa, view, .{ .width = 1000, .height = 680, .scale = 1, .theme = theme });
    defer main.deinit();
    var pixels: [4]damage.Surface = @splat(.{});
    defer for (&pixels) |*p| p.deinit(s.gpa);
    try render(&main, &pixels[0]);
    try snapshot(s, "one_tab", &.{&main}, pixels[0..1]);
    var creation: [15]u64 = undefined;
    for (&creation) |*time| {
        time.* = try action(s, &main, &pixels[0], .tab);
        nano.runFor(0.01);
    }
    try timing(s.gpa, "new_tab_first_frame", &creation);
    try snapshot(s, "sixteen_tabs_idle", &.{&main}, pixels[0..1]);
    const line = "log 中文 e\xcc\x81 abcdefghijklmnopqrstuvwxyz 0123456789 needle\r\n";
    for (s.sessions) |opt| if (opt) |session| {
        for (0..1000) |_| try vt.feed(session.vt, line);
        session.refresh();
    };
    main.frame();
    try render(&main, &pixels[0]);
    try snapshot(s, "sixteen_tabs_history", &.{&main}, pixels[0..1]);
    var switches: [120]u64 = undefined;
    for (0..16) |_| _ = try action(s, &main, &pixels[0], .next_tab);
    for (&switches) |*time| time.* = try action(s, &main, &pixels[0], .next_tab);
    try timing(s.gpa, "switch_tab", &switches);
    var others: [3]ui.Tester = undefined;
    var windows: [3]@TypeOf(s) = undefined;
    var count: usize = 0;
    defer {
        for (0..count) |i| {
            others[i].deinit();
            s.host.closeWindow(windows[i]);
        }
        s.host.active_id = s.id;
    }
    for (0..3) |i| {
        windows[i] = try s.host.create(false);
        try others[i].init(s.gpa, .init(windows[i], @TypeOf(s.*).view), .{ .width = 1000, .height = 680, .scale = 1, .theme = theme });
        count += 1;
        try render(&others[i], &pixels[i + 1]);
    }
    try snapshot(s, "four_windows", &.{ &main, &others[0], &others[1], &others[2] }, &pixels);
    for (0..count) |i| {
        others[i].deinit();
        s.host.closeWindow(windows[i]);
        pixels[i + 1].deinit(s.gpa);
    }
    count = 0;
    s.host.active_id = s.id;
    _ = try action(s, &main, &pixels[0], .close_other_tabs);
    nano.runFor(0.05);
    main.frame();
    try render(&main, &pixels[0]);
    try snapshot(s, "closed_to_one_tab", &.{&main}, pixels[0..1]);
    // A controlled transient allocation models one exceptionally large frame.
    // It is deliberately separate from normal terminal/history measurements.
    const transient = try main.ctx.alloc().alloc(u8, 32 * 1024 * 1024);
    @memset(transient, 0x5a);
    try snapshot(s, "transient_frame_32mib", &.{&main}, pixels[0..1]);
    for (0..180) |_| {
        main.frame();
        try render(&main, &pixels[0]);
    }
    try snapshot(s, "recovered_frame", &.{&main}, pixels[0..1]);
    var recovery_switches: [120]u64 = undefined;
    _ = try action(s, &main, &pixels[0], .tab);
    for (&recovery_switches) |*time| time.* = try action(s, &main, &pixels[0], .next_tab);
    try timing(s.gpa, "switch_after_peak", &recovery_switches);
    for (s.sessions) |opt| if (opt) |session| if (session.fatal) return error.TerminalFailed;
    std.debug.print("Memory checks completed.\n", .{});
}
