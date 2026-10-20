//! A dedicated transient window, addressed only by its stable Host ID. Hiding
//! never closes a tab or PTY. Screen workarea is supplied by the platform/host
//! in nanoui's primary-top-left coordinate system; no fixed monitor is assumed.
const std = @import("std");
test {
    _ = @import("quick_terminal_check.zig");
}

pub const Position = enum { top, bottom, left, right, center };
pub const Bounds = struct { x: f64, y: f64, width: f64, height: f64 };
pub const Geometry = struct {
    screen: Bounds,
    position: Position = .top,
    width: f64 = 1,
    height: f64 = 0.4,
    always_on_top: bool = true,
    auto_hide: bool = true,
};
pub const Layout = struct { outer: Bounds, content_width: f64, content_height: f64 };
pub const GeometryError = error{ InvalidGeometry, InvalidWindowMetrics, ScreenTooSmall };

/// `chrome` is the difference between frame and content dimensions. AppKit's
/// setSize accepts content size; GTK's current nanoui frame/content both report
/// client size. Use the same planned rectangle after an asynchronous GTK resize.
pub fn layout(geometry: Geometry, chrome: [2]f64) GeometryError!Layout {
    const s = geometry.screen;
    if (!finite(s.x) or !finite(s.y) or !finite(s.width) or !finite(s.height) or
        s.width <= 0 or s.height <= 0 or s.width > 1e6 or s.height > 1e6 or
        !finite(geometry.width) or !finite(geometry.height) or
        geometry.width <= 0 or geometry.width > 1 or geometry.height <= 0 or geometry.height > 1 or
        !finite(s.x + s.width) or !finite(s.y + s.height)) return error.InvalidGeometry;
    if (!finite(chrome[0]) or !finite(chrome[1]) or chrome[0] < 0 or chrome[1] < 0) return error.InvalidWindowMetrics;
    // Respect the normal application's minimum content size where the screen
    // fits it. On a small monitor, reduce the minimum instead of going offscreen.
    const width = @min(s.width, @max(s.width * geometry.width, 480 + chrome[0]));
    const height = @min(s.height, @max(s.height * geometry.height, 240 + chrome[1]));
    const content_width = width - chrome[0];
    const content_height = height - chrome[1];
    if (content_width < 1 or content_height < 1) return error.ScreenTooSmall;
    var x = s.x + (s.width - width) / 2;
    var y = s.y + (s.height - height) / 2;
    switch (geometry.position) {
        .top => y = s.y,
        .bottom => y = s.y + s.height - height,
        .left => x = s.x,
        .right => x = s.x + s.width - width,
        .center => {},
    }
    return .{ .outer = .{ .x = x, .y = y, .width = width, .height = height }, .content_width = content_width, .content_height = content_height };
}

fn finite(value: f64) bool {
    return std.math.isFinite(value);
}

