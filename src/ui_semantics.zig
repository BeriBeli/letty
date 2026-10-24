//! Frame geometry annotations for application controls, independent of AX/OS.
//! Labels/values/commands are bounded owned data. Widget IDs are captured at
//! construction and resolved only after final layout; no Context is retained.
const std = @import("std");
const ui = @import("nanoui").ui;
const actions = @import("actions.zig");
const Text = @import("fixed_text.zig").Text;
pub const Control = enum(u32) { panel, body, query, cancel, accept, copy, command };
pub const SmallArgs = union(enum) { none, amount: f32, index: usize, direction: actions.Direction, offset: isize, resize: struct { direction: actions.Direction, pixels: u16 } };
pub const Command = struct {
    action: actions.Action,
    target_tab: u64 = 0,
    args: SmallArgs = .none,
    pub fn from(r: actions.Request) ?Command {
        return .{
            .action = r.action,
            .args = switch (r.args) {
                .none => .none,
                .amount => |v| .{ .amount = v },
                .index => |v| .{ .index = v },
                .direction => |v| .{ .direction = v },
                .offset => |v| .{ .offset = v },
                .resize => |v| .{ .resize = .{ .direction = v.direction, .pixels = v.pixels } },
                .bytes => return null, // palettes/menus have no user byte actions
            },
        };
    }
    pub fn request(c: Command) actions.Request {
        return .{ .action = c.action, .args = switch (c.args) {
            .none => .none,
            .amount => |v| .{ .amount = v },
            .index => |v| .{ .index = v },
            .direction => |v| .{ .direction = v },
            .offset => |v| .{ .offset = v },
            .resize => |v| .{ .resize = .{ .direction = v.direction, .pixels = v.pixels } },
        } };
    }
};
pub const Entry = struct {
    widget: u64,
    control: Control,
    ordinal: u32 = 0,
    label: Text(256) = .{},
    value: Text(1024) = .{},
    enabled: bool = true,
    selected: bool = false,
    truncated: bool = false,
    command: ?Command = null,
};
pub const Geometry = struct {
    entries: [24]Entry = undefined,
    count: usize = 0,
    generation: u64 = 0,
    frame: u64 = 0,
    overflow: bool = false,
    pub fn begin(g: *Geometry, generation: u64, frame: u64) void {
        g.count = 0;
        g.generation = generation;
        g.frame = frame;
        g.overflow = false;
    }
    pub fn add(g: *Geometry, ctx: *ui.Context, control: Control, ordinal: u32, label: []const u8, value: []const u8, enabled: bool, selected: bool, command: ?Command) void {
        if (g.count == g.entries.len) {
            g.overflow = true;
            return;
        }
        var e: Entry = .{ .widget = ctx.peekId(null), .control = control, .ordinal = ordinal, .enabled = enabled, .selected = selected, .command = command };
        e.label.set(label);
        e.value.set(value);
        e.truncated = label.len > e.label.buf.len or value.len > e.value.buf.len;
        g.entries[g.count] = e;
        g.count += 1;
    }
    pub fn find(g: *const Geometry, control: Control, ordinal: u32) ?*const Entry {
        for (g.entries[0..g.count]) |*entry| if (entry.control == control and entry.ordinal == ordinal) return entry;
        return null;
    }
};
pub fn advance(value: *u64) void {
    // Exhaustion is explicit, rather than recycling OS identities.
    value.* = std.math.add(u64, value.*, 1) catch @panic("semantic generation exhausted");
}
