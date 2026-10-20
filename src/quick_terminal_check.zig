//! Pure geometry and injected Host/native-window tests. No nanoui App, real
//! display, window, system keyboard, clipboard or desktop focus is touched.
const std = @import("std");
const quick = @import("quick_terminal.zig");
const App = struct { flags: struct { hidden: bool = false } = .{} };
const Native = struct {
    owner: *Window,
    rect: quick.Bounds = .{ .x = 50, .y = 50, .width = 1000, .height = 728 },
    content: [2]f64 = .{ 1000, 700 },
    minimum: [2]f64 = .{ 480, 240 },
    top: bool = false,
    shown: bool = false,
    shows: usize = 0,
    hides: usize = 0,
    sizes: usize = 0,
    positions: usize = 0,
    async_resize: bool = false,
    blur_after_show: bool = false,

    pub fn frame(n: *Native) quick.Bounds {
        return n.rect;
    }
    pub fn contentSize(n: *Native) [2]f64 {
        return n.content;
    }
    pub fn setMinSize(n: *Native, w: f64, h: f64) void {
        n.minimum = .{ w, h };
    }
    pub fn setSize(n: *Native, w: f64, h: f64) void {
        n.sizes += 1;
        if (!n.async_resize) {
            const chrome = .{ n.rect.width - n.content[0], n.rect.height - n.content[1] };
            n.content = .{ w, h };
            n.rect.width = w + chrome[0];
            n.rect.height = h + chrome[1];
        }
    }
    pub fn setPosition(n: *Native, x: f64, y: f64) void {
        n.positions += 1;
        n.rect.x = x;
        n.rect.y = y;
    }
    pub fn setAlwaysOnTop(n: *Native, on: bool) void {
        n.top = on;
    }
    pub fn show(n: *Native) void {
        n.shown = true;
        n.shows += 1;
        n.owner.window_focused = true;
        if (n.owner.host.quick) |state| state.focusChanged(n.owner.host, n.owner.id, true);
        if (n.blur_after_show) {
            n.owner.window_focused = false;
            if (n.owner.host.quick) |state| state.focusChanged(n.owner.host, n.owner.id, false);
        }
    }
    pub fn hide(n: *Native) void {
        n.shown = false;
        n.hides += 1;
        n.owner.window_focused = false;
        if (n.owner.host.quick) |state| state.focusChanged(n.owner.host, n.owner.id, false);
    }
};
const Window = struct {
    id: u64,
    pid: u64,
    host: *Host,
    native: Native = undefined,
    window: ?*Native = null,
    window_focused: bool = false,
    syncs: usize = 0,
    closing: bool = false,
    pub fn syncFocus(w: *Window) void {
        w.syncs += 1;
    }
};
const Host = struct {
    app: *App,
    quick: ?*quick.State = null,
    windows: [8]Window = undefined,
    live: [8]bool = @splat(false),
    next_id: u64 = 1,
    active_id: u64 = 0,
    creates: usize = 0,
    closes: usize = 0,
    native_activations: usize = 0,
    fail_create: bool = false,
    invalid_metrics: bool = false,

    pub fn find(h: *Host, id: u64) ?*Window {
        for (&h.windows, h.live) |*w, live| if (live and w.id == id and !w.closing) return w;
        return null;
    }
    pub fn create(h: *Host, native: bool) !*Window {
        if (h.fail_create) return error.WindowLimit;
        for (&h.windows, 0..) |*w, i| if (!h.live[i]) {
            w.* = .{ .id = h.next_id, .pid = 1000 + h.next_id, .host = h };
            h.next_id += 1;
            w.native = .{ .owner = w };
            if (h.invalid_metrics) w.native.content[1] = 99999;
            if (native) w.window = &w.native;
            h.live[i] = true;
            h.creates += 1;
            h.activate(w, native);
            return w;
        };
        return error.WindowLimit;
    }
    pub fn activate(h: *Host, w: *Window, native: bool) void {
        for (&h.windows, h.live) |*other, live| if (live and other != w and other.window_focused) {
            other.window_focused = false;
            other.syncFocus();
        };
        h.active_id = w.id;
        if (native and !h.app.flags.hidden) h.native_activations += 1;
    }
    pub fn closeWindow(h: *Host, w: *Window) void {
        for (&h.windows, 0..) |*other, i| if (other == w and h.live[i]) {
            w.closing = true;
            h.live[i] = false;
            h.closes += 1;
            if (h.quick) |state| state.closed(w.id);
            return;
        };
    }
};
const geometry: quick.Geometry = .{ .screen = .{ .x = -1600, .y = 80, .width = 1600, .height = 1000 }, .width = 0.5, .height = 0.4 };
fn near(expected: f64, actual: f64) !void {
    try std.testing.expectApproxEqAbs(expected, actual, 0.000001);
}

