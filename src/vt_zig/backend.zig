//! Production native Zig adapter using the official Ghostty module.
const types = @import("../vt_types.zig");
const context = @import("context.zig");
const render = @import("render.zig");
const input = @import("input.zig");
const selection = @import("selection.zig");
const search = @import("search.zig");
const navigation = @import("navigation.zig");
const links = @import("links.zig");
pub const Vt = context.Context;
pub const create = context.create;
pub const destroy = context.destroy;
pub const lt_vt_free = destroy;
pub const capabilities: types.Capabilities = .{ .basic = true, .frame = true, .input = true, .events = true, .history = true, .selection = true, .search = true, .links = true };
pub fn lt_vt_failed(self: *Vt) bool {
    return self.fatal != null;
}
pub fn lt_vt_error(self: *Vt) ?anyerror {
    return self.fatal;
}
pub fn lt_vt_feed(self: *Vt, bytes: [*]const u8, len: usize) void {
    context.feed(self, bytes[0..len]);
}
pub const lt_vt_resize = context.resize;
pub const lt_vt_settings = context.settings;
pub const lt_vt_colors = context.colors;
pub const lt_vt_palette = context.palette;
pub const lt_vt_frame = render.frame;
pub const lt_vt_next = render.next;
pub const lt_vt_frame_end = render.end;
pub const lt_vt_key = input.key;
pub const lt_vt_mouse = input.mouse;
pub const lt_vt_focus = input.focus;
pub const lt_vt_focus_enabled = input.focusEnabled;
pub const lt_vt_paste = input.paste;
pub fn lt_vt_mouse_tracking(self: *Vt) bool {
    return self.terminal.flags.mouse_event != .none;
}
pub fn lt_vt_bracketed(self: *Vt) bool {
    return self.terminal.modes.get(.bracketed_paste);
}
pub fn lt_vt_events(self: *Vt, output: *types.Events) void {
    output.* = self.event_snapshot;
}
pub fn lt_vt_title(self: *Vt, output: [*]u8, cap: usize) usize {
    const len = @min(cap, self.title.len);
    @memcpy(output[0..len], self.title.text()[0..len]);
    return len;
}
pub fn lt_vt_pwd(self: *Vt, output: [*]u8, cap: usize) usize {
    if (self.pwd_overflow or self.pwd.len >= cap) return 0;
    @memcpy(output[0..self.pwd.len], self.pwd.text());
    output[self.pwd.len] = 0;
    return self.pwd.len;
}
pub fn lt_vt_revision(self: *Vt) u64 {
    return self.revision;
}
pub const lt_vt_scroll = navigation.scroll;
pub const lt_vt_bottom = navigation.bottom;
pub const lt_vt_scroll_to = navigation.scrollTo;
pub const lt_vt_prompt_jump = navigation.promptJump;
pub const lt_vt_scroll_info = navigation.scrollInfo;
pub const lt_vt_reset = navigation.reset;
pub const lt_vt_clear_screen = navigation.clearScreen;
pub const lt_vt_select = selection.select;
pub const lt_vt_has_selection = selection.has;
pub const lt_vt_clear_selection = selection.clear;
pub const lt_vt_select_all = selection.all;
pub const lt_vt_copy = selection.copy;
pub const lt_vt_search = search.set;
pub const lt_vt_search_tick = search.tick;
pub const lt_vt_search_next = search.next;
pub const lt_vt_search_info = search.info;
pub const lt_vt_search_close = search.close;
pub const lt_vt_link_at = links.at;
pub const lt_vt_token_at = links.token;
