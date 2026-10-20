//! One independently owned document. The host assigns id and unregisters its
//! fdwatch before open/deinit. Worker results never retain this State pointer.
const std = @import("std");
pub const loader = @import("loader.zig");
pub const Kind = loader.Kind;
pub const Status = loader.Status;
pub const Hooks = loader.Hooks;
pub const Prepared = loader.Prepared;
const Text = @import("../fixed_text.zig").Text;
pub const State = struct {
    id: u64 = 0,
    generation: u64 = 0,
    path: Text(4096) = .{},
    bytes: []const u8 = &.{},
    kind: Kind = .unsupported,
    status: Status = .closed,
    revision: u64 = 0,
    stale: bool = false,
    watch_available: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    lines: usize = 0,
    loader: ?loader.Loader = null,
    hooks: Hooks = .{},
    prepared: ?Prepared = null,
    owned: ?loader.Result = null,
    pub fn open(self: *State, gpa: std.mem.Allocator, path: []const u8) !void {
        const generation = try next(self.generation);
        const candidate = try loader.Loader.init(path, generation, self.hooks);
        self.deinit(gpa);
        self.generation = generation;
        self.path.set(path);
        self.loader = candidate;
        self.status = .loading;
    }
    pub fn refresh(self: *State) !void {
        const source = if (self.loader) |*value| value else return error.PreviewClosed;
        const generation = try next(self.generation);
        try source.refresh(generation);
        self.generation = generation;
        self.status = .loading;
        self.stale = self.owned != null;
    }
    pub fn fd(self: *const State) ?c_int {
        return if (self.loader) |*value| value.fd() else null;
    }
    /// true means an event/result was consumed; call again until false.
    /// A watcher event schedules a fresh generation rather than publishing an
    /// already queued old snapshot. Only successful latest results replace data.
    pub fn drain(self: *State, gpa: std.mem.Allocator) !bool {
        _ = gpa; // Content stays in the globally budgeted C-owned snapshot.
        const source = if (self.loader) |*value| value else return false;
        var result = (try source.drain()) orelse return false;
        defer result.deinit();
        if (result.raw.changed != 0) {
            try self.refresh();
            return true;
        }
        if (result.raw.generation != self.generation) return true;
        const status = std.enums.fromInt(Status, result.raw.status) orelse return error.InvalidPreviewSnapshot;
        const kind = std.enums.fromInt(Kind, result.raw.kind) orelse return error.InvalidPreviewSnapshot;
        self.watch_available = result.raw.watch_available != 0;
        if (status == .ready or status == .watch_error) {
            if (result.raw.length > loader.max_image_bytes or result.raw.lines > loader.max_lines) return error.InvalidPreviewSnapshot;
            const pointer = result.raw.bytes orelse return error.InvalidPreviewSnapshot;
            if (self.owned) |*owned| owned.deinit();
            if (self.prepared) |prepared| prepared.deinit();
            self.bytes = pointer[0..result.raw.length];
            self.prepared = result.takePrepared();
            self.kind = kind;
            self.width = result.raw.width;
            self.height = result.raw.height;
            self.lines = result.raw.lines;
            self.owned = result;
            @memset(std.mem.asBytes(&result.raw), 0);
            self.revision +|= 1;
            self.stale = false;
        } else self.stale = self.owned != null;
        self.status = status;
        return true;
    }
    pub fn takePrepared(self: *State) ?Prepared {
        const result = self.prepared;
        self.prepared = null;
        return result;
    }
    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        _ = gpa;
        if (self.loader) |*source| source.deinit();
        if (self.owned) |*owned| owned.deinit();
        if (self.prepared) |prepared| prepared.deinit();
        const id = self.id;
        const generation = self.generation +| 1;
        const revision = self.revision;
        const hooks = self.hooks;
        self.* = .{ .id = id, .generation = generation, .revision = revision, .hooks = hooks };
    }
};
fn next(generation: u64) !u64 {
    if (generation == std.math.maxInt(u64)) return error.PreviewGenerationExhausted;
    return generation + 1;
}
test "closed preview preserves host identity and monotonically revokes generations" {
    var state: State = .{ .id = 73, .generation = 9, .revision = 4 };
    state.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 73), state.id);
    try std.testing.expectEqual(@as(u64, 10), state.generation);
    try std.testing.expectEqual(@as(u64, 4), state.revision);
    try std.testing.expect(state.status == .closed and state.fd() == null and !try state.drain(std.testing.allocator));
    try std.testing.expectError(error.PreviewClosed, state.refresh());
}
test "owned preview model retains a successful snapshot across reload failure" {
    const c = struct {
        extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
        extern "c" fn rmdir([*:0]const u8) c_int;
        extern "c" fn realpath([*:0]const u8, [*]u8) ?[*:0]u8;
        extern "c" fn fopen([*:0]const u8, [*:0]const u8) ?*anyopaque;
        extern "c" fn fwrite([*]const u8, usize, usize, *anyopaque) usize;
        extern "c" fn fclose(*anyopaque) c_int;
        extern "c" fn unlink([*:0]const u8) c_int;
        extern "c" fn usleep(c_uint) c_int;
    };
    const gpa = std.testing.allocator;
    var template: [48:0]u8 = @splat(0);
    const text = "/tmp/letty-preview-model-XXXXXX";
    @memcpy(template[0..text.len], text);
    const directory = c.mkdtemp(&template);
    try std.testing.expect(directory != null);
    defer _ = c.rmdir(directory.?);
    var canonical: [4096]u8 = undefined;
    try std.testing.expect(c.realpath(directory.?, &canonical) != null);
    const path = try std.fmt.allocPrintSentinel(gpa, "{s}/owned.md", .{std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&canonical)), 0)}, 0);
    defer gpa.free(path);
    const file = c.fopen(path.ptr, "wb") orelse return error.PreviewFixtureOpen;
    try std.testing.expectEqual(@as(usize, 7), c.fwrite("owned\r\n", 1, 7, file));
    _ = c.fclose(file);
    var state: State = .{ .id = 44 };
    defer state.deinit(gpa);
    try state.open(gpa, path);
    for (0..400) |_| {
        while (try state.drain(gpa)) {}
        if (state.status != .loading) break;
        _ = c.usleep(10000);
    }
    try std.testing.expectEqual(Status.ready, state.status);
    try std.testing.expectEqualStrings("owned\n", state.bytes);
    const pointer = state.bytes.ptr;
    const revision = state.revision;
    try std.testing.expectError(error.InvalidPreviewPath, state.open(gpa, "https://invalid/doc.md"));
    try std.testing.expect(state.bytes.ptr == pointer and state.status == .ready);
    try std.testing.expect(c.unlink(path.ptr) == 0);
    try state.refresh();
    for (0..400) |_| {
        while (try state.drain(gpa)) {}
        if (state.status != .loading) break;
        _ = c.usleep(10000);
    }
    try std.testing.expectEqual(Status.missing, state.status);
    try std.testing.expect(state.stale and state.bytes.ptr == pointer and state.revision == revision);
    try std.testing.expectEqualStrings("owned\n", state.bytes);
}