test "all five anchors use supplied negative-origin workarea and account for chrome" {
    var g = geometry;
    const positions = [_]quick.Position{ .top, .bottom, .left, .right, .center };
    const xs = [_]f64{ -1200, -1200, -1600, -800, -1200 };
    const ys = [_]f64{ 80, 680, 380, 380, 380 };
    for (positions, xs, ys) |position, x, y| {
        g.position = position;
        const l = try quick.layout(g, .{ 8, 28 });
        try near(x, l.outer.x);
        try near(y, l.outer.y);
        try near(800, l.outer.width);
        try near(400, l.outer.height);
        try near(792, l.content_width);
        try near(372, l.content_height);
    }
}

test "minimum dimensions clamp to available screen and reject impossible native decoration" {
    var g = geometry;
    g.width = 0.01;
    g.height = 0.01;
    const normal = try quick.layout(g, .{ 8, 28 });
    try near(488, normal.outer.width);
    try near(268, normal.outer.height);
    g.screen = .{ .x = 0, .y = 0, .width = 300, .height = 200 };
    const tiny = try quick.layout(g, .{ 8, 28 });
    try near(292, tiny.content_width);
    try near(172, tiny.content_height);
    try near(0, tiny.outer.x);
    try near(0, tiny.outer.y);
    try std.testing.expectError(error.ScreenTooSmall, quick.layout(g, .{ 300, 28 }));
}

test "malformed geometry and metrics fail without a native operation" {
    var g = geometry;
    for ([_]f64{ 0, -0.1, 1.1, std.math.nan(f64), std.math.inf(f64) }) |bad| {
        g.width = bad;
        try std.testing.expectError(error.InvalidGeometry, quick.layout(g, .{ 0, 0 }));
        g = geometry;
        g.height = bad;
        try std.testing.expectError(error.InvalidGeometry, quick.layout(g, .{ 0, 0 }));
        g = geometry;
    }
    g.screen.x = std.math.nan(f64);
    try std.testing.expectError(error.InvalidGeometry, quick.layout(g, .{ 0, 0 }));
    try std.testing.expectError(error.InvalidWindowMetrics, quick.layout(geometry, .{ -1, 0 }));
    var app: App = .{};
    var host: Host = .{ .app = &app };
    var state: quick.State = .{};
    try std.testing.expectError(error.InvalidGeometry, state.toggle(&host, g));
    try std.testing.expectEqual(@as(usize, 0), host.creates);
}

test "show hide and reshow preserve dedicated stable window PID and ordinary window" {
    var app: App = .{};
    var state: quick.State = .{};
    var host: Host = .{ .app = &app, .quick = &state };
    const ordinary = try host.create(true);
    const ordinary_id = ordinary.id;
    const ordinary_pid = ordinary.pid;
    const initial_focus = host.native_activations;
    try state.toggle(&host, geometry);
    const id = state.window_id.?;
    const w = host.find(id).?;
    const pid = w.pid;
    try std.testing.expect(state.visible);
    try std.testing.expect(w.native.shown and w.native.top);
    try std.testing.expectEqual(@as(usize, 1), w.native.shows);
    try std.testing.expectEqual(id, host.active_id);
    try near(-1200, w.native.rect.x);
    try near(80, w.native.rect.y);
    try near(400, w.native.rect.height);
    try state.toggle(&host, geometry);
    try std.testing.expect(!state.visible and !w.native.shown);
    try std.testing.expectEqual(ordinary_id, host.active_id);
    try std.testing.expect(w.syncs > 0 and !w.window_focused);
    try state.toggle(&host, geometry);
    try std.testing.expectEqual(id, state.window_id.?);
    try std.testing.expectEqual(pid, host.find(id).?.pid);
    try std.testing.expectEqual(ordinary_pid, host.find(ordinary_id).?.pid);
    try std.testing.expectEqual(@as(usize, 2), host.creates);
    try std.testing.expectEqual(@as(usize, 0), host.closes);
    // Only Host's fallback first create(true) may focus. Re-show uses show(),
    // and hide/blur never requests native focus on the ordinary window.
    try std.testing.expectEqual(initial_focus + 1, host.native_activations);
}

test "focus loss only auto-hides matching quick window and never steals focus" {
    var app: App = .{};
    var state: quick.State = .{};
    var host: Host = .{ .app = &app, .quick = &state };
    const ordinary = try host.create(true);
    try state.toggle(&host, geometry);
    const w = host.find(state.window_id.?).?;
    const before = host.native_activations;
    state.focusChanged(&host, ordinary.id, false);
    state.focusChanged(&host, w.id, true);
    try std.testing.expect(state.visible);
    state.focusChanged(&host, w.id, false);
    try std.testing.expect(!state.visible);
    try std.testing.expectEqual(@as(usize, 1), w.native.hides);
    try std.testing.expectEqual(before, host.native_activations);
    state.focusChanged(&host, w.id, false);
    try std.testing.expectEqual(@as(usize, 1), w.native.hides);
    var g = geometry;
    g.auto_hide = false;
    try state.toggle(&host, g);
    state.focusChanged(&host, w.id, false);
    try std.testing.expect(state.visible);
}

