//! Real VT + renderer fixture for colored Starship/Nerd Font prompts.
const std = @import("std");
const ui = @import("nanoui").ui;
const vt = @import("vt.zig");
const Config = @import("config.zig").Config;
const Session = @import("session.zig").Session;
const View = @import("terminal_view.zig").View;
const Fixture = struct {
    session: Session,
    view: View = .{},
    cfg: Config = .{},
    fn draw(f: *Fixture, ctx: *ui.Context) void {
        const font = ctx.text.font(.{ .size = f.cfg.font_size, .mono = true });
        const cw = @round(ctx.text.layout("M", .{ .size = f.cfg.font_size, .mono = true }).width * ctx.scale) / ctx.scale;
        const ch = @round((font.ascent + font.descent + font.leading) * ctx.scale) / ctx.scale;
        _ = ctx.open(.{ .width = .fill, .height = .fill, .clip = true, .background = ui.Color.hex(f.cfg.background) }, null);
        defer ctx.end();
        f.view.draw(&f.session, ctx, f.cfg, cw, ch, false, .{ .w = ctx.size.w, .h = ctx.size.h });
    }
};
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.TerminalRenderCheck;
}
fn reply(_: ?*anyopaque, _: [*]const u8, _: usize) callconv(.c) void {}
pub fn run(s: anytype) !void {
    const terminal = try vt.create(s.gpa, s.app.io, 80, 1, 0, 1024 * 1024, reply, null);
    defer vt.destroy(terminal);
    var fixture: Fixture = .{ .session = .{ .id = 1, .gpa = s.gpa, .vt = terminal, .cols = 80, .rows = 1, .tx = undefined, .notify_ctx = null, .notify = undefined } };
    vt.lt_vt_colors(terminal, fixture.cfg.foreground, fixture.cfg.background);
    const prompt = "\x1b[?25l\x1b[38;2;243;139;168m\x1b[48;2;243;139;168m\x1b[38;2;17;17;27m󰀵 beribeli\x1b[48;2;250;179;135m\x1b[38;2;243;139;168m\x1b[38;2;17;17;27m ~ \x1b[48;2;180;190;254m\x1b[38;2;250;179;135m\x1b[38;2;17;17;27m  21:52 \x1b[0m\x1b[38;2;180;190;254m\x1b[0m";
    vt.lt_vt_feed(terminal, prompt.ptr, prompt.len);
    var tester: ui.Tester = undefined;
    try tester.init(s.gpa, .init(&fixture, Fixture.draw), .{ .width = 650, .height = 70, .theme = @import("appearance.zig").theme(fixture.cfg) });
    defer tester.deinit();
    var saw_glyph = false;
    var backgrounds: usize = 0;
    var ordered = true;
    for (tester.instances.items) |instance| {
        if (instance.kind == 1) saw_glyph = true;
        if (instance.kind == 0) {
            backgrounds += 1;
            if (saw_glyph) ordered = false;
        }
    }
    try check(saw_glyph and backgrounds > 10 and ordered, "colored prompt backgrounds never overwrite Nerd Font glyph overhang");
    try tester.screenshot(".cache/test-logs/starship-prompt.png");
}
