//! Native Zig VT facade. UI types and platform I/O stay Letty-owned.
const types = @import("vt_types.zig");
pub const backend_name = "zig";
const backend = @import("vt_zig/backend.zig");
pub const Vt = backend.Vt;
pub const Reply = types.Reply;
pub const Cell = types.Cell;
pub const Cursor = types.Cursor;
pub const Scroll = types.Scroll;
pub const SearchInfo = types.SearchInfo;
pub const Link = types.Link;
pub const Events = types.Events;
pub const capabilities = backend.capabilities;
const graphics = @import("vt_zig/graphics.zig");
pub const GraphicsSnapshot = graphics.Snapshot;
pub const GraphicsInfo = graphics.Info;
pub const configureGraphics = graphics.configure;
pub const captureGraphics = graphics.capture;
pub const graphicsInfo = graphics.info;
pub const memoryInfo = @import("vt_zig/memory.zig").info;
pub const create = backend.create;
pub const destroy = backend.destroy;
pub const prompt_clear_supported = true;
/// A completed VT mutation returns an owned request for a shell redraw. The
/// Session preflights and performs that write after the parser is unlocked.
pub fn clearForShell(v: *Vt) !bool {
    return @import("vt_zig/prompt_clear.zig").clearForShell(v, true);
}
pub fn feed(v: *Vt, bytes: []const u8) !void {
    backend.lt_vt_feed(v, bytes.ptr, bytes.len);
    if (backend.lt_vt_error(v)) |err| return err;
}
pub const lt_vt_free = backend.lt_vt_free;
pub const lt_vt_feed = backend.lt_vt_feed;
pub const lt_vt_resize = backend.lt_vt_resize;
pub const lt_vt_settings = backend.lt_vt_settings;
pub const lt_vt_colors = backend.lt_vt_colors;
pub const lt_vt_scroll = backend.lt_vt_scroll;
pub const lt_vt_bottom = backend.lt_vt_bottom;
pub const lt_vt_frame = backend.lt_vt_frame;
pub const lt_vt_next = backend.lt_vt_next;
pub const lt_vt_frame_end = backend.lt_vt_frame_end;
pub const lt_vt_key = backend.lt_vt_key;
pub const lt_vt_mouse = backend.lt_vt_mouse;
pub const lt_vt_mouse_tracking = backend.lt_vt_mouse_tracking;
pub const lt_vt_bracketed = backend.lt_vt_bracketed;
pub const lt_vt_select = backend.lt_vt_select;
pub const lt_vt_copy = backend.lt_vt_copy;
pub const lt_vt_clear_selection = backend.lt_vt_clear_selection;
pub const lt_vt_search = backend.lt_vt_search;
pub const lt_vt_search_tick = backend.lt_vt_search_tick;
pub const lt_vt_search_next = backend.lt_vt_search_next;
pub const lt_vt_search_close = backend.lt_vt_search_close;
pub const lt_vt_title = backend.lt_vt_title;
pub const lt_vt_palette = backend.lt_vt_palette;
pub const lt_vt_has_selection = backend.lt_vt_has_selection;
pub const lt_vt_scroll_info = backend.lt_vt_scroll_info;
pub const lt_vt_scroll_to = backend.lt_vt_scroll_to;
pub const lt_vt_search_info = backend.lt_vt_search_info;
pub const lt_vt_select_all = backend.lt_vt_select_all;
pub const lt_vt_clear_screen = backend.lt_vt_clear_screen;
pub const lt_vt_reset = backend.lt_vt_reset;
pub const lt_vt_link_at = backend.lt_vt_link_at;
pub const lt_vt_token_at = backend.lt_vt_token_at;
pub const lt_vt_revision = backend.lt_vt_revision;
pub const lt_vt_events = backend.lt_vt_events;
pub const lt_vt_pwd = backend.lt_vt_pwd;
pub const lt_vt_prompt_jump = backend.lt_vt_prompt_jump;
pub const lt_vt_focus_enabled = backend.lt_vt_focus_enabled;
pub const lt_vt_focus = backend.lt_vt_focus;
pub const lt_vt_paste = backend.lt_vt_paste;
pub const lt_vt_failed = backend.lt_vt_failed;
pub const lt_vt_error = backend.lt_vt_error;

const osc52 = @import("vt_zig/osc52.zig");
pub const configureClipboardWrite = osc52.configure;
pub const takeClipboardWrite = osc52.take;
