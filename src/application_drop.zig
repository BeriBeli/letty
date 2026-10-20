//! Owned file-drop queue. Native callbacks validate/copy only; drain() runs on
//! the next UI frame and pastes to the reserved stable SessionID, never active.
const std = @import("std");
const paths = @import("drop_paths.zig");
pub const Phase = enum(c_int) { probe = 0, reserve = 1, deliver = 2, cancel = 3 };
pub const Target = struct { window: u64, session: u64 = 0, document: u64 = 0 };
pub const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    fn valid(r: Rect) bool {
        return std.math.isFinite(r.x) and std.math.isFinite(r.y) and std.math.isFinite(r.width) and std.math.isFinite(r.height) and std.math.isFinite(r.x + r.width) and std.math.isFinite(r.y + r.height) and r.width > 0 and r.height > 0;
    }
    fn contains(r: Rect, x: f64, y: f64) bool {
        return x >= r.x and y >= r.y and x < r.x + r.width and y < r.y + r.height;
    }
};
pub const Pane = struct { session: u64 = 0, document: u64 = 0, rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 } };
pub const Host = struct {
    ctx: *anyopaque,
    window: u64,
    /// Recheck modal/layout.visible/zoom and exact session liveness. No focus
    /// change, allocation, PTY write, callback-driven close or event loop here.
    valid: *const fn (*anyopaque, Target) bool,
    wake: *const fn (*anyopaque) void,
    shell: ?*const fn (*anyopaque, Target) paths.Shell = null,
    /// Only drain calls paste. Root adapter resolves this ID again and invokes
    /// TerminalView.paste, preserving bracketed paste and queue failure policy.
    paste: *const fn (*anyopaque, Target, []const u8) bool,
    open_preview: ?*const fn (*anyopaque, Target, []const u8) bool = null,
};
pub const Callback = *const fn (?*anyopaque, c_int, u64, ?[*]const ?[*:0]const u8, usize, f64, f64, bool) callconv(.c) bool;
pub const Adapter = struct {
    attach: *const fn (*anyopaque, Callback, ?*anyopaque, [*]u8, usize) ?*anyopaque,
    detach: *const fn (*anyopaque) void,
    geometry: *const fn (*anyopaque, f64, f64) void,
    current: *const fn (*anyopaque) bool,
};
extern "c" fn lt_drop_attach(*anyopaque, Callback, ?*anyopaque, [*]u8, usize) ?*anyopaque;
extern "c" fn lt_drop_detach(*anyopaque) void;
extern "c" fn lt_drop_set_geometry(*anyopaque, f64, f64) void;
extern "c" fn lt_drop_geometry_current(*anyopaque) bool;
fn nativeAttach(v: *anyopaque, cb: Callback, ctx: ?*anyopaque, diag: [*]u8, cap: usize) ?*anyopaque {
    return lt_drop_attach(v, cb, ctx, diag, cap);
}
fn nativeDetach(handle: *anyopaque) void {
    lt_drop_detach(handle);
}
fn nativeGeometry(handle: *anyopaque, w: f64, h: f64) void {
    lt_drop_set_geometry(handle, w, h);
}
fn nativeCurrent(handle: *anyopaque) bool {
    return lt_drop_geometry_current(handle);
}
const native: Adapter = .{ .attach = nativeAttach, .detach = nativeDetach, .geometry = nativeGeometry, .current = nativeCurrent };
const Reservation = struct { token: u64, target: Target, x: f64, y: f64 };
pub const Pending = struct { target: Target, text: []u8, preview_only: bool = false, shell: paths.Shell = .unknown };