test "headless app creates native fixture without showing or changing desktop focus" {
    var app: App = .{ .flags = .{ .hidden = true } };
    var state: quick.State = .{};
    var host: Host = .{ .app = &app, .quick = &state };
    try state.toggle(&host, geometry);
    const w = host.find(state.window_id.?).?;
    try std.testing.expect(state.visible);
    try std.testing.expect(!w.native.shown and !w.window_focused);
    try std.testing.expectEqual(@as(usize, 0), w.native.shows);
    try std.testing.expectEqual(@as(usize, 0), host.native_activations);
    try state.toggle(&host, geometry);
    try state.toggle(&host, geometry);
    try std.testing.expectEqual(@as(usize, 1), host.creates);
    try std.testing.expectEqual(@as(usize, 0), w.native.shows);
}

test "hidden reconfigure keeps visibility and session while applying current geometry and options" {
    var app: App = .{};
    var state: quick.State = .{};
    var host: Host = .{ .app = &app, .quick = &state };
    try state.toggle(&host, geometry);
    const w = host.find(state.window_id.?).?;
    const pid = w.pid;
    try state.toggle(&host, geometry);
    var g = geometry;
    g.position = .bottom;
    g.always_on_top = false;
    g.auto_hide = false;
    try state.reconfigure(&host, g);
    try std.testing.expect(!state.visible and !w.native.shown and !w.native.top and !state.auto_hide);
    try std.testing.expectEqual(pid, w.pid);
    try near(680, w.native.rect.y);
    try std.testing.expectEqual(@as(usize, 1), w.native.shows);
    const sizes = w.native.sizes;
    g.width = 0;
    try std.testing.expectError(error.InvalidGeometry, state.reconfigure(&host, g));
    try std.testing.expectEqual(sizes, w.native.sizes);
}

test "GTK asynchronous resize positioning uses planned dimensions rather than stale frame" {
    var app: App = .{};
    var state: quick.State = .{};
    var host: Host = .{ .app = &app, .quick = &state };
    try state.toggle(&host, geometry);
    const w = host.find(state.window_id.?).?;
    w.native.async_resize = true;
    var g = geometry;
    g.position = .bottom;
    g.height = 0.7;
    try state.reconfigure(&host, g);
    try near(400, w.native.rect.height); // intentionally stale size
    try near(380, w.native.rect.y); // planned 700px at bottom of 80..1080
}

test "close invalidates only stable quick identity and next toggle creates new PTY" {
    var app: App = .{};
    var state: quick.State = .{};
    var host: Host = .{ .app = &app, .quick = &state };
    const ordinary = try host.create(true);
    const oid = ordinary.id;
    try state.toggle(&host, geometry);
    const old_id = state.window_id.?;
    const old_pid = host.find(old_id).?.pid;
    state.closed(oid);
    try std.testing.expect(state.owns(old_id));
    // find() must exclude closing windows even before retirement completes.
    host.find(old_id).?.closing = true;
    try state.toggle(&host, geometry);
    try std.testing.expect(state.window_id.? != old_id);
    try std.testing.expect(host.find(state.window_id.?).?.pid != old_pid);
    try std.testing.expect(host.find(oid) != null);
    const current = host.find(state.window_id.?).?;
    host.closeWindow(current);
    try std.testing.expect(state.window_id == null and !state.visible);
}

test "create failure leaves old host active and placement failure retires newly created PTY" {
    var app: App = .{};
    var state: quick.State = .{};
    var host: Host = .{ .app = &app, .quick = &state };
    const ordinary = try host.create(true);
    host.fail_create = true;
    try std.testing.expectError(error.WindowLimit, state.toggle(&host, geometry));
    try std.testing.expect(state.window_id == null);
    try std.testing.expectEqual(ordinary.id, host.active_id);
    host.fail_create = false;
    host.invalid_metrics = true;
    try std.testing.expectError(error.InvalidWindowMetrics, state.toggle(&host, geometry));
    try std.testing.expect(state.window_id == null and !state.visible);
    try std.testing.expectEqual(ordinary.id, host.active_id);
    try std.testing.expectEqual(@as(usize, 1), host.closes);
}

test "transition callbacks cannot recursively toggle or reconfigure" {
    var app: App = .{};
    var state: quick.State = .{ .transitioning = true };
    var host: Host = .{ .app = &app, .quick = &state };
    try std.testing.expectError(error.TransitionInProgress, state.toggle(&host, geometry));
    try std.testing.expectError(error.TransitionInProgress, state.reconfigure(&host, geometry));
    try std.testing.expectEqual(@as(usize, 0), host.creates);
}

test "synchronous blur during show is handled after the native transition exactly once" {
    var app: App = .{};
    var state: quick.State = .{};
    var host: Host = .{ .app = &app, .quick = &state };
    _ = try host.create(true);
    try state.toggle(&host, geometry);
    const w = host.find(state.window_id.?).?;
    try state.toggle(&host, geometry);
    w.native.blur_after_show = true;
    const hides = w.native.hides;
    try state.toggle(&host, geometry);
    try std.testing.expect(!state.visible and !state.pending_blur and !state.transitioning);
    try std.testing.expectEqual(hides + 1, w.native.hides);
    try std.testing.expectEqual(@as(usize, 2), host.creates);
}
