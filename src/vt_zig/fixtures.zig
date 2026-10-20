//! Additional native-only boundary fixtures; intentionally not imported by the
//! N1 shared baseline while its implementation is frozen. Root can wire run()
//! into an isolated native target after recording that baseline.
const std = @import("std");
const backend = @import("backend.zig");
const Sink = struct {
    bytes: [4096]u8 = undefined,
    len: usize = 0,
    calls: usize = 0,
    overflow: bool = false,
    reenter: ?*backend.Vt = null,
    fn receive(raw: ?*anyopaque, data: [*]const u8, len: usize) callconv(.c) void {
        const self: *Sink = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (len > self.bytes.len - self.len) self.overflow = true else {
            @memcpy(self.bytes[self.len..][0..len], data[0..len]);
            self.len += len;
        }
        if (self.reenter) |context| {
            self.reenter = null;
            backend.lt_vt_feed(context, "ILLEGAL", 7);
        }
    }
    fn reset(self: *Sink) void {
        self.len = 0;
        self.calls = 0;
    }
    fn text(self: *const Sink) []const u8 {
        return self.bytes[0..self.len];
    }
};
fn check(ok: bool, description: []const u8, total: *usize) !void {
    if (!ok) {
        std.debug.print("FAIL NATIVE BOUNDARY {s}\n", .{description});
        return error.NativeBoundaryFailure;
    }
    total.* += 1;
    std.debug.print("PASS NATIVE BOUNDARY {s}\n", .{description});
}
pub fn run(gpa: std.mem.Allocator, io: std.Io) !usize {
    var total: usize = 0;
    var replies = Sink{};
    const v = try backend.create(gpa, io, 10, 3, 200, 1024 * 1024, Sink.receive, &replies);
    defer backend.destroy(v);
    try check(v.stream.handler.core.terminal == &v.terminal, "stream owner address remains stable", &total);
    try check(backend.lt_vt_resize(v, 0, 3, 8, 18) != 0 and backend.lt_vt_resize(v, 65536, 3, 8, 18) != 0 and v.terminal.cols == 10 and v.terminal.rows == 3 and !backend.lt_vt_failed(v), "invalid grid rejected without mutation or fatal state", &total);
    const query = "\x1b[18t";
    backend.lt_vt_feed(v, query, query.len);
    try check(replies.calls == 1 and std.mem.eql(u8, replies.text(), "\x1b[8;3;10t"), "native geometry effect answers exactly once", &total);
    const mode = "\x1b[?2048h";
    backend.lt_vt_feed(v, mode, mode.len);
    replies.reset();
    try check(backend.lt_vt_resize(v, 20, 4, 9, 19) == 0 and replies.calls == 1 and std.mem.eql(u8, replies.text(), "\x1b[48;4;20;76;180t"), "in-band resize reports exact new grid and pixels once", &total);
    var long: [5000]u8 = @splat('x');
    @memcpy(long[4095..][0..4], "🙂");
    v.copyMetadata(.title, &long);
    try check(v.title.len == 4095 and v.title_truncated and std.unicode.utf8ValidateSlice(v.title.text()) and !backend.lt_vt_failed(v), "long title truncates on UTF8 boundary without killing VT", &total);
    v.copyMetadata(.pwd, &long);
    var pwd: [4096]u8 = undefined;
    try check(v.pwd_overflow and backend.lt_vt_pwd(v, &pwd, pwd.len) == 0 and v.pwd.len == 0 and !backend.lt_vt_failed(v), "oversized PWD is rejected rather than turned into a false valid path", &total);
    v.copyMetadata(.pwd, "file://localhost/private/tmp");
    const pwd_len = backend.lt_vt_pwd(v, &pwd, pwd.len);
    try check(!v.pwd_overflow and std.mem.eql(u8, pwd[0..pwd_len], "file://localhost/private/tmp") and pwd[pwd_len] == 0, "a later valid PWD clears overflow and preserves sentinel", &total);
    var output: [256]u8 = undefined;
    var written: usize = 0;
    try check(backend.lt_vt_key(v, 0x104, 0, "", 0, &output, 1, &written) == -3 and written == 3 and !backend.lt_vt_failed(v), "short key buffer reports complete required length without fatal VT", &total);
    const mouse_mode = "\x1b[?1000h\x1b[?1006h";
    backend.lt_vt_feed(v, mouse_mode, mouse_mode.len);
    try check(backend.lt_vt_mouse_tracking(v) and backend.lt_vt_mouse(v, 0, 1, 0, 2, 1, &output, output.len, &written) == 0 and std.mem.eql(u8, output[0..written], "\x1b[<0;3;2M"), "native SGR mouse uses terminal reporting modes and cell geometry", &total);
    var unsafe = [_]u8{ 'A', 0x1b, 'B' };
    try check(backend.lt_vt_paste(&unsafe, unsafe.len, true, &output, 1, &written) == -3 and written == 15 and unsafe[1] == ' ', "short paste buffer reports framed length and normalizes controls", &total);
    var separate = Sink{};
    const reentrant = try backend.create(gpa, io, 10, 3, 200, 1024 * 1024, Sink.receive, &separate);
    defer backend.destroy(reentrant);
    separate.reenter = reentrant;
    backend.lt_vt_feed(reentrant, "\x1b[6n", 4);
    const reentrant_error = backend.lt_vt_error(reentrant);
    try check(separate.calls == 1 and reentrant_error != null and reentrant_error.? == error.ReentrantVt and reentrant.terminal.screens.active.cursor.x == 0 and !reentrant.busy, "reentrant callback is rejected, visible and never feeds nested text", &total);
    const allocation = try parserAllocationStatus(gpa, io);
    try check(allocation.allocator_failed and allocation.host_failed, "OSC capture allocation failure becomes host-visible even if parser drops the sequence", &total);
    return total;
}

