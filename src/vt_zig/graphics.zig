//! Serialized graphics policy/capture boundary. UI receives owned scalars and
//! pixels only; no upstream storage, PageList Pin or parser borrow escapes.
const std = @import("std");
const native = @import("../vt_native_graphics.zig");
const guarded = @import("../vt_native_graphics/guarded_stream.zig");
const Context = @import("context.zig").Context;
pub const Snapshot = native.Snapshot;
pub const Info = struct {
    enabled: bool,
    compiled: bool,
    rejections: u64,
    /// Pass to renderer State.epoch. RIS/config switches invalidate old keys.
    epoch: u64,
    storage_bytes_per_screen: usize,
    storage_used_bytes: usize,
    snapshot_bytes: usize,
    core_limit: usize,
    graphics_limit: usize,
    core_used: usize,
    graphics_used: usize,
};

// Context creation and all VT operations are on the host's serialized UI
// thread. Initialize the process-global decoder before constructing a terminal;
// repeated Context creation does not replace an installed hook or allocate.
var png_installed = false;
pub fn installPngDecoder() void {
    if (png_installed) return;
    native.installPngDecoder();
    png_installed = true;
}

pub fn configure(v: *Context, enabled: bool) !void {
    if (!v.enter()) return v.fatal orelse error.VtUnavailable;
    defer v.leave();
    if (v.graphics_enabled == enabled) return;
    // No allocator swap. Disabled releases both screens and an incomplete APC,
    // and ignores its tail until the next official APC start action.
    try guarded.configure(&v.stream, enabled);
    if (v.status() != 0) return v.fatal orelse error.VtUnavailable;
    v.graphics_enabled = enabled;
    v.graphics_epoch +%= 1;
    v.changed();
}

/// out must be initialized (.{}), and all its prior payloads must have been
/// allocated with the SAME gpa. Caller owns deinit(gpa), independently of VT.
/// Capture BEFORE opening a text frame; it refuses to invalidate that borrow.
/// Every failure and disabled capture leaves out empty. The bounded native
/// copy explicitly reports skipped images/placements, never hides host OOM.
pub fn capture(v: *Context, gpa: std.mem.Allocator, out: *Snapshot) !void {
    out.deinit(gpa);
    if (v.frame_open) return error.GraphicsCaptureDuringFrame;
    if (!v.enter()) return v.fatal orelse error.VtUnavailable;
    defer v.leave();
    if (!v.graphics_enabled) return;
    out.* = native.take(gpa, &v.terminal) catch |err| {
        // Snapshot allocations use the caller's separate <=8MiB payload
        // allowance. Unlike soft terminal APC admission, actual copy OOM is
        // fatal and must be visible to the PTY/renderer host.
        if (err == error.OutOfMemory) v.fail(err);
        return err;
    };
    if (v.status() != 0) {
        out.deinit(gpa);
        return v.fatal orelse error.VtUnavailable;
    }
}

/// Scalar readback only. Host serializes this with configure/feed/capture;
/// counters are settled by status/leave, not consumed/reset by this read.
pub fn info(v: *const Context) Info {
    var stored: usize = 0;
    if (comptime native.compiled) {
        inline for (.{ .primary, .alternate }) |key| {
            if (v.terminal.screens.all.get(key)) |screen| stored +|= screen.kitty_images.total_bytes;
        }
    }
    return .{
        .enabled = v.graphics_enabled,
        .compiled = native.compiled,
        .rejections = v.graphics_rejections,
        .epoch = v.graphics_epoch,
        .storage_bytes_per_screen = native.storage_bytes,
        .storage_used_bytes = stored,
        .snapshot_bytes = native.snapshot_bytes,
        .core_limit = v.quota.limits.core_bytes,
        .graphics_limit = v.quota.limits.graphics_bytes,
        .core_used = v.quota.core_used,
        .graphics_used = v.quota.graphics_used,
    };
}
