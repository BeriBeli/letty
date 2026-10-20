//! Explicit, bounded headless measurements, not an application polling loop.
const std = @import("std");
const nano = @import("nanoui");
const ui = nano.ui;
const vt_api = @import("vt.zig");
const c = @import("platform_ffi.zig");
extern "c" fn lt_cpu_micros() u64;
extern "c" fn lt_micros() u64;
fn reply(_: ?*anyopaque, _: [*]const u8, _: usize) callconv(.c) void {}
pub fn run(s: anytype, view: ui.View, theme: ui.Theme, count: u8, startup_ms: u64) !void {
    if (count != 1 and count != 4 and count != 16) return error.InvalidPaneCount;
    s.window_focused = true;
    var t: ui.Tester = undefined;
    try t.init(s.gpa, view, .{ .width = 1000, .height = 680, .theme = theme });
    defer t.deinit();
    const start = lt_micros();
    for (1..count) |i| {
        s.menu_actions[0] = .{ .action = if (i % 2 == 1) .horizontal else .vertical };
        s.menu_action_count = 1;
        t.frame();
    }
    const deadline = c.lt_millis() + 15000;
    while (c.lt_millis() < deadline) {
        nano.runFor(0.01);
        t.frame();
        var completed: usize = 0;
        for (s.sessions) |opt| if (opt) |p| if (p.events.bells > 0) {
            completed += 1;
        };
        if (completed == count) break;
    }
    var completed: usize = 0;
    for (s.sessions) |opt| if (opt) |p| if (p.events.bells > 0) {
        completed += 1;
    };
    if (completed != count) return error.ProducerTimeout;
    const completion = lt_micros() - start;
    var times: [60]u64 = undefined;
    var total: u64 = 0;
    for (&times) |*time| {
        const before = lt_micros();
        t.frame();
        time.* = lt_micros() - before;
        total += time.*;
    }
    std.mem.sort(u64, &times, {}, struct {
        fn less(_: void, a: u64, b: u64) bool {
            return a < b;
        }
    }.less);
    const cpu_before = lt_cpu_micros();
    const wall_before = lt_micros();
    nano.runFor(2);
    const idle_cpu = lt_cpu_micros() - cpu_before;
    const idle_wall = lt_micros() - wall_before;
    const vt = try vt_api.create(s.gpa, s.app.io, 80, 24, 100000, 64 * 1024 * 1024, reply, null);
    defer vt_api.lt_vt_free(vt);
    const line = "log 中文 e\xcc\x81 abcdefghijklmnopqrstuvwxyz needle\r\n";
    const history_start = lt_micros();
    for (0..100000) |_| try vt_api.feed(vt, line);
    const history_feed = lt_micros() - history_start;
    const search_start = lt_micros();
    if (vt_api.lt_vt_search(vt, "needle", 6) != 0) return error.SearchFailed;
    var matches: usize = 0;
    var slices: usize = 0;
    var max_search_tick: u64 = 0;
    while (true) {
        const tick_start = lt_micros();
        const pending = vt_api.lt_vt_search_tick(vt, &matches);
        max_search_tick = @max(max_search_tick, lt_micros() - tick_start);
        if (pending < 0) return error.SearchFailed;
        if (pending == 0) break;
        slices += 1;
        if (slices > 100000) return error.SearchTimeout;
    }
    if (matches == 0 or vt_api.lt_vt_failed(vt)) return error.MissingSearchResults;
    const search_us = lt_micros() - search_start;
    // Real pane viewport scrolling plus complete nanoui frame construction.
    const session = s.active().?;
    const scroll_start = lt_micros();
    for (0..60) |_| {
        vt_api.lt_vt_scroll(session.vt, -1);
        t.frame();
    }
    const scroll_us = lt_micros() - scroll_start;
    std.debug.print("PERF {{\"panes\":{d},\"startup_ms\":{d},\"producer_complete_us\":{d},\"frame_mean_us\":{d},\"frame_p95_us\":{d},\"idle_cpu_us\":{d},\"idle_wall_us\":{d},\"history_feed_us\":{d},\"search_us\":{d},\"search_tick_max_us\":{d},\"search_slices\":{d},\"matches\":{d},\"scroll_60_frames_us\":{d}}}\n", .{ count, startup_ms, completion, total / times.len, times[56], idle_cpu, idle_wall, history_feed, search_us, max_search_tick, slices, matches, scroll_us });
}
