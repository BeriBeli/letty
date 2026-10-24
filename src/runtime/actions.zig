//! Local action catalog, shared by menus, palette and bindings.
const std = @import("std");
pub const Key = struct { key: u21, cmd: bool = false, ctrl: bool = false, alt: bool = false, shift: bool = false };
pub const Action = struct { id: []const u8, title: []const u8, menu: []const u8, mac: []const u8, pc: []const u8, implemented: bool = true };
pub const all = [_]Action{
    .{ .id = "settings.open", .title = "Settings…", .menu = "Letty", .mac = "CmdOrCtrl+,", .pc = "Ctrl+," },
    .{ .id = "session.new", .title = "New Session", .menu = "Session", .mac = "CmdOrCtrl+T", .pc = "Ctrl+Shift+T" },
    .{ .id = "session.newHome", .title = "New Session in Home", .menu = "Session", .mac = "CmdOrCtrl+Shift+T", .pc = "" },
    .{ .id = "document.open", .title = "Open File in Workspace…", .menu = "Session", .mac = "CmdOrCtrl+O", .pc = "Ctrl+Shift+O" },
    .{ .id = "document.side", .title = "Open File in Side Preview…", .menu = "Session", .mac = "CmdOrCtrl+Alt+O", .pc = "Ctrl+Alt+Shift+O" },
    .{ .id = "document.toggle", .title = "Toggle Side Preview", .menu = "View", .mac = "CmdOrCtrl+Shift+O", .pc = "Ctrl+Alt+O" },
    .{ .id = "document.selected", .title = "Preview Selected Path", .menu = "Session", .mac = "", .pc = "" },
    .{ .id = "document.save", .title = "Save Document", .menu = "Edit", .mac = "CmdOrCtrl+S", .pc = "Ctrl+S" },
    .{ .id = "document.refresh", .title = "Refresh Document", .menu = "View", .mac = "", .pc = "" },
    .{ .id = "document.edit", .title = "Edit Document Source", .menu = "Edit", .mac = "", .pc = "" },
    .{ .id = "project.open", .title = "Open Project…", .menu = "Session", .mac = "CmdOrCtrl+Alt+P", .pc = "Ctrl+Alt+P" },
    .{ .id = "palette.open", .title = "Go to Session…", .menu = "Session", .mac = "CmdOrCtrl+P", .pc = "Ctrl+Shift+P" },
    .{ .id = "session.attention", .title = "Jump to Session Needing You", .menu = "Session", .mac = "CmdOrCtrl+J", .pc = "Ctrl+Shift+J" },
    .{ .id = "session.next", .title = "Next Session", .menu = "Session", .mac = "CmdOrCtrl+Shift+]", .pc = "Ctrl+PageDown" },
    .{ .id = "session.previous", .title = "Previous Session", .menu = "Session", .mac = "CmdOrCtrl+Shift+[", .pc = "Ctrl+PageUp" },
    .{ .id = "session.rename", .title = "Rename Session", .menu = "Session", .mac = "CmdOrCtrl+R", .pc = "" },
    .{ .id = "pane.restart", .title = "Restart Pane", .menu = "Session", .mac = "CmdOrCtrl+Shift+R", .pc = "Ctrl+Shift+R" },
    .{ .id = "pane.close", .title = "Close", .menu = "Session", .mac = "CmdOrCtrl+W", .pc = "Ctrl+Shift+W" },
    .{ .id = "session.close", .title = "Close Session", .menu = "Session", .mac = "CmdOrCtrl+Shift+W", .pc = "" },
    .{ .id = "find.open", .title = "Find…", .menu = "Edit", .mac = "CmdOrCtrl+F", .pc = "Ctrl+Shift+F" },
    .{ .id = "find.next", .title = "Find Next", .menu = "Edit", .mac = "CmdOrCtrl+G", .pc = "" },
    .{ .id = "find.previous", .title = "Find Previous", .menu = "Edit", .mac = "CmdOrCtrl+Shift+G", .pc = "" },
    .{ .id = "pane.split.right", .title = "Split Right", .menu = "Pane", .mac = "CmdOrCtrl+D", .pc = "Alt+Shift+=" },
    .{ .id = "pane.split.down", .title = "Split Down", .menu = "Pane", .mac = "CmdOrCtrl+Shift+D", .pc = "Alt+Shift+-" },
    .{ .id = "pane.zoom", .title = "Zoom Pane", .menu = "Pane", .mac = "CmdOrCtrl+Shift+Enter", .pc = "Ctrl+Shift+Enter" },
    .{ .id = "pane.next", .title = "Next Pane", .menu = "Pane", .mac = "CmdOrCtrl+]", .pc = "Ctrl+Shift+]" },
    .{ .id = "pane.previous", .title = "Previous Pane", .menu = "Pane", .mac = "CmdOrCtrl+[", .pc = "Ctrl+Shift+[" },
    .{ .id = "pane.left", .title = "Pane Left", .menu = "Pane", .mac = "CmdOrCtrl+Alt+Left", .pc = "Alt+Left" },
    .{ .id = "pane.right", .title = "Pane Right", .menu = "Pane", .mac = "CmdOrCtrl+Alt+Right", .pc = "Alt+Right" },
    .{ .id = "pane.up", .title = "Pane Above", .menu = "Pane", .mac = "CmdOrCtrl+Alt+Up", .pc = "Alt+Up" },
    .{ .id = "pane.down", .title = "Pane Below", .menu = "Pane", .mac = "CmdOrCtrl+Alt+Down", .pc = "Alt+Down" },
    .{ .id = "sidebar.toggle", .title = "Toggle Sidebar", .menu = "View", .mac = "CmdOrCtrl+B", .pc = "Ctrl+Shift+B" },
    .{ .id = "changes.toggle", .title = "Toggle Changes", .menu = "View", .mac = "CmdOrCtrl+Alt+G", .pc = "Ctrl+Shift+G" },
    .{ .id = "text.bigger", .title = "Bigger", .menu = "View", .mac = "CmdOrCtrl+=", .pc = "Ctrl+=" },
    .{ .id = "text.smaller", .title = "Smaller", .menu = "View", .mac = "CmdOrCtrl+-", .pc = "Ctrl+-" },
    .{ .id = "text.reset", .title = "Actual Size", .menu = "View", .mac = "CmdOrCtrl+0", .pc = "Ctrl+0" },
    .{ .id = "window.new", .title = "New Window", .menu = "Session", .mac = "Cmd+N", .pc = "Ctrl+Shift+N" },
    .{ .id = "app.quit", .title = "Quit Letty", .menu = "Letty", .mac = "Cmd+Q", .pc = "" },
    .{ .id = "edit.copy", .title = "Copy", .menu = "Edit", .mac = "Cmd+C", .pc = "Ctrl+Shift+C" },
    .{ .id = "edit.paste", .title = "Paste", .menu = "Edit", .mac = "Cmd+V", .pc = "Ctrl+Shift+V" },
    .{ .id = "edit.selectAll", .title = "Select All", .menu = "Edit", .mac = "Cmd+A", .pc = "Ctrl+Shift+A" },
    .{ .id = "terminal.clear", .title = "Clear Screen", .menu = "Edit", .mac = "Cmd+K", .pc = "Ctrl+Shift+K" },
};
pub fn known(id: []const u8) bool {
    for (all) |a| if (std.mem.eql(u8, a.id, id)) return true;
    return false;
}
pub fn parse(raw: []const u8, mac: bool) !Key {
    if (raw.len == 0) return error.EmptyShortcut;
    var result: Key = .{ .key = 0 };
    var parts = std.mem.splitScalar(u8, raw, '+');
    while (parts.next()) |part_| {
        const part = std.mem.trim(u8, part_, " \t");
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(part, "cmdorctrl") or eq(part, "cmd") or eq(part, "super") or eq(part, "command") or eq(part, "meta")) {
            if (mac) result.cmd = true else result.ctrl = true;
        } else if (eq(part, "ctrl") or eq(part, "control")) result.ctrl = true else if (eq(part, "alt") or eq(part, "option") or eq(part, "opt")) result.alt = true else if (eq(part, "shift")) result.shift = true else {
            const names = .{ .{ "Left", @as(u21, 0xf702) }, .{ "Right", @as(u21, 0xf703) }, .{ "Up", @as(u21, 0xf700) }, .{ "Down", @as(u21, 0xf701) }, .{ "PageUp", @as(u21, 0xf72c) }, .{ "PageDown", @as(u21, 0xf72d) }, .{ "Enter", @as(u21, 13) }, .{ "Return", @as(u21, 13) }, .{ "Tab", @as(u21, 9) }, .{ "Escape", @as(u21, 27) }, .{ "Space", @as(u21, 32) }, .{ "Plus", @as(u21, '+') } };
            var found = false;
            inline for (names) |n| if (eq(part, n[0])) {
                result.key = n[1];
                found = true;
            };
            if (!found and part.len >= 2 and (part[0] == 'f' or part[0] == 'F')) {
                const number = std.fmt.parseInt(u8, part[1..], 10) catch 0;
                if (number >= 1 and number <= 24) {
                    result.key = 0xf703 + @as(u21, number);
                    found = true;
                }
            }
            if (!found) {
                if (part.len == 0) {
                    result.key = '+';
                    continue;
                }
                var it = (try std.unicode.Utf8View.init(part)).iterator();
                const cp = it.nextCodepoint() orelse return error.InvalidShortcut;
                if (it.nextCodepoint() != null) return error.InvalidShortcut;
                result.key = lower(cp);
            }
        }
    }
    if (result.key == 0) return error.InvalidShortcut;
    return result;
}
pub fn eql(a: Key, b: Key) bool {
    return a.key == b.key and a.cmd == b.cmd and a.ctrl == b.ctrl and a.alt == b.alt and a.shift == b.shift;
}
pub fn keys(index: usize, bindings: []const []const u8, mac: bool) []const u8 {
    const action = all[index];
    var key = if (mac) action.mac else action.pc;
    for (bindings) |binding| {
        const at = std.mem.lastIndexOfScalar(u8, binding, '=') orelse continue;
        const raw = std.mem.trim(u8, binding[0..at], " \t");
        const id = std.mem.trim(u8, binding[at + 1 ..], " \t");
        if (std.mem.eql(u8, id, action.id)) key = if (std.mem.eql(u8, raw, "none")) "" else raw else if (key.len > 0 and (known(id) or std.mem.eql(u8, id, "unbind"))) {
            const a = parse(key, mac) catch continue;
            const b = parse(raw, mac) catch continue;
            if (eql(a, b)) key = "";
        }
    }
    return key;
}
pub fn match(event: Key, bindings: []const []const u8, mac: bool) ?[]const u8 {
    // Later actions win a collision, matching an explicit override.
    var result: ?[]const u8 = null;
    for (all, 0..) |a, i| {
        if (!a.implemented) continue;
        const key = parse(keys(i, bindings, mac), mac) catch continue;
        if (eql(event, key)) result = a.id;
    }
    return result;
}
fn lower(cp: u21) u21 {
    return if (cp < 128) std.ascii.toLower(@intCast(cp)) else cp;
}
/// Kero's run/word-start scoring, walking UTF-8 codepoints rather than bytes.
pub fn fuzzy(query: []const u8, subject: []const u8) i32 {
    if (query.len == 0) return 0;
    var q = (std.unicode.Utf8View.init(query) catch return -1).iterator();
    var target = q.nextCodepoint();
    while (target != null and target.? == ' ') target = q.nextCodepoint();
    var s = (std.unicode.Utf8View.init(subject) catch return -1).iterator();
    var score: i32 = 0;
    var run: i32 = 0;
    var count: i32 = 0;
    var previous: u21 = 0;
    while (s.nextCodepoint()) |cp| {
        count += 1;
        if (target) |want| {
            if (lower(want) == lower(cp)) {
                run += 1;
                score += 1 + run * 2 + @as(i32, if (count == 1 or (previous < 128 and !std.ascii.isAlphanumeric(@intCast(previous)))) 6 else 0);
                target = q.nextCodepoint();
                while (target != null and target.? == ' ') target = q.nextCodepoint();
            } else run = 0;
        }
        previous = cp;
    }
    return if (target != null) -1 else score * 10 - count;
}
test "Letty platform shortcuts preserve shell controls and support unbind/rebind" {
    const t = std.testing;
    try t.expect(match(.{ .key = 'd', .ctrl = true }, &.{}, false) == null);
    try t.expectEqualStrings("pane.split.right", match(.{ .key = '=', .alt = true, .shift = true }, &.{}, false).?);
    try t.expect(match(.{ .key = 't', .cmd = true }, &.{"cmd+t=unbind"}, true) == null);
    try t.expectEqualStrings("session.new", match(.{ .key = 'x', .cmd = true }, &.{ "cmd+t=unbind", "cmd+x=session.new" }, true).?);
    try t.expect(fuzzy("git", "Git Changes") > fuzzy("git", "a git directory"));
    try t.expect(fuzzy("终端", "新终端") >= 0);
    try t.expectEqual(@as(i32, -1), fuzzy("zz", "terminal"));
}

