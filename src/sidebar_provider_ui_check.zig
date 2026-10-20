//! Application-level event/worker ownership against private Session PTYs and
//! temporary non-Git directories. Ports stay disabled; no user process scan or
//! repository lookup is requested. No work is launched from draw().
const std = @import("std");
const nano = @import("nanoui");
const ui = nano.ui;
const vt = @import("vt.zig");
const c = @import("platform_ffi.zig");
const Config = @import("config.zig").Config;
const Profile = @import("config.zig").Profile;
const Session = @import("session.zig").Session;
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn lt_mkdirs([*:0]const u8) c_int;
const Identity = struct { window: u64, session: u64, pid: c_int };
fn check(ok: bool, label: []const u8) !void {
    std.debug.print("{s} UI Sidebar provider {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    if (!ok) return error.SidebarProviderUiCheck;
}
const Probe = struct {
    id: u64,
    original: *const fn (?*anyopaque, u64) void,
    original_context: ?*anyopaque,
    count: usize = 0,
    closed: bool = false,
    late: usize = 0,
    fn notify(raw: ?*anyopaque, id: u64) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        if (self.closed and id == self.id) {
            self.late += 1;
            return;
        }
        self.count += 1;
        self.original(self.original_context, id);
    }
};
fn cwd(session: *Session, path: []const u8) !void {
    const sequence = try std.fmt.allocPrint(session.gpa, "\x1b]7;file://localhost{s}\x1b\\", .{path});
    defer session.gpa.free(sequence);
    try vt.feed(session.vt, sequence);
    session.refresh();
}
fn awaitReady(session: *Session, t: *ui.Tester) !void {
    // An OSC7 emitted by a real shell cannot precede login/exec readiness.
    // Wait on this private child's real PTY output before injecting its cwd.
    const started = c.lt_millis();
    while (c.lt_millis() -| started < 4000) {
        nano.runFor(0.01);
        t.frame();
        if (session.eof or session.fatal) return error.SidebarProviderSessionExited;
        if (vt.lt_vt_select_all(session.vt) != 0) continue;
        defer vt.lt_vt_clear_selection(session.vt);
        var bytes: [4096]u8 = undefined;
        var len: usize = 0;
        if (vt.lt_vt_copy(session.vt, &bytes, bytes.len, &len) != 0) return error.SidebarProviderReadyCopy;
        if (std.mem.indexOf(u8, bytes[0..len], "__SIDEBAR_PROVIDER_READY__") != null) return;
    }
    return error.SidebarProviderReadyTimeout;
}
fn awaitCurrent(session: *Session, t: *ui.Tester, generation: u64) !void {
    const started = c.lt_millis();
    for (0..250) |_| {
        nano.runFor(0.01);
        t.frame();
        if (session.metadata.snapshot) |snapshot| {
            if (snapshot.generation != generation or !snapshot.currentFor(session.id, session.metadata.generation)) return error.SidebarStaleProviderPublished;
            return;
        }
        if (session.eof or session.fatal) return error.SidebarProviderSessionExited;
        if (session.metadata.last_error != null) return error.SidebarProviderWorkerFailed;
    }
    const state = &session.metadata;
    std.debug.print("SIDEBAR_PROVIDER_COMPLETIONS count={d} last={any}\n", .{ state.completions, state.last_completion });
    std.debug.print("SIDEBAR_PROVIDER_TIMEOUT elapsed_ms={d} expected_generation={d} current_generation={d} pending={any} owner={any} provider={any} watch={d} mac_watch={any} delay={any} last_start={d} error={s} session_id={d} pid={d} eof={any} fatal={any} status={any}\n", .{ c.lt_millis() -| started, generation, state.generation, state.pending, state.owner != null, state.provider != null, state.watch, state.mac_watch != null, state.delay != null, state.last_start, if (state.last_error) |err| @errorName(err) else "none", session.id, session.pid, session.eof, session.fatal, session.status });
    // Only inspect/drain after this check has already failed; successful runs
    // must prove production fd-watch delivery rather than test-side polling.
    if (state.provider) |*provider| {
        const result = provider.drain() catch |err| {
            std.debug.print("SIDEBAR_PROVIDER_TIMEOUT_DRAIN error={s}\n", .{@errorName(err)});
            return error.SidebarProviderTimeout;
        };
        if (result) |snapshot| {
            std.debug.print("SIDEBAR_PROVIDER_TIMEOUT_DRAIN generation={d} session={d} root_pid={d} birth={d} git={s} ports={s} current={any} elapsed_us={d}\n", .{ snapshot.generation, snapshot.session_id, snapshot.root_pid, snapshot.root_birth, @tagName(snapshot.git_state), @tagName(snapshot.ports_state), snapshot.currentFor(session.id, state.generation), snapshot.elapsed_us });
        } else std.debug.print("SIDEBAR_PROVIDER_TIMEOUT_DRAIN no_completed_result\n", .{});
    }
    return error.SidebarProviderTimeout;
}
fn empty(session: *Session) bool {
    const state = &session.metadata;
    return state.owner == null and state.provider == null and state.watch == 0 and state.mac_watch == null and state.delay == null and state.snapshot == null and !state.pending and !state.git and !state.ports;
}
pub fn run(s: anytype) !void {
    var originals: [16]Identity = undefined;
    var count: usize = 0;
    for (s.host.windows) |entry| if (entry) |w| for (w.sessions) |maybe| if (maybe) |session| {
        if (count == originals.len) return error.SidebarOriginalIdentityLimit;
        originals[count] = .{ .window = w.id, .session = session.id, .pid = session.pid };
        count += 1;
    };
    try isolated(s);
    for (originals[0..count]) |original| {
        const w = s.host.find(original.window) orelse return error.SidebarOriginalWindowLost;
        var found = false;
        for (w.sessions) |maybe| if (maybe) |session| if (session.id == original.session and session.pid == original.pid) {
            found = true;
            break;
        };
        if (!found) return error.SidebarOriginalSessionChanged;
    }
    try check(count > 0, "private metadata fixture teardown preserves every surrounding application Session ID and PID");
}
fn isolated(s: anytype) !void {
    const Host = @typeInfo(@TypeOf(s.host)).pointer.child;
    const Window = @typeInfo(@TypeOf(s)).pointer.child;
    var arena = std.heap.ArenaAllocator.init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const template = try a.dupeSentinel(u8, "/tmp/letty-sidebar-provider-XXXXXX", 0);
    const directory = mkdtemp(template) orelse return error.SidebarProviderDirectory;
    defer _ = std.c.rmdir(directory);
    var absolute: [4096]u8 = undefined;
    if (c.lt_absolute_path(directory, &absolute, absolute.len) != 0) return error.SidebarProviderDirectory;
    const root = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&absolute)), 0);
    const first_path = try std.fmt.allocPrintSentinel(a, "{s}/one", .{root}, 0);
    const last_path = try std.fmt.allocPrintSentinel(a, "{s}/two", .{root}, 0);
    if (lt_mkdirs(first_path) != 0 or lt_mkdirs(last_path) != 0) return error.SidebarProviderDirectory;
    defer {
        _ = std.c.rmdir(first_path);
        _ = std.c.rmdir(last_path);
    }
    const profiles = [_]Profile{.{}};
    const cfg: Config = .{ .shell = "/bin/sh", .shell_integration = .none, .profiles = &profiles, .command = "exec /bin/sh -c 'printf \"__SIDEBAR_PROVIDER_READY__\\r\\n\"; sleep 30'", .copy_on_select = .none, .confirm_close = .never, .clear_default_keybinds = true, .workspace_navigation = .sidebar, .sidebar_show_git = true, .sidebar_show_ports = false };
    var host: Host = .{ .gpa = s.gpa, .arena = a, .app = s.app, .cfg = cfg, .state_path = "/dev/null", .read_path = "/dev/null", .command_override = cfg.command, .override_profile = profiles[0].name, .demo = true, .hold = true };
    host.services.init(&host);
    defer {
        host.deinit();
        nano.runFor(0.03);
    }
    const w = try host.create(false);
    const source = w.active().?;
    const source_id = source.id;
    const source_pid = source.pid;
    var probe: Probe = .{ .id = source_id, .original = source.notify, .original_context = source.notify_ctx };
    source.notify = Probe.notify;
    source.notify_ctx = &probe;
    // Probe's stack storage remains alive through Host teardown/error paths;
    // no source pointer is dereferenced after w.close(0) below.
    var t: ui.Tester = undefined;
    try t.init(s.gpa, .init(w, Window.view), .{ .width = 900, .height = 560, .theme = @import("appearance.zig").theme(cfg) });
    defer t.deinit();
    try check(source.metadata.owner == source and source.metadata.git and !source.metadata.ports and source.metadata.provider == null, "enabled Git metadata waits for trusted Session cwd instead of scanning application or user directory");
    try awaitReady(source, &t);
    try check(source.metadata.provider == null and source.pid == source_pid and !source.eof, "real private shell READY precedes injected OSC7 and root process identity capture");
    try cwd(source, root);
    const initial_generation = source.metadata.generation;
    const worker_started = std.mem.eql(u8, source.cwd.text(), root) and initial_generation > 0 and source.metadata.provider != null and source.metadata.last_start > 0;
    if (!worker_started) {
        const last_errno = std.c.errno(@as(c_int, -1));
        const state = &source.metadata;
        std.debug.print("SIDEBAR_PROVIDER_FIRST_START cwd=\"{s}\" expected_cwd=\"{s}\" currentgen={d} owner={any} exact_owner={any} git={any} ports={any} pending={any} delay={any} provider={any} last_start={d} error={s} errno={s} session={d} pid={d} eof={any} fatal={any} status={any}\n", .{ source.cwd.text(), root, state.generation, state.owner != null, state.owner == source, state.git, state.ports, state.pending, state.delay != null, state.provider != null, state.last_start, if (state.last_error) |err| @errorName(err) else "none", @tagName(last_errno), source.id, source.pid, source.eof, source.fatal, source.status });
    }
    try check(worker_started, "real OSC7 plus Session.refresh starts bounded native worker before another draw");
    try awaitCurrent(source, &t, initial_generation);
    const initial = source.metadata.snapshot.?;
    try check(initial.git_state == .non_repository and initial.ports_state == .disabled and initial.port_count == 0 and initial.branchText().len == 0 and initial.root_pid == source_pid and initial.currentFor(source_id, initial_generation), "notification-fd callback publishes current owned nonrepository result for exact private child PID");
    try check(probe.count > 0 and (source.metadata.watch != 0 or source.metadata.mac_watch != null), "native metadata completion reaches application notification through installed platform fd watch");
    const idle_generation = source.metadata.generation;
    const idle_start = source.metadata.last_start;
    const notifications = probe.count;
    for (0..32) |_| t.frame();
    try check(source.metadata.generation == idle_generation and source.metadata.last_start == idle_start and probe.count == notifications, "repeated static sidebar draw frames neither request metadata nor start another worker");
    const before_burst = source.metadata.generation;
    try cwd(source, first_path);
    const first_start = source.metadata.last_start;
    try cwd(source, root);
    try cwd(source, last_path);
    const latest = source.metadata.generation;
    try check(latest == before_burst + 3 and source.metadata.last_start == first_start and source.metadata.snapshot == null and std.mem.eql(u8, source.cwd.text(), last_path), "rapid trusted-cwd events invalidate old snapshot and coalesce without repeated immediate starts");
    try awaitCurrent(source, &t, latest);
    try check(source.metadata.snapshot.?.generation == latest and source.metadata.snapshot.?.git_state == .non_repository and source.metadata.snapshot.?.currentFor(source_id, latest), "older canceled completion cannot publish over the merged latest-cwd generation");
    const prompt_generation = source.metadata.generation;
    try vt.feed(source.vt, "\x1b]133;A\x1b\\");
    source.refresh();
    try check(source.metadata.generation > prompt_generation and source.metadata.snapshot == null, "actual VT prompt event revokes prior metadata through Session.refresh without rendering trigger");
    try awaitCurrent(source, &t, source.metadata.generation);
    // Force a merged pending request, then exercise actual config->Session
    // disable before its delayed/completing worker can wake the owner again.
    source.metadata.request();
    source.metadata.request();
    w.cfg.sidebar_show_git = false;
    w.configureSession(source);
    try check(empty(source), "configuration disable clears snapshot provider fd watches pending delay flags and Session owner");
    const disabled_notifications = probe.count;
    for (0..30) |_| {
        nano.runFor(0.01);
        t.frame();
    }
    try check(empty(source) and source.metadata.generation == 0 and probe.count == disabled_notifications and source.pid == source_pid, "disabled worker completion and repeated draw cannot republish or notify while child remains unchanged");
    try w.add(.tab);
    const survivor = w.active().?;
    const survivor_id = survivor.id;
    const survivor_pid = survivor.pid;
    w.cfg.sidebar_show_git = true;
    w.configureSession(source);
    source.metadata.request();
    try check(source.metadata.owner == source and source.metadata.provider != null, "re-enabled owned Session has active worker resources before close regression");
    probe.closed = true;
    w.close(0);
    for (0..35) |_| {
        nano.runFor(0.01);
        t.frame();
    }
    try check(probe.late == 0 and w.sessions[0] == null and host.find(w.id) == w and w.active().?.id == survivor_id and w.active().?.pid == survivor_pid, "closing Session cancels metadata callback ownership while independent tab and PID remain live");
    // A dedicated noninteractive shell exits on our explicit private input;
    // no shell startup file or external process is consulted.
    const prior_command = w.command_override;
    w.command_override = "exec /bin/sh -c 'printf \"__SIDEBAR_PROVIDER_READY__\\r\\n\"; read directive; test \"$directive\" = exit; exit $?'";
    try w.add(.tab);
    w.command_override = prior_command;
    const exiting = w.active().?;
    const exit_id = exiting.id;
    const exit_pid = exiting.pid;
    const exit_tab = w.layout.tabs[w.layout.active_tab].id;
    try awaitReady(exiting, &t);
    try cwd(exiting, first_path);
    try awaitCurrent(exiting, &t, exiting.metadata.generation);
    try check(exiting.metadata.provider != null and exiting.metadata.snapshot.?.git_state == .non_repository and !exiting.eof, "hold-exit fixture first completes a real owned worker before private child exit");
    if (!exiting.send("exit\n")) return error.SidebarProviderExitInputRefused;
    for (0..250) |_| {
        nano.runFor(0.01);
        t.frame();
        if (exiting.eof and exiting.status != null) break;
    }
    try check(exiting.eof and exiting.status != null and exiting.status.? == 0 and !exiting.closing and exiting.id == exit_id and exiting.pid == exit_pid and w.layout.tabIndex(exit_tab) != null, "natural child exit leaves its held VT tab and stable Session identity available");
    try check(empty(exiting), "held natural exit releases provider snapshot owner notification watches and pending timer without closing tab");
    for (0..10) |_| {
        nano.runFor(0.01);
        t.frame();
    }
    try check(empty(exiting) and exiting.metadata.generation == 0 and survivor.pid == survivor_pid and !survivor.eof, "held exited tab cannot restart metadata during later frames and independent child stays alive");
    // Exercise the production fatal-render path only at the end of this
    // fixture, after establishing its own successful real worker.
    try awaitReady(survivor, &t);
    w.configureSession(survivor);
    try cwd(survivor, last_path);
    try awaitCurrent(survivor, &t, survivor.metadata.generation);
    survivor.metadata.request();
    survivor.renderFailed();
    try check(survivor.fatal and survivor.pid == survivor_pid and empty(survivor), "fatal render failure immediately stops active or delayed metadata resources while preserving owned child identity for normal teardown");
}
