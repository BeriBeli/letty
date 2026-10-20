//! UI-thread-only adapter. Initialize in its final address before attach(); IDs
//! must never be recycled during a window's lifetime. Call detach() before the
//! owning window/view dies. No VT, configuration, frame or host pointers are kept.
//! publish() copies caller records; the OS callback only queues owned IDs. Call
//! dispatch() from the UI event loop, outside AppKit/ATK callbacks, then publish
//! the resulting UI state. This component does not enable application AX itself.
const std = @import("std");
pub const ax = @import("accessibility.zig");
pub const max_requests = 64;
pub const Target = struct {
    window: u64,
    session: u64 = 0,
    document: u64 = 0,
    document_generation: u64 = 0,
    tab: u64 = 0,
    pub fn eql(a: Target, b: Target) bool {
        return a.window == b.window and a.session == b.session and a.tab == b.tab and a.document == b.document and a.document_generation == b.document_generation;
    }
};
/// UTF-8 byte offsets within *visible* text. Caller supplies the viewport only,
/// never scrollback. There is deliberately no terminal/history reader here.
pub const VisibleText = struct {
    text: []const u8,
    caret: u32 = 0,
    selection_start: u32 = 0,
    selection_end: u32 = 0,
};
pub const Record = struct {
    node: ax.Input,
    target: Target,
    /// Mandatory for terminal nodes, forbidden for other roles. Terminal value
    /// must be empty, making accidentally passing a separate history value fail.
    visible_text: ?VisibleText = null,
};
pub const Request = struct { node: u64, target: Target, action: ax.Action };
const Route = struct { node: u64, target: Target };
const NativeHandle = struct {
    bridge: *ax.Native,
    update: *const fn (*ax.Native, *const ax.Snapshot, u32) bool,
    detach: *const fn (*ax.Native) void,
};
pub const Adapter = struct {
    window: u64,
    wake: ?struct { context: *anyopaque, call: *const fn (*anyopaque) void } = null,
    snapshot: ax.Snapshot = .{},
    routes: [ax.max_nodes]Route = undefined,
    route_count: usize = 0,
    requests: [max_requests]Request = undefined,
    request_count: usize = 0,
    native: ?NativeHandle = null,
    alive: bool = true,
    publishing: bool = false,
    callback_active: bool = false,
    dispatching: bool = false,

    pub fn init(window: u64) !Adapter {
        if (window == 0) return error.InvalidWindowId;
        return .{ .window = window };
    }
    pub fn attach(self: *Adapter, view: *anyopaque) !void {
        if (!self.alive) return error.AccessibilityDetached;
        if (self.native != null) return error.AccessibilityAlreadyAttached;
        if (self.publishing or self.callback_active or self.dispatching) return error.AccessibilityReentrant;
        const bridge = ax.lt_ax_attach(view, callback, self) orelse return error.AccessibilityUnavailable;
        errdefer ax.lt_ax_detach(bridge);
        if (self.snapshot.count != 0 and !nativeUpdate(bridge, &self.snapshot, ax.Notify.tree | ax.Notify.focus | ax.Notify.value | ax.Notify.state)) return error.AccessibilityBackendFailed;
        self.native = .{ .bridge = bridge, .update = nativeUpdate, .detach = nativeDetach };
    }
    /// Permanent teardown. Already retained OS elements are retired by the native
    /// bridge and cannot call this adapter again. Repeated detach is harmless.
    pub fn detach(self: *Adapter) void {
        self.alive = false;
        self.wake = null;
        self.request_count = 0;
        if (self.native) |native| {
            self.native = null;
            native.detach(native.bridge);
        }
        self.snapshot = .{};
        self.route_count = 0;
    }
    /// Transactional: validation/native failure keeps the prior owned tree and
    /// route table. A queued request is revalidated at dispatch, not silently
    /// retargeted when a tab/session moves or a modal dialog appears.
    pub fn publish(self: *Adapter, records: []const Record) !ax.Change {
        if (!self.alive) return error.AccessibilityDetached;
        if (self.publishing or self.callback_active or self.dispatching) return error.AccessibilityReentrant;
        if (records.len == 0 or records.len > ax.max_nodes) return error.AccessibilityNodeLimit;
        self.publishing = true;
        defer self.publishing = false;
        var next = ax.Snapshot{};
        var routes: [ax.max_nodes]Route = undefined;
        for (records, 0..) |record, i| {
            if (record.target.window != self.window) return error.AccessibilityWrongWindow;
            var node = record.node;
            if (node.role == .terminal) {
                const text = record.visible_text orelse return error.AccessibilityVisibleTextRequired;
                if (node.value.len != 0 or record.target.session == 0 or record.target.tab == 0) return error.InvalidAccessibilityTerminal;
                if (text.selection_start > text.selection_end or !boundary(text.text, text.caret) or !boundary(text.text, text.selection_start) or !boundary(text.text, text.selection_end)) return error.InvalidAccessibilityRange;
                const prefix = try ax.visiblePrefix(text.text);
                node.value = prefix.text;
                node.state |= ax.State.read_only;
                if (prefix.truncated) node.state |= ax.State.truncated;
                node.caret = @intCast(@min(text.caret, prefix.text.len));
                node.selection_start = @intCast(@min(text.selection_start, prefix.text.len));
                node.selection_end = @intCast(@min(text.selection_end, prefix.text.len));
            } else if (record.visible_text != null) return error.InvalidAccessibilityTerminal;
            try next.add(node);
            routes[i] = .{ .node = node.id, .target = record.target };
        }
        const focus = next.focused();
        if (focus != 0 and !interactable(&next, focus)) return error.InvalidAccessibilityFocus;
        const change = next.changes(&self.snapshot);
        var flags: u32 = 0;
        if (change.tree or change.geometry) flags |= ax.Notify.tree;
        if (change.focus) flags |= ax.Notify.focus;
        if (change.value) flags |= ax.Notify.value;
        if (change.state) flags |= ax.Notify.state;
        if (self.native) |native| if (!native.update(native.bridge, &next, flags)) return error.AccessibilityBackendFailed;
        self.snapshot = next;
        @memcpy(self.routes[0..records.len], routes[0..records.len]);
        self.route_count = records.len;
        return change;
    }
    /// Useful to OS and test adapters alike: acceptance only means queued, not
    /// performed. The bounded queue rejects overflow and all reentrant requests.
    pub fn enqueue(self: *Adapter, id: u64, action: ax.Action) bool {
        if (!self.alive or self.publishing or self.callback_active or self.dispatching or self.request_count == max_requests) return false;
        self.callback_active = true;
        defer self.callback_active = false;
        if (!self.snapshot.canInvoke(id, action) or !interactable(&self.snapshot, id)) return false;
        const target_route = self.route(id) orelse return false;
        self.requests[self.request_count] = .{ .node = id, .target = target_route.target, .action = action };
        self.request_count += 1;
        if (self.wake) |wake| wake.call(wake.context); // schedule only; never dispatch here
        return true;
    }
    /// host.accessibilityAlive(Target) bool must validate current live window,
    /// session and tab membership. host.accessibilityDispatch(Request)!void is
    /// called only here, outside callbacks. Closed/stale requests are discarded.
    /// Reentrant dispatch/publish/enqueue is refused; the failed dispatched item
    /// is consumed, remaining items stay queued for the next event-loop turn.
    pub fn dispatch(self: *Adapter, host: anytype) !usize {
        if (!self.alive) return error.AccessibilityDetached;
        if (self.callback_active or self.publishing or self.dispatching) return error.AccessibilityReentrant;
        self.dispatching = true;
        defer self.dispatching = false;
        var performed: usize = 0;
        while (self.alive and self.request_count > 0) {
            const request = self.requests[0];
            self.request_count -= 1;
            std.mem.copyForwards(Request, self.requests[0..self.request_count], self.requests[1..][0..self.request_count]);
            const current = self.route(request.node) orelse continue;
            if (!current.target.eql(request.target) or !self.snapshot.canInvoke(request.node, request.action) or !interactable(&self.snapshot, request.node)) continue;
            if (!host.accessibilityAlive(request.target)) continue;
            // Resolve may synchronously close the owner; never dispatch then.
            if (!self.alive) break;
            try host.accessibilityDispatch(request);
            performed += 1;
        }
        return performed;
    }
    fn route(self: *const Adapter, id: u64) ?Route {
        for (self.routes[0..self.route_count]) |item| if (item.node == id) return item;
        return null;
    }
    fn callback(context: ?*anyopaque, id: u64, raw: u32) callconv(.c) c_int {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return 0));
        const action = std.enums.fromInt(ax.Action, raw) orelse return 0;
        return @intFromBool(self.enqueue(id, action));
    }
    fn nativeUpdate(bridge: *ax.Native, snapshot: *const ax.Snapshot, flags: u32) bool {
        var storage: [ax.max_nodes]ax.WireNode = undefined;
        const wire = snapshot.wire(&storage);
        return ax.lt_ax_update(bridge, wire.ptr, wire.len, flags) == 0;
    }
    fn nativeDetach(bridge: *ax.Native) void {
        ax.lt_ax_detach(bridge);
    }
};
fn boundary(text: []const u8, at: u32) bool {
    return at <= text.len and (at == text.len or text[at] & 0xc0 != 0x80);
}
fn interactable(snapshot: *const ax.Snapshot, id: u64) bool {
    var modal: u64 = 0;
    for (snapshot.nodes[0..snapshot.count]) |node| if (node.state & (ax.State.visible | ax.State.modal) == (ax.State.visible | ax.State.modal)) {
        modal = node.id;
    };
    if (modal != 0 and !snapshot.descendant(id, modal)) return false;
    var next = id;
    while (next != 0) {
        const node = snapshot.find(next) orelse return false;
        if (node.state & (ax.State.enabled | ax.State.visible) != (ax.State.enabled | ax.State.visible)) return false;
        next = node.parent;
    }
    return true;
}
test {
    _ = @import("application_accessibility_test.zig");
}
