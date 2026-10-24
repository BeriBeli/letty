//! Kero's mygo UI palette, shared by every Letty surface.
const ui = @import("nanoui").ui;
const Config = @import("config.zig").Config;
pub fn theme(cfg: Config) ui.Theme {
    const light = @as(u32, cfg.background >> 16) * 299 + @as(u32, (cfg.background >> 8) & 255) * 587 + @as(u32, cfg.background & 255) * 114 > 128000;
    var th = if (light) ui.Theme.light else ui.Theme.dark_theme;
    th.mono_font = cfg.font;
    th.background = ui.Color.hex(if (light) @as(u24, 0xffffff) else 0x232328);
    th.text = ui.Color.hex(if (light) @as(u24, 0x1d1d1f) else 0xececf0);
    th.muted = ui.Color.hex(if (light) @as(u24, 0x6e6e78) else 0xa9a9b4);
    th.surface = ui.Color.hex(cfg.ui_panel orelse if (light) @as(u24, 0xffffff) else 0x232328);
    th.surface_hover = th.text.alpha(if (light) 0.04 else 0.05);
    th.border = if (cfg.ui_border) |v| ui.Color.hex(v) else th.text.alpha(if (light) 0.07 else 0.08);
    th.accent = ui.Color.hex(cfg.ui_accent orelse if (light) @as(u24, 0x3b6cf6) else 0x6b93ff);
    th.accent_hover = th.accent;
    th.danger = ui.Color.hex(if (light) @as(u24, 0xd93a35) else 0xff6961);
    th.accent_text = .white;
    return th;
}
