//! Hidden real-VT/font/raster checks. No shell, OS font registration, native
//! window, clipboard, user config, or application Session is mutated.
const std = @import("std");
const ui = @import("nanoui").ui;
const vt = @import("vt.zig");
const Config = @import("config.zig").Config;
const Session = @import("session.zig").Session;
const View = @import("terminal_view.zig").View;
const rows = 9;
const cols = 64;
const maple = "Maple Mono Normal NL NF CN";
const samples = [_][]const u8{ "ASCII fi", "中", "e\xcc\x81", "󰀵", "Bold", "┌─┐", "💁🏻‍♂️", "☺️" };
const labels = [_][]const u8{ "ASCII", "CJK", "combining", "Nerd", "bold-italic", "box", "ZWJ", "VS" };
const scene = "ASCII fi\r\n中\r\ne\xcc\x81\r\n󰀵\r\n\x1b[1;3mBold\x1b[0m\r\n┌─┐\r\n💁🏻‍♂️\r\n☺️";

fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.FontRenderCheck;
}
fn require(ok: bool, label: []const u8) !void {
    if (!ok) try check(false, label);
}
fn closeEnough(a: f32, b: f32) bool {
    return @abs(a - b) < 0.05;
}
fn reply(_: ?*anyopaque, _: [*]const u8, _: usize) callconv(.c) void {}
fn theme(cfg: Config) ui.Theme {
    var result = @import("appearance.zig").theme(cfg);
    result.font = cfg.font;
    result.mono_font = cfg.font;
    return result;
}

const Fixture = struct {
    session: Session,
    view: View = .{},
    cfg: Config = .{ .font = maple, .font_size = 18 },
    cw: f32 = 0,
    ch: f32 = 0,
    fn draw(f: *Fixture, ctx: *ui.Context) void {
        const style = @import("terminal_runs.zig").configure(ctx, f.cfg) catch |err| {
            ctx.text.last_shape_error = @errorName(err);
            return;
        };
        const font = ctx.text.font(style);
        f.cw = @round(ctx.text.layout("M", style).width * ctx.scale) / ctx.scale;
        f.ch = @round((font.ascent + font.descent + font.leading) * ctx.scale) / ctx.scale;
        _ = ctx.open(.{ .width = .fill, .height = .fill, .clip = true, .background = ui.Color.hex(f.cfg.background) }, null);
        defer ctx.end();
        f.view.draw(&f.session, ctx, f.cfg, f.cw, f.ch, true, .{ .w = ctx.size.w, .h = ctx.size.h });
    }
    fn feed(f: *Fixture, payload: []const u8) !void {
        vt.lt_vt_clear_selection(f.session.vt);
        vt.lt_vt_search_close(f.session.vt);
        try vt.feed(f.session.vt, "\x1b[0m\x1b[2J\x1b[H\x1b[?25l");
        try vt.feed(f.session.vt, payload);
        try vt.feed(f.session.vt, "\x1b[9;1H"); // cursor cannot split the sample rows
    }
};

const Row = struct {
    bytes: [256]u8 = @splat(0),
    len: usize = 0,
    heads: usize = 0,
    tails: usize = 0,
    end: u32 = 0,
    flags: u32 = 0,
    fn text(r: *const Row) []const u8 {
        return r.bytes[0..r.len];
    }
};
fn snapshot(terminal: *vt.Vt) ![rows]Row {
    var cursor: vt.Cursor = .{};
    try check(vt.lt_vt_frame(terminal, &cursor) == 0, "font fixture VT snapshot opens");
    defer vt.lt_vt_frame_end(terminal);
    var result: [rows]Row = @splat(.{});
    var cell: vt.Cell = undefined;
    while (vt.lt_vt_next(terminal, &cell)) {
        if (cell.y >= rows) continue;
        const row = &result[cell.y];
        if (cell.width == 0) {
            row.tails += 1;
            continue;
        }
        if (cell.len == 0) continue;
        try require(cell.len <= row.bytes.len - row.len, "fixture row copy remains bounded");
        @memcpy(row.bytes[row.len..][0..cell.len], cell.text.?[0..cell.len]);
        row.len += cell.len;
        row.heads += 1;
        row.end = cell.x + cell.width;
        row.flags |= cell.flags;
    }
    return result;
}

