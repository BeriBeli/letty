//! Runs inside the file worker; only immutable input and page-owned CPU data.
const std = @import("std");
const loader = @import("loader.zig");
const model = @import("model.zig");
const panel = @import("panel.zig");
pub const hooks: loader.Hooks = .{ .prepare = prepare, .release = release };
fn prepare(_: ?*anyopaque, path: [*:0]const u8, bytes: [*]const u8, length: usize, raw_kind: c_int, out: *?*anyopaque) callconv(.c) c_int {
    out.* = null;
    const kind = std.enums.fromInt(model.Kind, raw_kind) orelse return @backingInt(model.Status.unsupported);
    const gpa = std.heap.page_allocator;
    const value = gpa.create(panel.Prepared) catch return @backingInt(model.Status.io_error);
    value.* = panel.Prepared.initWithPath(gpa, kind, bytes[0..length], std.mem.span(path)) catch |err| {
        gpa.destroy(value);
        return failure(err);
    };
    if (value.prepare_error) |err| {
        value.deinit();
        gpa.destroy(value);
        return failure(err);
    }
    out.* = value;
    return @backingInt(model.Status.ready);
}
fn release(_: ?*anyopaque, raw: *anyopaque) callconv(.c) void {
    const value: *panel.Prepared = @ptrCast(@alignCast(raw));
    value.deinit();
    std.heap.page_allocator.destroy(value);
}
pub fn take(owned: loader.Prepared) panel.Prepared {
    const value: *panel.Prepared = @ptrCast(@alignCast(owned.value));
    const result = value.*;
    std.heap.page_allocator.destroy(value);
    return result;
}

fn failure(err: anyerror) c_int {
    return @backingInt(switch (err) {
        error.TooLarge, error.DocumentTooLarge, error.PreviewMarkdownLimit, error.PreviewTextLimit, error.PreviewLineLimit, error.PreviewLongLineLimit, error.PreviewImageLimit => model.Status.too_large,
        error.Unsupported, error.NotPng => model.Status.unsupported,
        error.Corrupt => model.Status.invalid_image,
        else => model.Status.io_error,
    });
}
