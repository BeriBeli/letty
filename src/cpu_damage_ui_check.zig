//! Exercises real raster kernels and persistent BGRA output, without opening a
//! window. Synthetic texels test CPU sampling, not font or X11 correctness.
const std = @import("std");
const ui = @import("nanoui").ui;
pub fn run(s: anytype) !void {
    const count = try ui.CpuDamage.check(s.gpa);
    std.debug.print("CPU_DAMAGE {{\"checks\":{d},\"pixel_comparison\":\"full CPU reference\",\"x11\":\"not measured\"}}\n", .{count});
}

const vt = @import("vt.zig");
const Session = @import("session.zig").Session;
const TerminalView = @import("terminal_view.zig").View;
const Config = @import("config.zig").Config;
const PaneFixture = struct {
    sessions: [16]Session = undefined,
    views: [16]TerminalView = @splat(.{}),
    count: usize = 0,
    grid: usize,
    cfg: Config = .{},
    overlay: bool = false,
    fn deinit(f: *PaneFixture, gpa: std.mem.Allocator) void {
        for (0..f.count) |i| {
            f.views[i].deinit(gpa);
            vt.destroy(f.sessions[i].vt);
        }
    }
    fn draw(f: *PaneFixture, ctx: *ui.Context) void {
        const font = ctx.text.font(.{ .size = f.cfg.font_size, .mono = true });
        const cw = @round(ctx.text.layout("M", .{ .size = f.cfg.font_size, .mono = true }).width * ctx.scale) / ctx.scale;
        const ch = @round((font.ascent + font.descent + font.leading) * ctx.scale) / ctx.scale;
        const side: f32 = @floatFromInt(f.grid);
        ui.column(ctx, .{ .width = .fill, .height = .fill });
        defer ui.end(ctx);
        for (0..f.grid) |row| {
            ui.row(ctx, .{ .width = .fill, .height = .fill });
            for (0..f.grid) |col| {
                const index = row * f.grid + col;
                _ = ctx.open(.{ .width = .fill, .height = .fill, .clip = true, .background = .hex(f.cfg.background) }, null);
                f.views[index].draw(&f.sessions[index], ctx, f.cfg, cw, ch, index == 0, .{ .x = @as(f32, @floatFromInt(col)) * 1000 / side, .y = @as(f32, @floatFromInt(row)) * 680 / side, .w = 1000 / side, .h = 680 / side });
                ctx.end();
            }
            ui.end(ctx);
        }
        if (f.overlay) {
            ui.column(ctx, .{ .absolute = true, .offset = .{ .x = 120, .y = 70 }, .width = .{ .px = 300 }, .height = .{ .px = 140 }, .clip = true, .radius = 14, .padding = .all(14), .background = ui.Color.hex(0x223344).alpha(0.75), .shadow = .{ .y = 4, .blur = 12, .color = ui.Color.black.alpha(0.3) } });
            ui.text(ctx, "Search overlay 0123456789", .{ .color = .white });
            ui.end(ctx);
        }
    }
};
fn noReply(_: ?*anyopaque, _: [*]const u8, _: usize) callconv(.c) void {}
fn micros() u64 {
    return @intFromFloat(ui.clock.now() * 1_000_000);
}
const Phase = enum { idle_before, output, scroll, search, selection, cursor, overlay, idle_after };
const Meter = struct {
    mutation_us: u64 = 0,
    tree_us: u64 = 0,
    full_us: u64 = 0,
    dirty_us: u64 = 0,
    none_frames: usize = 0,
    full_frames: usize = 0,
    rect_frames: usize = 0,
    cleared_pixels: usize = 0,
    replayed_instances: usize = 0,
    cursor_visible_frames: usize = 0,
};