const Audit = struct { runs: usize = 0, fallback: usize = 0, glyphs: usize = 0, missing: usize = 0, sprites: usize = 0, width: f32 = 0 };
fn audit(t: *ui.Tester, f: *const Fixture, row: usize) !Audit {
    var result: Audit = .{};
    const y = f.cfg.padding_y[0] + @as(f32, @floatFromInt(row)) * f.ch;
    for (t.ctx.nodes.items) |node| {
        if (!closeEnough(node.rect.y, y)) continue;
        switch (node.content) {
            .text => {
                result.fallback += 1;
                result.width += node.rect.w;
            },
            .glyph_run => |shaped_run| {
                result.runs += 1;
                result.width += node.rect.w;
                try ui.gridText.validate(shaped_run.str, shaped_run.cells, f.cw);
                try require(closeEnough(node.rect.w, ui.gridText.width(shaped_run.cells, f.cw)), "glyph run retains exact VT column width");
                for (shaped_run.glyphs) |glyph| {
                    result.glyphs += 1;
                    _ = try ui.gridText.owner(shaped_run.cells, glyph.index);
                    try require(std.math.isFinite(glyph.x) and std.math.isFinite(glyph.y), "glyph cluster positions are finite and owned by a VT cell");
                    if (glyph.glyph == 0) {
                        result.missing += 1;
                        continue;
                    }
                    try require(glyph.font < t.text.run_fonts.items.len, "glyph references a live raster font");
                    if (comptime @hasField(@TypeOf(t.text), "db")) {
                        const face = t.text.run_faces.items[glyph.font];
                        const source = t.text.db.source(face) orelse return error.FontSourceUnavailable;
                        const raster_font = t.text.run_fonts.items[glyph.font].font;
                        try require(source.bytes.ptr == raster_font.data.ptr and source.bytes.len == raster_font.data.len and source.index == t.text.db.faces.items[face].index, "HB glyph and raster font share source bytes and TTC index");
                        try require(glyph.glyph < raster_font.num_glyphs, "HB glyph ID is valid for the same TrueType source");
                    }
                    if (t.text.glyph(glyph, 0)) |sprite| if (sprite.w > 0 and sprite.h > 0) {
                        result.sprites += 1;
                    };
                }
            },
            else => {},
        }
    }
    return result;
}
fn ink(t: *ui.Tester, f: *const Fixture, row: usize) !usize {
    const pixels = try t.render(t.gpa);
    defer pixels.deinit(t.gpa);
    const first: usize = @intFromFloat(@max(0, (f.cfg.padding_y[0] + @as(f32, @floatFromInt(row)) * f.ch) * t.scale));
    const last: usize = @min(pixels.height, first + @as(usize, @intFromFloat(@ceil(f.ch * t.scale))));
    const bg = f.cfg.background;
    var count: usize = 0;
    for (@min(first, last)..last) |y| for (0..pixels.width) |x| {
        const at = (y * pixels.width + x) * 4;
        if (pixels.bytes[at] != @as(u8, @truncate(bg)) or pixels.bytes[at + 1] != @as(u8, @truncate(bg >> 8)) or pixels.bytes[at + 2] != @as(u8, @truncate(bg >> 16))) count += 1;
    };
    return count;
}
fn filename(t: *ui.Tester, buffer: []u8, kind: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, ".cache/test-logs/font-{s}-{s}.png", .{ kind, if (comptime @hasField(@TypeOf(t.text), "db")) "portable" else "standard" });
}
fn modeSpans(t: *ui.Tester, f: *Fixture, enabled: bool) !void {
    const snap = try snapshot(f.session.vt);
    std.debug.print("FONT_MODE {s} ZWJ(heads={d},tails={d},end={d}) VS(heads={d},tails={d},end={d})\n", .{
        if (enabled) "2027-explicitly-enabled" else "upstream-default-no-2027-sequence",
        snap[6].heads,
        snap[6].tails,
        snap[6].end,
        snap[7].heads,
        snap[7].tails,
        snap[7].end,
    });
    for ([_]usize{ 6, 7 }) |row| {
        try require(std.mem.eql(u8, snap[row].text(), samples[row]), "both grapheme modes preserve exact ZWJ/VS input bytes");
        const projected = try audit(t, f, row);
        // In default mode upstream may store several positive-width cells for
        // one emoji sequence. A joined HB/CoreText glyph must not shrink that
        // VT-owned span. Unsupported-font fallback leaves the same cell widths.
        try check(snap[row].heads > 0 and snap[row].end > 0 and projected.runs + projected.fallback > 0 and
            closeEnough(projected.width, @as(f32, @floatFromInt(snap[row].end)) * f.cw), "UI glyph or fallback runs preserve the actual VT span in each grapheme mode");
    }
    if (enabled) try require(snap[6].heads == 1 and snap[6].end == 2 and snap[7].heads == 1 and snap[7].end == 2, "explicit mode 2027 creates one two-column ZWJ/VS grapheme");
}
fn sampleChecks(t: *ui.Tester, f: *Fixture) !void {
    const snap = try snapshot(f.session.vt);
    for (samples, labels, 0..) |sample, label, row| {
        try check(std.mem.eql(u8, sample, snap[row].text()), "real VT preserves fixture grapheme bytes");
        const result = try audit(t, f, row);
        const supported = result.runs > 0 and result.fallback == 0 and result.glyphs > 0 and result.missing == 0 and result.sprites > 0;
        std.debug.print("FONT_CAPABILITY {s} {s} runs={d} glyphs={d} missing={d} sprites={d} fallback={d}\n", .{ label, if (supported) "covered-and-rasterized" else "UNSUPPORTED", result.runs, result.glyphs, result.missing, result.sprites, result.fallback });
        // ASCII, ordinary bold/italic and box drawing are the required floor.
        // Optional script/icon/color availability is recorded, never tofu PASS.
        if (row == 0 or row == 4 or row == 5) try check(supported, "required font scene has real glyphs and raster ink");
        if (supported) try require(try ink(t, f, row) > 0, "covered sample reaches actual offscreen pixels");
    }
    try check(snap[1].heads == 1 and snap[1].tails == 1 and snap[1].end == 2, "CJK wide tail remains one two-column VT grapheme");
    try check(snap[2].heads == 1 and snap[2].end == 1, "combining accent retains one VT column");
    try check(snap[4].flags & 3 == 3, "bold and italic come from actual VT SGR flags");
    try check(snap[6].heads == 1 and snap[6].end == 2 and snap[7].heads == 1, "explicit 2027 ZWJ and VS stay within their original VT grapheme cells");
    if (t.findGridCell("中")) |rect| {
        const row = try audit(t, f, 1);
        if (row.fallback == 0) try require(closeEnough(rect.w, 2 * f.cw), "rendered CJK mapping spans exactly two grid columns");
    }
    var path: [160]u8 = undefined;
    try t.screenshot(try filename(t, &path, "scene"));
}

