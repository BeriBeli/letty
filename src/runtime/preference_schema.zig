//! Human labels and finite choices for the native settings form.
const std = @import("std");
pub const Field = struct { title: []const u8, group: []const u8, choices: []const []const u8 = &.{} };
pub fn field(key: []const u8) Field {
    const entries = .{
        .{ "new-session-directory", "New sessions start in", "General", &[_][]const u8{ "current", "project", "home" } },
        .{ "session-name", "Name sessions after", "General", &[_][]const u8{ "focused", "lead", "folder" } },
        .{ "focus-follows-mouse", "Focus follows mouse", "General", &[_][]const u8{} },
        .{ "confirm-close", "Ask before closing a running program", "General", &[_][]const u8{} },
        .{ "window-theme", "Appearance", "Appearance", &[_][]const u8{ "system", "light", "dark" } },
        .{ "language", "Language", "Appearance", &[_][]const u8{ "system", "en", "zh-Hans" } },
        .{ "background", "Background", "Appearance", &[_][]const u8{ "rex", "mist", "meadow", "dusk", "petal", "plain" } },
        .{ "window-translucent", "Translucent window", "Appearance", &[_][]const u8{} },
        .{ "font-family", "Font", "Terminal", &[_][]const u8{} },
        .{ "font-size", "Size", "Terminal", &[_][]const u8{} },
        .{ "font-weight", "Weight", "Terminal", &[_][]const u8{} },
        .{ "line-height", "Line height", "Terminal", &[_][]const u8{} },
        .{ "font-ligatures", "Ligatures", "Terminal", &[_][]const u8{} },
        .{ "font-thicken", "Thicken text", "Terminal", &[_][]const u8{} },
        .{ "minimum-contrast", "Minimum contrast", "Terminal", &[_][]const u8{} },
        .{ "dim-unfocused-terminals", "Dim unfocused terminals", "Terminal", &[_][]const u8{} },
        .{ "cursor-style", "Shape", "Terminal", &[_][]const u8{ "block", "bar", "underline" } },
        .{ "cursor-style-blink", "Blink", "Terminal", &[_][]const u8{} },
        .{ "theme", "Terminal theme", "Terminal", &[_][]const u8{} },
        .{ "macos-option-as-alt", "Option is Meta", "Input", &[_][]const u8{} },
        .{ "copy-on-select", "Copy on select", "Input", &[_][]const u8{} },
        .{ "clipboard-read", "Programs reading the clipboard", "Input", &[_][]const u8{ "ask", "allow", "deny" } },
        .{ "right-click-action", "Right click", "Input", &[_][]const u8{ "context-menu", "paste", "copy-or-paste" } },
        .{ "command", "Shell", "Shell", &[_][]const u8{} },
        .{ "scrollback-limit", "Scrollback", "Shell", &[_][]const u8{} },
        .{ "notify-on-waiting", "A session needs me", "Notifications", &[_][]const u8{} },
        .{ "notify-on-done", "An agent finishes", "Notifications", &[_][]const u8{} },
        .{ "notify-on-error", "A program fails", "Notifications", &[_][]const u8{} },
        .{ "notify-sound", "Play a sound", "Notifications", &[_][]const u8{} },
        .{ "dock-badge", "Badge the Dock icon", "Notifications", &[_][]const u8{} },
        .{ "dock-bounce", "Bounce the Dock icon", "Notifications", &[_][]const u8{} },
        .{ "git-status", "Show git status", "Changes", &[_][]const u8{} },
        .{ "diff-layout", "Diffs", "Changes", &[_][]const u8{ "auto", "split", "unified" } },
    };
    inline for (entries) |entry| if (std.mem.eql(u8, key, entry[0])) return .{ .title = entry[1], .group = entry[2], .choices = entry[3] };
    return .{ .title = key, .group = "General" };
}

pub fn detail(key: []const u8) []const u8 {
    const entries = .{
        .{ "session-name", "Until you or an agent name one. With Pane You’re In, a pane running only its shell defers to the pane that needs you most." },
        .{ "focus-follows-mouse", "A pane takes the focus when the pointer moves into it, without a click." },
        .{ "confirm-close", "When a pane or session you close has a program other than the shell running." },
        .{ "window-translucent", "Let the desktop show through the window’s background." },
        .{ "font-family", "JetBrains Mono with Nerd Fonts’ icons comes with Letty. Any installed monospaced font works; names separated by commas are tried in order." },
        .{ "font-ligatures", "Join characters as the font draws them, as => and !=." },
        .{ "font-thicken", "A heavier stroke, as Ghostty’s font-thicken." },
        .{ "dim-unfocused-terminals", "When a session has several panes, the terminals you’re not in fade." },
        .{ "cursor-style", "Programs may change it." },
        .{ "macos-option-as-alt", "Option sends Alt to programs, as for Emacs and readline, instead of typing accents." },
        .{ "copy-on-select", "What you select goes to the clipboard." },
        .{ "clipboard-read", "As with OSC 52: agents asking for what you copied." },
        .{ "scrollback-limit", "How much output each pane keeps, also while no window shows it." },
        .{ "notify-on-waiting", "A program asks something, rings the bell, or reports it is blocked." },
        .{ "notify-on-done", "While you look at another session, or another app." },
        .{ "notify-on-error", "One that reports an error (OSC 7501)." },
        .{ "dock-badge", "With the number of sessions that need you." },
        .{ "dock-bounce", "Once, when a session comes to need you." },
        .{ "git-status", "Each session's branch and changes, by its panes' titles and in the sidebar." },
        .{ "diff-layout", "Auto shows diffs unified while the changes panel is narrow, and side by side once it's wide." },
    };
    inline for (entries) |entry| if (std.mem.eql(u8, key, entry[0])) return entry[1];
    return "";
}
