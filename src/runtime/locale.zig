//! Kero's pinned English/Simplified Chinese catalog; product additions are explicit.
const std = @import("std");
const os = @import("platform.zig");
var english: ?std.json.Parsed(std.json.Value) = null;
var chinese: ?std.json.Parsed(std.json.Value) = null;
var by_phrase: std.StringHashMapUnmanaged([]const u8) = .empty;
var active_zh = false;
var allocator: std.mem.Allocator = undefined;
pub fn init(a: std.mem.Allocator, language: []const u8) !void {
    allocator = a;
    english = try std.json.parseFromSlice(std.json.Value, a, @embedFile("locale_en"), .{});
    errdefer deinit();
    chinese = try std.json.parseFromSlice(std.json.Value, a, @embedFile("locale_zh"), .{});
    var iterator = english.?.value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string or std.mem.startsWith(u8, entry.key_ptr.*, "@")) continue;
        if (chinese.?.value.object.get(entry.key_ptr.*)) |translated| if (translated == .string) try by_phrase.put(a, entry.value_ptr.string, translated.string);
    }
    inline for (additions) |pair| try by_phrase.put(a, pair[0], pair[1]);
    select(language);
}
pub fn select(language: []const u8) void {
    const tag = if (std.mem.eql(u8, language, "system")) os.env("LC_ALL") orelse os.env("LC_MESSAGES") orelse os.env("LANG") orelse "en" else language;
    active_zh = std.mem.startsWith(u8, tag, "zh");
}
pub fn deinit() void {
    by_phrase.deinit(allocator);
    by_phrase = .empty;
    if (english) |*value| value.deinit();
    if (chinese) |*value| value.deinit();
    english = null;
    chinese = null;
    active_zh = false;
}
pub fn t(value: []const u8) []const u8 {
    if (!active_zh) return value;
    return by_phrase.get(value) orelse value;
}
pub fn isChinese() bool {
    return active_zh;
}
const additions = .{
    .{ "Show Changes", "显示更改" },
    .{ "Unavailable", "不可用" },
    .{ "Rename Workspace", "重命名工作区" },
    .{ "Close Workspace", "关闭工作区" },
    .{ "Show in Folder", "在文件夹中显示" },
    .{ "Workspace name", "工作区名称" },
    .{ "Project name", "项目名称" },
    .{ "Rename Project", "重命名项目" },
    .{ "Edit environment", "编辑环境变量" },
    .{ "Read the saved configuration from disk.", "从磁盘读取已保存的配置。" },
    .{ "Mark as read", "标为已读" },
    .{ "Copy session ID", "复制会话标识" },
    .{ "Copy directory", "复制目录" },
    .{ "Reveal directory", "显示目录" },
    .{ "Move to project", "移动到项目" },
    .{ "Diff exceeds the 100000-line preview limit. Open the file externally.", "差异超过十万行预览上限，请使用外部应用打开文件。" },
    .{ "Find in diff…", "在差异中查找…" },
    .{ "More context", "展开更多上下文" },
    .{ "All context", "展开全部上下文" },
    .{ "Collapse context", "折叠上下文" },
    .{ "Edit file", "编辑文件" },
    .{ "Save file", "保存文件" },
    .{ "Reload file", "重新加载文件" },
    .{ "Close editor", "关闭编辑器" },
    .{ "Find in file…", "在文件中查找…" },
    .{ "Next match", "下一个匹配项" },
    .{ "Undo", "撤销" },
    .{ "Redo", "重做" },
    .{ "Revert hunk", "撤销此处改动" },
    .{ "Keep", "保留" },
    .{ "Kept", "已保留" },
    .{ "Return to this pane and wait for the agent to finish before saving.", "请返回此窗格并等待智能体完成后再保存。" },
    .{ "Letty", "Letty" },
    .{ "Terminal", "终端" },
    .{ "Session", "会话" },
    .{ "Pane", "窗格" },
    .{ "View", "显示" },
    .{ "Window", "窗口" },
    .{ "Edit", "编辑" },
    .{ "Settings", "设置" },
    .{ "Default", "默认" },
    .{ "Enabled", "启用" },
    .{ "Apply", "应用" },
    .{ "Back to terminal", "返回终端" },
    .{ "Save settings", "保存设置" },
    .{ "Reload configuration", "重新加载配置" },
    .{ "Choose terminal theme…", "选择终端主题…" },
    .{ "Terminal themes", "终端主题" },
    .{ "Search Ghostty themes…", "搜索 Ghostty 主题…" },
    .{ "Use for both", "用于明暗模式" },
    .{ "Use for light", "用于浅色模式" },
    .{ "Use for dark", "用于深色模式" },
    .{ "Back to settings", "返回设置" },
    .{ "Search settings…", "搜索设置…" },
    .{ "Search sessions and commands…", "搜索会话和命令…" },
    .{ "Go to session or run a command", "前往会话或运行命令" },
    .{ "Close palette", "关闭命令面板" },
    .{ "Rename session", "重命名会话" },
    .{ "Session name", "会话名称" },
    .{ "Rename", "重命名" },
    .{ "Find in terminal…", "在终端中查找…" },
    .{ "Close find", "关闭查找" },
    .{ "Open a terminal to begin", "新建终端以开始" },
    .{ "+ New terminal", "+ 新建终端" },
    .{ "Dim unfocused terminals", "淡化未聚焦的终端" },
    .{ "Refresh", "刷新" },
    .{ "Close changes", "关闭改动面板" },
    .{ "Reading repository…", "正在读取仓库…" },
    .{ "No agent turn snapshot yet. Showing uncommitted changes.", "尚无智能体回合快照，显示未提交的改动。" },
    .{ "Choose a changed file", "选择已改动的文件" },
    .{ "Agent turn", "智能体回合" },
    .{ "Open file", "打开文件" },
    .{ "Copy selection", "复制所选内容" },
    .{ "Paste", "粘贴" },
    .{ "Select all", "全选" },
    .{ "Clear terminal", "清空终端" },
    .{ "Open link", "打开链接" },
    .{ "Copy link", "复制链接" },
    .{ "Environment", "环境变量" },
    .{ "One NAME=value per line. Applied to new terminals.", "每行一个 NAME=value，仅用于新建终端。" },
    .{ "This list exceeds the form limit. Use Edit configuration.", "列表超出表单容量，请使用“编辑配置文件”。" },
    .{ "Save environment", "保存环境变量" },
    .{ "Search shortcuts…", "搜索快捷键…" },
    .{ "Back to settings", "返回设置" },
    .{ "Keyboard shortcuts", "键盘快捷键" },
    .{ "Edit configuration", "编辑配置文件" },
    .{ "Record shortcut", "录制快捷键" },
    .{ "Press a key combination; Escape cancels.", "请按下组合键，按 Escape 取消。" },
    .{ "Unbind", "取消绑定" },
    .{ "Reset", "恢复默认" },
    .{ "New terminal directory", "新终端的目录" },
    .{ "Session naming", "会话命名方式" },
    .{ "Focus follows mouse", "焦点跟随鼠标" },
    .{ "Confirm close", "关闭前确认" },
    .{ "Appearance", "外观" },
    .{ "Language", "语言" },
    .{ "Background", "背景" },
    .{ "Window translucency", "窗口半透明" },
    .{ "Font family", "字体" },
    .{ "Font size", "字号" },
    .{ "Font weight", "字重" },
    .{ "Line height", "行高" },
    .{ "Font ligatures", "字体连字" },
    .{ "Thicken text", "加粗文字" },
    .{ "Minimum contrast", "最低对比度" },
    .{ "Cursor shape", "光标形状" },
    .{ "Blink cursor", "光标闪烁" },
    .{ "Terminal theme", "终端主题" },
    .{ "Option as Alt", "将 Option 用作 Alt" },
    .{ "Copy on select", "选中即复制" },
    .{ "Program clipboard reads", "程序读取剪贴板" },
    .{ "Right click", "右键操作" },
    .{ "Shell", "Shell" },
    .{ "Scrollback limit (MiB)", "回滚容量（MiB）" },
    .{ "Notify when waiting", "等待输入时通知" },
    .{ "Notify when done", "完成时通知" },
    .{ "Notify on error", "出错时通知" },
    .{ "Notification sound", "通知声音" },
    .{ "Dock badge", "程序坞角标" },
    .{ "Request attention", "请求注意" },
    .{ "Show Git status", "显示版本控制状态" },
    .{ "Diff layout", "差异布局" },
};
test "locale switches pinned phrases and product additions without changing source text" {
    try init(std.testing.allocator, "zh-Hans");
    defer deinit();
    try std.testing.expectEqualStrings("设置", t("Settings"));
    try std.testing.expectEqualStrings("新建会话", t("New Session"));
    try std.testing.expectEqualStrings("/tmp/filename", t("/tmp/filename"));
    select("en");
    try std.testing.expectEqualStrings("Settings", t("Settings"));
}