fn splitFi(t: *ui.Tester, f: *Fixture, label: []const u8) !void {
    const value = try audit(t, f, 0);
    try check(value.runs == 2 and value.fallback == 0 and value.missing == 0 and value.glyphs >= 2 and value.sprites >= 2 and closeEnough(value.width, 2 * f.cw), label);
    for (t.ctx.nodes.items) |node| if (node.content == .glyph_run and closeEnough(node.rect.y, f.cfg.padding_y[0])) {
        const shaped_run = node.content.glyph_run;
        try check(shaped_run.cells.len == 1 and shaped_run.cells[0].width == 1 and shaped_run.str.len == 1, "boundary run owns exactly one original VT cell");
    };
}
fn fontError(t: *ui.Tester, f: *const Fixture, label: []const u8, value: Audit) void {
    std.debug.print("FONT_ERROR {s} family={s} runs={d} glyphs={d} missing={d} sprites={d} fallback={d} width={d} last_shape_error={s}\n", .{
        label, f.cfg.font, value.runs, value.glyphs, value.missing, value.sprites, value.fallback, value.width, t.text.last_shape_error orelse "none",
    });
    if (comptime @hasField(@TypeOf(t.text), "db")) {
        std.debug.print("FONT_DB {any}\n", .{t.text.db.stats()});
        if (t.text.db.family(f.cfg.font, 400, false)) |face| {
            const metadata = t.text.db.faces.items[face];
            std.debug.print("FONT_FACE id={d} family={s} path={s} ttc_index={d}\n", .{ face, metadata.style.name(), metadata.path, metadata.index });
            if (t.text.db.loaded.contains(face)) {
                if (t.text.db.source(face)) |source| std.debug.print("FONT_SOURCE bytes={d} index={d} digest={x}\n", .{ source.bytes.len, source.index, source.digest });
            } else std.debug.print("FONT_SOURCE not-loaded (diagnostic does not allocate or retry)\n", .{});
        } else std.debug.print("FONT_FACE family-not-indexed\n", .{});
    }
}
extern "c" fn CTFontCopyFamilyName(*const anyopaque) ?*anyopaque;
extern "c" fn CFStringGetCString(*const anyopaque, [*]u8, isize, u32) bool;
extern "c" fn CFRelease(*const anyopaque) void;
fn selectedFamily(t: *ui.Tester, family: []const u8) bool {
    if (comptime @hasField(@TypeOf(t.text), "db")) return t.text.db.family(family, 400, false) != null;
    const font = t.text.font(.{ .size = 18, .mono = true });
    const name = CTFontCopyFamilyName(@ptrCast(font.ref)) orelse return false;
    defer CFRelease(name);
    var buffer: [256]u8 = undefined;
    if (!CFStringGetCString(name, &buffer, buffer.len, 0x08000100)) return false;
    return std.ascii.eqlIgnoreCase(std.mem.sliceTo(&buffer, 0), family);
}
const Signature = struct {
    ids: [128]u16 = @splat(0),
    len: usize = 0,
    fn items(value: *const Signature) []const u16 {
        return value.ids[0..value.len];
    }
};
fn signature(t: *ui.Tester, f: *const Fixture) !Signature {
    var result: Signature = .{};
    for (t.ctx.nodes.items) |node| if (node.content == .glyph_run and closeEnough(node.rect.y, f.cfg.padding_y[0])) {
        for (node.content.glyph_run.glyphs) |glyph| {
            try require(result.len < result.ids.len, "feature glyph signature remains bounded");
            result.ids[result.len] = glyph.glyph;
            result.len += 1;
        }
    };
    return result;
}
fn mapleFeatures(t: *ui.Tester, f: *Fixture) !void {
    // Local preflight: MapleMono-NF-CN-Regular.ttf identifies this exact family,
    // TrueType glyf+GSUB/calt. !=, == and -> substitute glyph IDs through calt;
    // their glyph counts can remain equal, so count-only tests would miss it.
    f.cfg.font = "Maple Mono NF CN";
    f.cfg.font_ligatures = true;
    f.cfg.font_features = .{};
    try f.cfg.font_features.put(.{ .tag = "calt".*, .value = 1 });
    try f.cfg.font_features.put(.{ .tag = "liga".*, .value = 1 });
    t.theme = theme(f.cfg);
    try f.feed("!= == ->");
    t.text.last_shape_error = null;
    t.frame();
    if (!selectedFamily(t, f.cfg.font)) {
        std.debug.print("FONT_CAPABILITY Maple-calt UNSUPPORTED family-not-installed\n", .{});
        return;
    }
    const enabled = try audit(t, f, 0);
    fontError(t, f, "Maple-calt-enabled", enabled);
    try require(enabled.runs == 1 and enabled.fallback == 0 and enabled.missing == 0 and enabled.sprites > 0, "installed Maple calt test shapes and rasterizes real glyphs");
    const on = try signature(t, f);
    var path: [160]u8 = undefined;
    try t.screenshot(try filename(t, &path, "feature-on"));
    f.cfg.font_ligatures = false;
    t.text.last_shape_error = null;
    t.frame();
    const disabled = try audit(t, f, 0);
    const off = try signature(t, f);
    fontError(t, f, "Maple-calt-disabled", disabled);
    std.debug.print("FONT_FEATURE Maple-calt on_ids={any} off_ids={any} on_width={d} off_width={d}\n", .{ on.items(), off.items(), enabled.width, disabled.width });
    try require(disabled.runs == 1 and disabled.fallback == 0 and disabled.missing == 0 and disabled.sprites > 0 and
        !std.mem.eql(u16, on.items(), off.items()) and closeEnough(enabled.width, disabled.width) and closeEnough(disabled.width, 8 * f.cw), "Maple calt changes actual glyph IDs while all eight VT columns remain fixed");
    try require(try ink(t, f, 0) > 0, "feature-disabled glyphs reach offscreen pixels");
    std.debug.print("FONT_CAPABILITY Maple-calt actual-glyph-substitution-covered\n", .{});
    try t.screenshot(try filename(t, &path, "feature-off"));
}
fn ligatures(t: *ui.Tester, f: *Fixture) !void {
    f.cfg.font = "Times New Roman";
    f.cfg.font_ligatures = true;
    try f.cfg.font_features.put(.{ .tag = "liga".*, .value = 1 });
    t.theme = theme(f.cfg);
    try f.feed("fi");
    t.text.last_shape_error = null;
    t.frame();
    const enabled = try audit(t, f, 0);
    fontError(t, f, "Times-fi-enabled", enabled);
    try check(enabled.runs == 1 and enabled.fallback == 0 and enabled.missing == 0, "unbroken fi uses a real whole-row shaped run");
    f.cfg.font_ligatures = false;
    t.text.last_shape_error = null;
    t.frame();
    const disabled = try audit(t, f, 0);
    fontError(t, f, "Times-fi-disabled", disabled);
    try check(disabled.runs == 1 and disabled.glyphs == 2 and closeEnough(disabled.width, 2 * f.cw) and closeEnough(enabled.width, disabled.width), "liga off yields separate glyphs while preserving both VT columns");
    if (enabled.glyphs < disabled.glyphs) {
        try require(enabled.glyphs == 1, "actual installed Times fi ligature crosses two fixed cells");
        std.debug.print("FONT_CAPABILITY Times-fi-ligature covered enabled={d} disabled={d}\n", .{ enabled.glyphs, disabled.glyphs });
    } else std.debug.print("FONT_CAPABILITY Times-fi-ligature UNSUPPORTED enabled={d} disabled={d}\n", .{ enabled.glyphs, disabled.glyphs });
    f.cfg.font_ligatures = true;
    try f.feed("f\x1b[1mi\x1b[0m");
    t.frame();
    try splitFi(t, f, "SGR style boundary prevents a cross-cell ligature");
    try f.feed("fi");
    vt.lt_vt_select(f.session.vt, 0, 0, 0);
    vt.lt_vt_select(f.session.vt, 0, 0, 1);
    try check(vt.lt_vt_has_selection(f.session.vt), "fixture selects one real VT cell");
    t.frame();
    try splitFi(t, f, "selection boundary prevents a cross-cell ligature");
    try f.feed("fi");
    try check(vt.lt_vt_search(f.session.vt, "f", 1) == 0, "fixture starts real incremental VT search");
    var total: usize = 0;
    var complete = false;
    for (0..128) |_| {
        const more = vt.lt_vt_search_tick(f.session.vt, &total);
        if (more < 0) return error.FontSearchFailure;
        if (more == 0) {
            complete = true;
            break;
        }
    }
    try check(complete and total == 1, "fixture search completes with exactly one match");
    t.frame();
    try splitFi(t, f, "search boundary prevents a cross-cell ligature");
    try f.feed("fi");
    try vt.feed(f.session.vt, "\x1b[?25h\x1b[1;1H");
    t.frame();
    try splitFi(t, f, "cursor cell isolation prevents a cross-cell ligature");
    var path: [160]u8 = undefined;
    try t.screenshot(try filename(t, &path, "cursor-boundary"));
}

