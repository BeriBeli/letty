//! Real native VT -> pane graphics.prepare -> View.draw -> nanoui pixels.
//! Integrated in ui_check: no PTY, Window or OS clipboard. The same assertions
//! run with Metal and the portable raster using their actual pixel output.
const std = @import("std");
const ui = @import("nanoui").ui;
const vt = @import("vt.zig");
const Session = @import("session.zig").Session;
const View = @import("terminal_view.zig").View;
const Config = @import("config.zig").Config;
const Bridge = @import("nanoui_graphics_resources.zig");
const cw: f32 = 12;
const ch: f32 = 24;
const png_red = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==";
const Replies = struct {
    data: [4096]u8 = undefined,
    len: usize = 0,
    overflow: bool = false,
    fn receive(ptr: ?*anyopaque, data: [*]const u8, len: usize) callconv(.c) void {
        const self: *Replies = @ptrCast(@alignCast(ptr.?));
        if (len > self.data.len - self.len) {
            self.overflow = true;
            return;
        }
        @memcpy(self.data[self.len..][0..len], data[0..len]);
        self.len += len;
    }
    fn has(self: *const Replies, bytes: []const u8) bool {
        return !self.overflow and std.mem.indexOf(u8, self.data[0..self.len], bytes) != null;
    }
};
const Fixture = struct {
    gpa: std.mem.Allocator,
    sessions: [2]Session = undefined,
    replies: [2]Replies = @splat(.{}),
    views: [2]View = @splat(.{}),
    initialized: usize = 0,
    store: ?*Bridge.Store = null,
    visible: [2]bool = .{ true, true },
    active: [2]bool = .{ false, false },
    errors: [2]?anyerror = @splat(null),
    cfg: Config = .{ .kitty_graphics = true, .font_size = 14, .background = 0, .foreground = 0xeeeeee, .cursor = 0xeeeeee, .explicit_cursor = true, .selection_foreground = 0xffffff, .selection_background = 0x336699, .explicit_selection_fg = true, .explicit_selection_bg = true, .padding_x = .{ 0, 0 }, .padding_y = .{ 0, 0 }, .ui_accent = 0x774411 },
    fn init(self: *Fixture, io: std.Io) !void {
        errdefer self.destroyTerminals();
        for (0..2) |i| {
            const terminal = try vt.create(self.gpa, io, 12, 4, 200, 1024 * 1024, Replies.receive, &self.replies[i]);
            self.sessions[i] = .{ .id = i + 1, .gpa = self.gpa, .vt = terminal, .cols = 12, .rows = 4, .tx = undefined, .notify_ctx = null, .notify = undefined };
            self.initialized += 1;
            try vt.configureGraphics(terminal, true);
            if (vt.lt_vt_resize(terminal, 12, 4, 12, 24) != 0) return error.GraphicsFixtureResize;
            vt.lt_vt_colors(terminal, self.cfg.foreground, self.cfg.background);
            var palette: [16]u32 = undefined;
            for (self.cfg.palette, 0..) |v, j| palette[j] = v;
            vt.lt_vt_palette(terminal, &palette, self.cfg.cursor);
            try self.clean(i);
        }
    }
    fn destroyTerminals(self: *Fixture) void {
        for (0..self.initialized) |i| vt.destroy(self.sessions[i].vt);
        self.initialized = 0;
    }
    fn destroyViews(self: *Fixture) void {
        for (&self.views) |*view| view.deinit(self.gpa);
    }
    fn feed(self: *Fixture, index: usize, bytes: []const u8) !void {
        try vt.feed(self.sessions[index].vt, bytes);
    }
    fn clean(self: *Fixture, index: usize) !void {
        vt.lt_vt_reset(self.sessions[index].vt);
        try self.feed(index, "\x1b[?25l\x1b[0m\x1b[H");
        self.active[index] = false;
    }
    fn rect(ctx: *const ui.Context, index: usize) ui.Rect {
        const half = ctx.size.w / 2;
        return .{ .x = @as(f32, @floatFromInt(index)) * half, .w = half, .h = ctx.size.h };
    }
    fn draw(self: *Fixture, ctx: *ui.Context) void {
        const store = self.store orelse return; // Tester's init runs one frame.
        self.errors = @splat(null);
        // Prepare ALL panes before emitting any raw-image nodes. No later
        // sync may remove resources referenced by an earlier pane's tree.
        for (0..2) |i| {
            if (!self.visible[i]) {
                self.views[i].graphics.deactivate();
                continue;
            }
            self.views[i].graphics.prepare(&self.sessions[i], ctx, self.cfg, cw, ch, rect(ctx, i), store) catch |err| {
                self.errors[i] = err;
            };
        }
        for (0..2) |i| {
            const r = rect(ctx, i);
            _ = ctx.open(.{ .absolute = true, .offset = .{ .x = r.x, .y = r.y }, .width = .{ .px = r.w }, .height = .{ .px = r.h }, .clip = true, .background = ui.Color.hex(self.cfg.background) }, null);
            if (self.visible[i]) self.views[i].draw(&self.sessions[i], ctx, self.cfg, cw, ch, self.active[i], r);
            ctx.end();
        }
    }
    fn frame(self: *Fixture, tester: *ui.Tester) !void {
        tester.frame();
        for (self.errors) |maybe| if (maybe) |err| return err;
        for (self.views) |view| if (view.graphics.error_name != null) return error.GraphicsLayerFailed;
    }
    fn key(self: *const Fixture, index: usize) ?u64 {
        const renderer = self.views[index].graphics.renderer orelse return null;
        if (renderer.command_count == 0) return null;
        return renderer.commands[0].key;
    }
    fn transmit(self: *Fixture, pane: usize, id: u32, format: u32, width: u32, height: u32, columns: u16, rows: u16, z: i32, encoded: []const u8) !void {
        const command = try std.fmt.allocPrint(self.gpa, "\x1b_Ga=T,f={d},s={d},v={d},i={d},c={d},r={d},C=1,z={d};{s}\x1b\\", .{ format, width, height, id, columns, rows, z, encoded });
        defer self.gpa.free(command);
        try self.feed(pane, command);
    }
    fn solid(self: *Fixture, pane: usize, id: u32, encoded: []const u8, z: i32) !void {
        try self.transmit(pane, id, 24, 1, 1, 4, 2, z, encoded);
    }
    fn big(self: *Fixture, pane: usize, id: u32) !void {
        // Real RGB protocol data, not a fabricated renderer image. 3MiB
        // storage ->4MiB owned RGBA, within each image and parser cap.
        const raw = try self.gpa.alloc(u8, 1024 * 1024 * 3);
        defer self.gpa.free(raw);
        var pos: usize = 0;
        while (pos < raw.len) : (pos += 3) @memcpy(raw[pos..][0..3], &[_]u8{ 255, 0, 0 });
        const encoded = try self.gpa.alloc(u8, std.base64.standard.Encoder.calcSize(raw.len));
        defer self.gpa.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, raw);
        try self.transmit(pane, id, 24, 1024, 1024, 4, 2, 0, encoded);
    }
};
fn check(ok: bool, label: []const u8, count: *usize) !void {
    std.debug.print("{s} UI M9 {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.TerminalGraphicsUiCheck;
    count.* += 1;
}
fn near(actual: u32, expected: u32) bool {
    inline for (.{ 0, 8, 16 }) |shift| {
        const a: i32 = @intCast((actual >> shift) & 255);
        const b: i32 = @intCast((expected >> shift) & 255);
        if (@abs(a - b) > 3) return false;
    }
    return true;
}
fn pixel(pixels: ui.gpu.Pixels, x: usize, y: usize) u32 {
    std.debug.assert(x < pixels.width and y < pixels.height);
    const bytes = pixels.bytes[(y * pixels.width + x) * 4 ..][0..4];
    return (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[1]) << 8) | bytes[0];
}
fn color(t: *ui.Tester, x: usize, y: usize, expected: u32) !bool {
    const pixels = try t.render(t.gpa);
    defer pixels.deinit(t.gpa);
    return near(pixel(pixels, x, y), expected);
}
fn redCount(t: *ui.Tester, width: usize, height: usize) !usize {
    const pixels = try t.render(t.gpa);
    defer pixels.deinit(t.gpa);
    var result: usize = 0;
    for (0..height) |y| for (0..width) |x| {
        if (near(pixel(pixels, x, y), 0xff0000)) result += 1;
    };
    return result;
}

