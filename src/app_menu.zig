//! Native menu presentation shares command metadata and dispatcher requests.
const std = @import("std");
const nano = @import("nanoui");
const bindings = @import("keybindings.zig");
const catalogue = @import("command_catalogue.zig");
const Action = @import("actions.zig").Action;
const Request = @import("actions.zig").Request;
pub fn clicked(s: anytype, item: *nano.menu.Item) void {
    const request: Request = blk: {
        if (std.meta.stringToEnum(Action, item.id)) |action| break :blk .{ .action = action };
        for (catalogue.entries) |entry| if (std.mem.eql(u8, item.id, entry.keywords)) break :blk entry.request();
        return;
    };
    if (s.menu_action_count < s.menu_actions.len) {
        s.menu_actions[s.menu_action_count] = request;
        s.menu_action_count += 1;
    } else s.status = "Too many pending commands. Please retry.";
    if (s.window) |w| w.redraw();
}
fn menuItem(s: anytype, action: Action, click: nano.MenuClick) nano.MenuItem {
    return menuRequest(s, .{ .action = action }, click);
}
fn menuRequest(s: anytype, request: Request, click: nano.MenuClick) nano.MenuItem {
    for (catalogue.entries) |entry| if (entry.request().same(request)) return .{ .label = entry.title, .id = entry.keywords, .accelerator = bindings.nativeAcceleratorFor(s.cfg.keybinds, s.cfg.clear_default_keybinds, request), .click = click };
    return .{ .label = catalogue.title(request.action), .id = @tagName(request.action), .accelerator = bindings.nativeAcceleratorFor(s.cfg.keybinds, s.cfg.clear_default_keybinds, request), .click = click };
}
pub fn install(s: anytype) !void {
    const host = s.host;
    if (host.settings_focused) return installSettings(host);
    const click = nano.MenuClick.of(host, struct {
        fn call(app: @TypeOf(host), entry: *nano.menu.Item) void {
            if (std.mem.eql(u8, entry.id, "new_window")) {
                app.queue(.{ .action = .new_window });
                return;
            }
            for (catalogue.entries) |command| if (std.mem.eql(u8, entry.id, command.keywords)) {
                app.queue(command.request());
                return;
            };
            if (std.meta.stringToEnum(Action, entry.id)) |action| app.queue(.{ .action = action });
        }
    }.call);
    try s.app.setMenu(&.{
        .{ .label = "Letty", .submenu = &.{
            .{ .role = .about },                .separator,
            menuItem(s, .open_settings, click), .separator,
            .{ .role = .hide },                 .{ .role = .hide_others },
            .{ .role = .unhide },               .separator,
            menuItem(s, .quit, click),
        } },
        .{ .label = "File", .submenu = &.{
            menuItem(s, .open_file_workspace, click),
            menuItem(s, .open_file_preview, click),
            menuItem(s, .move_preview_to_workspace, click),
            menuItem(s, .preview_selected_path, click),
            .separator,
            .{ .label = "Next Launch Profile", .id = "next_profile", .hidden = s.cfg.profiles.len <= 1, .click = click },
            menuItem(s, .new_window, click),
            menuItem(s, .tab, click),
            .separator,
            menuItem(s, .horizontal, click),
            menuItem(s, .vertical, click),
            menuItem(s, .split_left, click),
            menuItem(s, .split_up, click),
            .separator,
            menuItem(s, .save, click),
            .separator,
            menuItem(s, .close, click),
            menuItem(s, .close_tab, click),
            menuItem(s, .close_other_tabs, click),
            menuItem(s, .close_window, click),
        } },
        .{ .label = "Edit", .submenu = &.{
            menuItem(s, .copy, click),
            menuItem(s, .paste, click),
            .separator,
            menuItem(s, .reload, click),
            menuItem(s, .open_config, click),
            menuItem(s, .diagnostics, click),
            menuItem(s, .search, click),
            menuItem(s, .search_next, click),
            menuItem(s, .search_previous, click),
            menuItem(s, .select_all, click),
            menuItem(s, .clear_screen, click),
            menuItem(s, .reset, click),
        } },
        .{ .label = "View", .submenu = &.{
            menuItem(s, .palette, click),
            menuItem(s, .toggle_sidebar, click),
            menuItem(s, .toggle_file_preview, click),
            menuItem(s, .refresh_file_preview, click),
            menuItem(s, .close_file_preview, click),
            menuItem(s, .toggle_tab_pin, click),
            .separator,
            menuItem(s, .font_up, click),
            menuItem(s, .font_down, click),
            menuItem(s, .font_reset, click),
            menuItem(s, .scroll_top, click),
            menuItem(s, .scroll_bottom, click),
            menuItem(s, .page_up, click),
            menuItem(s, .page_down, click),
            .separator,
            menuItem(s, .next_window, click),
            menuItem(s, .previous_window, click),
            menuItem(s, .previous_tab, click),
            menuItem(s, .next_tab, click),
            menuItem(s, .next_pane, click),
            menuItem(s, .previous_pane, click),
            menuRequest(s, .{ .action = .focus_pane, .args = .{ .direction = .left } }, click),
            menuRequest(s, .{ .action = .focus_pane, .args = .{ .direction = .right } }, click),
            menuRequest(s, .{ .action = .focus_pane, .args = .{ .direction = .up } }, click),
            menuRequest(s, .{ .action = .focus_pane, .args = .{ .direction = .down } }, click),
            menuItem(s, .toggle_zoom, click),
            menuItem(s, .equalize, click),
            menuItem(s, .rename_tab, click),
            menuRequest(s, .{ .action = .move_tab, .args = .{ .offset = -1 } }, click),
            menuRequest(s, .{ .action = .move_tab, .args = .{ .offset = 1 } }, click),
            .separator,
            .{ .role = .toggle_full_screen },
        } },
        .{ .role = .window_menu },
    });
}

pub fn installSettings(h: anytype) !void {
    const click = nano.MenuClick.of(h, struct {
        fn call(host: @TypeOf(h), item: *nano.menu.Item) void {
            if (std.meta.stringToEnum(Action, item.id)) |action| host.queue(.{ .action = action });
        }
    }.call);
    try h.app.setMenu(&.{
        .{ .label = "Letty", .submenu = &.{
            .{ .role = .about }, .separator,
            .{ .label = "Settings…", .id = "open_settings", .accelerator = bindings.nativeAcceleratorFor(h.cfg.keybinds, h.cfg.clear_default_keybinds, .{ .action = .open_settings }), .click = click },
            .separator,          .{ .label = "Quit", .id = "quit", .accelerator = bindings.nativeAcceleratorFor(h.cfg.keybinds, h.cfg.clear_default_keybinds, .{ .action = .quit }), .click = click },
        } },
        .{ .label = "File", .submenu = &.{.{ .label = "New Window", .id = "new_window", .accelerator = bindings.nativeAcceleratorFor(h.cfg.keybinds, h.cfg.clear_default_keybinds, .{ .action = .new_window }), .click = click }} },
        .{ .role = .edit_menu },
        .{ .role = .window_menu },
    });
}