fn sgr(t: *ui.Tester, f: *Fixture) !void {
    try f.feed("\x1b[58;2;17;34;51m\x1b[4:1mA\x1b[4:2mB\x1b[4:3mC\x1b[4:4mD\x1b[4:5mE\x1b[24m\x1b[53mO\x1b[55m\x1b[7mI\x1b[27m\x1b[2mF\x1b[22m\x1b[8mH\x1b[28m");
    {
        var cursor: vt.Cursor = .{};
        try check(vt.lt_vt_frame(f.session.vt, &cursor) == 0, "SGR fixture snapshots actual VT cells");
        defer vt.lt_vt_frame_end(f.session.vt);
        var cell: vt.Cell = undefined;
        var seen: [9]bool = @splat(false);
        while (vt.lt_vt_next(f.session.vt, &cell)) {
            if (cell.y != 0 or cell.x >= 9) continue;
            seen[cell.x] = true;
            switch (cell.x) {
                0...4 => try check(cell.underline == cell.x + 1 and cell.underline_color == 0x112233 and cell.flags & 4 != 0, "SGR 4:1..5 and 58 RGB survive real VT projection"),
                5 => try check(cell.flags & 128 != 0, "SGR overline survives real VT projection"),
                6 => try check(cell.fg == f.cfg.background and cell.bg == f.cfg.foreground, "SGR inverse swaps actual foreground and background"),
                7 => try check(cell.fg != f.cfg.foreground and cell.fg != f.cfg.background, "SGR faint changes actual projected ink color"),
                8 => try check(cell.flags & 256 != 0 and cell.len == 0, "SGR conceal hides render text without mutating backing cells"),
                else => unreachable,
            }
        }
        for (seen) |present| try check(present, "SGR fixture observed every original cell");
    }
    vt.lt_vt_select(f.session.vt, 0, 0, 0);
    vt.lt_vt_select(f.session.vt, 8, 0, 1);
    var copy: [64]u8 = undefined;
    var len: usize = 0;
    try check(vt.lt_vt_copy(f.session.vt, &copy, copy.len, &len) == 0 and std.mem.eql(u8, copy[0..len], "ABCDEOIFH"), "concealed H remains in exact VT copy without system clipboard");
    vt.lt_vt_clear_selection(f.session.vt);
    t.frame();
    try check(!t.containsText("H"), "concealed glyph never reaches UI text or glyph runs");
    var path: [160]u8 = undefined;
    try t.screenshot(try filename(t, &path, "sgr"));
}

