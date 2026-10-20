//! Shared nanoui chrome follows terminal colours, including external dark themes.
const ui = @import("nanoui").ui;
const Config = @import("config.zig").Config;
const paper = @import("theme.zig");
pub fn theme(cfg: Config) ui.Theme {
    const bg = ui.Color.hex(cfg.background);
    const fg = ui.Color.hex(cfg.foreground);
    const light = @as(u32, cfg.background >> 16) * 299 + @as(u32, (cfg.background >> 8) & 255) * 587 + @as(u32, cfg.background & 255) * 114 > 128000;
    var th = if (light) ui.Theme.light else ui.Theme.dark_theme;
    const is_paper = cfg.background == paper.background and cfg.foreground == paper.foreground;
    th.mono_font = cfg.font;
    th.background = bg;
    th.text = fg;
    th.surface = if (cfg.ui_panel) |v| ui.Color.hex(v) else if (is_paper) ui.Color.hex(paper.panel) else bg.mix(fg, 0.04);
    th.surface_hover = if (is_paper) ui.Color.hex(paper.hover) else bg.mix(fg, 0.1);
    th.border = if (cfg.ui_border) |v| ui.Color.hex(v) else if (is_paper) ui.Color.hex(paper.border) else bg.mix(fg, 0.17);
    th.muted = if (is_paper) ui.Color.hex(0x72756b) else fg.mix(bg, 0.45);
    th.accent = ui.Color.hex(cfg.ui_accent orelse if (is_paper) paper.accent else cfg.palette[4]);
    th.accent_hover = th.accent;
    // Paper's own red instead of the platform default, for errors/danger actions.
    if (is_paper) th.danger = ui.Color.hex(paper.palette[1]);
    th.accent_text = bg;
    return th;
}
