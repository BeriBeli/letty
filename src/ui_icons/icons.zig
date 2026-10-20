//! Embedded Lucide SVG rasterizations shared by both rendering backends.
const ui = @import("nanoui").ui;
pub const Icon = enum { monitor, terminal, keyboard, clipboard, settings, folder, document, code, search, plus, close, left, right, up, down, more, pin, panel, reset, copy, external, check, sun, moon, lock, file_verilog, file_markdown, file_c, file_h, file_cpp, file_hpp, file_python, file_tcl, file_console, file_makefile, file_zig, file_json, file_yaml, file_rust, file_javascript, file_typescript };
pub fn draw(ctx: *ui.Context, icon: Icon, size: f32, opacity: f32) void {
    const bg = ctx.theme.background;
    const light = bg.r * 0.299 + bg.g * 0.587 + bg.b * 0.114 > 0.5;
    const asset: struct { key: []const u8, bytes: []const u8 } = switch (icon) {
        .monitor => if (light) .{ .key = "letty-ui-monitor-ink", .bytes = @embedFile("assets/monitor-ink.png") } else .{ .key = "letty-ui-monitor-light", .bytes = @embedFile("assets/monitor-light.png") },
        .terminal => if (light) .{ .key = "letty-ui-square-terminal-ink", .bytes = @embedFile("assets/square-terminal-ink.png") } else .{ .key = "letty-ui-square-terminal-light", .bytes = @embedFile("assets/square-terminal-light.png") },
        .keyboard => if (light) .{ .key = "letty-ui-keyboard-ink", .bytes = @embedFile("assets/keyboard-ink.png") } else .{ .key = "letty-ui-keyboard-light", .bytes = @embedFile("assets/keyboard-light.png") },
        .clipboard => if (light) .{ .key = "letty-ui-clipboard-ink", .bytes = @embedFile("assets/clipboard-ink.png") } else .{ .key = "letty-ui-clipboard-light", .bytes = @embedFile("assets/clipboard-light.png") },
        .settings => if (light) .{ .key = "letty-ui-settings-2-ink", .bytes = @embedFile("assets/settings-2-ink.png") } else .{ .key = "letty-ui-settings-2-light", .bytes = @embedFile("assets/settings-2-light.png") },
        .folder => if (light) .{ .key = "letty-ui-folder-ink", .bytes = @embedFile("assets/folder-ink.png") } else .{ .key = "letty-ui-folder-light", .bytes = @embedFile("assets/folder-light.png") },
        .document => if (light) .{ .key = "letty-ui-file-text-ink", .bytes = @embedFile("assets/file-text-ink.png") } else .{ .key = "letty-ui-file-text-light", .bytes = @embedFile("assets/file-text-light.png") },
        .code => if (light) .{ .key = "letty-ui-code-xml-ink", .bytes = @embedFile("assets/code-xml-ink.png") } else .{ .key = "letty-ui-code-xml-light", .bytes = @embedFile("assets/code-xml-light.png") },
        .search => if (light) .{ .key = "letty-ui-search-ink", .bytes = @embedFile("assets/search-ink.png") } else .{ .key = "letty-ui-search-light", .bytes = @embedFile("assets/search-light.png") },
        .plus => if (light) .{ .key = "letty-ui-plus-ink", .bytes = @embedFile("assets/plus-ink.png") } else .{ .key = "letty-ui-plus-light", .bytes = @embedFile("assets/plus-light.png") },
        .close => if (light) .{ .key = "letty-ui-x-ink", .bytes = @embedFile("assets/x-ink.png") } else .{ .key = "letty-ui-x-light", .bytes = @embedFile("assets/x-light.png") },
        .left => if (light) .{ .key = "letty-ui-chevron-left-ink", .bytes = @embedFile("assets/chevron-left-ink.png") } else .{ .key = "letty-ui-chevron-left-light", .bytes = @embedFile("assets/chevron-left-light.png") },
        .right => if (light) .{ .key = "letty-ui-chevron-right-ink", .bytes = @embedFile("assets/chevron-right-ink.png") } else .{ .key = "letty-ui-chevron-right-light", .bytes = @embedFile("assets/chevron-right-light.png") },
        .up => if (light) .{ .key = "letty-ui-chevron-up-ink", .bytes = @embedFile("assets/chevron-up-ink.png") } else .{ .key = "letty-ui-chevron-up-light", .bytes = @embedFile("assets/chevron-up-light.png") },
        .down => if (light) .{ .key = "letty-ui-chevron-down-ink", .bytes = @embedFile("assets/chevron-down-ink.png") } else .{ .key = "letty-ui-chevron-down-light", .bytes = @embedFile("assets/chevron-down-light.png") },
        .more => if (light) .{ .key = "letty-ui-ellipsis-ink", .bytes = @embedFile("assets/ellipsis-ink.png") } else .{ .key = "letty-ui-ellipsis-light", .bytes = @embedFile("assets/ellipsis-light.png") },
        .pin => if (light) .{ .key = "letty-ui-pin-ink", .bytes = @embedFile("assets/pin-ink.png") } else .{ .key = "letty-ui-pin-light", .bytes = @embedFile("assets/pin-light.png") },
        .panel => if (light) .{ .key = "letty-ui-panel-right-ink", .bytes = @embedFile("assets/panel-right-ink.png") } else .{ .key = "letty-ui-panel-right-light", .bytes = @embedFile("assets/panel-right-light.png") },
        .reset => if (light) .{ .key = "letty-ui-rotate-ccw-ink", .bytes = @embedFile("assets/rotate-ccw-ink.png") } else .{ .key = "letty-ui-rotate-ccw-light", .bytes = @embedFile("assets/rotate-ccw-light.png") },
        .copy => if (light) .{ .key = "letty-ui-copy-ink", .bytes = @embedFile("assets/copy-ink.png") } else .{ .key = "letty-ui-copy-light", .bytes = @embedFile("assets/copy-light.png") },
        .external => if (light) .{ .key = "letty-ui-external-link-ink", .bytes = @embedFile("assets/external-link-ink.png") } else .{ .key = "letty-ui-external-link-light", .bytes = @embedFile("assets/external-link-light.png") },
        .check => if (light) .{ .key = "letty-ui-check-ink", .bytes = @embedFile("assets/check-ink.png") } else .{ .key = "letty-ui-check-light", .bytes = @embedFile("assets/check-light.png") },
        .sun => if (light) .{ .key = "letty-ui-sun-ink", .bytes = @embedFile("assets/sun-ink.png") } else .{ .key = "letty-ui-sun-light", .bytes = @embedFile("assets/sun-light.png") },
        .moon => if (light) .{ .key = "letty-ui-moon-ink", .bytes = @embedFile("assets/moon-ink.png") } else .{ .key = "letty-ui-moon-light", .bytes = @embedFile("assets/moon-light.png") },
        .lock => if (light) .{ .key = "letty-ui-lock-keyhole-ink", .bytes = @embedFile("assets/lock-keyhole-ink.png") } else .{ .key = "letty-ui-lock-keyhole-light", .bytes = @embedFile("assets/lock-keyhole-light.png") },
        .file_verilog => .{ .key = "letty-language-verilog", .bytes = @embedFile("languages/verilog.png") },
        .file_markdown => .{ .key = "letty-language-markdown", .bytes = @embedFile("languages/markdown.png") },
        .file_c => .{ .key = "letty-language-c", .bytes = @embedFile("languages/c.png") },
        .file_h => .{ .key = "letty-language-h", .bytes = @embedFile("languages/h.png") },
        .file_cpp => .{ .key = "letty-language-cpp", .bytes = @embedFile("languages/cpp.png") },
        .file_hpp => .{ .key = "letty-language-hpp", .bytes = @embedFile("languages/hpp.png") },
        .file_python => .{ .key = "letty-language-python", .bytes = @embedFile("languages/python.png") },
        .file_tcl => .{ .key = "letty-language-tcl", .bytes = @embedFile("languages/tcl.png") },
        .file_console => .{ .key = "letty-language-console", .bytes = @embedFile("languages/console.png") },
        .file_makefile => .{ .key = "letty-language-makefile", .bytes = @embedFile("languages/makefile.png") },
        .file_zig => .{ .key = "letty-language-zig", .bytes = @embedFile("languages/zig.png") },
        .file_json => .{ .key = "letty-language-json", .bytes = @embedFile("languages/json.png") },
        .file_yaml => .{ .key = "letty-language-yaml", .bytes = @embedFile("languages/yaml.png") },
        .file_rust => .{ .key = "letty-language-rust", .bytes = @embedFile("languages/rust.png") },
        .file_javascript => .{ .key = "letty-language-javascript", .bytes = @embedFile("languages/javascript.png") },
        .file_typescript => .{ .key = "letty-language-typescript", .bytes = @embedFile("languages/typescript.png") },
    };
    _ = ui.image(ctx, .{ .key = asset.key, .bytes = asset.bytes, .max_width = size, .max_height = size, .radius = 0, .opacity = opacity });
}

pub fn file(path: []const u8) Icon {
    return switch (@import("../file_type.zig").classify(path)) {
        .generic => .document,
        .verilog => .file_verilog,
        .markdown => .file_markdown,
        .c => .file_c,
        .h => .file_h,
        .cpp => .file_cpp,
        .hpp => .file_hpp,
        .python => .file_python,
        .tcl => .file_tcl,
        .console => .file_console,
        .makefile => .file_makefile,
        .zig => .file_zig,
        .json => .file_json,
        .yaml => .file_yaml,
        .rust => .file_rust,
        .javascript => .file_javascript,
        .typescript => .file_typescript,
    };
}
