//! Draft: bounded config candidate table, no native side effects.
const std = @import("std");
const keys = @import("keybindings.zig");
const service = @import("application_hotkeys.zig");
pub fn collect(a: std.mem.Allocator, bindings: []const keys.Binding) ![]service.Entry {
    var count: usize = 0;
    for (bindings, 0..) |*binding, i| {
        if (!binding.flags.global or !keys.effectiveOverride(bindings, i)) continue;
        try keys.validate(binding);
        if (binding.action != .unbind) count += 1;
    }
    if (count > service.max_bindings) return error.TooManyGlobalBindings;
    const entries = try a.alloc(service.Entry, count);
    errdefer a.free(entries);
    var at: usize = 0;
    for (bindings, 0..) |*binding, i| {
        if (!binding.flags.global or !keys.effectiveOverride(bindings, i) or binding.action == .unbind) continue;
        entries[at] = .{ .chord = keys.globalChord(binding.trigger().chords[0]), .request = binding.request() };
        try service.validateRequest(&entries[at].request);
        at += 1;
    }
    return entries;
}