pub const Bridge = struct {
    gpa: std.mem.Allocator,
    host: Host,
    adapter: Adapter,
    handle: ?*anyopaque = null,
    panes: []Pane = &.{},
    pane_count: usize = 0,
    geometry_ready: bool = false,
    reservation: ?Reservation = null,
    pending: ?Pending = null,
    diagnostic: [256]u8 = @splat(0),
    last_error: ?anyerror = null,
    rejected: u64 = 0,
    accepted: u64 = 0,
    discarded: u64 = 0,
    pasted: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, host: Host) Bridge {
        return initWithAdapter(gpa, host, native);
    }
    pub fn initWithAdapter(gpa: std.mem.Allocator, host: Host, adapter: Adapter) Bridge {
        return .{ .gpa = gpa, .host = host, .adapter = adapter };
    }
    /// Stable address before attaching; host, adapter and Bridge outlive all C
    /// callbacks. No Window/Session/config pointer is retained in Pending.
    pub fn attach(self: *Bridge, view: *anyopaque) !void {
        if (self.handle != null) return error.DropAlreadyAttached;
        self.handle = self.adapter.attach(view, receive, self, &self.diagnostic, self.diagnostic.len) orelse return error.NativeDropUnavailable;
    }
    pub fn detach(self: *Bridge) void {
        const handle = self.handle;
        self.handle = null; // Ignore a synchronous/late cancel during teardown.
        if (handle) |h| self.adapter.detach(h);
        self.reservation = null;
        self.invalidateGeometry();
        self.clearPending();
    }
    pub fn deinit(self: *Bridge) void {
        self.detach();
        @import("dynamic_storage.zig").release(Pane, &self.panes);
        self.* = undefined;
    }
    pub fn setViewSize(self: *Bridge, width: f64, height: f64) void {
        if (self.handle) |handle| self.adapter.geometry(handle, width, height);
    }
    pub fn invalidateGeometry(self: *Bridge) void {
        self.setViewSize(0, 0);
        self.geometry_ready = false;
        self.pane_count = 0;
        self.reservation = null;
    }
    /// Publish only current visible/zoomed viewport rectangles, in logical
    /// top-left native view points, after layout. Modal/unready => invalidate.
    /// Geometry and identifiers are copied; no frame slice survives this call.
    pub fn publish(self: *Bridge, panes: []const Pane, modal: bool) !void {
        self.geometry_ready = false;
        self.pane_count = 0;
        errdefer self.reservation = null;
        if (modal) {
            self.reservation = null;
            return;
        }
        if (panes.len == 0) return error.InvalidDropGeometry;
        for (panes, 0..) |pane, i| {
            if (!pane.rect.valid() or (pane.session == 0) == (pane.document == 0)) return error.InvalidDropGeometry;
            for (panes[0..i]) |prior| if (prior.session == pane.session and prior.document == pane.document) return error.InvalidDropGeometry;
        }
        try @import("dynamic_storage.zig").ensure(Pane, &self.panes, panes.len, .{});
        @memcpy(self.panes[0..panes.len], panes);
        self.pane_count = panes.len;
        self.geometry_ready = true;
        if (self.reservation) |reserved| {
            const now = self.hit(reserved.x, reserved.y);
            if (now == null or !std.meta.eql(now.?, reserved.target)) self.reservation = null;
        }
    }
    fn hit(self: *Bridge, x: f64, y: f64) ?Target {
        if (self.handle == null or !self.adapter.current(self.handle.?) or !self.geometry_ready or !std.math.isFinite(x) or !std.math.isFinite(y)) return null;
        var found: ?Target = null;
        for (self.panes[0..self.pane_count]) |pane| if (pane.rect.contains(x, y)) {
            if (found != null) return null; // Ambiguous/overlapping geometry.
            found = .{ .window = self.host.window, .session = pane.session, .document = pane.document };
        };
        const target = found orelse return null;
        return if (self.host.valid(self.host.ctx, target)) target else null;
    }
    fn current(self: *Bridge, target: Target) bool {
        if (self.handle == null or !self.adapter.current(self.handle.?) or !self.geometry_ready or target.window != self.host.window or !self.host.valid(self.host.ctx, target)) return false;
        for (self.panes[0..self.pane_count]) |pane| if (pane.session == target.session and pane.document == target.document) return true;
        return false;
    }
    fn clearPending(self: *Bridge) void {
        if (self.pending) |p| self.gpa.free(p.text);
        self.pending = null;
    }
    fn reject(self: *Bridge, err: anyerror) bool {
        self.last_error = err;
        self.rejected +|= 1;
        return false;
    }
    /// Public solely so fake adapters can exercise the exact native callback
    /// contract without installing a destination or synthesizing OS events.
    pub fn receive(raw: ?*anyopaque, phase_raw: c_int, token: u64, entries: ?[*]const ?[*:0]const u8, count: usize, x: f64, y: f64, uris: bool) callconv(.c) bool {
        const self: *Bridge = @ptrCast(@alignCast(raw orelse return false));
        if (self.handle == null) return false;
        const phase = std.enums.fromInt(Phase, phase_raw) orelse return self.reject(error.InvalidDropPhase);
        switch (phase) {
            .probe => return self.pending == null and self.hit(x, y) != null,
            .reserve => {
                self.reservation = null;
                if (token == 0 or self.pending != null) return self.reject(error.DropBusy);
                const target = self.hit(x, y) orelse return self.reject(error.DropTargetUnavailable);
                self.reservation = .{ .token = token, .target = target, .x = x, .y = y };
                return true;
            },
            .cancel => {
                if (self.reservation) |r| if (r.token == token) {
                    self.reservation = null;
                };
                return false; // Never cancel an already accepted Pending.
            },
            .deliver => {
                const reserved = self.reservation orelse return self.reject(error.DropNotReserved);
                if (reserved.token != token or token == 0) return self.reject(error.StaleDropToken);
                defer self.reservation = null;
                if (self.pending != null) return self.reject(error.DropBusy);
                const target = self.hit(x, y) orelse return self.reject(error.DropTargetUnavailable);
                if (!std.meta.eql(target, reserved.target)) return self.reject(error.DropTargetChanged);
                if (count == 0 or count > paths.max_paths or entries == null) return self.reject(error.DropPathLimit);
                var slices: [paths.max_paths][]const u8 = undefined;
                const max_raw: usize = if (uris) paths.max_path_bytes * 3 + 32 else paths.max_path_bytes;
                for (0..count) |i| {
                    const pointer = entries.?[i] orelse return self.reject(error.InvalidDropPath);
                    var len: usize = 0;
                    while (len <= max_raw and pointer[len] != 0) : (len += 1) {}
                    if (len == 0 or len > max_raw) return self.reject(error.InvalidDropPath);
                    slices[i] = pointer[0..len];
                }
                if (target.document != 0) {
                    if (count != 1 or self.host.open_preview == null) return self.reject(error.PreviewDropRequiresOneFile);
                    const owned = self.gpa.dupe(u8, slices[0]) catch |err| return self.reject(err);
                    self.pending = .{ .target = target, .text = owned };
                    self.accepted +|= 1;
                    self.host.wake(self.host.ctx);
                    return true;
                }
                const shell = if (self.host.shell) |get| get(self.host.ctx, target) else .unknown;
                var preview_only = shell == .unknown;
                const owned = if (preview_only) paths.preview(self.gpa, slices[0..count], uris) catch |err| return self.reject(err) else (if (uris) paths.quoteUrisForShell(self.gpa, slices[0..count], shell) else paths.quoteForShell(self.gpa, slices[0..count], shell)) catch |err| fallback: {
                    if (err != error.RemoteDropUri) return self.reject(err);
                    preview_only = true;
                    break :fallback paths.preview(self.gpa, slices[0..count], uris) catch |fallback_error| return self.reject(fallback_error);
                };
                self.pending = .{ .target = reserved.target, .text = owned, .preview_only = preview_only, .shell = shell };
                self.accepted +|= 1;
                self.last_error = null;
                self.host.wake(self.host.ctx); // Schedules a frame, never paste.
                return true;
            },
        }
    }
    /// Call exactly at a normal UI frame boundary, after close/modal actions
    /// have been applied, BEFORE invalidating geometry for the new layout.
    /// Consumes once even if the source Session closed, became hidden, or paste
    /// failed. It never reposts to a newly active/reused pane slot.
    /// Transfer preview ownership only on the UI turn. No diagnostic raw text
    /// can fall through to paste even if a host forgets its preview surface.
    pub fn takePreview(self: *Bridge) ?Pending {
        const pending = self.pending orelse return null;
        if (!pending.preview_only) return null;
        self.pending = null;
        if (!self.current(pending.target)) {
            self.gpa.free(pending.text);
            self.discarded +|= 1;
            return null;
        }
        return pending;
    }
    pub fn drain(self: *Bridge) bool {
        const pending = self.pending orelse return false;
        self.pending = null;
        defer self.gpa.free(pending.text);
        if (pending.target.document != 0) {
            const call = self.host.open_preview orelse {
                self.discarded +|= 1;
                return false;
            };
            if (!self.current(pending.target) or !call(self.host.ctx, pending.target, pending.text)) {
                self.discarded +|= 1;
                return false;
            }
            return true;
        }
        if (pending.preview_only or !self.current(pending.target) or (if (self.host.shell) |get| get(self.host.ctx, pending.target) else .unknown) != pending.shell) {
            self.discarded +|= 1;
            return false;
        }
        if (!self.host.paste(self.host.ctx, pending.target, pending.text)) {
            self.discarded +|= 1;
            return false;
        }
        self.pasted +|= 1;
        return true;
    }
};

