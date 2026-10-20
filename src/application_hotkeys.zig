//! Host-owned global shortcuts. Keep Manager at a stable address from init to
//! deinit. Native callbacks only deliver an owned request to the host's queue;
//! they must not run application actions or retain the borrowed request pointer.
const std = @import("std");
const hotkey = @import("global_hotkey.zig");
const actions = @import("actions.zig");

pub const Chord = hotkey.Chord;
pub const max_bindings = hotkey.max_bindings;
pub const Entry = struct { chord: Chord, request: actions.Request };
pub const Deliver = *const fn (?*anyopaque, *const actions.Request) void;
pub const Error = hotkey.ReplaceError || error{ AlreadyInitialized, Reentrant, InvalidRequest };

pub const Manager = struct {
    registry: hotkey.Manager = .{},
    entries: [max_bindings]Entry = undefined,
    count: usize = 0,
    deliver: ?Deliver = null,
    context: ?*anyopaque = null,
    mutating: bool = false,
    delivering: bool = false,
    muted_events: usize = 0,
    staged_entries: [max_bindings]Entry = undefined,
    staged_count: usize = 0,
    prepared: bool = false,

    /// A disabled startup never opens a native backend, checks permissions or
    /// registers shortcuts. An enabled startup may fail and remains inert.
    pub fn nativeInit(self: *Manager, enabled: bool, deliver: Deliver, context: ?*anyopaque) Error!bool {
        if (self.mutating or self.delivering) return error.Reentrant;
        if (!enabled) return false;
        if (self.registry.adapter != null) return error.AlreadyInitialized;
        self.mutating = true;
        defer self.mutating = false;
        try self.registry.initNative(received, self);
        self.deliver = deliver;
        self.context = context;
        return true;
    }

    /// Tests and embedders supply a backend without loading native libraries.
    pub fn initAdapter(self: *Manager, adapter: hotkey.Adapter, deliver: Deliver, context: ?*anyopaque) Error!void {
        if (self.mutating or self.delivering) return error.Reentrant;
        if (self.registry.adapter != null) return error.AlreadyInitialized;
        self.registry = hotkey.Manager.init(adapter, received, self);
        self.deliver = deliver;
        self.context = context;
    }

    /// The registry commits first. Only a successful registration transaction
    /// publishes new owned Requests. Config arenas may be destroyed on return.
    /// A successful commit with cleanup_pending still publishes the new table;
    /// the native registry mutes every orphan until cleanup can be retried.
    pub fn replace(self: *Manager, entries: []const Entry) Error!hotkey.Commit {
        try self.prepare(entries);
        return self.commitPrepared();
    }
    /// Reserve OS chords and own every Request before a fallible config save.
    /// The old request table remains active until the no-failure commit below.
    pub fn prepare(self: *Manager, entries: []const Entry) Error!void {
        if (self.mutating or self.delivering) return error.Reentrant;
        if (self.prepared) return error.PreparationPending;
        if (entries.len > max_bindings) return error.Limit;
        var bindings: [max_bindings]hotkey.Binding = undefined;
        for (entries, 0..) |*entry, i| {
            try validateRequest(&entry.request);
            bindings[i] = .{ .id = @intCast(i + 1), .chord = entry.chord };
        }
        self.mutating = true;
        defer self.mutating = false;
        try self.registry.prepare(bindings[0..entries.len]);
        for (entries, 0..) |*entry, i| {
            self.staged_entries[i] = entry.*;
            self.staged_entries[i].chord = entry.chord.normalized();
        }
        self.staged_count = entries.len;
        self.prepared = true;
    }
    pub fn commitPrepared(self: *Manager) hotkey.Commit {
        std.debug.assert(self.prepared and !self.mutating and !self.delivering);
        self.mutating = true;
        defer self.mutating = false;
        const commit = self.registry.commitPrepared();
        @memcpy(self.entries[0..self.staged_count], self.staged_entries[0..self.staged_count]);
        self.count = self.staged_count;
        self.staged_count = 0;
        self.prepared = false;
        return commit;
    }
    pub fn rollbackPrepared(self: *Manager) void {
        std.debug.assert(!self.mutating and !self.delivering);
        self.mutating = true;
        defer self.mutating = false;
        self.registry.rollbackPrepared();
        self.staged_count = 0;
        self.prepared = false;
    }

    pub fn lastError(self: *const Manager) []const u8 {
        return self.registry.lastError();
    }

    /// Explicitly rejects destruction inside Deliver. The host must enqueue a
    /// deferred disable/quit action, then deinit outside the native callback.
    pub fn deinit(self: *Manager) error{Reentrant}!void {
        if (self.mutating or self.delivering) return error.Reentrant;
        self.mutating = true;
        defer self.mutating = false;
        self.registry.deinit();
        self.count = 0;
        self.staged_count = 0;
        self.prepared = false;
        self.deliver = null;
        self.context = null;
    }

    fn received(context: ?*anyopaque, id: u32) void {
        const self: *Manager = @ptrCast(@alignCast(context.?));
        // An adapter can synchronously dispatch while adding/removing a grab.
        // No half-published map or nested action escapes those transitions.
        if (self.mutating or self.delivering) {
            self.muted_events +|= 1;
            return;
        }
        if (id == 0 or id > self.count) return;
        const deliver = self.deliver orelse return;
        self.delivering = true;
        defer self.delivering = false;
        deliver(self.context, &self.entries[id - 1].request);
    }
};

/// Typed/JSON callers must satisfy the same argument constraints as text parse.
/// Defaults represented by .none remain valid and normalize during dispatch.
pub fn validateRequest(request: *const actions.Request) error{InvalidRequest}!void {
    if (request.action == .none or request.action == .unbind) return error.InvalidRequest;
    if (request.action == .send_bytes) {
        if (request.args != .bytes or request.args.bytes.len > @import("action_bytes.zig").capacity) return error.InvalidRequest;
        return;
    }
    if (request.args == .none) return;
    const valid = switch (request.action) {
        .font_up, .font_down => request.args == .amount and std.math.isFinite(request.args.amount) and request.args.amount > 0 and request.args.amount <= 32,
        .goto_tab => request.args == .index and request.args.index >= 1 and request.args.index <= 8,
        .focus_pane => request.args == .direction,
        .move_tab => request.args == .offset and request.args.offset != 0 and request.args.offset >= -7 and request.args.offset <= 7,
        .resize_pane => request.args == .resize and request.args.resize.pixels > 0 and request.args.resize.pixels <= 1000,
        else => false,
    };
    if (!valid) return error.InvalidRequest;
}
test {
    _ = @import("application_hotkeys_check.zig");
}