pub fn run(s: anytype) !void {
    var count: usize = 0;
    var f: Fixture = .{ .gpa = s.gpa };
    try f.init(s.app.io);
    defer f.destroyTerminals();
    var tester: ui.Tester = undefined;
    try tester.init(s.gpa, .init(&f, Fixture.draw), .{ .width = 384, .height = 120, .scale = 1, .theme = @import("appearance.zig").theme(f.cfg) });
    defer tester.deinit();
    var store = Bridge.Store.init(&tester.text);
    defer store.deinit();
    f.store = &store;
    defer {
        // Store/Image ownership must end before Tester's text/atlas. Avoid
        // retaining any draw tree/instances carrying the removed raw keys.
        f.destroyViews();
        f.store = null;
        tester.instances.clearRetainingCapacity();
        tester.ctx.nodes.clearRetainingCapacity();
    }
    try f.solid(0, 11, "/wAA", 0);
    try f.frame(&tester);
    try check(try color(&tester, 6, 6, 0xff0000), "RGB direct protocol reaches actual pane pixels", &count);
    try f.feed(0, "\x1b_Ga=q,f=24,s=1,v=1,i=91;/wAA\x1b\\");
    try check(f.replies[0].has("i=91;OK"), "image query keeps the real host PTY reply effect", &count);
    try f.transmit(0, 11, 32, 1, 1, 4, 2, 0, "AP8AgA==");
    try f.frame(&tester);
    try check(try color(&tester, 6, 6, 0x008000), "RGBA alpha composes premultiplied pixels over pane background", &count);
    try f.transmit(0, 11, 100, 1, 1, 4, 2, 0, png_red);
    try f.frame(&tester);
    try check(try color(&tester, 6, 6, 0xff0000), "real PNG decoder reaches actual pane pixels", &count);
    const previous_key = f.key(0).?;
    try f.solid(0, 11, "AP8A", 0);
    try f.frame(&tester);
    try check(try color(&tester, 6, 6, 0x00ff00) and f.key(0).? != previous_key and store.live_keys == 1, "same-ID revision replaces and frees the old managed key", &count);
    try f.feed(0, "\x1b_Ga=d,d=I,i=11\x1b\\");
    try f.frame(&tester);
    try check(try color(&tester, 6, 6, 0) and store.live_keys == 0, "protocol delete removes both pixels and resource ownership", &count);

    try f.feed(0, "\x1b_Ga=T,f=24,s=2,v=1,i=11,c=4,r=2,C=1,m=1;/wAA\x1b\\");
    try f.frame(&tester);
    try check(store.live_keys == 0 and try color(&tester, 6, 6, 0), "incomplete direct chunk never uploads or paints a partial image", &count);
    try f.feed(0, "\x1b_Gm=0;AAD/\x1b\\");
    try f.frame(&tester);
    try check(store.live_keys == 1 and try color(&tester, 6, 6, 0xff0000) and try color(&tester, 42, 6, 0x0000ff), "completed direct chunks reach matching source pixels", &count);
    const complete_key = f.key(0).?;
    try f.transmit(0, 12, 100, 1, 1, 4, 2, 0, "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAMAAAAoyzS7AAAACklEQVR4nGNgAAAAAgABSK+kcQAAAABJRU5ErkJggg==");
    try f.frame(&tester);
    try check(f.key(0).? == complete_key and store.live_keys == 1 and try color(&tester, 6, 6, 0xff0000) and !vt.lt_vt_failed(f.sessions[0].vt), "malformed PNG palette is rejected while prior image and terminal survive", &count);
    try f.transmit(0, 11, 100, 1, 1, 4, 2, 0, "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAMAAAAoyzS7AAAAA1BMVEX/AAAZ4gk3AAAACklEQVR4nGNgBAAAAwACS/Xd6gAAAABJRU5ErkJggg==");
    try f.frame(&tester);
    try check(store.live_keys == 0 and try color(&tester, 6, 6, 0) and !vt.lt_vt_failed(f.sessions[0].vt), "invalid same-ID PNG replacement releases the old image without fabricated black pixels", &count);
    try f.transmit(0, 11, 100, 1, 1, 4, 2, 0, "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAMAAAAoyzS7AAAAA1BMVEX/AAAZ4gk3AAAACklEQVR4nGNgAAAAAgABSK+kcQAAAABJRU5ErkJggg==");
    try f.frame(&tester);
    try check(store.live_keys == 1 and try color(&tester, 6, 6, 0xff0000), "valid indexed PNG recovers after a rejected replacement", &count);
    const removals_before = store.diagnostics.removals;
    const uploads_before = store.diagnostics.uploads;
    for (0..24) |revision| {
        try f.solid(0, 11, if (revision % 2 == 0) "AP8A" else "/wAA", 0);
        try f.frame(&tester);
        if (store.live_keys != 1 or tester.text.images.managed_bytes != 4) return error.GraphicsRevisionResourceLeak;
    }
    try check(store.diagnostics.uploads - uploads_before == 24 and store.diagnostics.removals - removals_before == 24 and try color(&tester, 6, 6, 0xff0000), "24 protocol revisions replace pixels with constant decoded ownership", &count);

    // Device scale changes VT cell pixels as well as nanoui render scale.
    // A two-color source crop catches scaling source coordinates twice.
    try f.clean(0);
    tester.scale = 2;
    tester.text.setScale(2);
    if (vt.lt_vt_resize(f.sessions[0].vt, 12, 4, 24, 48) != 0) return error.GraphicsFixtureResize;
    try f.feed(0, "\x1b_Ga=T,f=24,s=2,v=1,i=11,c=4,r=2,C=1,x=1,w=1;/wAAAAD/\x1b\\");
    try f.frame(&tester);
    const scaled = f.views[0].graphics.renderer.?.commands[0];
    {
        const pixels = try tester.render(tester.gpa);
        defer pixels.deinit(tester.gpa);
        std.debug.print("M9_SCALE_DIAGNOSTIC {{\"scale\":{d},\"frame_width\":{d},\"frame_height\":{d},\"source\":[{d},{d},{d},{d}],\"destination\":[{d},{d},{d},{d}],\"clip\":[{d},{d},{d},{d}],\"samples_rgb\":[\"{x:0>6}\",\"{x:0>6}\",\"{x:0>6}\",\"{x:0>6}\",\"{x:0>6}\",\"{x:0>6}\"]}}\n", .{
            tester.scale,                pixels.width,              pixels.height,
            scaled.source_pixels.x,      scaled.source_pixels.y,    scaled.source_pixels.width,
            scaled.source_pixels.height, scaled.destination.x,      scaled.destination.y,
            scaled.destination.width,    scaled.destination.height, scaled.clip.x,
            scaled.clip.y,               scaled.clip.width,         scaled.clip.height,
            pixel(pixels, 0, 12),        pixel(pixels, 12, 12),     pixel(pixels, 47, 12),
            pixel(pixels, 84, 12),       pixel(pixels, 95, 12),     pixel(pixels, 108, 12),
        });
    }
    try check(scaled.source_pixels.x == 1 and scaled.source_pixels.width == 1 and scaled.destination.width == 48 and try color(&tester, 12, 12, 0x0000ff) and try color(&tester, 84, 12, 0x0000ff) and try color(&tester, 108, 12, 0), "2x device scale crops source pixels once and preserves placement in points", &count);
    tester.scale = 1;
    tester.text.setScale(1);
    if (vt.lt_vt_resize(f.sessions[0].vt, 12, 4, 12, 24) != 0) return error.GraphicsFixtureResize;

    try f.clean(0);
    try f.feed(0, "\x1b[44mMMMM\x1b[0m\x1b[H");
    try f.solid(0, 11, "/wAA", std.math.minInt(i32));
    try f.frame(&tester);
    try check(try color(&tester, 6, 2, f.cfg.palette[4]), "below-background image stays behind opaque SGR cells", &count);
    try f.solid(0, 11, "/wAA", -1);
    try f.frame(&tester);
    try check(try color(&tester, 6, 2, 0xff0000) and try redCount(&tester, 48, 24) < 48 * 24, "below-text image covers cell background while real glyphs remain above", &count);
    try f.solid(0, 11, "/wAA", 0);
    try f.frame(&tester);
    try check(try redCount(&tester, 48, 24) == 48 * 24, "above-text image covers glyphs across the full placed row", &count);
    vt.lt_vt_select(f.sessions[0].vt, 0, 0, 0);
    vt.lt_vt_select(f.sessions[0].vt, 3, 0, 1);
    try f.frame(&tester);
    try check(try color(&tester, 6, 2, f.cfg.selection_background), "selection overlay stays above a positive-z image", &count);
    vt.lt_vt_clear_selection(f.sessions[0].vt);
    if (vt.lt_vt_search(f.sessions[0].vt, "MMMM", 4) != 0) return error.GraphicsSearchStart;
    var found: usize = 0;
    var completed = false;
    for (0..64) |_| {
        if (vt.lt_vt_search_tick(f.sessions[0].vt, &found) == 0) {
            completed = true;
            break;
        }
    }
    try f.frame(&tester);
    try check(completed and found == 1 and try color(&tester, 6, 2, 0x774411), "incremental search overlay stays above image pixels", &count);
    vt.lt_vt_search_close(f.sessions[0].vt);
    f.active[0] = true;
    try f.feed(0, "\x1b[H\x1b[2 q\x1b[?25h");
    try f.frame(&tester);
    try check(try color(&tester, 6, 2, f.cfg.cursor), "active block cursor covers a positive-z image", &count);

    try f.clean(0);
    try f.transmit(0, 11, 24, 1, 2, 4, 4, 0, "/wAAAP8A");
    try f.feed(0, "\x1b[4;1H\n");
    try f.frame(&tester);
    const clipped = f.views[0].graphics.renderer.?.commands[0];
    try check(clipped.destination.y == 0 and clipped.source_pixels.y > 0 and try color(&tester, 6, 60, 0x00ff00) and try color(&tester, 6, 84, 0), "negative scrolled placement crops source and destination without stretching", &count);
    if (vt.lt_vt_resize(f.sessions[0].vt, 6, 4, 12, 24) != 0) return error.GraphicsFixtureResize;
    f.sessions[0].cols = 6;
    try f.clean(0);
    try f.transmit(0, 11, 24, 1, 1, 12, 2, 0, "/wAA");
    tester.resize(320, 120);
    try f.frame(&tester);
    try check(try color(&tester, 6, 6, 0xff0000) and try color(&tester, 90, 6, 0), "VT and Tester resize clip the upload to the current pane grid", &count);
    if (vt.lt_vt_resize(f.sessions[0].vt, 12, 4, 12, 24) != 0) return error.GraphicsFixtureResize;
    f.sessions[0].cols = 12;
    tester.resize(384, 120);
    try f.clean(0);
    try f.solid(0, 11, "/wAA", 0);
    try f.frame(&tester);
    const primary_key = f.key(0).?;
    try f.feed(0, "\x1b[?1049h\x1b[H\x1b[?25l");
    try f.solid(0, 11, "AP8A", 0);
    try f.frame(&tester);
    try check(try color(&tester, 6, 6, 0x00ff00) and f.key(0).? != primary_key and store.live_keys == 1, "alternate screen cannot alias a primary image key", &count);
    try f.feed(0, "\x1b[?1049l");
    try f.frame(&tester);
    try check(try color(&tester, 6, 6, 0xff0000) and f.key(0).? != primary_key and store.live_keys == 1, "returning primary rebuilds a fresh key for preserved VT image", &count);
    const before_reset = f.key(0).?;
    try f.clean(0);
    try f.solid(0, 11, "/wAA", 0);
    try f.frame(&tester);
    try check(try color(&tester, 6, 6, 0xff0000) and f.key(0).? != before_reset, "RIS epoch prevents same-ID stale renderer reuse", &count);
    try vt.configureGraphics(f.sessions[0].vt, false);
    try f.frame(&tester);
    try check(try color(&tester, 6, 6, 0) and store.live_keys == 0, "disabling graphics immediately clears image output and resources", &count);
    try vt.configureGraphics(f.sessions[0].vt, true);
    try f.solid(0, 11, "AAD/", 0);
    try f.frame(&tester);
    try check(try color(&tester, 6, 6, 0x0000ff), "re-enabled graphics accepts a fresh direct image", &count);
    const shown_key = f.key(0).?;
    f.visible[0] = false;
    try f.frame(&tester);
    try check(store.live_keys == 0 and try color(&tester, 6, 6, 0), "hidden pane releases resources without a new terminal feed", &count);
    f.visible[0] = true;
    try f.frame(&tester);
    try check(f.key(0).? != shown_key and try color(&tester, 6, 6, 0x0000ff), "showing pane recaptures with a new monotonic key", &count);

    try f.clean(0);
    try f.solid(0, 11, "/wAA", 0);
    try f.solid(1, 11, "AP8A", 0);
    try f.frame(&tester);
    try check(try color(&tester, 6, 6, 0xff0000) and try color(&tester, 198, 6, 0x00ff00) and f.key(0).? != f.key(1).? and store.live_keys == 2, "one TextSystem isolates same image ID across two pane Views", &count);
    try std.Io.Dir.cwd().createDirPath(s.app.io, ".cache/test-logs");
    var filename: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&filename, ".cache/test-logs/m9-{s}.png", .{if (comptime @hasField(@TypeOf(tester.text), "db")) "portable" else "standard"});
    try tester.screenshot(path);
    const raster_fingerprint = fingerprint: {
        const pixels = try tester.render(tester.gpa);
        defer pixels.deinit(tester.gpa);
        break :fingerprint std.hash.Wyhash.hash(0, pixels.bytes);
    };
    f.visible[0] = false;
    try f.frame(&tester);
    try check(store.live_keys == 1 and try color(&tester, 198, 6, 0x00ff00), "removing one View preserves the other pane's shared-atlas pixels", &count);
    try f.feed(1, "\x1b_Ga=d,d=I,i=11\x1b\\");
    try f.frame(&tester);
    try check(store.live_keys == 0 and try color(&tester, 198, 6, 0), "last pane deletion releases the remaining managed key", &count);
    try independentStores(&f, &tester, &store, s.app.io, &count);

    f.visible[0] = true;
    try f.clean(0);
    try f.big(0, 21);
    try f.big(0, 22);
    try f.solid(1, 31, "AP8A", 0);
    tester.frame(); // Expected aggregate admission error for pane1 only.
    try check(f.errors[0] == null and f.errors[1] != null and f.errors[1].? == error.ManagedBudgetExceeded and store.live_keys == 2 and store.diagnostics.admission_rejections > 0 and !vt.lt_vt_failed(f.sessions[1].vt), "shared 8MiB admission rejects a third image without failing its terminal", &count);
    const atlas_generation = tester.text.images.generation;
    tester.frame();
    try check(tester.text.images.stats.atlas_skipped > 0 and !tester.text.images.stats.prepare_failed and tester.text.images.generation == atlas_generation, "visible atlas footprint overflow skips explicitly and stays stable on idle", &count);
    f.replies[1].len = 0;
    try f.feed(1, "\x1b[3;1HALIVE\x1b[6n");
    tester.frame();
    try check(f.replies[1].has("\x1b[3;6R") and tester.containsText("ALIVE") and !vt.lt_vt_failed(f.sessions[1].vt), "shared renderer rejection preserves subsequent text and DSR replies", &count);
    f.visible[0] = false;
    try f.frame(&tester);
    try check(store.live_keys == 1 and try color(&tester, 198, 6, 0x00ff00), "freed aggregate budget admits the previously rejected pane", &count);
    try check(tester.clipboard.items.len == 0 and !f.replies[0].overflow and !f.replies[1].overflow, "hidden fixture never touches clipboard or overflows host reply storage", &count);
    try actualOom(&f, &tester, &store, s.app.io, &count);
    std.debug.print("M9_UI {{\"checks\":{d},\"pixels\":\"actual Tester.render\",\"comparison_scene\":\"two-pane-red-green-384x120-bgra\",\"raster_wyhash\":\"{x}\",\"pty\":false,\"window\":false,\"screenshot\":\"{s}\"}}\n", .{ count, raster_fingerprint, path });
}