/// Root WindowState requires `drop_bridge:?Bridge = null`. This generic helper
/// avoids importing app.zig and uses the existing stable window/session IDs.
pub fn attach(view: *anyopaque, window: anytype) !void {
    if (window.drop_bridge != null) return error.DropAlreadyAttached;
    window.drop_bridge = Bridge.init(window.gpa, hostFor(window));
    errdefer {
        window.drop_bridge.?.deinit();
        window.drop_bridge = null;
    }
    try window.drop_bridge.?.attach(view);
}
pub fn detach(window: anytype) void {
    if (window.drop_bridge) |*bridge| bridge.deinit();
    window.drop_bridge = null;
}
pub fn drain(window: anytype, ctx: anytype) bool {
    const bridge = if (window.drop_bridge) |*value| value else return false;
    if (comptime @hasField(@typeInfo(@TypeOf(window)).pointer.child, "preview")) if (bridge.pending) |pending| if (pending.target.document != 0 and @import("application_preview.zig").composing(window, ctx)) {
        bridge.clearPending();
        bridge.discarded +|= 1;
        window.status = "Finish text composition before dropping a file into preview";
        return false;
    };
    return drainToDialog(bridge, &window.confirmation, ctx);
}
/// Shared by root windows and owned native/Tester's UI fixture.
pub fn drainToDialog(bridge: *Bridge, dialog: anytype, ctx: anytype) bool {
    if (bridge.takePreview()) |pending| {
        defer bridge.gpa.free(pending.text);
        var end = @min(7000, pending.text.len);
        while (end > 0 and end < pending.text.len and pending.text[end] & 0xc0 == 0x80) end -= 1;
        dialog.show(ctx, .drop_preview, "File drop preview", ctx.print("Source: Session {d}. Unknown shell or non-local file URI. Review or copy these details; no bytes were sent to the terminal.\n\n{s}{s}", .{ pending.target.session, pending.text[0..end], if (end < pending.text.len) "\n… preview truncated; Copy Details copies this preview only" else "" }), "Close");
        return true;
    }
    return bridge.drain();
}
pub fn hostFor(window: anytype) Host {
    const Window = @typeInfo(@TypeOf(window)).pointer.child;
    return .{
        .ctx = window,
        .window = window.id,
        .valid = struct {
            fn valid(raw: *anyopaque, target: Target) bool {
                const s: *Window = @ptrCast(@alignCast(raw));
                // Bridge attachment owns the native surface lifetime; the target
                // is the stable logical Window, also used by offscreen Testers.
                if (target.window != s.id or s.closing or s.retired or s.deinitialized or s.modalOpen()) return false;
                if (comptime @hasField(Window, "preview")) if (target.document != 0) {
                    if (s.layout.tab_count == 0) return false;
                    const d = s.preview.active(s.layout.tabs[s.layout.active_tab].id) orelse return false;
                    return d.id == target.document and !s.preview.dockFor(d.tab_id).collapsed;
                };
                if (s.search_open) return false;
                for (s.sessions, 0..) |maybe, slot| if (maybe) |session| if (session.id == target.session) {
                    if (session.closing or session.fatal or session.eof or session.fd < 0) return false;
                    if (!s.layout.visible(@intCast(slot))) return false;
                    return if (s.zoom) |zoom| zoom == session.id else true;
                };
                return false;
            }
        }.valid,
        .shell = struct {
            fn shell(raw: *anyopaque, target: Target) paths.Shell {
                const s: *Window = @ptrCast(@alignCast(raw));
                if (s.id != target.window) return .unknown;
                for (s.sessions) |maybe| if (maybe) |session| if (session.id == target.session) return session.drop_shell;
                return .unknown;
            }
        }.shell,
        .wake = struct {
            fn wake(raw: *anyopaque) void {
                const s: *Window = @ptrCast(@alignCast(raw));
                if (s.window) |w| w.redraw();
            }
        }.wake,
        .paste = struct {
            fn paste(raw: *anyopaque, target: Target, text: []const u8) bool {
                const s: *Window = @ptrCast(@alignCast(raw));
                if (target.window != s.id) return false;
                for (s.sessions) |maybe| if (maybe) |session| if (session.id == target.session) return @import("terminal_view.zig").View.paste(session, session.gpa, text);
                return false;
            }
        }.paste,
        .open_preview = struct {
            fn call(raw: *anyopaque, target: Target, text: []const u8) bool {
                const s: *Window = @ptrCast(@alignCast(raw));
                if (comptime @hasField(Window, "preview")) {
                    const d = s.preview.active(if (s.layout.tab_count > 0) s.layout.tabs[s.layout.active_tab].id else 0) orelse return false;
                    if (target.window != s.id or target.document != d.id) return false;
                    @import("application_preview.zig").open(s, text) catch |err| {
                        s.status = @import("terminal_paths.zig").invalidMessage(err);
                        return false;
                    };
                    return true;
                }
                return false;
            }
        }.call,
    };
}

