//! Bounded service capability state for Inspector/diagnostics; no input bodies.
const Text = @import("fixed_text.zig").Text;
pub const Snapshot = struct {
    hotkeys_registered: usize = 0,
    quick_window: u64 = 0,
    quick_visible: bool = false,
    screen_observer: bool = false,
    queued: usize = 0,
    dropped: u64 = 0,
    ax_native: bool = false,
    ax_nodes: usize = 0,
    last_error: Text(128) = .{},
    /// No API to join all macOS Spaces or override compositor policy is used.
    cross_desktop: enum { unsupported } = .unsupported,
};
pub fn capture(services: anytype, accessibility: anytype) Snapshot {
    var result: Snapshot = .{ .hotkeys_registered = services.hotkeys.count, .quick_window = services.quick.window_id orelse 0, .quick_visible = services.quick.visible, .screen_observer = services.screen_watch.callback != null, .queued = services.count, .dropped = services.dropped };
    if (accessibility.adapter) |*adapter| {
        result.ax_native = adapter.native != null;
        result.ax_nodes = adapter.snapshot.count;
    }
    if (accessibility.last_error) |err| result.last_error.set(@errorName(err));
    if (services.last_screen_error) |err| result.last_error.set(@errorName(err));
    return result;
}
