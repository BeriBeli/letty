//! Bounded same-process lifecycle and live-PTY load; only owned hidden UI.
const std = @import("std");
const nano = @import("nanoui");
const vt = @import("vt.zig");
const c = @import("platform_ffi.zig");
extern "c" fn lt_cpu_micros() u64;
fn expect(ok: bool, label: []const u8) !void {
    if (!ok) {
        std.debug.print("FAIL STABILITY {s}\n", .{label});
        return error.StabilityFailure;
    }
}
fn matches(session: anytype, text: []const u8) !bool {
    if (vt.lt_vt_search(session.vt, text.ptr, text.len) != 0) return error.SearchSet;
    var total: usize = 0;
    for (0..1024) |_| {
        const pending = vt.lt_vt_search_tick(session.vt, &total);
        if (pending < 0) return error.SearchTick;
        if (pending == 0) return total > 0;
    }
    return error.SearchTimeout;
}
pub fn run(s: anytype, view: nano.ui.View, theme: nano.ui.Theme, cycles: u16) !void {
    if (cycles < 8 or cycles > 256) return error.InvalidStabilityCycles;
    s.cfg.confirm_close = .never;
    s.cfg.copy_on_select = .none;
    s.window_focused = true;
    var tester: nano.ui.Tester = undefined;
    try tester.init(s.gpa, view, .{ .width = 1000, .height = 680, .theme = theme });
    defer tester.deinit();
    const survivor = s.active().?;
    const survivor_id = survivor.id;
    const survivor_pid = survivor.pid;
    const start = c.lt_millis();
    const cpu_start = lt_cpu_micros();
    for (0..cycles) |cycle| {
        try s.add(.horizontal);
        const slot = s.layout.active_pane;
        const session = s.active().?;
        const pid = session.pid;
        var command: [512]u8 = undefined;
        // The literal result never occurs in echoed command text. Input is
        // queued while the PTY is producing output, then acknowledged by shell.
        const output = try std.fmt.bufPrint(&command, "awk 'BEGIN {{for(i=0;i<4000;i++) print i,\"中文 needle payload abcdefghijklmnopqrstuvwxyz\"}}'; printf 'READY_%s\\n' '{d}'\n", .{cycle});
        try expect(session.send(output), "bounded producer command queued");
        nano.runFor(0.002);
        const input = try std.fmt.bufPrint(&command, "printf 'INPUT_%s\\n' '{d}'\n", .{cycle});
        try expect(session.send(input), "input queued during output");
        var marker_buf: [32]u8 = undefined;
        const marker = try std.fmt.bufPrint(&marker_buf, "INPUT_{d}", .{cycle});
        const deadline = c.lt_millis() + 10000;
        var acknowledged = false;
        while (c.lt_millis() < deadline) {
            nano.runFor(0.01);
            tester.frame();
            try expect(!session.fatal and !vt.lt_vt_failed(session.vt), "live VT has no fatal error");
            if (try matches(session, marker)) {
                acknowledged = true;
                break;
            }
        }
        try expect(acknowledged, "continuous output does not starve input");
        vt.lt_vt_search_close(session.vt);
        vt.lt_vt_scroll(session.vt, -30);
        vt.lt_vt_select(session.vt, 0, 0, 0);
        vt.lt_vt_select(session.vt, 12, 1, 1);
        var copy: [4096]u8 = undefined;
        var len: usize = 0;
        try expect(vt.lt_vt_copy(session.vt, &copy, copy.len, &len) == 0 and len > 0, "selection copies retained output");
        tester.resize(if (cycle % 2 == 0) 900 else 1000, 680);
        tester.frame();
        session.reportFocus(false);
        session.reportFocus(true);
        s.close(slot);
        tester.frame();
        nano.runFor(0.2);
        try expect(s.active().?.id == survivor_id and s.active().?.pid == survivor_pid and s.host.paneCount() == 1, "close reclaims pane and preserves survivor");
        std.debug.print("STABILITY {{\"cycle\":{d},\"retired_pid\":{d},\"active_ptys\":1,\"elapsed_ms\":{d}}}\n", .{ cycle + 1, pid, c.lt_millis() - start });
    }
    std.debug.print("STABILITY_DONE {{\"backend\":\"{s}\",\"cycles\":{d},\"elapsed_ms\":{d},\"cpu_us\":{d},\"survivor_pid\":{d}}}\n", .{ vt.backend_name, cycles, c.lt_millis() - start, lt_cpu_micros() - cpu_start, survivor_pid });
}