/// Actual VT -> TerminalView -> Tester -> portable atlas -> same-instance
/// full/dirty CPU draws, alternated every sample. No real PTY, user window or
/// clipboard; no X11/presentation timing. Native CoreText is explicitly skipped
/// because its atlas is not a CPU mask. Root can expose a dedicated CLI switch.
pub fn benchmark(s: anytype, panes: u8) !void {
    const Atlas = @TypeOf(@as(ui.Tester, undefined).text.atlas);
    if (comptime !@hasDecl(Atlas, "mask")) {
        std.debug.print("CPU_DAMAGE_PERF {{\"panes\":{d},\"status\":\"skipped\",\"reason\":\"native CoreText atlas has no CPU mask\"}}\n", .{panes});
    } else {
        if (panes != 1 and panes != 4 and panes != 16) return error.InvalidPaneCount;
        const gpa = s.gpa;
        const grid: usize = if (panes == 1) 1 else if (panes == 4) 2 else 4;
        var fixture: PaneFixture = .{ .grid = grid };
        defer fixture.deinit(gpa);
        for (0..panes) |i| {
            const cols: u16 = @intCast(112 / grid);
            const rows: u16 = @intCast(32 / grid);
            const terminal = try vt.create(gpa, s.app.io, cols, rows, 100000, 16 * 1024 * 1024, noReply, null);
            fixture.sessions[i] = .{ .id = i + 1, .gpa = gpa, .vt = terminal, .cols = cols, .rows = rows, .tx = undefined, .notify_ctx = null, .notify = undefined };
            fixture.count += 1;
            vt.lt_vt_colors(terminal, fixture.cfg.foreground, fixture.cfg.background);
            if (vt.lt_vt_settings(terminal, 1, false, 100000, 16 * 1024 * 1024) != 0) return error.VtSettingsFailed;
            try vt.feed(terminal, "\x1b[?25l");
        }
        const history_start = micros();
        var line: [192]u8 = undefined;
        for (0..20000) |i| {
            const value = try std.fmt.bufPrint(&line, "\x1b[38;2;120;180;220mrow {d:0>5} needle 中文 e\xcc\x81 ffi -> 0123456789\x1b[0m\r\n", .{i});
            try vt.feed(fixture.sessions[i % panes].vt, value);
        }
        const history_us = micros() - history_start;
        var tester: ui.Tester = undefined;
        try tester.init(gpa, .init(&fixture, PaneFixture.draw), .{ .width = 1000, .height = 680, .scale = 1, .theme = @import("appearance.zig").theme(fixture.cfg) });
        defer tester.deinit();
        tester.dt = 0; // Hold animation/cursor clock fixed; mutations are explicit.
        tester.frame();
        const reference = try gpa.alloc(u8, 1000 * 680 * 4);
        defer gpa.free(reference);
        const full_pixels: ui.gpu.Pixels = .{ .bytes = reference, .width = 1000, .height = 680 };
        var persistent: ui.CpuDamage.Surface = .{};
        defer persistent.deinit(gpa);
        _ = try persistent.render(gpa, tester.instances.items, tester.text.atlas.mask(), tester.text.images.pictures(), .{ .width = 1000, .height = 680, .scale = 1, .clear = ui.gpu.color4(tester.ctx.theme.background), .glyph_generation = tester.text.atlas.generation, .image_generation = tester.text.images.generation });
        var search_us: u64 = 0;
        var matches_total: usize = 0;
        inline for (std.meta.tags(Phase)) |phase| {
            if (phase == .search) {
                const search_start = micros();
                for (fixture.sessions[0..fixture.count]) |session| {
                    if (vt.lt_vt_search(session.vt, "needle", 6) != 0) return error.SearchFailed;
                    var matches: usize = 0;
                    var ticks: usize = 0;
                    while (true) {
                        const pending = vt.lt_vt_search_tick(session.vt, &matches);
                        if (pending < 0) return error.SearchFailed;
                        if (pending == 0) break;
                        ticks += 1;
                        if (ticks > 100000) return error.SearchTimeout;
                    }
                    matches_total += matches;
                }
                search_us = micros() - search_start;
                if (matches_total == 0) return error.MissingSearchResults;
            }
            if (phase == .selection or phase == .idle_after) {
                for (fixture.sessions[0..fixture.count]) |session| {
                    vt.lt_vt_search_close(session.vt);
                    vt.lt_vt_clear_selection(session.vt);
                    try vt.feed(session.vt, "\x1b[?25l");
                }
                fixture.overlay = false;
                tester.frame();
                _ = try persistent.render(gpa, tester.instances.items, tester.text.atlas.mask(), tester.text.images.pictures(), .{ .width = 1000, .height = 680, .scale = 1, .clear = ui.gpu.color4(tester.ctx.theme.background), .glyph_generation = tester.text.atlas.generation, .image_generation = tester.text.images.generation });
            }
            if (phase == .cursor) {
                for (fixture.sessions[0..fixture.count]) |session| {
                    vt.lt_vt_search_close(session.vt);
                    vt.lt_vt_clear_selection(session.vt);
                    vt.lt_vt_bottom(session.vt);
                    try vt.feed(session.vt, "\x1b[?25h\x1b[2;1H");
                }
                tester.frame();
                _ = try persistent.render(gpa, tester.instances.items, tester.text.atlas.mask(), tester.text.images.pictures(), .{ .width = 1000, .height = 680, .scale = 1, .clear = ui.gpu.color4(tester.ctx.theme.background), .glyph_generation = tester.text.atlas.generation, .image_generation = tester.text.images.generation });
            }
            var meter: Meter = .{};
            for (0..12) |sample| {
                const mutation_start = micros();
                for (fixture.sessions[0..fixture.count]) |session| switch (phase) {
                    .output => {
                        const value = try std.fmt.bufPrint(&line, "output {d:0>5} needle 中文 e\xcc\x81 ffi 0123456789\r\n", .{sample});
                        try vt.feed(session.vt, value);
                    },
                    .scroll => vt.lt_vt_scroll(session.vt, -1),
                    .search => vt.lt_vt_search_next(session.vt, false),
                    .selection => {
                        vt.lt_vt_select(session.vt, 1, 0, 0);
                        vt.lt_vt_select(session.vt, @intCast(2 + sample), 1, 1);
                    },
                    .cursor => {
                        const value = try std.fmt.bufPrint(&line, "\x1b[?25h\x1b[2;{d}H", .{2 + sample});
                        try vt.feed(session.vt, value);
                    },
                    else => {},
                };
                if (phase == .overlay) fixture.overlay = sample % 2 == 0;
                meter.mutation_us += micros() - mutation_start;
                const tree_start = micros();
                tester.frame();
                meter.tree_us += micros() - tree_start;
                if (phase == .cursor) {
                    const cursor = fixture.views[0].cursor;
                    if (!cursor.visible or cursor.y != 1 or cursor.x != 1 + sample) return error.CursorNotActuallyVisible;
                    meter.cursor_visible_frames += 1;
                }
                const mask = tester.text.atlas.mask();
                const pictures = tester.text.images.pictures();
                const frame: ui.CpuDamage.Frame = .{ .width = 1000, .height = 680, .scale = 1, .clear = ui.gpu.color4(tester.ctx.theme.background), .glyph_generation = tester.text.atlas.generation, .image_generation = tester.text.images.generation };
                var result: ui.CpuDamage.Result = undefined;
                if (sample % 2 == 0) {
                    const full_start = micros();
                    ui.raster.draw(full_pixels, tester.instances.items, mask, pictures, 1, tester.ctx.theme.background);
                    meter.full_us += micros() - full_start;
                    const dirty_start = micros();
                    result = try persistent.render(gpa, tester.instances.items, mask, pictures, frame);
                    meter.dirty_us += micros() - dirty_start;
                } else {
                    const dirty_start = micros();
                    result = try persistent.render(gpa, tester.instances.items, mask, pictures, frame);
                    meter.dirty_us += micros() - dirty_start;
                    const full_start = micros();
                    ui.raster.draw(full_pixels, tester.instances.items, mask, pictures, 1, tester.ctx.theme.background);
                    meter.full_us += micros() - full_start;
                }
                if (!std.mem.eql(u8, reference, persistent.bytes)) return error.CpuPanePixelMismatch;
                if (phase == .cursor and result.damage == .none) return error.VisibleCursorDidNotDamagePixels;
                switch (result.damage) {
                    .none => meter.none_frames += 1,
                    .full => meter.full_frames += 1,
                    .rect => meter.rect_frames += 1,
                }
                meter.cleared_pixels += result.work.cleared_pixels;
                meter.replayed_instances += result.work.drawn_instances;
                for (fixture.sessions[0..fixture.count]) |session| if (vt.lt_vt_failed(session.vt)) return error.VtFailed;
            }
            if ((phase == .idle_before or phase == .idle_after) and meter.none_frames != 12) return error.StaticCpuFrameNotIdle;
            std.debug.print("CPU_DAMAGE_PERF {{\"status\":\"passed\",\"panes\":{d},\"phase\":\"{s}\",\"frames\":12,\"width\":1000,\"height\":680,\"scale\":1,\"history_lines_total\":20000,\"history_feed_us\":{d},\"search_work_us\":{d},\"matches\":{d},\"mutation_us\":{d},\"frame_tree_us\":{d},\"full_cpu_us\":{d},\"dirty_cpu_us\":{d},\"cursor_visible_frames\":{d},\"none_frames\":{d},\"full_frames\":{d},\"rect_frames\":{d},\"dirty_cleared_pixels\":{d},\"full_cleared_pixels\":8160000,\"replayed_instances\":{d},\"pixels_equal\":true,\"x11_presentation\":\"not measured\"}}\n", .{ panes, @tagName(phase), history_us, search_us, matches_total, meter.mutation_us, meter.tree_us, meter.full_us, meter.dirty_us, meter.cursor_visible_frames, meter.none_frames, meter.full_frames, meter.rect_frames, meter.cleared_pixels, meter.replayed_instances });
        }
    }
}
