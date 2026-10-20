//! M11 real Host service transaction/queue and hidden Quick Terminal fixtures.
//! Only the injected registration adapter is enabled. No native hotkey backend,
//! visible window, system clipboard, desktop focus or OS permission is used.
const std = @import("std");
const nano = @import("nanoui");
const ui = nano.ui;
const keys = @import("keybindings.zig");
const hotkey = @import("global_hotkey.zig");
const actions = @import("actions.zig");
const Config = @import("config.zig").Config;
const Profile = @import("config.zig").Profile;

fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.ServicesHotkeysUiCheck;
}
const Fake = struct {
    const Entry = struct { key: u32, token: u64, handle: u64 };
    entries: [64]?Entry = @splat(null),
    next: u64 = 1,
    adds: usize = 0,
    removes: usize = 0,
    shutdowns: usize = 0,
    conflict: ?u32 = null,
    fn from(context: ?*anyopaque) *Fake {
        return @ptrCast(@alignCast(context.?));
    }
    fn adapter(self: *Fake) hotkey.Adapter {
        return .{ .context = self, .add = add, .remove = remove, .shutdown = shutdown };
    }
    fn add(context: ?*anyopaque, chord: hotkey.Chord, token_: u64) hotkey.RegisterError!u64 {
        const self = from(context);
        self.adds += 1;
        if (self.conflict == chord.key) return error.Conflict;
        for (&self.entries) |*entry| if (entry.* == null) {
            const handle = self.next;
            self.next += 1;
            entry.* = .{ .key = chord.key, .token = token_, .handle = handle };
            return handle;
        };
        return error.Limit;
    }
    fn remove(context: ?*anyopaque, handle: u64) bool {
        const self = from(context);
        self.removes += 1;
        for (&self.entries) |*entry| if (entry.* != null and entry.*.?.handle == handle) {
            entry.* = null;
            return true;
        };
        return false;
    }
    fn shutdown(context: ?*anyopaque) void {
        const self = from(context);
        self.shutdowns += 1;
        self.entries = @splat(null);
    }
    fn token(self: *const Fake, key: u32) u64 {
        for (self.entries) |entry| if (entry != null and entry.?.key == key) return entry.?.token;
        unreachable;
    }
    fn live(self: *const Fake) usize {
        var n: usize = 0;
        for (self.entries) |entry| if (entry != null) {
            n += 1;
        };
        return n;
    }
};