pub const State = struct {
    window_id: ?u64 = null,
    previous_id: ?u64 = null,
    visible: bool = false,
    auto_hide: bool = true,
    transitioning: bool = false,
    pending_blur: bool = false,

    pub fn owns(self: *const State, id: u64) bool {
        return self.window_id != null and self.window_id.? == id;
    }

    /// Host uses its normal create(true), find(id), activate(window, native),
    /// closeWindow(window) and app.flags.hidden APIs. A production host may
    /// supply createQuick() to create a native window initially hidden, avoiding
    /// a brief ordinary frame before placement. It must return a normal stable
    /// registered window, with its dedicated PTY and no focus or save side effect.
    pub fn toggle(self: *State, host: anytype, geometry: Geometry) !void {
        if (self.transitioning) return error.TransitionInProgress;
        _ = try layout(geometry, .{ 0, 0 });
        self.transitioning = true;
        defer self.finishTransition(host);
        if (self.window_id) |id| {
            if (host.find(id)) |w| {
                if (self.visible) {
                    self.hideWindow(host, w);
                    return;
                }
                try self.showWindow(host, w, geometry);
                return;
            }
            self.closed(id);
        }
        const previous = host.active_id;
        const Host = @typeInfo(@TypeOf(host)).pointer.child;
        const w = if (@hasDecl(Host, "createQuick")) try host.createQuick() else try host.create(true);
        // Creation failure is handled by Host. A newly created window that
        // cannot be placed must also be retired; don't leak a hidden live PTY.
        errdefer {
            self.closed(w.id);
            host.closeWindow(w);
            if (host.find(previous)) |prior| host.activate(prior, false);
        }
        self.window_id = w.id;
        self.previous_id = if (previous != w.id and host.find(previous) != null) previous else null;
        try self.showWindow(host, w, geometry);
    }

    /// Reflow an existing dedicated window on config/monitor change without
    /// showing it or replacing its PTY. Invalid geometry has no window effects.
    pub fn reconfigure(self: *State, host: anytype, geometry: Geometry) !void {
        if (self.transitioning) return error.TransitionInProgress;
        _ = try layout(geometry, .{ 0, 0 });
        const id = self.window_id orelse return;
        const w = host.find(id) orelse {
            self.closed(id);
            return;
        };
        self.transitioning = true;
        defer self.finishTransition(host);
        try self.place(w, geometry);
    }

    /// Forward actual window focus events. Blur hides only the dedicated quick
    /// window and never raises another window or activates the application.
    pub fn focusChanged(self: *State, host: anytype, id: u64, focused: bool) void {
        if (!self.owns(id)) return;
        if (focused) {
            self.pending_blur = false;
            return;
        }
        if (!self.visible) return;
        if (self.transitioning) {
            self.pending_blur = true;
            return;
        }
        if (!self.auto_hide) return;
        const w = host.find(id) orelse {
            self.closed(id);
            return;
        };
        self.transitioning = true;
        defer self.transitioning = false;
        self.hideWindow(host, w);
    }

    /// Call while retiring/closing a Host window, even if find(id) no longer
    /// returns it. Closing an ordinary window leaves the quick PTY untouched.
    pub fn closed(self: *State, id: u64) void {
        if (self.previous_id != null and self.previous_id.? == id) self.previous_id = null;
        if (!self.owns(id)) return;
        self.window_id = null;
        self.visible = false;
        self.previous_id = null;
        self.pending_blur = false;
    }

    fn finishTransition(self: *State, host: anytype) void {
        self.transitioning = false;
        // show()/setAlwaysOnTop can report focus synchronously. Honor a final
        // blur after placement, without nesting hide() in native window calls.
        if (self.pending_blur) {
            self.pending_blur = false;
            if (self.window_id) |id| self.focusChanged(host, id, false);
        }
    }

    fn place(self: *State, w: anytype, geometry: Geometry) !void {
        const window = w.window orelse return error.NoNativeWindow;
        const frame = window.frame();
        const content = window.contentSize();
        if (!finite(frame.width) or !finite(frame.height) or !finite(content[0]) or !finite(content[1]) or
            frame.width <= 0 or frame.height <= 0 or content[0] <= 0 or content[1] <= 0 or
            content[0] > frame.width or content[1] > frame.height) return error.InvalidWindowMetrics;
        const next = try layout(geometry, .{ frame.width - content[0], frame.height - content[1] });
        window.setMinSize(@min(480, next.content_width), @min(240, next.content_height));
        window.setSize(next.content_width, next.content_height);
        window.setPosition(next.outer.x, next.outer.y);
        window.setAlwaysOnTop(geometry.always_on_top);
        self.auto_hide = geometry.auto_hide;
    }

    fn showWindow(self: *State, host: anytype, w: anytype, geometry: Geometry) !void {
        try self.place(w, geometry);
        if (host.active_id != w.id and host.find(host.active_id) != null) self.previous_id = host.active_id;
        self.visible = true;
        // A headless test app must not become visible or take desktop focus.
        // In production show() makes the native window key; activate(false)
        // updates Host bookkeeping without redundantly focusing it a second time.
        host.activate(w, false);
        if (!host.app.flags.hidden) w.window.?.show();
    }

    fn hideWindow(self: *State, host: anytype, w: anytype) void {
        self.visible = false; // before hide(), which can synchronously report blur
        self.pending_blur = false;
        if (w.window) |window| window.hide();
        w.window_focused = false;
        w.syncFocus();
        if (host.active_id == w.id) {
            if (self.previous_id) |id| if (host.find(id)) |prior| {
                host.activate(prior, false);
                return;
            };
            host.active_id = 0;
        }
    }
};
