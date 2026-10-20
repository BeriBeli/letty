//! Owned, bounded accessibility snapshots. Hosts supply only visible terminal text,
//! never history, and queue OS actions by stable ID rather than executing VT work
//! inside accessibility callbacks. Geometry uses host-local logical points.
const std = @import("std");
pub const max_nodes = 128;
pub const max_bytes = 64 * 1024;
pub const max_label = 256;
pub const max_value = 16 * 1024;
pub const Role = enum(u32) { group, tab_group, tab, pane, search, dialog, button, menu, menu_item, scrollbar, terminal, label, document, text_field };
pub const State = struct {
    pub const enabled: u32 = 1;
    pub const focusable: u32 = 2;
    pub const focused: u32 = 4;
    pub const selected: u32 = 8;
    pub const expanded: u32 = 16;
    pub const visible: u32 = 32;
    pub const checked: u32 = 64;
    pub const read_only: u32 = 128;
    pub const modal: u32 = 256;
    pub const truncated: u32 = 512;
};
pub const Action = enum(u32) { press = 1, focus = 2, increment = 4, decrement = 8, copy = 16, dismiss = 32 };
pub const Bounds = extern struct { x: f32 = 0, y: f32 = 0, width: f32 = 0, height: f32 = 0 };
pub const Input = struct {
    id: u64,
    parent: u64 = 0,
    role: Role = .group,
    state: u32 = State.enabled | State.visible,
    actions: u32 = 0,
    bounds: Bounds = .{},
    label: []const u8 = "",
    value: []const u8 = "",
    /// UTF-8 BYTE offsets. Native adapters convert to UTF-16 (macOS) or scalar
    /// offsets (ATK), so CJK/emoji never confuse bytes with OS character offsets.
    caret: u32 = 0,
    selection_start: u32 = 0,
    selection_end: u32 = 0,
};
pub const Node = struct {
    id: u64,
    parent: u64,
    role: Role,
    state: u32,
    actions: u32,
    bounds: Bounds,
    label_start: u32,
    label_len: u32,
    value_start: u32,
    value_len: u32,
    caret: u32,
    selection_start: u32,
    selection_end: u32,
};
pub const WireNode = extern struct {
    id: u64,
    parent: u64,
    role: u32,
    state: u32,
    actions: u32,
    bounds: Bounds,
    label: [*]const u8,
    label_len: usize,
    value: [*]const u8,
    value_len: usize,
    caret: u32,
    selection_start: u32,
    selection_end: u32,
};
pub const Notify = struct {
    pub const tree: u32 = 1;
    pub const focus: u32 = 2;
    pub const value: u32 = 4;
    pub const state: u32 = 8;
};
pub const Change = struct { tree: bool = false, focus: bool = false, value: bool = false, geometry: bool = false, state: bool = false };
pub const Snapshot = struct {
    nodes: [max_nodes]Node = undefined,
    count: usize = 0,
    bytes: [max_bytes]u8 = undefined,
    used: usize = 0,
    pub fn add(self: *Snapshot, input: Input) !void {
        if (self.count == max_nodes) return error.AccessibilityNodeLimit;
        if (input.id == 0 or self.find(input.id) != null) return error.InvalidAccessibilityId;
        if ((self.count == 0) != (input.parent == 0)) return error.InvalidAccessibilityRoot;
        if (input.parent != 0 and self.find(input.parent) == null) return error.InvalidAccessibilityParent;
        var depth: usize = 0;
        var parent = input.parent;
        while (parent != 0) {
            depth += 1;
            if (depth >= 16) return error.AccessibilityDepth;
            parent = self.find(parent).?.parent;
        }
        for ([_]f32{ input.bounds.x, input.bounds.y, input.bounds.width, input.bounds.height }) |v| if (!std.math.isFinite(v)) return error.InvalidAccessibilityBounds;
        if (input.bounds.width < 0 or input.bounds.height < 0) return error.InvalidAccessibilityBounds;
        if (input.label.len > max_label or input.value.len > max_value) return error.AccessibilityTextLimit;
        for ([_][]const u8{ input.label, input.value }) |text| {
            if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidAccessibilityText;
        }
        if (input.selection_start > input.selection_end or !boundary(input.value, input.caret) or !boundary(input.value, input.selection_start) or !boundary(input.value, input.selection_end)) return error.InvalidAccessibilityRange;
        if (input.state & State.focused != 0) {
            if (input.state & (State.focusable | State.enabled | State.visible) != (State.focusable | State.enabled | State.visible) or self.focused() != 0) return error.InvalidAccessibilityFocus;
        }
        if (input.actions & ~@as(u32, 63) != 0) return error.InvalidAccessibilityAction;
        const needed = input.label.len + input.value.len + 2;
        if (needed > self.bytes.len - self.used) return error.AccessibilityByteLimit;
        const label_start = self.used;
        self.copy(input.label);
        const value_start = self.used;
        self.copy(input.value);
        self.nodes[self.count] = .{ .id = input.id, .parent = input.parent, .role = input.role, .state = input.state, .actions = input.actions, .bounds = input.bounds, .label_start = @intCast(label_start), .label_len = @intCast(input.label.len), .value_start = @intCast(value_start), .value_len = @intCast(input.value.len), .caret = input.caret, .selection_start = input.selection_start, .selection_end = input.selection_end };
        self.count += 1;
    }
    fn copy(self: *Snapshot, text: []const u8) void {
        @memcpy(self.bytes[self.used..][0..text.len], text);
        self.used += text.len;
        self.bytes[self.used] = 0;
        self.used += 1;
    }
    pub fn find(self: *const Snapshot, id: u64) ?*const Node {
        for (self.nodes[0..self.count]) |*node| if (node.id == id) return node;
        return null;
    }
    pub fn label(self: *const Snapshot, node: Node) []const u8 {
        return self.bytes[node.label_start..][0..node.label_len];
    }
    pub fn value(self: *const Snapshot, node: Node) []const u8 {
        return self.bytes[node.value_start..][0..node.value_len];
    }
    pub fn focused(self: *const Snapshot) u64 {
        for (self.nodes[0..self.count]) |node| if (node.state & State.focused != 0) return node.id;
        return 0;
    }
    pub fn canInvoke(self: *const Snapshot, id: u64, action: Action) bool {
        const node = self.find(id) orelse return false;
        var ancestor: u64 = id;
        while (ancestor != 0) {
            const parent = self.find(ancestor) orelse return false;
            if (parent.state & (State.enabled | State.visible) != (State.enabled | State.visible)) return false;
            ancestor = parent.parent;
        }
        var modal: u64 = 0;
        for (self.nodes[0..self.count]) |candidate| {
            if (candidate.state & (State.modal | State.visible) == (State.modal | State.visible)) modal = candidate.id;
        }
        if (modal != 0 and !self.descendant(id, modal)) return false;
        return node.state & (State.enabled | State.visible) == (State.enabled | State.visible) and node.actions & @backingInt(action) != 0;
    }
    pub fn descendant(self: *const Snapshot, id: u64, ancestor: u64) bool {
        var next = id;
        while (next != 0) {
            if (next == ancestor) return true;
            next = (self.find(next) orelse return false).parent;
        }
        return false;
    }
    /// Keyboard traversal honors the innermost modal subtree. The host still
    /// decides when Tab belongs to a control versus the terminal application.
    pub fn nextFocusable(self: *const Snapshot, after: u64, reverse: bool) ?u64 {
        if (self.count == 0) return null;
        var modal: u64 = 0;
        var from: usize = if (reverse) 0 else self.count - 1;
        for (self.nodes[0..self.count], 0..) |node, i| {
            if (node.state & (State.modal | State.visible) == (State.modal | State.visible)) modal = node.id;
            if (node.id == after) from = i;
        }
        for (1..self.count + 1) |offset| {
            const index = if (reverse) (from + self.count - offset) % self.count else (from + offset) % self.count;
            const node = self.nodes[index];
            if (node.state & (State.enabled | State.visible | State.focusable) != (State.enabled | State.visible | State.focusable)) continue;
            var ancestor = node.parent;
            var available = true;
            while (ancestor != 0) {
                const parent = self.find(ancestor).?;
                if (parent.state & (State.enabled | State.visible) != (State.enabled | State.visible)) available = false;
                ancestor = parent.parent;
            }
            if (!available) continue;
            if (modal == 0 or self.descendant(node.id, modal)) return node.id;
        }
        return null;
    }
    pub fn wire(self: *const Snapshot, output: *[max_nodes]WireNode) []const WireNode {
        for (self.nodes[0..self.count], 0..) |node, i| output[i] = .{ .id = node.id, .parent = node.parent, .role = @backingInt(node.role), .state = node.state, .actions = node.actions, .bounds = node.bounds, .label = self.label(node).ptr, .label_len = node.label_len, .value = self.value(node).ptr, .value_len = node.value_len, .caret = node.caret, .selection_start = node.selection_start, .selection_end = node.selection_end };
        return output[0..self.count];
    }
    pub fn changes(self: *const Snapshot, old: *const Snapshot) Change {
        var result = Change{ .tree = self.count != old.count, .focus = self.focused() != old.focused() };
        for (self.nodes[0..self.count], 0..) |node, i| {
            const prior = old.find(node.id) orelse {
                result.tree = true;
                continue;
            };
            if (node.parent != prior.parent or node.role != prior.role or node.actions != prior.actions or (i < old.count and node.id != old.nodes[i].id) or !std.mem.eql(u8, self.label(node), old.label(prior.*))) result.tree = true;
            if (!std.mem.eql(u8, self.value(node), old.value(prior.*)) or node.caret != prior.caret or node.selection_start != prior.selection_start or node.selection_end != prior.selection_end) result.value = true;
            if (node.state != prior.state) result.state = true;
            if ((node.state ^ prior.state) & State.visible != 0) result.tree = true;
            if (node.bounds.x != prior.bounds.x or node.bounds.y != prior.bounds.y or node.bounds.width != prior.bounds.width or node.bounds.height != prior.bounds.height) result.geometry = true;
        }
        return result;
    }
};
fn boundary(text: []const u8, offset: u32) bool {
    return offset <= text.len and (offset == text.len or text[offset] & 0xc0 != 0x80);
}
pub fn visiblePrefix(text: []const u8) !struct { text: []const u8, truncated: bool } {
    if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidAccessibilityText;
    var n = @min(text.len, max_value);
    while (n < text.len and n > 0 and text[n] & 0xc0 == 0x80) n -= 1;
    return .{ .text = text[0..n], .truncated = n != text.len };
}
pub const Native = opaque {};
pub const Callback = *const fn (?*anyopaque, u64, u32) callconv(.c) c_int;
pub extern "c" fn lt_ax_attach(host: *anyopaque, callback: Callback, context: ?*anyopaque) ?*Native;
pub extern "c" fn lt_ax_update(*Native, [*]const WireNode, usize, u32) c_int;
pub extern "c" fn lt_ax_detach(*Native) void;
pub extern "c" fn lt_ax_capability() c_int;
test {
    _ = @import("accessibility_test.zig");
}