/// Separate TextSystems model independent window renderers without creating
/// real desktop windows. Their Images/atlas/managed-key ownership is distinct.
fn independentStores(f: *Fixture, tester: *ui.Tester, store: *Bridge.Store, io: std.Io, count: *usize) !void {
    var other: Fixture = .{ .gpa = f.gpa };
    try other.init(io);
    defer other.destroyTerminals();
    other.visible[1] = false;
    var second: ui.Tester = undefined;
    try second.init(f.gpa, .init(&other, Fixture.draw), .{ .width = 384, .height = 120, .scale = 1, .theme = @import("appearance.zig").theme(other.cfg) });
    defer second.deinit();
    var second_store = Bridge.Store.init(&second.text);
    defer second_store.deinit();
    other.store = &second_store;
    defer {
        other.destroyViews();
        other.store = null;
        second.instances.clearRetainingCapacity();
        second.ctx.nodes.clearRetainingCapacity();
    }
    f.visible[0] = true;
    try f.clean(0);
    try f.solid(0, 11, "/wAA", 0);
    try other.solid(0, 11, "AP8A", 0);
    try f.frame(tester);
    try other.frame(&second);
    try check(store.live_keys == 1 and second_store.live_keys == 1 and try color(tester, 6, 6, 0xff0000) and try color(&second, 6, 6, 0x00ff00), "independent window TextSystems retain different same-ID protocol pixels", count);
    try f.feed(0, "\x1b_Ga=d,d=I,i=11\x1b\\");
    try f.frame(tester);
    try other.frame(&second);
    try check(store.live_keys == 0 and second_store.live_keys == 1 and try color(tester, 6, 6, 0) and try color(&second, 6, 6, 0x00ff00), "deleting in one window leaves the other atlas resource and pixels intact", count);
    other.visible[0] = false;
    try other.frame(&second);
    try check(store.live_keys == 0 and second_store.live_keys == 0 and second.text.images.managed_bytes == 0 and try color(&second, 6, 6, 0), "independent window hide releases its decoded ownership", count);
}