const Fake = struct {
    allowed: bool = true,
    native_current: bool = true,
    second: u64 = 22,
    wake_count: usize = 0,
    paste_count: usize = 0,
    open_count: usize = 0,
    document: u64 = 99,
    shell: paths.Shell = .posix,
    target: Target = .{ .window = 0, .session = 0 },
    bytes: [256]u8 = undefined,
    len: usize = 0,
    fn host(f: *Fake) Host {
        return .{ .ctx = f, .window = 1, .valid = valid, .wake = wake, .paste = paste, .shell = getShell, .open_preview = openDocument };
    }
    fn getShell(raw: *anyopaque, _: Target) paths.Shell {
        const f: *Fake = @ptrCast(@alignCast(raw));
        return f.shell;
    }
    fn valid(raw: *anyopaque, target: Target) bool {
        const f: *Fake = @ptrCast(@alignCast(raw));
        return f.allowed and target.window == 1 and (if (target.document != 0) target.document == f.document and target.session == 0 else target.session == 11 or target.session == f.second);
    }
    fn wake(raw: *anyopaque) void {
        const f: *Fake = @ptrCast(@alignCast(raw));
        f.wake_count += 1;
    }
    fn paste(raw: *anyopaque, target: Target, text: []const u8) bool {
        const f: *Fake = @ptrCast(@alignCast(raw));
        if (text.len > f.bytes.len) return false;
        f.target = target;
        @memcpy(f.bytes[0..text.len], text);
        f.len = text.len;
        f.paste_count += 1;
        return true;
    }
    fn openDocument(raw: *anyopaque, target: Target, text: []const u8) bool {
        const f: *Fake = @ptrCast(@alignCast(raw));
        if (text.len > f.bytes.len) return false;
        @memcpy(f.bytes[0..text.len], text);
        f.len = text.len;
        f.target = target;
        f.open_count += 1;
        return true;
    }
    fn attached(view: *anyopaque, _: Callback, _: ?*anyopaque, _: [*]u8, _: usize) ?*anyopaque {
        return view;
    }
    fn detached(_: *anyopaque) void {}
    fn geometry(_: *anyopaque, _: f64, _: f64) void {}
    fn current(raw: *anyopaque) bool {
        const f: *Fake = @ptrCast(@alignCast(raw));
        return f.native_current;
    }
    const adapter: Adapter = .{ .attach = attached, .detach = detached, .geometry = geometry, .current = current };
};
fn fakePanes(second: u64) [2]Pane {
    return .{ .{ .session = 11, .rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 } }, .{ .session = second, .rect = .{ .x = 100, .y = 0, .width = 100, .height = 100 } } };
}
fn event(b: *Bridge, phase: Phase, token: u64, values: []const ?[*:0]const u8, x: f64, uris: bool) bool {
    return Bridge.receive(b, @backingInt(phase), token, if (values.len == 0) null else values.ptr, values.len, x, 20, uris);
}
test "drop callback owns quoted data and never pastes before frame drain" {
    var f: Fake = .{};
    var b = Bridge.initWithAdapter(std.testing.allocator, f.host(), Fake.adapter);
    defer b.deinit();
    try b.attach(&f);
    try b.publish(&fakePanes(22), false);
    var name = [_:0]u8{ '/', 't', 'm', 'p', '/', 'a' };
    try std.testing.expect(event(&b, .reserve, 1, &.{}, 150, false));
    try std.testing.expect(event(&b, .deliver, 1, &.{ &name, "/tmp/$(bad)" }, 150, false));
    name[5] = 'b';
    try std.testing.expect(f.paste_count == 0 and f.wake_count == 1);
    try std.testing.expect(!event(&b, .probe, 0, &.{}, 20, false)); // One bounded pending item.
    try std.testing.expect(b.drain());
    try std.testing.expectEqual(@as(u64, 22), f.target.session);
    try std.testing.expectEqualStrings("'/tmp/a' '/tmp/$(bad)' ", f.bytes[0..f.len]);
    try std.testing.expect(!b.drain());
}
test "async source close and pane-slot reuse cannot retarget the reservation" {
    var f: Fake = .{};
    var b = Bridge.initWithAdapter(std.testing.allocator, f.host(), Fake.adapter);
    defer b.deinit();
    try b.attach(&f);
    try b.publish(&fakePanes(22), false);
    try std.testing.expect(event(&b, .reserve, 4, &.{}, 150, false));
    f.second = 33;
    try b.publish(&fakePanes(33), false);
    try std.testing.expect(!event(&b, .deliver, 4, &.{"/tmp/a"}, 150, false));
    try std.testing.expect(b.pending == null and f.paste_count == 0);
}
test "source close after accept discards exactly once without active fallback" {
    var f: Fake = .{};
    var b = Bridge.initWithAdapter(std.testing.allocator, f.host(), Fake.adapter);
    defer b.deinit();
    try b.attach(&f);
    try b.publish(&fakePanes(22), false);
    try std.testing.expect(event(&b, .reserve, 5, &.{}, 150, false));
    try std.testing.expect(event(&b, .deliver, 5, &.{"/tmp/a"}, 150, false));
    f.second = 33;
    try b.publish(&fakePanes(33), false);
    try std.testing.expect(!b.drain() and b.discarded == 1 and f.paste_count == 0);
    try std.testing.expect(!b.drain() and b.discarded == 1);
}
test "modal or missing/ambiguous geometry refuses native callbacks" {
    var f: Fake = .{};
    var b = Bridge.initWithAdapter(std.testing.allocator, f.host(), Fake.adapter);
    defer b.deinit();
    try b.attach(&f);
    try std.testing.expect(!event(&b, .probe, 0, &.{}, 20, false));
    try b.publish(&fakePanes(22), true);
    try std.testing.expect(!event(&b, .reserve, 9, &.{}, 20, false));
    var panes = fakePanes(22);
    panes[1].rect.x = 0;
    try b.publish(&panes, false);
    try std.testing.expect(!event(&b, .probe, 0, &.{}, 20, false));
    try b.publish(&fakePanes(22), false);
    f.allowed = false;
    try std.testing.expect(!event(&b, .reserve, 10, &.{}, 20, false));
}
test "unchanged frame publication preserves GTK reserve and old tokens cannot cancel it" {
    var f: Fake = .{};
    var b = Bridge.initWithAdapter(std.testing.allocator, f.host(), Fake.adapter);
    defer b.deinit();
    try b.attach(&f);
    try b.publish(&fakePanes(22), false);
    try std.testing.expect(event(&b, .reserve, 20, &.{}, 20, false));
    try b.publish(&fakePanes(22), false);
    try std.testing.expect(!event(&b, .cancel, 19, &.{}, 20, false));
    try std.testing.expect(!event(&b, .deliver, 19, &.{"/tmp/old"}, 20, false));
    try std.testing.expect(event(&b, .deliver, 20, &.{"/tmp/new"}, 20, false));
    _ = event(&b, .cancel, 20, &.{}, 20, false); // Native retire after accepted delivery.
    try std.testing.expect(b.pending != null and b.drain());
    try std.testing.expectEqualStrings("'/tmp/new' ", f.bytes[0..f.len]);
}
test "GTK URIs are decoded locally and invalid paths never queue" {
    var f: Fake = .{};
    var b = Bridge.initWithAdapter(std.testing.allocator, f.host(), Fake.adapter);
    defer b.deinit();
    try b.attach(&f);
    try b.publish(&fakePanes(22), false);
    try std.testing.expect(event(&b, .reserve, 30, &.{}, 20, false));
    try std.testing.expect(event(&b, .deliver, 30, &.{"file://LOCALHOST/tmp/a%20b+z"}, 20, true));
    try std.testing.expect(b.drain());
    try std.testing.expectEqualStrings("'/tmp/a b+z' ", f.bytes[0..f.len]);
    try std.testing.expect(event(&b, .reserve, 31, &.{}, 20, false));
    try std.testing.expect(event(&b, .deliver, 31, &.{"file://remote/tmp/a"}, 20, true));
    const remote = b.takePreview().?;
    defer b.gpa.free(remote.text);
    try std.testing.expectEqualStrings("file://remote/tmp/a\n", remote.text);
    try std.testing.expect(event(&b, .reserve, 32, &.{}, 20, false));
    try std.testing.expect(!event(&b, .deliver, 32, &.{"/tmp/a\nb"}, 20, false));
    try std.testing.expect(b.pending == null and f.paste_count == 1);
}
test "drop copy OOM remains a visible failure with no borrowed pending data" {
    var f: Fake = .{};
    var fault = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var b = Bridge.initWithAdapter(fault.allocator(), f.host(), Fake.adapter);
    defer b.deinit();
    try b.attach(&f);
    try b.publish(&fakePanes(22), false);
    try std.testing.expect(event(&b, .reserve, 40, &.{}, 20, false));
    try std.testing.expect(!event(&b, .deliver, 40, &.{"/tmp/a"}, 20, false));
    try std.testing.expect(b.last_error != null and b.last_error.? == error.OutOfMemory and b.pending == null and f.paste_count == 0);
}
test "detach frees pending ownership and retired callbacks are suppressed" {
    var f: Fake = .{};
    var b = Bridge.initWithAdapter(std.testing.allocator, f.host(), Fake.adapter);
    defer b.deinit();
    try b.attach(&f);
    try b.publish(&fakePanes(22), false);
    try std.testing.expect(event(&b, .reserve, 50, &.{}, 20, false));
    try std.testing.expect(event(&b, .deliver, 50, &.{"/tmp/a"}, 20, false));
    b.detach();
    b.detach();
    try std.testing.expect(!event(&b, .deliver, 50, &.{"/tmp/a"}, 20, false));
    try std.testing.expect(!b.drain() and b.pending == null and f.paste_count == 0);
}