pub const ParserAllocationStatus = struct { allocator_failed: bool, semantic_failure: bool, host_failed: bool };
/// Allocating upstream OSC capture can swallow allocator failure without setting
/// semantic_failure. The heap audit must still expose that event to the host.
pub fn parserAllocationStatus(gpa: std.mem.Allocator, io: std.Io) !ParserAllocationStatus {
    var replies = Sink{};
    var fault = std.testing.FailingAllocator.init(gpa, .{});
    const context = try backend.create(fault.allocator(), io, 10, 3, 200, 1024 * 1024, Sink.receive, &replies);
    defer backend.destroy(context);
    var input: [20 * 1024]u8 = @splat('x');
    // OSC 52 selects allocating capture; OSC 2 titles use fixed capture and
    // would never exercise the allocation failure. Clipboard effects remain
    // readonly, so this fixture cannot touch the system clipboard.
    const prefix = "\x1b]52;c;";
    @memcpy(input[0..prefix.len], prefix);
    input[input.len - 1] = 7;
    fault.fail_index = fault.alloc_index;
    fault.resize_fail_index = fault.resize_index;
    backend.lt_vt_feed(context, &input, input.len);
    return .{ .allocator_failed = fault.has_induced_failure, .semantic_failure = context.stream.handler.core.semantic_failure, .host_failed = backend.lt_vt_failed(context) };
}

