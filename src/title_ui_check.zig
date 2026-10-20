//! Title routing through the real VT cache and existing tab metadata.
const std = @import("std");
const ui = @import("nanoui").ui;
const vt = @import("vt.zig");
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI TITLE {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.TitleUiCheck;
}
fn set(session: anytype, value: []const u8) void {
    vt.lt_vt_feed(session.vt, "\x1b]2;", 4);
    vt.lt_vt_feed(session.vt, value.ptr, value.len);
    vt.lt_vt_feed(session.vt, "\x07", 1);
    session.refresh();
}
pub fn run(s: anytype, t: *ui.Tester) !void {
    const tab = s.layout.active_tab;
    const metadata = s.layout.tabs[tab];
    const session = s.active().?;
    var old: [4096]u8 = undefined;
    const old_len = vt.lt_vt_title(session.vt, &old, old.len);
    defer {
        set(session, old[0..old_len]);
        s.layout.tabs[tab] = metadata;
        t.frame();
    }
    try s.layout.rename(metadata.id, "");
    set(session, "editor 项目");
    t.frame();
    try check(std.mem.eql(u8, s.tabLabel(tab), "editor 项目"), "OSC2 updates the automatic tab title");
    try s.layout.rename(metadata.id, "My workspace");
    set(session, "build");
    t.frame();
    try check(std.mem.eql(u8, s.tabLabel(tab), "My workspace"), "manual tab names survive shell/application title updates");
    try s.layout.rename(metadata.id, "");
    t.frame();
    try check(std.mem.eql(u8, s.tabLabel(tab), "build"), "clearing manual name resumes the terminal title");
    var long: [600]u8 = undefined;
    for (0..200) |i| @memcpy(long[i * 3 ..][0..3], "项");
    set(session, &long);
    t.frame();
    try check(session.title_len == 255 and std.unicode.utf8ValidateSlice(s.tabLabel(tab)) and !session.fatal, "long Unicode titles truncate on a complete character");
    set(session, "");
    t.frame();
    try check(s.tabLabel(tab).len > 0 and !std.mem.eql(u8, s.tabLabel(tab), "Local"), "no terminal title falls back to directory or launch command");
    const root = s.layout.roots[tab];
    for (s.sessions, 0..) |entry, slot| {
        const other = entry orelse continue;
        if (other == session or !s.layout.contains(root, @intCast(slot))) continue;
        var saved: [4096]u8 = undefined;
        const saved_len = vt.lt_vt_title(other.vt, &saved, saved.len);
        const focused = s.layout.active_pane;
        defer {
            set(other, saved[0..saved_len]);
            s.focusPane(focused);
            t.frame();
        }
        set(other, "Other pane");
        try check(other.feedback_changed, "background title changes request a tab-strip redraw");
        s.focusPane(@intCast(slot));
        t.frame();
        try check(std.mem.eql(u8, s.tabLabel(tab), "Other pane"), "split focus selects that pane's title");
        break;
    }
}