test "native resize before a fresh layout refuses delivery and queued drain" {
    var f: Fake = .{};
    var b = Bridge.initWithAdapter(std.testing.allocator, f.host(), Fake.adapter);
    defer b.deinit();
    try b.attach(&f);
    try b.publish(&fakePanes(22), false);
    try std.testing.expect(event(&b, .reserve, 60, &.{}, 20, false));
    f.native_current = false;
    try std.testing.expect(!event(&b, .deliver, 60, &.{"/tmp/a"}, 20, false));
    f.native_current = true;
    try std.testing.expect(event(&b, .reserve, 61, &.{}, 20, false));
    try std.testing.expect(event(&b, .deliver, 61, &.{"/tmp/a"}, 20, false));
    f.native_current = false;
    try std.testing.expect(!b.drain() and b.discarded == 1 and f.paste_count == 0);
}

test "unknown shell preview is owned and cannot reach PTY paste" {
    var f: Fake = .{ .shell = .unknown };
    var b = Bridge.initWithAdapter(std.testing.allocator, f.host(), Fake.adapter);
    defer b.deinit();
    try b.attach(&f);
    try b.publish(&fakePanes(22), false);
    try std.testing.expect(event(&b, .reserve, 70, &.{}, 20, false));
    try std.testing.expect(event(&b, .deliver, 70, &.{"/tmp/a'b"}, 20, false));
    const preview = b.takePreview().?;
    defer b.gpa.free(preview.text);
    try std.testing.expectEqualStrings("/tmp/a'b\n", preview.text);
    try std.testing.expect(f.paste_count == 0 and !b.drain());
    try std.testing.expect(event(&b, .reserve, 71, &.{}, 20, false));
    try std.testing.expect(event(&b, .deliver, 71, &.{"/tmp/a"}, 20, false));
    try std.testing.expect(!b.drain() and f.paste_count == 0);
}
test "shell change between callback and UI drain revokes prepared quoting" {
    var f: Fake = .{};
    var b = Bridge.initWithAdapter(std.testing.allocator, f.host(), Fake.adapter);
    defer b.deinit();
    try b.attach(&f);
    try b.publish(&fakePanes(22), false);
    try std.testing.expect(event(&b, .reserve, 72, &.{}, 20, false));
    try std.testing.expect(event(&b, .deliver, 72, &.{"/tmp/a"}, 20, false));
    f.shell = .fish;
    try std.testing.expect(!b.drain() and f.paste_count == 0 and b.discarded == 1);
}

