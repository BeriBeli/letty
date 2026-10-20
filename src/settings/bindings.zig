//! Parser-safe recording; display accelerators may contain '=' or '>'.
const std = @import("std");
const keys = @import("../keybindings.zig");
const actions = @import("../actions.zig");
const catalogue = @import("../command_catalogue.zig");
pub fn chord(a: std.mem.Allocator, original: keys.Chord) ![]const u8 {
    return rawChord(a, original.native());
}
fn rawChord(a: std.mem.Allocator, original: keys.Chord) ![]const u8 {
    const key = original.native().key;
    const formatted = if (key == '=') try a.dupe(u8, "equal") else if (key == '>') try a.dupe(u8, "greater") else if (key == '<') try a.dupe(u8, "less") else try keys.formatAccelerator(a, .{ .key = key });
    defer a.free(formatted);
    return std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}", .{ if (original.cmd) "super+" else "", if (original.ctrl) "ctrl+" else "", if (original.alt) "alt+" else "", if (original.shift) "shift+" else "", formatted });
}
pub fn trigger(a: std.mem.Allocator, binding: keys.Binding) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    if (binding.flags.global) try out.writer.writeAll("global:");
    const sequence = binding.trigger();
    for (sequence.chords[0..sequence.len], 0..) |part, index| {
        if (index > 0) try out.writer.writeByte('>');
        const formatted = if (binding.flags.global) try rawChord(a, part) else try chord(a, part);
        defer a.free(formatted);
        try out.writer.writeAll(formatted);
    }
    return out.toOwnedSlice();
}
pub fn action(entry: catalogue.Entry) ?[]const u8 {
    const token = entry.keywords[0 .. std.mem.indexOfScalar(u8, entry.keywords, ' ') orelse entry.keywords.len];
    const parsed = actions.parse(token) catch return switch (entry.action) {
        .font_up => "increase_font_size:1",
        .font_down => "decrease_font_size:1",
        else => null,
    };
    return if (parsed.same(entry.request())) token else null;
}
pub fn request(request_: actions.Request) ?[]const u8 {
    for (catalogue.entries) |entry| if (entry.request().same(request_)) if (action(entry)) |spec| return spec;
    return switch (request_.action) {
        .palette => "toggle_command_palette",
        .ignore => "ignore",
        .unbind => "unbind",
        else => null,
    };
}