fn reloadAndScale(t: *ui.Tester, f: *Fixture) !void {
    f.cfg = .{ .font = maple, .font_size = 16 };
    t.theme = theme(f.cfg);
    try f.feed(scene);
    t.scale = 1;
    t.text.setScale(1);
    t.frame();
    const before = try snapshot(f.session.vt);
    const cw = f.cw;
    f.cfg.font_size = 24;
    t.scale = 2;
    t.text.setScale(2);
    t.frame();
    const after = try snapshot(f.session.vt);
    try check(f.cw > cw and after[1].end == before[1].end and after[2].end == before[2].end and after[6].end == before[6].end, "scale and font size change raster pitch without changing VT widths");
    var old = std.heap.ArenaAllocator.init(t.gpa);
    var old_live = true;
    defer if (old_live) old.deinit();
    f.cfg.font = try old.allocator().dupe(u8, "Times New Roman");
    const names = try old.allocator().alloc([]const u8, 1);
    names[0] = try old.allocator().dupe(u8, maple);
    f.cfg.font_fallbacks = names;
    t.theme = theme(f.cfg);
    t.frame();
    const first_name = f.cfg.font.ptr;
    var replacement = std.heap.ArenaAllocator.init(t.gpa);
    var replacement_live = true;
    defer if (replacement_live) replacement.deinit();
    f.cfg.font = try replacement.allocator().dupe(u8, "Times New Roman");
    const equal_names = try replacement.allocator().alloc([]const u8, 1);
    equal_names[0] = try replacement.allocator().dupe(u8, maple);
    f.cfg.font_fallbacks = equal_names;
    t.theme = theme(f.cfg);
    t.frame();
    try check(t.text.family != null and t.text.mono_family != null and
        t.text.family.?.ptr != first_name and t.text.family.?.ptr != f.cfg.font.ptr and
        t.text.mono_family.?.ptr != first_name and t.text.mono_family.?.ptr != f.cfg.font.ptr, "same-content family reload retains owned names from neither config arena");
    old.deinit();
    old_live = false;
    t.frame(); // equal-content reload must not retain a pointer into old
    const equal_reload = try audit(t, f, 0);
    try check(equal_reload.runs > 0 and equal_reload.fallback == 0 and equal_reload.missing == 0 and equal_reload.sprites > 0, "same-content family reload still shapes and rasterizes after first arena release");
    f.cfg = .{ .font = maple, .font_size = 18, .font_ligatures = false, .font_fallbacks = &.{"Times New Roman"} };
    t.theme = theme(f.cfg);
    // Publish the next config/theme before releasing its predecessor; the text
    // system independently owns its family and fallback copies.
    t.text.setFamilies(f.cfg.font, f.cfg.font);
    try t.text.setFallbacks(f.cfg.font_fallbacks);
    replacement.deinit();
    replacement_live = false;
    t.frame();
    t.frame(); // old two-frame layouts/features must no longer be borrowed
    const current = try snapshot(f.session.vt);
    for (samples, 0..) |sample, i| try check(std.mem.eql(u8, sample, current[i].text()), "config arena release leaves exact original VT text intact");
    const ascii = try audit(t, f, 0);
    try check(ascii.runs > 0 and ascii.fallback == 0 and ascii.missing == 0 and ascii.sprites > 0 and try ink(t, f, 0) > 0, "post-reload layout and raster work after old config arena is freed");
    var path: [160]u8 = undefined;
    try t.screenshot(try filename(t, &path, "reload-scale"));
}