test "document drop reserves stable identity and never quotes or pastes into a PTY" {
    var f: Fake = .{ .shell = .unknown };
    var bridge = Bridge.initWithAdapter(std.testing.allocator, f.host(), Fake.adapter);
    defer bridge.deinit();
    try bridge.attach(&f);
    var panes = [_]Pane{
        .{ .session = 11, .rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 } },
        .{ .document = 99, .rect = .{ .x = 100, .y = 0, .width = 100, .height = 100 } },
    };
    try bridge.publish(&panes, false);
    try std.testing.expect(event(&bridge, .reserve, 71, &.{}, 150, true));
    try std.testing.expect(event(&bridge, .deliver, 71, &.{"file:///tmp/a%20中.md"}, 150, true));
    try std.testing.expect(f.open_count == 0 and f.paste_count == 0);
    try std.testing.expect(bridge.drain());
    try std.testing.expectEqualStrings("file:///tmp/a%20中.md", f.bytes[0..f.len]);
    try std.testing.expect(f.open_count == 1 and f.paste_count == 0 and f.target.document == 99);
    try std.testing.expect(event(&bridge, .reserve, 72, &.{}, 150, false));
    try std.testing.expect(!event(&bridge, .deliver, 72, &.{ "/a", "/b" }, 150, false));
    try std.testing.expect(event(&bridge, .reserve, 73, &.{}, 150, false));
    try std.testing.expect(event(&bridge, .deliver, 73, &.{"/b"}, 150, false));
    f.document = 100;
    panes[1].document = 100;
    try bridge.publish(&panes, false);
    try std.testing.expect(!bridge.drain());
    try std.testing.expect(f.open_count == 1 and f.paste_count == 0);
}
