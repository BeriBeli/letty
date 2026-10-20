//! Session-scoped native metadata. start() is called by host events, never
//! draw(); notificationFd() integrates with existing fdwatch. No timers or
//! callbacks enter nanoui here. drain() returns a complete owned value.
const std = @import("std");
pub const State = enum(c_int) { disabled = 0, ok = 1, non_repository = 2, unavailable = 3, permission = 4, timeout = 5, cancelled = 6, stale = 7, limit = 8, failed = 9 };
pub const max_ports = 32;
pub const max_timeout_ms = 1500;
pub const Port = extern struct { pid: i32, port: u16, family: u8, reserved: u8 = 0, birth: u64 };
const Raw = extern struct {
    session_id: u64,
    generation: u64,
    root_birth: u64,
    root_pid: i32,
    git_state: c_int,
    ports_state: c_int,
    error_code: i32,
    git_dirty: u32,
    git_detached: u32,
    port_count: u32,
    partial: u32,
    scanned_pids: u32,
    scanned_fds: u32,
    elapsed_us: u64,
    branch: [256]u8,
    head: [32]u8,
    ports: [max_ports]Port,
};
comptime {
    std.debug.assert(@sizeOf(Port) == 16 and @sizeOf(Raw) == 872);
    std.debug.assert(@offsetOf(Raw, "branch") == 72);
}
pub const Snapshot = struct {
    session_id: u64,
    generation: u64,
    root_birth: u64,
    root_pid: i32,
    git_state: State,
    ports_state: State,
    git_dirty: bool,
    git_detached: bool,
    branch: [256]u8,
    head: [32]u8,
    ports: [max_ports]Port,
    port_count: usize,
    partial: bool,
    scanned_pids: u32,
    scanned_fds: u32,
    elapsed_us: u64,
    pub fn branchText(self: *const Snapshot) []const u8 {
        return std.mem.sliceTo(&self.branch, 0);
    }
    pub fn headText(self: *const Snapshot) []const u8 {
        return std.mem.sliceTo(&self.head, 0);
    }
    pub fn listeningPorts(self: *const Snapshot) []const Port {
        return self.ports[0..self.port_count];
    }
    /// Host also revokes generations when cwd/flags/window/session change.
    /// Failed/unknown results are current diagnostics, never fake metadata.
    pub fn currentFor(self: *const Snapshot, session_id: u64, generation: u64) bool {
        return self.session_id == session_id and self.generation == generation and self.root_birth > 0 and self.root_pid > 0 and self.git_state != .stale and self.ports_state != .stale and self.git_state != .cancelled and self.ports_state != .cancelled;
    }
};
pub const Options = struct {
    generation: u64,
    /// Caller has validated this is the Session's trusted local directory.
    cwd: ?[:0]const u8 = null,
    git: bool = false,
    ports: bool = false,
    timeout_ms: u32 = 750,
};
const Context = opaque {};
extern "c" fn lt_nav_provider_create(u64, i32) ?*Context;
extern "c" fn lt_nav_provider_fd(*const Context) c_int;
extern "c" fn lt_nav_provider_start(*Context, u64, ?[*:0]const u8, c_int, c_int, u32) c_int;
extern "c" fn lt_nav_provider_cancel(*Context) void;
extern "c" fn lt_nav_provider_drain(*Context, *Raw) c_int;
extern "c" fn lt_nav_provider_destroy(*Context) void;
pub const Provider = struct {
    handle: *Context,
    pub fn init(session_id: u64, root_pid: i32) !Provider {
        return .{ .handle = lt_nav_provider_create(session_id, root_pid) orelse return error.ProviderUnavailable };
    }
    pub fn notificationFd(self: *const Provider) c_int {
        return lt_nav_provider_fd(self.handle);
    }
    /// false means busy. To replace work: cancel(), retain fdwatch until drain,
    /// then start a merged newer generation. No old cwd pointer is retained.
    pub fn start(self: *Provider, options: Options) !bool {
        if (options.generation == 0 or options.timeout_ms == 0 or options.timeout_ms > max_timeout_ms or (!options.git and !options.ports)) return error.InvalidProviderRequest;
        if (options.git) {
            const cwd = options.cwd orelse return error.InvalidProviderRequest;
            if (cwd.len == 0 or cwd.len > 4095 or cwd[0] != '/' or !std.unicode.utf8ValidateSlice(cwd) or std.mem.indexOfAny(u8, cwd, "\x00\r\n") != null) return error.InvalidProviderRequest;
        }
        return switch (lt_nav_provider_start(self.handle, options.generation, if (options.cwd) |cwd| cwd.ptr else null, @intFromBool(options.git), @intFromBool(options.ports), options.timeout_ms)) {
            0 => false,
            1 => true,
            else => error.ProviderStartFailed,
        };
    }
    pub fn cancel(self: *Provider) void {
        lt_nav_provider_cancel(self.handle);
    }
    pub fn drain(self: *Provider) !?Snapshot {
        var raw: Raw = undefined;
        return switch (lt_nav_provider_drain(self.handle, &raw)) {
            0 => null,
            1 => try decode(raw),
            else => error.ProviderDrainFailed,
        };
    }
    /// Host unhooks fdwatch first. This nonblocking retire cancels + detaches
    /// the independent short worker. It reaps Git and frees resources itself;
    /// no UI/Session/cwd borrow survives. Cancel checks run every <=10ms between
    /// bounded platform calls. OS scheduling is not a hard real-time guarantee.
    pub fn deinit(self: *Provider) void {
        lt_nav_provider_destroy(self.handle);
        self.* = undefined;
    }
};
fn decode(raw: Raw) !Snapshot {
    const git_state = std.enums.fromInt(State, raw.git_state) orelse return error.InvalidProviderSnapshot;
    const ports_state = std.enums.fromInt(State, raw.ports_state) orelse return error.InvalidProviderSnapshot;
    if (raw.port_count > max_ports or raw.scanned_pids > 256 or raw.scanned_fds > 8193 or raw.session_id == 0 or raw.generation == 0 or raw.root_pid <= 0 or raw.root_birth == 0) return error.InvalidProviderSnapshot;
    if (std.mem.indexOfScalar(u8, &raw.branch, 0) == null or std.mem.indexOfScalar(u8, &raw.head, 0) == null) return error.InvalidProviderSnapshot;
    const branch = std.mem.sliceTo(&raw.branch, 0);
    if (!std.unicode.utf8ValidateSlice(branch)) return error.InvalidProviderSnapshot;
    for (branch) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidProviderSnapshot;
    for (std.mem.sliceTo(&raw.head, 0)) |byte| if (!std.ascii.isHex(byte)) return error.InvalidProviderSnapshot;
    for (raw.ports[0..raw.port_count]) |port| if (port.pid <= 0 or port.birth == 0 or port.port == 0 or (port.family != 4 and port.family != 6)) return error.InvalidProviderSnapshot;
    return .{ .session_id = raw.session_id, .generation = raw.generation, .root_birth = raw.root_birth, .root_pid = raw.root_pid, .git_state = git_state, .ports_state = ports_state, .git_dirty = raw.git_dirty != 0, .git_detached = raw.git_detached != 0, .branch = raw.branch, .head = raw.head, .ports = raw.ports, .port_count = raw.port_count, .partial = raw.partial != 0, .scanned_pids = raw.scanned_pids, .scanned_fds = raw.scanned_fds, .elapsed_us = raw.elapsed_us };
}
test "provider result keeps only owned metadata and checks current session generation" {
    var raw: Raw = std.mem.zeroes(Raw);
    raw.session_id = 12;
    raw.generation = 7;
    raw.root_pid = 123;
    raw.root_birth = 456;
    raw.git_state = 1;
    raw.ports_state = 1;
    @memcpy(raw.branch[0..4], "main");
    raw.port_count = 1;
    raw.ports[0] = .{ .pid = 124, .birth = 457, .port = 8000, .family = 4 };
    const snapshot = try decode(raw);
    @memset(&raw.branch, 0);
    try std.testing.expectEqualStrings("main", snapshot.branchText());
    try std.testing.expectEqual(@as(u16, 8000), snapshot.listeningPorts()[0].port);
    try std.testing.expect(snapshot.currentFor(12, 7));
    try std.testing.expect(!snapshot.currentFor(12, 8) and !snapshot.currentFor(13, 7));
}
test "provider decoder rejects corrupted lengths text states and stale ownership" {
    var raw: Raw = std.mem.zeroes(Raw);
    raw.session_id = 12;
    raw.generation = 7;
    raw.root_pid = 123;
    raw.root_birth = 456;
    raw.git_state = 7;
    try std.testing.expect(!(try decode(raw)).currentFor(12, 7));
    raw.git_state = 6;
    try std.testing.expect(!(try decode(raw)).currentFor(12, 7));
    raw.port_count = 33;
    try std.testing.expectError(error.InvalidProviderSnapshot, decode(raw));
    raw.port_count = 0;
    raw.git_state = 99;
    try std.testing.expectError(error.InvalidProviderSnapshot, decode(raw));
    raw.git_state = 1;
    raw.branch[0] = 0xff;
    try std.testing.expectError(error.InvalidProviderSnapshot, decode(raw));
}