/// Inverse of parse; uses named special keys so persisted shortcuts are portable.
pub fn format(a: std.mem.Allocator, key: Key) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    if (key.cmd) try out.writer.writeAll("Cmd+");
    if (key.ctrl) try out.writer.writeAll("Ctrl+");
    if (key.alt) try out.writer.writeAll("Alt+");
    if (key.shift) try out.writer.writeAll("Shift+");
    const special: ?[]const u8 = switch (key.key) {
        13 => "Enter",
        9 => "Tab",
        27 => "Escape",
        32 => "Space",
        '+' => "Plus",
        0xf702 => "Left",
        0xf703 => "Right",
        0xf700 => "Up",
        0xf701 => "Down",
        0xf72c => "PageUp",
        0xf72d => "PageDown",
        else => null,
    };
    if (special) |name| try out.writer.writeAll(name) else if (key.key >= 0xf704 and key.key <= 0xf71b) try out.writer.print("F{d}", .{key.key - 0xf703}) else {
        var bytes: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(key.key, &bytes);
        try out.writer.writeAll(bytes[0..n]);
    }
    return out.toOwnedSlice();
}
test "explicit bindings win default collisions and named shortcuts round trip" {
    const t = std.testing;
    try t.expectEqualStrings("session.new", match(.{ .key = 'w', .cmd = true }, &.{"Cmd+W=session.new"}, true).?);
    try t.expect(match(.{ .key = 'w', .cmd = true }, &.{"none=pane.close"}, true) == null);
    const a = t.allocator;
    for ([_][]const u8{ "Ctrl+F5", "Alt+F24", "Cmd+Shift+Plus", "Ctrl+PageDown" }) |raw| {
        const k = try parse(raw, true);
        const value = try format(a, k);
        defer a.free(value);
        try t.expect(eql(k, try parse(value, true)));
    }
}