/// Separate M9 entry: existing boundary suite counts remain unchanged until
/// the host explicitly adds this actual Context/guarded-stream fixture target.
pub fn runGraphics(gpa: std.mem.Allocator, io: std.Io) !usize {
    const graphics = @import("graphics.zig");
    const types = @import("../vt_types.zig");
    const rgb = "\x1b_Ga=T,f=24,s=1,v=1,i=11,c=1,r=1,C=1;/wAA\x1b\\";
    const png = "\x1b_Ga=T,f=100,i=12,c=1,r=1,C=1;iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==\x1b\\";
    var total: usize = 0;
    var replies = Sink{};
    const v = try backend.create(gpa, io, 10, 3, 200, 1024 * 1024, Sink.receive, &replies);
    defer backend.destroy(v);
    var snapshot: graphics.Snapshot = .{};
    defer snapshot.deinit(gpa);
    const initial = graphics.info(v);
    try check(!initial.enabled and initial.core_limit + initial.graphics_limit == 208 * 1024 * 1024 and initial.rejections == 0, "M9 defaults disabled with legal-max fixed engine quota", &total);
    try check(backend.lt_vt_settings(v, 0, true, 200, 128 * 1024 * 1024 + 1) != 0 and !backend.lt_vt_failed(v), "M9 invalid history reload cannot weaken quota or kill VT", &total);
    try graphics.configure(v, true);
    if (backend.lt_vt_resize(v, 10, 3, 8, 18) != 0) return error.GraphicsFixtureSize;
    const enabled_epoch = graphics.info(v).epoch;
    try graphics.configure(v, true);
    try check(graphics.info(v).enabled and graphics.info(v).epoch == enabled_epoch, "M9 enable is idempotent", &total);
    backend.lt_vt_feed(v, rgb, rgb.len);
    try graphics.capture(v, gpa, &snapshot);
    std.debug.print("GRAPHICS SNAPSHOT images={d} placements={d} bytes={d} skipped={d}/{d} supported={any} quota={any} replies={s}\n", .{ snapshot.image_count, snapshot.placement_count, snapshot.owned_bytes, snapshot.skipped_images, snapshot.skipped_placements, snapshot.supported, graphics.info(v), replies.text() });
    try check(snapshot.image_count == 1 and snapshot.placement_count == 1 and snapshot.owned_bytes == 4 and std.mem.eql(u8, snapshot.images[0].rgba, &.{ 255, 0, 0, 255 }), "M9 real RGB captures bounded owned pixels", &total);
    backend.lt_vt_feed(v, "A", 1);
    try check(std.mem.eql(u8, snapshot.images[0].rgba, &.{ 255, 0, 0, 255 }), "M9 owned snapshot survives subsequent feed", &total);
    var cursor: types.Cursor = .{};
    try check(backend.lt_vt_frame(v, &cursor) == 0, "M9 text frame opens after owned capture", &total);
    var refused = false;
    graphics.capture(v, gpa, &snapshot) catch |err| {
        refused = err == error.GraphicsCaptureDuringFrame;
    };
    try check(refused and v.frame_open and snapshot.image_count == 0 and !backend.lt_vt_failed(v), "M9 capture refuses an open text borrow without killing VT", &total);
    backend.lt_vt_frame_end(v);
    backend.lt_vt_reset(v);
    try check(graphics.info(v).epoch != enabled_epoch and graphics.info(v).enabled, "M9 RIS changes renderer identity and preserves enabled policy", &total);
    backend.lt_vt_feed(v, rgb, rgb.len);
    try graphics.capture(v, gpa, &snapshot);
    try graphics.configure(v, false);
    try graphics.capture(v, gpa, &snapshot);
    try check(snapshot.image_count == 0 and snapshot.placement_count == 0 and graphics.info(v).storage_used_bytes == 0, "M9 disable clears resident images and the old owned snapshot", &total);

    // Test-only lower graphics allowance: production create always uses48MiB
    // and settings never reconfigures that fixed engine allocator identity.
    var limits = v.quota.limits;
    limits.graphics_bytes = 64 * 1024;
    try v.quota.reconfigure(limits);
    try graphics.configure(v, true);
    const audit_epoch = v.allocation_audit.failure_epoch;
    backend.lt_vt_feed(v, png, png.len);
    const rejected = graphics.info(v).rejections;
    _ = v.status();
    _ = v.status();
    try check(rejected > 0 and graphics.info(v).rejections == rejected and !backend.lt_vt_failed(v) and v.allocation_audit.failure_epoch == audit_epoch, "M9 real PNG scratch rejection is soft and status readback never double counts", &total);
    replies.reset();
    const text_query = "\x1b[HOK\x1b[6n";
    backend.lt_vt_feed(v, text_query, text_query.len);
    try check(!backend.lt_vt_failed(v) and std.mem.indexOf(u8, replies.text(), "\x1b[1;3R") != null and graphics.info(v).rejections == rejected, "M9 ordinary text and PTY DSR survive graphics rejection", &total);
    backend.lt_vt_feed(v, rgb, rgb.len);
    var fault = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var oom = false;
    graphics.capture(v, fault.allocator(), &snapshot) catch |err| {
        oom = err == error.OutOfMemory;
    };
    try check(oom and backend.lt_vt_failed(v) and backend.lt_vt_error(v).? == error.OutOfMemory and snapshot.image_count == 0, "M9 actual snapshot allocator OOM is fatal and leaves no partial snapshot", &total);

    var child = std.testing.FailingAllocator.init(gpa, .{});
    const simultaneous = try backend.create(child.allocator(), io, 10, 3, 200, 1024 * 1024, Sink.receive, &replies);
    defer backend.destroy(simultaneous);
    try graphics.configure(simultaneous, true);
    if (!simultaneous.enter()) return error.UnexpectedContextFailure;
    // Seed a genuine APC admission denial, then a real parser allocation OOM
    // within the same operation. The hard failure must take priority.
    const scope = simultaneous.quota.enterApc();
    if (simultaneous.gpa.alloc(u8, 64 * 1024 * 1024)) |unexpected| {
        simultaneous.gpa.free(unexpected);
        return error.ExpectedGraphicsRejection;
    } else |_| {}
    scope.deinit();
    child.fail_index = child.alloc_index;
    child.resize_fail_index = child.resize_index;
    simultaneous.stream.nextSlice(png);
    simultaneous.leave();
    try check(backend.lt_vt_failed(simultaneous) and backend.lt_vt_error(simultaneous).? == error.OutOfMemory and simultaneous.graphics_rejections > 0 and simultaneous.allocation_audit.failure_epoch > 0, "M9 true host OOM wins over same-operation soft rejection", &total);
    return total;
}
