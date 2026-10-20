//! Typed requests shared by bindings, menus, palettes and application dispatch.
const std = @import("std");
pub const Action = enum { none, send_bytes, next_profile, tab, horizontal, vertical, close, close_tab, close_window, copy, paste, search, palette, save, next_tab, previous_tab, next_pane, font_up, font_down, font_reset, quit, reload, goto_tab, unbind, ignore, split_left, split_up, focus_pane, previous_pane, toggle_zoom, equalize, resize_pane, move_tab, rename_tab, scroll_top, scroll_bottom, page_up, page_down, select_all, clear_screen, reset, search_next, search_previous, end_search, close_other_tabs, open_config, diagnostics, search_selection, paste_primary, open_link, copy_link, prompt_previous, prompt_next, new_window, next_window, previous_window, open_theme_browser, inspector, toggle_quick_terminal, open_settings, toggle_sidebar, toggle_tab_pin, open_file_workspace, move_preview_to_workspace, open_file_preview, preview_selected_path, close_file_preview, toggle_file_preview, refresh_file_preview };
pub const Direction = enum { left, right, up, down };
pub const Argument = union(enum) { none, bytes: @import("action_bytes.zig").Payload, amount: f32, index: usize, direction: Direction, offset: isize, resize: struct { direction: Direction, pixels: u16 } };
pub const Request = struct {
    action: Action = .none,
    args: Argument = .none,
    pub fn normalized(r: Request) Request {
        if (r.args != .none) return r;
        return .{ .action = r.action, .args = switch (r.action) {
            .font_up, .font_down => .{ .amount = 1 },
            .goto_tab => .{ .index = 1 },
            .focus_pane => .{ .direction = .right },
            .move_tab => .{ .offset = 1 },
            .resize_pane => .{ .resize = .{ .direction = .right, .pixels = 10 } },
            else => .none,
        } };
    }
    pub fn amount(r: Request) f32 {
        return if (r.normalized().args == .amount) r.normalized().args.amount else 1;
    }
    pub fn index(r: Request) usize {
        return if (r.normalized().args == .index) r.normalized().args.index else 1;
    }
    pub fn same(a: Request, b: Request) bool {
        return std.meta.eql(a.normalized(), b.normalized());
    }
};
pub fn parse(name: []const u8) !Request {
    if (std.mem.eql(u8, name, "save_layout")) return .{ .action = .save };
    if (std.mem.eql(u8, name, "next_launch_profile")) return .{ .action = .next_profile };
    if (std.mem.startsWith(u8, name, "text:") or std.mem.startsWith(u8, name, "csi:") or std.mem.startsWith(u8, name, "esc:"))
        return .{ .action = .send_bytes, .args = .{ .bytes = try @import("action_bytes.zig").parse(name) } };
    const names = .{ .{ "open_file_workspace", Action.open_file_workspace }, .{ "move_preview_to_workspace", Action.move_preview_to_workspace }, .{ "open_file_preview", Action.open_file_preview }, .{ "preview_selected_path", Action.preview_selected_path }, .{ "close_file_preview", Action.close_file_preview }, .{ "toggle_file_preview", Action.toggle_file_preview }, .{ "refresh_file_preview", Action.refresh_file_preview }, .{ "open_settings", Action.open_settings }, .{ "toggle_sidebar", Action.toggle_sidebar }, .{ "toggle_tab_pin", Action.toggle_tab_pin }, .{ "toggle_quick_terminal", Action.toggle_quick_terminal }, .{ "inspector:toggle", Action.inspector }, .{ "toggle_inspector", Action.inspector }, .{ "open_theme_browser", Action.open_theme_browser }, .{ "new_window", Action.new_window }, .{ "goto_window:next", Action.next_window }, .{ "goto_window:previous", Action.previous_window }, .{ "jump_to_prompt:-1", Action.prompt_previous }, .{ "jump_to_prompt:1", Action.prompt_next }, .{ "new_split:left", Action.split_left }, .{ "new_split:up", Action.split_up }, .{ "goto_split:previous", Action.previous_pane }, .{ "toggle_split_zoom", Action.toggle_zoom }, .{ "equalize_splits", Action.equalize }, .{ "prompt_tab_title", Action.rename_tab }, .{ "rename_tab", Action.rename_tab }, .{ "scroll_to_top", Action.scroll_top }, .{ "scroll_to_bottom", Action.scroll_bottom }, .{ "scroll_page_up", Action.page_up }, .{ "scroll_page_down", Action.page_down }, .{ "select_all", Action.select_all }, .{ "clear_screen", Action.clear_screen }, .{ "reset", Action.reset }, .{ "navigate_search:next", Action.search_next }, .{ "navigate_search:previous", Action.search_previous }, .{ "end_search", Action.end_search }, .{ "close_other_tabs", Action.close_other_tabs }, .{ "open_config", Action.open_config }, .{ "show_config_diagnostics", Action.diagnostics }, .{ "search_selection", Action.search_selection }, .{ "paste_from_selection", Action.paste_primary }, .{ "open_link", Action.open_link }, .{ "copy_url_to_clipboard", Action.copy_link }, .{ "quit", Action.quit }, .{ "new_tab", Action.tab }, .{ "new_split:right", Action.horizontal }, .{ "new_split:down", Action.vertical }, .{ "close_surface", Action.close }, .{ "close_tab", Action.close_tab }, .{ "close_tab:this", Action.close_tab }, .{ "close_window", Action.close_window }, .{ "copy_to_clipboard", Action.copy }, .{ "paste_from_clipboard", Action.paste }, .{ "start_search", Action.search }, .{ "toggle_command_palette", Action.palette }, .{ "reload_config", Action.reload }, .{ "next_tab", Action.next_tab }, .{ "previous_tab", Action.previous_tab }, .{ "goto_split:next", Action.next_pane }, .{ "reset_font_size", Action.font_reset }, .{ "unbind", Action.unbind }, .{ "ignore", Action.ignore } };
    inline for (names) |pair| if (std.mem.eql(u8, name, pair[0])) return .{ .action = pair[1] };
    if (std.mem.startsWith(u8, name, "goto_tab:")) {
        const value = std.fmt.parseInt(usize, name[9..], 10) catch return error.InvalidKeybind;
        if (value == 0) return error.InvalidKeybind;
        return .{ .action = .goto_tab, .args = .{ .index = value } };
    }
    const parameterized = .{ .{ "increase_font_size:", Action.font_up }, .{ "decrease_font_size:", Action.font_down } };
    inline for (parameterized) |pair| if (std.mem.startsWith(u8, name, pair[0])) {
        const value = try std.fmt.parseFloat(f32, name[pair[0].len..]);
        if (!std.math.isFinite(value) or value <= 0 or value > 32) return error.InvalidKeybind;
        return .{ .action = pair[1], .args = .{ .amount = value } };
    };
    if (std.mem.startsWith(u8, name, "goto_split:")) {
        const direction = std.meta.stringToEnum(Direction, name[11..]) orelse return error.InvalidKeybind;
        return .{ .action = .focus_pane, .args = .{ .direction = direction } };
    }
    if (std.mem.startsWith(u8, name, "move_tab:")) {
        const offset = try std.fmt.parseInt(isize, name[9..], 10);
        if (offset == 0) return error.InvalidKeybind;
        return .{ .action = .move_tab, .args = .{ .offset = offset } };
    }
    if (std.mem.startsWith(u8, name, "resize_split:")) {
        var parts = std.mem.splitScalar(u8, name[13..], ',');
        const direction = std.meta.stringToEnum(Direction, parts.next().?) orelse return error.InvalidKeybind;
        const pixels = try std.fmt.parseInt(u16, parts.next() orelse return error.InvalidKeybind, 10);
        if (pixels == 0 or pixels > 1000 or parts.next() != null) return error.InvalidKeybind;
        return .{ .action = .resize_pane, .args = .{ .resize = .{ .direction = direction, .pixels = pixels } } };
    }
    return error.UnsupportedKeybindAction;
}
pub const Capabilities = struct {
    windows: usize = 0,
    visible_windows: ?usize = null,
    tabs: usize = 0,
    panes: usize = 0,
    total_panes: usize = 0,
    selection: bool = false,
    profiles: usize = 1,
    searching: bool = false,
    alternate: bool = false,
    primary: bool = @import("builtin").os.tag == .linux,
    link: bool = false,
    prompts: bool = false,
    sidebar: bool = false,
    preview: bool = false,
    document_workspace: bool = false,
    neighbors: [4]bool = @splat(false),
    pub fn disabled(c: Capabilities, request: Request) ?[]const u8 {
        return switch (request.action) {
            .move_preview_to_workspace => if (!c.preview or c.document_workspace) "Open a side preview first" else null,
            .open_file_preview => if (c.document_workspace) "Select a terminal workspace for a side preview" else null,
            .close_file_preview, .refresh_file_preview => if (!c.preview) "No document preview" else null,
            .preview_selected_path => if (!c.selection) "Select a local file path first" else null,
            .toggle_sidebar => if (!c.sidebar) "Select sidebar workspace navigation first" else null,
            .toggle_tab_pin => if (c.tabs == 0) "No workspace" else null,
            .new_window => null,
            .next_window, .previous_window => if ((c.visible_windows orelse c.windows) < 2) "Only one window" else null,
            .tab => null,
            .horizontal, .vertical, .split_left, .split_up => if (c.document_workspace) "Select a terminal workspace to split" else null,
            .prompt_previous, .prompt_next => if (!c.prompts) "Shell prompt integration is unavailable" else null,
            .search_next, .search_previous => if (!c.searching) "Open a search first" else null,
            .clear_screen => if (c.alternate) "Clear screen is unavailable in alternate screen" else null,
            .paste_primary => if (!c.primary) "PRIMARY selection is only available on Linux" else null,
            .open_link, .copy_link => if (!c.link) "Point to a link first" else null,
            .inspector => if (c.panes == 0) "No terminal session" else null,
            .copy, .search_selection => if (!c.selection) "Select terminal text first" else null,
            .next_pane, .previous_pane, .toggle_zoom, .equalize, .resize_pane => if (c.panes < 2) "Only one pane in this tab" else null,
            .next_tab, .previous_tab, .move_tab, .close_other_tabs => if (c.tabs < 2) "Only one tab" else null,
            .next_profile => if (c.profiles < 2) "Only one launch profile" else null,
            .focus_pane => if (!c.neighbors[@backingInt(request.normalized().args.direction)]) "No pane in that direction" else null,
            .goto_tab => if (request.index() > c.tabs) "Tab does not exist" else null,
            else => null,
        };
    }
};
test "requests retain typed parameters and consistent availability" {
    const request = try parse("increase_font_size:2.5");
    try std.testing.expectEqual(@as(f32, 2.5), request.amount());
    try std.testing.expect(!request.same(.{ .action = .font_up }));
    try std.testing.expectEqual(@as(u8, 16), (try parse("goto_tab:16")).index());
    try std.testing.expectEqual(@as(usize, 1000), (try parse("goto_tab:1000")).index());
    try std.testing.expect((Capabilities{ .tabs = 8, .total_panes = 8 }).disabled(.{ .action = .tab }) == null);
    try std.testing.expect((Capabilities{ .tabs = 8, .total_panes = 16 }).disabled(.{ .action = .tab }) == null);
    try std.testing.expectError(error.InvalidKeybind, parse("goto_tab:1.5"));
    try std.testing.expect((Capabilities{ .tabs = 16 }).disabled(.{ .action = .tab }) == null);
    try std.testing.expect((Capabilities{}).disabled(.{ .action = .copy }) != null);
}

test "split and tab arguments reject incomplete or out of range requests" {
    try std.testing.expectEqual(Direction.left, (try parse("goto_split:left")).args.direction);
    try std.testing.expectEqual(@as(u16, 10), (try parse("resize_split:up,10")).args.resize.pixels);
    try std.testing.expectEqual(@as(i8, -1), (try parse("move_tab:-1")).args.offset);
    try std.testing.expectError(error.InvalidKeybind, parse("resize_split:up"));
    try std.testing.expectError(error.InvalidKeybind, parse("resize_split:up,0"));
    try std.testing.expectEqual(@as(isize, 1000), (try parse("move_tab:1000")).args.offset);
}
