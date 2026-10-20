//! The palette exposes application actions, never evaluates typed shell commands.
const std = @import("std");
const actions = @import("actions.zig");
const Action = actions.Action;
pub const Entry = struct {
    title: []const u8,
    keywords: []const u8,
    action: Action,
    args: actions.Argument = .none,
    pub fn request(e: Entry) actions.Request {
        return (actions.Request{ .action = e.action, .args = e.args }).normalized();
    }
};
pub fn title(action: Action) []const u8 {
    for (entries) |entry| if (entry.action == action) return entry.title;
    return if (action == .palette) "Command Palette…" else @tagName(action);
}
pub const entries = [_]Entry{
    .{ .title = "Open File in Workspace…", .keywords = "open_file_workspace markdown document 文件 工作区", .action = .open_file_workspace },
    .{ .title = "Move Preview to Workspace", .keywords = "move_preview_to_workspace expand document 文件 预览 工作区", .action = .move_preview_to_workspace },
    .{ .title = "Open File in Side Preview…", .keywords = "open_file_preview file markdown 文件 预览", .action = .open_file_preview },
    .{ .title = "Preview Selected Path", .keywords = "preview_selected_path 文件 所选 路径", .action = .preview_selected_path },
    .{ .title = "Close Document Preview", .keywords = "close_file_preview 关闭 文档", .action = .close_file_preview },
    .{ .title = "Show / Hide File Preview", .keywords = "toggle_file_preview 文档 收起 显示", .action = .toggle_file_preview },
    .{ .title = "Refresh Document Preview", .keywords = "refresh_file_preview 文档 刷新", .action = .refresh_file_preview },
    .{ .title = "Settings…", .keywords = "open_settings 设置 偏好", .action = .open_settings },
    .{ .title = "Toggle Workspace Sidebar", .keywords = "toggle_sidebar 工作区 侧栏", .action = .toggle_sidebar },
    .{ .title = "Pin / Unpin Workspace", .keywords = "toggle_tab_pin 置顶 工作区", .action = .toggle_tab_pin },
    .{ .title = "Terminal Inspector", .keywords = "inspector:toggle toggle_inspector 终端 检查器 字体 渲染", .action = .inspector },
    .{ .title = "Toggle Quick Terminal", .keywords = "toggle_quick_terminal 下拉终端", .action = .toggle_quick_terminal },
    .{ .title = "New Tab", .keywords = "new_tab 新建 标签", .action = .tab },
    .{ .title = "Split: Right", .keywords = "new_split:right horizontal 分屏 右", .action = .horizontal },
    .{ .title = "Split: Down", .keywords = "new_split:down vertical 分屏 下", .action = .vertical },
    .{ .title = "Find…", .keywords = "start_search search 搜索 查找", .action = .search },
    .{ .title = "Reload Configuration", .keywords = "reload_config config 重载 配置", .action = .reload },
    .{ .title = "Copy", .keywords = "copy_to_clipboard 复制", .action = .copy },
    .{ .title = "Paste PRIMARY Selection", .keywords = "paste_from_selection PRIMARY 中键 粘贴", .action = .paste_primary },
    .{ .title = "Paste", .keywords = "paste_from_clipboard 粘贴", .action = .paste },
    .{ .title = "Font Size: Increase", .keywords = "increase_font_size zoom in 字体 放大", .action = .font_up },
    .{ .title = "Font Size: Increase by 2", .keywords = "increase_font_size:2 字体 放大", .action = .font_up, .args = .{ .amount = 2 } },
    .{ .title = "Font Size: Decrease", .keywords = "decrease_font_size zoom out 字体 缩小", .action = .font_down },
    .{ .title = "Font Size: Reset", .keywords = "reset_font_size 字体 重置", .action = .font_reset },
    .{ .title = "Tab: Next", .keywords = "next_tab 标签 下一个", .action = .next_tab },
    .{ .title = "Tab: Previous", .keywords = "previous_tab 标签 上一个", .action = .previous_tab },
    .{ .title = "Split: Next", .keywords = "goto_split:next pane 分屏 下一个", .action = .next_pane },
    .{ .title = "Next Launch Profile", .keywords = "next_launch_profile profile 启动 预设", .action = .next_profile },
    .{ .title = "Save Layout", .keywords = "save_layout save 布局 保存", .action = .save },
    .{ .title = "Close Pane", .keywords = "close_surface 关闭 分屏", .action = .close },
    .{ .title = "Close Tab", .keywords = "close_tab 关闭 标签", .action = .close_tab },
    .{ .title = "Close Window", .keywords = "close_window 关闭 窗口", .action = .close_window },
    .{ .title = "Quit Letty", .keywords = "quit exit 退出", .action = .quit },
    .{ .title = "Split: Left", .keywords = "new_split:left 分屏 左", .action = .split_left },
    .{ .title = "Split: Up", .keywords = "new_split:up 分屏 上", .action = .split_up },
    .{ .title = "Split: Previous", .keywords = "goto_split:previous 分屏 上一个", .action = .previous_pane },
    .{ .title = "Split: Zoom / Restore", .keywords = "toggle_split_zoom 放大 还原", .action = .toggle_zoom },
    .{ .title = "Split: Equalize All", .keywords = "equalize_splits 均分", .action = .equalize },
    .{ .title = "Tab: Rename…", .keywords = "prompt_tab_title rename_tab 标签 重命名", .action = .rename_tab },
    .{ .title = "Focus Split: Left", .keywords = "goto_split:left focus 分屏 方向", .action = .focus_pane, .args = .{ .direction = .left } },
    .{ .title = "Resize Split: Left 10px", .keywords = "resize_split:left,10 分屏 调整", .action = .resize_pane, .args = .{ .resize = .{ .direction = .left, .pixels = 10 } } },
    .{ .title = "Focus Split: Right", .keywords = "goto_split:right focus 分屏 方向", .action = .focus_pane, .args = .{ .direction = .right } },
    .{ .title = "Resize Split: Right 10px", .keywords = "resize_split:right,10 分屏 调整", .action = .resize_pane, .args = .{ .resize = .{ .direction = .right, .pixels = 10 } } },
    .{ .title = "Focus Split: Up", .keywords = "goto_split:up focus 分屏 方向", .action = .focus_pane, .args = .{ .direction = .up } },
    .{ .title = "Resize Split: Up 10px", .keywords = "resize_split:up,10 分屏 调整", .action = .resize_pane, .args = .{ .resize = .{ .direction = .up, .pixels = 10 } } },
    .{ .title = "Focus Split: Down", .keywords = "goto_split:down focus 分屏 方向", .action = .focus_pane, .args = .{ .direction = .down } },
    .{ .title = "Resize Split: Down 10px", .keywords = "resize_split:down,10 分屏 调整", .action = .resize_pane, .args = .{ .resize = .{ .direction = .down, .pixels = 10 } } },
    .{ .title = "Tab: Move Left", .keywords = "move_tab:-1 标签 移动", .action = .move_tab, .args = .{ .offset = -1 } },
    .{ .title = "Tab: Move Right", .keywords = "move_tab:1 标签 移动", .action = .move_tab, .args = .{ .offset = 1 } },
    .{ .title = "Tab: Go to 1", .keywords = "goto_tab:1 标签", .action = .goto_tab, .args = .{ .index = 1 } },
    .{ .title = "Tab: Go to 2", .keywords = "goto_tab:2 标签", .action = .goto_tab, .args = .{ .index = 2 } },
    .{ .title = "Tab: Go to 3", .keywords = "goto_tab:3 标签", .action = .goto_tab, .args = .{ .index = 3 } },
    .{ .title = "Tab: Go to 4", .keywords = "goto_tab:4 标签", .action = .goto_tab, .args = .{ .index = 4 } },
    .{ .title = "Tab: Go to 5", .keywords = "goto_tab:5 标签", .action = .goto_tab, .args = .{ .index = 5 } },
    .{ .title = "Tab: Go to 6", .keywords = "goto_tab:6 标签", .action = .goto_tab, .args = .{ .index = 6 } },
    .{ .title = "Tab: Go to 7", .keywords = "goto_tab:7 标签", .action = .goto_tab, .args = .{ .index = 7 } },
    .{ .title = "Tab: Go to 8", .keywords = "goto_tab:8 标签", .action = .goto_tab, .args = .{ .index = 8 } },
    .{ .title = "Tab: Go to 9", .keywords = "goto_tab:9 标签", .action = .goto_tab, .args = .{ .index = 9 } },
    .{ .title = "Tab: Go to 10", .keywords = "goto_tab:10 标签", .action = .goto_tab, .args = .{ .index = 10 } },
    .{ .title = "Tab: Go to 11", .keywords = "goto_tab:11 标签", .action = .goto_tab, .args = .{ .index = 11 } },
    .{ .title = "Tab: Go to 12", .keywords = "goto_tab:12 标签", .action = .goto_tab, .args = .{ .index = 12 } },
    .{ .title = "Tab: Go to 13", .keywords = "goto_tab:13 标签", .action = .goto_tab, .args = .{ .index = 13 } },
    .{ .title = "Tab: Go to 14", .keywords = "goto_tab:14 标签", .action = .goto_tab, .args = .{ .index = 14 } },
    .{ .title = "Tab: Go to 15", .keywords = "goto_tab:15 标签", .action = .goto_tab, .args = .{ .index = 15 } },
    .{ .title = "Tab: Go to 16", .keywords = "goto_tab:16 标签", .action = .goto_tab, .args = .{ .index = 16 } },
    .{ .title = "Scroll: Top", .keywords = "scroll_to_top 历史 顶部", .action = .scroll_top },
    .{ .title = "Scroll: Bottom", .keywords = "scroll_to_bottom 历史 底部", .action = .scroll_bottom },
    .{ .title = "Scroll: Page Up", .keywords = "scroll_page_up 历史 上一页", .action = .page_up },
    .{ .title = "Scroll: Page Down", .keywords = "scroll_page_down 历史 下一页", .action = .page_down },
    .{ .title = "Select All", .keywords = "select_all 全选", .action = .select_all },
    .{ .title = "Clear Screen and Scrollback", .keywords = "clear_screen 清屏 清除 历史", .action = .clear_screen },
    .{ .title = "Reset Terminal", .keywords = "reset 重置 终端", .action = .reset },
    .{ .title = "Find: Next Match", .keywords = "navigate_search:next 搜索 下一个", .action = .search_next },
    .{ .title = "Find: Previous Match", .keywords = "navigate_search:previous 搜索 上一个", .action = .search_previous },
    .{ .title = "Find: Close", .keywords = "end_search 搜索 关闭", .action = .end_search },
    .{ .title = "Close Other Tabs", .keywords = "close_other_tabs 关闭 其他 标签", .action = .close_other_tabs },
    .{ .title = "Open Configuration…", .keywords = "open_config 打开 配置", .action = .open_config },
    .{ .title = "Browse Themes…", .keywords = "open_theme_browser theme color 主题 配色", .action = .open_theme_browser },
    .{ .title = "Configuration Diagnostics…", .keywords = "show_config_diagnostics 诊断 配置", .action = .diagnostics },
    .{ .title = "Find Selection", .keywords = "search_selection 搜索 选区", .action = .search_selection },

    .{ .title = "Open Link", .keywords = "open_link URL 链接 打开", .action = .open_link },
    .{ .title = "Copy Link Target", .keywords = "copy_url_to_clipboard URL 链接 复制", .action = .copy_link },

    .{ .title = "Previous Shell Prompt", .keywords = "jump_to_prompt:-1 上一 提示符", .action = .prompt_previous },
    .{ .title = "Next Shell Prompt", .keywords = "jump_to_prompt:1 下一 提示符", .action = .prompt_next },
    .{ .title = "New Window", .keywords = "new_window 新建 窗口", .action = .new_window },
    .{ .title = "Next Window", .keywords = "goto_window:next 下一 窗口", .action = .next_window },
    .{ .title = "Previous Window", .keywords = "goto_window:previous 上一 窗口", .action = .previous_window },
};
pub const Matches = struct { indices: [entries.len]usize = undefined, len: usize = 0 };
fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    return false;
}
fn matches(entry: Entry, query: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, query, " \t\r\n");
    while (words.next()) |word| if (!contains(entry.title, word) and !contains(entry.keywords, word)) return false;
    return true;
}
pub fn filter(query: []const u8) Matches {
    var result: Matches = .{};
    for (entries, 0..) |entry, i| if (matches(entry, query)) {
        result.indices[result.len] = i;
        result.len += 1;
    };
    return result;
}
test "palette searches titles, action names and translated keywords" {
    try std.testing.expectEqual(entries.len, filter(" \t ").len);
    const reload = filter("CONFIG reload");
    try std.testing.expectEqual(@as(usize, 1), reload.len);
    try std.testing.expectEqual(Action.reload, entries[reload.indices[0]].action);
    try std.testing.expectEqual(@as(usize, 1), filter("new_split:right").len);
    try std.testing.expectEqual(@as(usize, 1), filter("重载 配置").len);
    try std.testing.expectEqual(@as(usize, 0), filter("xyz_no_such_command").len);
}