pub fn run(s: anytype) !void {
    const terminal = try vt.create(s.gpa, s.app.io, cols, rows, 0, 1024 * 1024, reply, null);
    defer vt.destroy(terminal);
    var f: Fixture = .{ .session = .{ .id = 1, .gpa = s.gpa, .vt = terminal, .cols = cols, .rows = rows, .tx = undefined, .notify_ctx = null, .notify = undefined } };
    defer f.view.deinit(s.gpa);
    vt.lt_vt_colors(terminal, f.cfg.foreground, f.cfg.background);
    try f.feed(scene);
    var tester: ui.Tester = undefined;
    try tester.init(s.gpa, .init(&f, Fixture.draw), .{ .width = 900, .height = 400, .scale = 2, .theme = theme(f.cfg) });
    defer tester.deinit();
    try modeSpans(&tester, &f, false);
    var path: [160]u8 = undefined;
    try tester.screenshot(try filename(&tester, &path, "default-mode"));
    // Only this isolated VT is opted in. Application Context defaults and the
    // native VT goldens continue to use the fixed upstream default behavior.
    try vt.feed(terminal, "\x1b[?2027h");
    try f.feed(scene);
    tester.frame();
    try modeSpans(&tester, &f, true);
    try sampleChecks(&tester, &f);
    try mapleFeatures(&tester, &f);
    try ligatures(&tester, &f);
    try sgr(&tester, &f);
    try reloadAndScale(&tester, &f);
    try check(!vt.lt_vt_failed(terminal), "font renderer fixture leaves native VT healthy without a PTY");
}
