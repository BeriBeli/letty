//! Owned hidden NanoUIView + real native drop registry. Direct bridge calls
//! exercise delivery without synthesizing OS dragging/mouse/keyboard events.
//! No pasted byte reaches a PTY: only an isolated Session value/VT/TX is used.
const std = @import("std");
const builtin = @import("builtin");
const nano = @import("nanoui");
const ui = nano.ui;
const drop = @import("application_drop.zig");
const Session = @import("session.zig").Session;
const TerminalView = @import("terminal_view.zig").View;
const Queue = @import("queue.zig").Queue;
const vt = @import("vt.zig");
const app_ax = @import("application_accessibility.zig");
extern "c" fn lt_drop_find(*anyopaque) ?*anyopaque;
extern "c" fn lt_drop_probe(*anyopaque, f64, f64) bool;
extern "c" fn lt_drop_reserve(*anyopaque, f64, f64) bool;
extern "c" fn lt_drop_deliver(*anyopaque, [*]const [*:0]const u8, usize, f64, f64, bool) bool;
extern "c" fn lt_drop_geometry_current(*anyopaque) bool;

/// Supply only an actual backend. A missing/unavailable backend is reported
/// pending, never counted as successful AX interoperability coverage.
pub const AxBackend = struct {
    capability: *const fn () bool,
    attach: *const fn (std.mem.Allocator, u64, *anyopaque) anyerror!*anyopaque,
    detach: *const fn (std.mem.Allocator, *anyopaque) void,
};
pub const realAccessibility: AxBackend = .{
    .capability = struct {
        fn call() bool {
            return app_ax.ax.lt_ax_capability() == 1;
        }
    }.call,
    .attach = struct {
        fn call(gpa: std.mem.Allocator, id: u64, view: *anyopaque) !*anyopaque {
            const owner = try gpa.create(app_ax.Adapter);
            errdefer gpa.destroy(owner);
            owner.* = try .init(id);
            errdefer owner.detach();
            try owner.attach(view);
            return owner;
        }
    }.call,
    .detach = struct {
        fn call(gpa: std.mem.Allocator, raw: *anyopaque) void {
            const owner: *app_ax.Adapter = @ptrCast(@alignCast(raw));
            owner.detach();
            gpa.destroy(owner);
        }
    }.call,
};
const Fixture = struct {
    session: Session,
    original: *Session,
    window: ?*nano.Window = null,
    bridge: ?*drop.Bridge = null,
    window_id: u64 = 0x64726f705f7569,
    source_alive: bool = true,
    blocked: bool = false,
    active_session: u64 = 0,
    builds: usize = 0,
    wakes: usize = 0,
    paste_calls: usize = 0,
    shell: @import("drop_paths.zig").Shell = .posix,
    confirmation: @import("message_dialog.zig").Dialog = .{},
    drain_calls: usize = 0,
    last_drain: bool = false,
    last_target: u64 = 0,

    fn host(f: *Fixture) drop.Host {
        return .{ .ctx = f, .window = f.window_id, .valid = valid, .wake = wake, .paste = paste, .shell = knownShell };
    }
    fn knownShell(raw: *anyopaque, _: drop.Target) @import("drop_paths.zig").Shell {
        const f: *Fixture = @ptrCast(@alignCast(raw));
        return f.shell;
    }
    fn valid(raw: *anyopaque, target: drop.Target) bool {
        const f: *Fixture = @ptrCast(@alignCast(raw));
        return f.source_alive and !f.blocked and target.window == f.window_id and target.session == f.session.id and f.original.id == f.session.id and f.original.pid == f.session.pid and !f.original.closing;
    }
    fn wake(raw: *anyopaque) void {
        const f: *Fixture = @ptrCast(@alignCast(raw));
        f.wakes += 1;
        if (f.window) |window| window.redraw();
    }
    fn paste(raw: *anyopaque, target: drop.Target, text: []const u8) bool {
        const f: *Fixture = @ptrCast(@alignCast(raw));
        if (!valid(raw, target)) return false;
        // The value copy retains the real source's identity, but its own VT
        // and queue are private. Never let TerminalView.paste flush a real fd.
        const fd = f.session.fd;
        f.session.fd = -1;
        defer f.session.fd = fd;
        f.last_target = target.session;
        f.paste_calls += 1;
        return TerminalView.paste(&f.session, f.session.gpa, text);
    }
    fn draw(f: *Fixture, ctx: *ui.Context) void {
        f.builds += 1;
        if (f.bridge) |bridge| if (bridge.pending != null) {
            f.drain_calls += 1;
            f.last_drain = drop.drainToDialog(bridge, &f.confirmation, ctx);
        };
        ui.column(ctx, .{ .width = .fill, .height = .fill, .background = .hex(0x162028), .padding = .all(16) });
        ui.text(ctx, "Owned native drop bridge fixture", .{ .size = 14 });
        ui.end(ctx);
        if (f.confirmation.open) switch (f.confirmation.draw(ctx)) {
            .copy => ctx.clipboard.write(ctx.clipboard.ctx, f.confirmation.body.text()),
            .accept => f.confirmation.dismiss(ctx),
            else => {},
        };
    }
    fn publish(f: *Fixture) !void {
        const size = f.window.?.contentSize();
        try f.bridge.?.publish(&.{.{ .session = f.session.id, .rect = .{ .x = 0, .y = 0, .width = size[0], .height = size[1] } }}, f.blocked);
        f.bridge.?.setViewSize(size[0], size[1]);
    }
};
fn check(ok: bool, label: []const u8, count: *usize) !void {
    std.debug.print("{s} UI native drop {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.NativeDropUiCheck;
    count.* += 1;
}
fn noReply(_: ?*anyopaque, _: [*]const u8, _: usize) callconv(.c) void {}
fn noNotify(_: ?*anyopaque, _: u64) void {}
fn queueEquals(queue: Queue, expected: []const u8) bool {
    if (queue.len != expected.len) return false;
    var copy = queue;
    var pos: usize = 0;
    while (copy.len > 0) {
        const next = copy.peek();
        if (!std.mem.eql(u8, expected[pos..][0..next.len], next)) return false;
        pos += next.len;
        copy.consume(next.len);
    }
    return true;
}
fn nextFrame(surface: anytype, fallback: ?*ui.Tester) void {
    // Real occlusion policy forbids rebuilding a hidden Surface when the app
    // is not headless. Never toggle global App.flags: drive its SAME ui.View
    // callback through Tester in that case, keeping native registration real.
    if (fallback) |tester| tester.frame() else surface.frame();
}
fn deliver(handle: *anyopaque, values: []const [*:0]const u8, uris: bool) bool {
    return lt_drop_deliver(handle, values.ptr, values.len, 20, 20, uris);
}

pub fn run(s: anytype) !void {
    try runWithAccessibility(s, realAccessibility);
}
pub fn runWithAccessibility(s: anytype, accessibility: ?AxBackend) !void {
    if (comptime builtin.os.tag != .macos) {
        std.debug.print("NATIVE_DROP_SCOPE macOS owned NSView fixture pending on this target; real GTK/OS drop pending\n", .{});
        return;
    }
    var count: usize = 0;
    const source = s.active() orelse return error.NativeDropNeedsOwnedSourceSession;
    if (source.closing or source.eof or source.fatal) return error.NativeDropNeedsLiveSourceSession;
    const source_id = source.id;
    const source_pid = source.pid;
    const source_fd = source.fd;
    const source_queue = source.tx;
    const source_vt = source.vt;
    const source_revision = vt.lt_vt_revision(source_vt);
    const hidden_flag = s.app.flags.hidden;
    const terminal = try vt.create(source.gpa, s.app.io, 20, 4, 0, 1024 * 1024, noReply, null);
    defer vt.destroy(terminal);
    var fixture: Fixture = .{ .session = source.*, .original = source };
    fixture.session.vt = terminal;
    fixture.session.tx = try Queue.init(source.gpa, 128 * 1024);
    defer fixture.session.tx.deinit(source.gpa);
    fixture.session.read_watch = 0;
    fixture.session.write_watch = 0;
    fixture.session.child_watch = 0;
    fixture.session.mac_read = null;
    fixture.session.mac_child = null;
    fixture.session.notify_ctx = null;
    fixture.session.notify = noNotify;
    fixture.session.command_pending = false;
    fixture.session.focus_sink = null;
    const window = try s.app.newWindow(.{ .title = "Letty owned drop fixture", .visible = false, .width = 420, .height = 180, .content = .{ .view = .init(&fixture, Fixture.draw) } });
    fixture.window = window;
    defer {
        fixture.window = null;
        window.close();
        // Let Surface's already queued dead fallback retire before its view
        // callback context/allocator or the fixture's VT/TX leave scope.
        nano.runFor(0.03);
    }
    const surface = window.surface.?;
    const view: *anyopaque = @ptrCast(surface.nsview);
    var bridge = drop.Bridge.init(source.gpa, fixture.host());
    defer bridge.deinit();
    fixture.bridge = &bridge;
    defer fixture.bridge = null;
    try bridge.attach(view); // Real owned NanoUIView registerForDraggedTypes.
    const handle = bridge.handle.?;
    try check(!nano.objc.msg(bool, window.nswindow, "isVisible", .{}) and hidden_flag == s.app.flags.hidden, "owned window remains invisible without changing app flags", &count);
    try check(lt_drop_find(view) == handle, "actual native attach resolves the owned NanoUIView registry", &count);
    try check(!lt_drop_probe(handle, 20, 20), "unpublished native geometry refuses a drop", &count);
    try fixture.publish();
    try check(lt_drop_geometry_current(handle) and lt_drop_probe(handle, 20, 20), "published pane and true NSView bounds admit native probe", &count);
    var tester: ui.Tester = undefined;
    const use_tester = !s.app.flags.hidden;
    if (use_tester) try tester.init(source.gpa, .init(&fixture, Fixture.draw), .{ .width = 420, .height = 180 });
    defer if (use_tester) tester.deinit();
    const fallback: ?*ui.Tester = if (use_tester) &tester else null;
    const sample = [_][*:0]const u8{ "/tmp/O'Brien file.txt", "/tmp/$(not-run);literal" };
    const quoted = "'/tmp/O'\\''Brien file.txt' '/tmp/$(not-run);literal' ";
    try check(lt_drop_reserve(handle, 20, 20) and deliver(handle, &sample, false), "real native reserve and delivery accept local files", &count);
    try check(bridge.pending != null and fixture.session.tx.len == 0 and fixture.paste_calls == 0 and fixture.wakes == 1, "native callback only owns pending text and schedules UI work", &count);
    fixture.active_session = source_id ^ (@as(u64, 1) << 63); // No active fallback.
    const before_build = fixture.builds;
    nextFrame(surface, fallback);
    try check(fixture.builds > before_build and fixture.drain_calls == 1 and fixture.last_drain and queueEquals(fixture.session.tx, quoted), "UI frame drains exact POSIX quoted bytes through TerminalView.paste", &count);
    try check(fixture.last_target == source_id and fixture.session.id == source_id and fixture.session.pid == source_pid and fixture.session.fd == source_fd, "pending route preserves source ID/PID and restores the temporary fd", &count);
    try check(!fixture.session.command_pending and std.mem.indexOfAny(u8, fixture.session.tx.peek(), "\r\n") == null, "file paste appends a space and never Return or a command dispatch", &count);
    fixture.session.tx.consume(fixture.session.tx.len);
    try vt.feed(terminal, "\x1b[?2004h");
    try check(lt_drop_reserve(handle, 20, 20) and deliver(handle, &sample, false), "second delivery accepts a bracketed-paste terminal", &count);
    nextFrame(surface, fallback);
    try check(queueEquals(fixture.session.tx, "\x1b[200~" ++ quoted ++ "\x1b[201~"), "actual paste encoder frames the complete quoted list exactly once", &count);
    fixture.session.tx.consume(fixture.session.tx.len);
    try vt.feed(terminal, "\x1b[?2004l");
    var mutable = [_:0]u8{ '/', 't', 'm', 'p', '/', 'a' };
    const mutable_list = [_][*:0]const u8{&mutable};
    if (!lt_drop_reserve(handle, 20, 20) or !deliver(handle, &mutable_list, false)) return error.NativeDropDelivery;
    mutable[5] = 'b';
    nextFrame(surface, fallback);
    try check(queueEquals(fixture.session.tx, "'/tmp/a' "), "queued data owns the original path before native input storage changes", &count);
    fixture.session.tx.consume(fixture.session.tx.len);
    const uri = [_][*:0]const u8{"file://LOCALHOST/tmp/a%20b+z"};
    if (!lt_drop_reserve(handle, 20, 20) or !deliver(handle, &uri, true)) return error.NativeDropDelivery;
    nextFrame(surface, fallback);
    try check(queueEquals(fixture.session.tx, "'/tmp/a b+z' "), "URI callback contract preserves decoded spaces and literal plus", &count);
    fixture.session.tx.consume(fixture.session.tx.len);
    // This uses DELIVER's URI flag, not GTK's OS selection signal. The native
    // macOS pasteboard path and real OS/GTK drag events remain separate scope.
    fixture.blocked = true;
    try check(!lt_drop_probe(handle, 20, 20) and !lt_drop_reserve(handle, 20, 20), "modal host state rejects native route before copying payload", &count);
    fixture.blocked = false;
    if (!lt_drop_reserve(handle, 20, 20) or !deliver(handle, &sample, false)) return error.NativeDropDelivery;
    fixture.source_alive = false;
    nextFrame(surface, fallback);
    try check(fixture.session.tx.len == 0 and bridge.pending == null and bridge.discarded == 1, "closed source discards accepted pending text without retargeting", &count);
    fixture.source_alive = true;
    fixture.shell = .unknown;
    const pastes_before_preview = fixture.paste_calls;
    if (!lt_drop_reserve(handle, 20, 20) or !deliver(handle, &sample, false)) return error.NativeDropDelivery;
    nextFrame(surface, fallback);
    try check(fixture.confirmation.open and fixture.confirmation.kind == .drop_preview and fixture.session.tx.len == 0 and fixture.paste_calls == pastes_before_preview and std.mem.indexOf(u8, fixture.confirmation.body.text(), "/tmp/O'Brien file.txt") != null, "unknown shell uses raw diagnostic preview in the same UI drain without terminal insertion", &count);
    if (fallback) |t| {
        try t.clickText("Copy Details");
        try check(std.mem.eql(u8, t.clipboard.items, fixture.confirmation.body.text()) and fixture.session.tx.len == 0, "drop preview Copy Details uses only Tester clipboard and never PTY", &count);
        t.key(.enter);
        try check(!fixture.confirmation.open and fixture.session.tx.len == 0, "default Enter closes the preview without opening a config or pasting", &count);
    } else {
        fixture.confirmation.dismiss(&surface.ctx);
        std.debug.print("NATIVE_DROP_SCOPE preview click clipboard check requires the Tester path\n", .{});
    }
    fixture.shell = .posix;
    const remote = [_][*:0]const u8{"file://remote/tmp/forbidden"};
    try check(lt_drop_reserve(handle, 20, 20) and deliver(handle, &remote, true) and bridge.pending.?.preview_only and fixture.session.tx.len == 0, "remote URI is reserved only for raw preview and never PTY paste", &count);
    const remote_preview = bridge.takePreview() orelse return error.NativeDropPreview;
    defer bridge.gpa.free(remote_preview.text);
    try check(std.mem.eql(u8, remote_preview.text, "file://remote/tmp/forbidden\n") and fixture.session.tx.len == 0, "raw remote preview owns the original URI without local path conversion", &count);
    if (!lt_drop_reserve(handle, 20, 20)) return error.NativeDropReservation;
    window.setSize(500, 220);
    try check(!lt_drop_geometry_current(handle) and !lt_drop_probe(handle, 20, 20) and !deliver(handle, &sample, false), "native bounds change refuses stale probe and asynchronous delivery", &count);
    if (fallback) |t| t.resize(500, 220) else surface.frame();
    try fixture.publish();
    try check(lt_drop_geometry_current(handle) and lt_drop_probe(handle, 20, 20), "fresh UI geometry makes the resized owned view ready again", &count);
    if (!lt_drop_reserve(handle, 20, 20) or !deliver(handle, &sample, false)) return error.NativeDropDelivery;
    window.setSize(540, 240);
    nextFrame(surface, fallback);
    try check(fixture.session.tx.len == 0 and bridge.pending == null and bridge.discarded == 2, "drain also discards work if native resize preceded fresh geometry", &count);
    if (fallback) |t| t.resize(540, 240) else surface.frame();
    try fixture.publish();
    var ax_covered = false;
    if (accessibility) |backend| {
        if (backend.capability()) {
            try interoperability(&fixture, view, backend, &count);
            ax_covered = true;
        }
    }
    if (!ax_covered) std.debug.print("NATIVE_DROP_SCOPE AX isa interoperability pending: real backend not provided/available\n", .{});
    const final_handle = bridge.handle.?;
    if (!lt_drop_reserve(final_handle, 20, 20) or !deliver(final_handle, &sample, false)) return error.NativeDropDelivery;
    bridge.detach();
    try check(lt_drop_find(view) == null and !lt_drop_probe(final_handle, 20, 20) and !lt_drop_reserve(final_handle, 20, 20) and !deliver(final_handle, &sample, false), "native detach mutes registry and late bridge callbacks", &count);
    nextFrame(surface, fallback);
    try check(bridge.pending == null and fixture.session.tx.len == 0, "detaching releases undrained pending payload before view destruction", &count);
    try check(source.id == source_id and source.pid == source_pid and source.fd == source_fd and source.vt == source_vt and vt.lt_vt_revision(source_vt) == source_revision and source.tx.bytes.ptr == source_queue.bytes.ptr and source.tx.len == source_queue.len and source.tx.head == source_queue.head, "real source Session VT/queue/identity were never mutated or written", &count);
    try check(hidden_flag == s.app.flags.hidden and !nano.objc.msg(bool, window.nswindow, "isVisible", .{}), "fixture leaves global flags unchanged and owned window hidden", &count);
    std.debug.print("NATIVE_DROP_UI {{\"checks\":{d},\"real_nsview_attach\":true,\"ui_drain\":\"{s}\",\"ax_covered\":{},\"os_drag_events\":false,\"pty_writes\":false,\"real_gtk_os_drop\":\"pending\"}}\n", .{ count, if (use_tester) "same View via Tester (occluded Surface respected)" else "owned Surface.frame", ax_covered });
}

fn interoperability(fixture: *Fixture, view: *anyopaque, backend: AxBackend, count: *usize) !void {
    const bridge = fixture.bridge.?;
    const object: nano.objc.Object = @ptrCast(view);
    const original_class = nano.objc.msg(nano.objc.Class, object, "class", .{});
    var owner: ?*anyopaque = try backend.attach(fixture.session.gpa, fixture.window_id, view);
    defer if (owner) |live| backend.detach(fixture.session.gpa, live);
    const ax_class = nano.objc.msg(nano.objc.Class, object, "class", .{});
    try check(ax_class != original_class and lt_drop_probe(bridge.handle.?, 20, 20), "actual AX subclass attach preserves an already registered Drop destination", count);
    backend.detach(fixture.session.gpa, owner.?);
    owner = null;
    try check(nano.objc.msg(nano.objc.Class, object, "class", .{}) == original_class and lt_drop_probe(bridge.handle.?, 20, 20), "actual AX detach restores isa while Drop remains registered", count);
    bridge.detach();
    owner = try backend.attach(fixture.session.gpa, fixture.window_id, view);
    const second_ax_class = nano.objc.msg(nano.objc.Class, object, "class", .{});
    try bridge.attach(view);
    try fixture.publish();
    try check(nano.objc.msg(nano.objc.Class, object, "class", .{}) == second_ax_class and lt_drop_probe(bridge.handle.?, 20, 20), "Drop attach after actual AX does not replace its isa", count);
    bridge.detach();
    try check(nano.objc.msg(nano.objc.Class, object, "class", .{}) == second_ax_class, "Drop detach leaves the actual AX subclass intact", count);
    backend.detach(fixture.session.gpa, owner.?);
    owner = null;
    try check(nano.objc.msg(nano.objc.Class, object, "class", .{}) == original_class, "interleaved native bridge teardown restores the original owned view class", count);
    try bridge.attach(view);
    try fixture.publish();
}
