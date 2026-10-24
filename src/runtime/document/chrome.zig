//! Document controls share the application icon and theme system.
const nano = @import("nanoui");
const std = @import("std");
const ui = nano.ui;
pub const icons = @import("interface-assets").icons;
pub const Icon = icons.Icon;
pub fn fileIcon(path: []const u8) Icon {
    const name = std.fs.path.basename(path);
    if (std.ascii.eqlIgnoreCase(name, "Makefile") or std.ascii.eqlIgnoreCase(name, "GNUmakefile")) return .file_makefile;
    for ([_][]const u8{ ".bashrc", ".zshrc", ".profile", ".bash_profile" }) |value| if (std.mem.eql(u8, name, value)) return .file_console;
    const ext = std.fs.path.extension(name);
    const groups = .{ .{ ".md,.markdown,.mdown", Icon.file_markdown }, .{ ".sv,.svh,.v,.vh", Icon.file_verilog }, .{ ".c", Icon.file_c }, .{ ".h", Icon.file_h }, .{ ".cpp,.cc,.cxx", Icon.file_cpp }, .{ ".hpp,.hh,.hxx", Icon.file_hpp }, .{ ".py", Icon.file_python }, .{ ".tcl", Icon.file_tcl }, .{ ".sh,.bash,.zsh,.fish", Icon.file_console }, .{ ".zig", Icon.file_zig }, .{ ".json,.jsonc", Icon.file_json }, .{ ".yaml,.yml", Icon.file_yaml }, .{ ".rs", Icon.file_rust }, .{ ".js,.jsx,.mjs,.cjs", Icon.file_javascript }, .{ ".ts,.tsx,.mts,.cts", Icon.file_typescript } };
    inline for (groups) |group| {
        var extensions = std.mem.splitScalar(u8, group[0], ',');
        while (extensions.next()) |value| if (std.ascii.eqlIgnoreCase(ext, value)) return group[1];
    }
    return .document;
}
pub fn icon(ctx: *ui.Context, name: Icon, size: f32) void {
    icons.draw(ctx, name, size, 0.9);
}
pub fn button(ctx: *ui.Context, title: []const u8, options: ui.ButtonOptions) ui.Interaction {
    return ui.button(ctx, title, options);
}
pub fn iconControl(ctx: *ui.Context, name: Icon, extent: f32, active: bool, disabled: bool) ui.Interaction {
    const node = ctx.open(.{ .width = .{ .px = extent }, .height = .{ .px = extent }, .radius = 6, .control = !disabled, .align_items = .center, .justify = .center, .opacity = if (disabled) 0.4 else 1, .background = if (active) ctx.theme.accent.alpha(0.12) else null }, null);
    const hit = ctx.interact(node, .{ .focusable = !disabled });
    if (hit.hovered and !disabled) ctx.node(node).style.background = ctx.theme.surface_hover;
    icon(ctx, if (name == .lock and active) .lock_open else if (name == .more) .ellipsis else name, 16);
    ctx.end();
    var result = hit;
    if (disabled) {
        result.clicked = false;
        result.pressed = false;
    }
    return result;
}
pub fn ellipsize(ctx: *ui.Context, text: []const u8, width: f32, size: f32) []const u8 {
    if (ctx.text.width(text, .{ .size = size }) <= width) return text;
    var length = text.len;
    while (length > 0) {
        length -= 1;
        while (length > 0 and text[length] & 0xc0 == 0x80) length -= 1;
        const value = ctx.print("{s}…", .{text[0..length]});
        if (ctx.text.width(value, .{ .size = size }) <= width) return value;
    }
    return "…";
}