pub fn run(s: anytype) !void {
    const Host = @typeInfo(@TypeOf(s.host)).pointer.child;
    const Window = @typeInfo(@TypeOf(s)).pointer.child;
    const Deliver = struct {
        fn call(context: ?*anyopaque, request: *const actions.Request) void {
            const h: *Host = @ptrCast(@alignCast(context.?));
            h.services.enqueue(request) catch {
                h.services.dropped +|= 1;
            };
        }
    };
    var arena = std.heap.ArenaAllocator.init(s.gpa);
    defer arena.deinit();
    const profiles = [_]Profile{.{}};
    const cfg: Config = .{ .shell = "/bin/sh", .shell_integration = .none, .profiles = &profiles, .command = "exec /bin/sh -c 'sleep 30'", .copy_on_select = .none, .confirm_close = .never, .clear_default_keybinds = true };
    var fake: Fake = .{};
    var host: Host = .{ .gpa = s.gpa, .arena = arena.allocator(), .app = s.app, .cfg = cfg, .state_path = "/dev/null", .read_path = "/dev/null", .command_override = cfg.command, .override_profile = profiles[0].name, .demo = true, .hold = true };
    host.services.init(&host);
    defer {
        host.deinit();
        nano.runFor(0.025);
    }
    const first = try host.create(false);
    const first_pid = first.active().?.pid;
    const second = try host.create(false);
    const second_pid = second.active().?.pid;
    var t: ui.Tester = undefined;
    try t.init(s.gpa, .init(first, Window.view), .{ .width = 900, .height = 620, .theme = @import("appearance.zig").theme(cfg) });
    defer t.deinit();
    var bindings = [_]keys.Binding{
        try keys.parse("global:ctrl+alt+a=increase_font_size:2"),
        try keys.parse("global:ctrl+alt+b=start_search"),
        try keys.parse("ctrl+alt+z=new_tab"),
    };
    var next = cfg;
    next.keybinds = &bindings;
    var prepared = try host.services.prepare(next);
    defer prepared.deinit(s.gpa);
    try check(!prepared.enabled and prepared.entries.len == 2 and host.services.hotkeys.registry.adapter == null, "hidden real Host prepares only requested global bindings without loading native service");
    _ = try host.services.commit(&prepared);
    try check(host.services.hotkeys.registry.adapter == null, "disabled hidden Host commit remains inert with no OS registrations");
    try host.services.hotkeys.initAdapter(fake.adapter(), Deliver.call, &host);
    prepared.enabled = true; // Explicit injected adapter transaction, never nativeInit.
    _ = try host.services.commit(&prepared);
    host.cfg = next; // Matches host reload: publish only after service commit.
    try check(fake.live() == 2 and host.services.hotkeys.count == 2 and host.cfg.keybinds.ptr == bindings[0..].ptr, "real Host commit publishes owned requests only after injected registrations succeed");
    const a = fake.token('a');
    const b = fake.token('b');
    host.activate(first, false);
    const bytes_request = try actions.parse("text:SETTINGS_GUARD");
    const guard_pid = first.active().?.pid;
    const guard_tx = first.active().?.tx.len;
    host.settings_focused = true;
    const blocked_bytes = blk: {
        host.services.enqueue(&bytes_request) catch |err| break :blk err == error.SettingsInputActive;
        break :blk false;
    };
    try check(blocked_bytes and host.services.count == 0 and first.active().?.pid == guard_pid and first.active().?.tx.len == guard_tx, "focused Settings rejects service byte actions before enqueue without sending terminal input");
    const paste_request: actions.Request = .{ .action = .paste };
    const blocked_paste = blk: {
        host.services.enqueue(&paste_request) catch |err| break :blk err == error.SettingsInputActive;
        break :blk false;
    };
    try check(blocked_paste and host.services.count == 0, "focused Settings rejects service paste before reading any clipboard");
    const new_window: actions.Request = .{ .action = .new_window };
    const before_recording = host.count();
    host.settings.form.recording = true;
    const blocked_window = blk: {
        host.services.enqueue(&new_window) catch |err| break :blk err == error.SettingsInputActive;
        break :blk false;
    };
    try check(blocked_window and host.count() == before_recording and host.services.count == 0, "Settings shortcut recording refuses even app-wide global actions without creating a PTY");
    host.settings_focused = false;
    host.settings.form.recording = false;
    try host.services.enqueue(&new_window);
    const before_recording_drop = host.services.dropped;
    host.settings_focused = true;
    host.settings.form.recording = true;
    nano.runFor(0.005);
    try check(host.services.count == 0 and host.services.dropped == before_recording_drop + 1 and host.count() == before_recording, "app-wide action queued before shortcut recording is dropped by the event-loop wake");
    host.settings.form.recording = false;
    host.settings_focused = false;
    try host.services.enqueue(&bytes_request);
    const guard_dropped = host.services.dropped;
    host.settings_focused = true;
    t.frame();
    try check(host.services.count == 0 and host.services.dropped == guard_dropped + 1 and first.active().?.pid == guard_pid and first.active().?.tx.len == guard_tx, "service byte action queued before Settings focus is rejected again at execution");
    host.settings_focused = false;
    const first_font = first.cfg.font_size;
    const second_font = second.cfg.font_size;
    host.services.hotkeys.registry.dispatch(a);
    try check(host.services.count == 1 and first.cfg.font_size == first_font and host.services.armed, "registered service callback queues stable window target and one event-loop wake without executing action");
    host.activate(second, false);
    nano.runFor(0.003);
    t.frame();
    try check(first.cfg.font_size == first_font + 2 and second.cfg.font_size == second_font and host.services.count == 0, "deferred real Window action keeps original target after another window becomes active");
    host.activate(first, false);
    host.services.hotkeys.registry.dispatch(b);
    try first.add(.tab);
    const dropped = host.services.dropped;
    t.frame();
    try check(!first.search_open and host.services.count == 0 and host.services.dropped == dropped + 1, "queued session action is discarded after target tab/session changes rather than routed to new PTY");
    var bad = [_]keys.Binding{ try keys.parse("global:ctrl+alt+c=decrease_font_size:3"), try keys.parse("global:ctrl+alt+x=reset_font_size") };
    var rejected = next;
    rejected.keybinds = &bad;
    var failure = try host.services.prepare(rejected);
    defer failure.deinit(s.gpa);
    failure.enabled = true;
    fake.conflict = 'x';
    const failed = blk: {
        _ = host.services.commit(&failure) catch |err| break :blk err == error.Conflict;
        break :blk false;
    };
    try check(failed and fake.live() == 2 and host.services.hotkeys.count == 2 and host.cfg.keybinds.ptr == bindings[0..].ptr, "real Host service conflict rolls back staged grabs and leaves previous configuration/action table intact");
    const font = first.cfg.font_size;
    host.services.hotkeys.registry.dispatch(a);
    t.frame();
    try check(first.cfg.font_size == font + 2, "old registered token still dispatches previous owned request after failed reload transaction");
    fake.conflict = null;
    bindings[0] = try keys.parse("global:ctrl+alt+a=increase_font_size:3");
    const adds = fake.adds;
    var replacement = try host.services.prepare(next);
    defer replacement.deinit(s.gpa);
    replacement.enabled = true;
    _ = try host.services.commit(&replacement);
    const updated_font = first.cfg.font_size;
    host.services.hotkeys.registry.dispatch(a);
    t.frame();
    try check(fake.adds == adds and first.cfg.font_size == updated_font + 3, "same registered chord reuses native handle while real queue adopts changed request arguments");
    host.activate(second, false);
    host.services.hotkeys.registry.dispatch(a);
    const stale = host.services.dropped;
    host.closeWindow(second);
    nano.runFor(0.003);
    try check(host.services.count == 0 and host.services.dropped == stale + 1 and first.active().?.pid != second_pid, "event-loop wake drops a closed window target without touching a surviving PTY");
    try check(host.app.flags.hidden, "Quick Terminal fixture runs only inside the hidden application");
    const ordinary_count = host.count();
    const geometry = @import("quick_terminal.zig").Geometry{ .screen = .{ .x = 0, .y = 0, .width = 1024, .height = 768 }, .width = 0.75, .height = 0.5 };
    try host.services.quick.toggle(&host, geometry);
    const quick_id = host.services.quick.window_id.?;
    const quick = host.find(quick_id).?;
    const quick_pid = quick.active().?.pid;
    try check(quick.transient_quick and quick.window != null and quick_pid > 0 and host.count() == ordinary_count + 1 and (quick.ax.adapter == null or quick.ax.adapter.?.native == null), "dedicated Quick Terminal creates an initially hidden real native window and PTY without native AX");
    try host.services.quick.toggle(&host, geometry);
    const panes = host.paneCount();
    var moved = geometry;
    moved.screen = .{ .x = -1280, .y = 20, .width = 1280, .height = 900 };
    moved.position = .bottom;
    moved.auto_hide = false;
    try host.services.quick.reconfigure(&host, moved);
    try check(!host.services.quick.visible and quick.active().?.pid == quick_pid and host.paneCount() == panes and host.active().?.id != quick_id, "hidden Quick Terminal screen reflow keeps original PTY and remains absent from ordinary active-window routing");
    try host.services.quick.toggle(&host, moved);
    host.services.quick.focusChanged(&host, quick_id, false);
    try check(host.services.quick.visible and quick.active().?.pid == quick_pid and first.sessions[0].?.pid == first_pid, "restoring Quick Terminal and configured nonhiding blur preserve both quick and ordinary PTYs");
    moved.auto_hide = true;
    try host.services.quick.reconfigure(&host, moved);
    host.services.quick.focusChanged(&host, quick_id, false);
    try check(!host.services.quick.visible and quick.active().?.pid == quick_pid, "real hidden Quick Terminal auto-hide leaves its child running for next restore");
    host.services.hotkeys.registry.dispatch(a);
    host.services.stop();
    host.services.hotkeys.registry.dispatch(a);
    try check(fake.shutdowns == 1 and fake.live() == 0 and host.services.count == 0 and !host.services.armed and host.services.owner == null, "service stop cancels pending event-loop delivery and unregisters all injected grabs before owner teardown");
    host.services.init(&host);
    try fullCommitStatus(first, quick, &t);
}