fn actualOom(f: *Fixture, tester: *ui.Tester, store: *Bridge.Store, io: std.Io, count: *usize) !void {
    var replies: Replies = .{};
    const terminal = try vt.create(f.gpa, io, 12, 4, 200, 1024 * 1024, Replies.receive, &replies);
    defer vt.destroy(terminal);
    try vt.configureGraphics(terminal, true);
    if (vt.lt_vt_resize(terminal, 12, 4, 12, 24) != 0) return error.GraphicsFixtureResize;
    try vt.feed(terminal, "\x1b[?25l\x1b_Ga=T,f=24,s=1,v=1,i=99,c=1,r=1,C=1;/wAA\x1b\\");
    var failing = std.testing.FailingAllocator.init(f.gpa, .{ .fail_index = 0 });
    var session: Session = .{ .id = 99, .gpa = failing.allocator(), .vt = terminal, .cols = 12, .rows = 4, .tx = undefined, .notify_ctx = null, .notify = undefined };
    var view: View = .{};
    defer view.deinit(session.gpa);
    const admissions = store.diagnostics.admission_rejections;
    var oom = false;
    view.graphics.prepare(&session, &tester.ctx, f.cfg, cw, ch, .{ .w = 192, .h = 120 }, store) catch |err| {
        oom = err == error.OutOfMemory;
    };
    try check(oom and vt.lt_vt_failed(terminal) and store.diagnostics.admission_rejections == admissions and !view.graphics.active(), "actual snapshot host OOM stays fatal instead of masquerading as soft image admission", count);
}