fn fullCommitStatus(source: anytype, background: anytype, t: *ui.Tester) !void {
    const h = source.host;
    if (h.config_arena != null) return error.ServicesFixtureAlreadyOwnsConfig;
    // Reproduce next_profile's status borrowing from a real old config owner,
    // not a literal/stack Profile that remains valid after commit.
    h.config_arena = std.heap.ArenaAllocator.init(source.gpa);
    const old_allocator = h.config_arena.?.allocator();
    const old_profiles = try old_allocator.dupe(Profile, h.cfg.profiles);
    for (old_profiles) |*profile| profile.name = try old_allocator.dupe(u8, profile.name);
    h.cfg.profiles = old_profiles;
    for (h.windows) |entry| if (entry) |window| {
        window.cfg.profiles = old_profiles;
    };
    background.status = background.cfg.profiles[background.profile].name;
    const old_status_address = @intFromPtr(background.status.ptr);
    const source_id = source.active().?.id;
    const source_pid = source.active().?.pid;
    const background_id = background.active().?.id;
    const background_pid = background.active().?.pid;
    try check(background.status.len > 0 and background.status.ptr == old_profiles[background.profile].name.ptr, "full-commit regression starts with another window status borrowing the old config arena profile name");
    var next_arena = std.heap.ArenaAllocator.init(source.gpa);
    defer next_arena.deinit();
    const next_allocator = next_arena.allocator();
    var candidate = h.cfg;
    const next_profiles = try next_allocator.dupe(Profile, h.cfg.profiles);
    for (next_profiles) |*profile| profile.name = try next_allocator.dupe(u8, profile.name);
    candidate.profiles = next_profiles;
    candidate.font_size += 1; // Force the full config path, not navigation-only.
    const desired_font = candidate.font_size;
    var transaction = try @import("config_transaction.zig").Transaction(@TypeOf(source)).prepare(source, &next_arena, candidate);
    defer transaction.deinit();
    if (transaction.navigation_only) return error.ServicesExpectedFullConfigCommit;
    transaction.commit(&t.ctx);
    try check(background.status.len == 0 and h.cfg.font_size == desired_font and source.cfg.font_size == desired_font and background.cfg.font_size == desired_font and @intFromPtr(background.cfg.profiles[background.profile].name.ptr) != old_status_address and source.active().?.id == source_id and source.active().?.pid == source_pid and background.active().?.id == background_id and background.active().?.pid == background_pid, "full config commit clears borrowed background status before old arena release while adopting new profiles and preserving both PTYs");
    t.frame();
}
