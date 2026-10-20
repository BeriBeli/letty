//! Global shortcut ownership and transactional replacement. Native adapters are
//! opened only by initNative from the user's enabled application entry; tests
//! supply Fake and never open a display or register an OS shortcut.
const std = @import("std");
pub const max_bindings = 32;
pub const ctrl = 1;
pub const alt = 2;
pub const shift = 4;
pub const super = 8;
pub const Chord = struct {
    key: u32,
    modifiers: u32,
    pub fn normalized(c: Chord) Chord {
        var value = c;
        if (value.key >= 'A' and value.key <= 'Z') value.key += 'a' - 'A';
        if (value.modifiers & shift != 0) value.key = switch (value.key) {
            '<' => ',',
            '>' => '.',
            '{' => '[',
            '}' => ']',
            '_' => '-',
            '+' => '=',
            else => value.key,
        };
        return value;
    }
    pub fn same(a: Chord, b: Chord) bool {
        return std.meta.eql(a.normalized(), b.normalized());
    }
};
/// ID belongs to a host-owned action table. No action text/config arena pointer
/// is retained here. A hotkey callback queues this ID for the application's
/// active/quick window policy; never destroy Manager inside the callback.
pub const Binding = struct { id: u32, chord: Chord };
pub const RegisterError = error{ Unsupported, Unavailable, Conflict, Invalid, System, Limit };
pub const ReplaceError = RegisterError || error{ DuplicateId, DuplicateChord, CleanupPending, PreparationPending, Reentrant };
pub const Adapter = struct {
    context: ?*anyopaque,
    add: *const fn (?*anyopaque, Chord, u64) RegisterError!u64,
    remove: *const fn (?*anyopaque, u64) bool,
    shutdown: ?*const fn (?*anyopaque) void = null,
    diagnostic: ?*const fn (?*anyopaque) []const u8 = null,
};
pub const Callback = *const fn (?*anyopaque, u32) void;
const Entry = struct { binding: Binding, handle: u64, token: u64 };
pub const Commit = struct { cleanup_pending: usize = 0 };
pub const Manager = struct {
    adapter: ?Adapter = null,
    callback: ?Callback = null,
    context: ?*anyopaque = null,
    entries: [max_bindings]Entry = undefined,
    count: usize = 0,
    orphans: [max_bindings]u64 = undefined,
    orphan_count: usize = 0,
    next_token: u64 = 1,
    diagnostic: [256]u8 = @splat(0),
    staged: [max_bindings]Entry = undefined,
    staged_count: usize = 0,
    staged_added: [max_bindings]u64 = undefined,
    staged_added_count: usize = 0,
    prepared: bool = false,
    mutating: bool = false,

    pub fn init(adapter: Adapter, callback: Callback, context: ?*anyopaque) Manager {
        return .{ .adapter = adapter, .callback = callback, .context = context };
    }
    /// Initialize self to .{} first. Keep self at a stable address until deinit; Carbon/GLib retain only self
    /// as callback context. Failure leaves an inert, safely deinitializable self.
    pub fn initNative(self: *Manager, callback: Callback, context: ?*anyopaque) RegisterError!void {
        if (self.adapter != null) return error.Invalid;
        self.* = .{ .callback = callback, .context = context };
        const backend = lt_hotkey_open(nativeEvent, self, &self.diagnostic, self.diagnostic.len) orelse return error.Unavailable;
        self.adapter = .{ .context = backend, .add = nativeAdd, .remove = nativeRemove, .shutdown = nativeShutdown, .diagnostic = nativeDiagnostic };
    }
    pub fn lastError(self: *const Manager) []const u8 {
        return std.mem.sliceTo(&self.diagnostic, 0);
    }
    fn rememberError(self: *Manager, text: []const u8) void {
        const len = @min(text.len, self.diagnostic.len - 1);
        @memcpy(self.diagnostic[0..len], text[0..len]);
        self.diagnostic[len] = 0;
    }
    fn cleanup(self: *Manager) void {
        const adapter = self.adapter orelse return;
        var keep: usize = 0;
        for (self.orphans[0..self.orphan_count]) |handle| {
            if (!adapter.remove(adapter.context, handle)) {
                self.orphans[keep] = handle;
                keep += 1;
            }
        }
        self.orphan_count = keep;
    }
    fn discard(self: *Manager, handle: u64) void {
        const adapter = self.adapter.?;
        if (!adapter.remove(adapter.context, handle)) {
            std.debug.assert(self.orphan_count < self.orphans.len);
            self.orphans[self.orphan_count] = handle;
            self.orphan_count += 1;
        }
    }
    /// Additions are staged while every old binding remains valid. Registration
    /// failure rolls back additions and preserves the complete old action table.
    /// A rare failed unregister is retained as a muted orphan for retry/teardown;
    /// successful commit still reports it explicitly instead of lying about full
    /// cleanup. The host can show a warning and offer disable/re-enable.
    pub fn replace(self: *Manager, bindings: []const Binding) ReplaceError!Commit {
        try self.prepare(bindings);
        return self.commitPrepared();
    }
    /// Reserve every new native chord while retaining the old published table.
    /// New tokens stay muted until commit. A caller may now perform fallible
    /// filesystem work, then commit without another registration attempt.
    pub fn prepare(self: *Manager, bindings: []const Binding) ReplaceError!void {
        if (self.mutating) return error.Reentrant;
        if (self.prepared) return error.PreparationPending;
        const adapter = self.adapter orelse return error.Unavailable;
        self.mutating = true;
        defer self.mutating = false;
        self.diagnostic[0] = 0;
        if (bindings.len > max_bindings) return error.Limit;
        for (bindings, 0..) |binding, i| {
            if (binding.id == 0 or binding.chord.key == 0 or binding.chord.key > 0x10ffff or (binding.chord.key >= 0xd800 and binding.chord.key <= 0xdfff) or binding.chord.modifiers & ~@as(u32, 15) != 0 or binding.chord.modifiers & (ctrl | alt | super) == 0) return error.Invalid;
            for (bindings[0..i]) |previous| {
                if (previous.id == binding.id) return error.DuplicateId;
                if (previous.chord.same(binding.chord)) return error.DuplicateChord;
            }
        }
        self.cleanup();
        if (self.orphan_count != 0) {
            self.rememberError("Previous OS hotkey unregistration failed; disable and enable global shortcuts to retry cleanup");
            return error.CleanupPending;
        }
        var next: [max_bindings]Entry = undefined;
        var added: [max_bindings]u64 = undefined;
        var added_count: usize = 0;
        for (bindings, 0..) |binding, index| {
            const canonical = Binding{ .id = binding.id, .chord = binding.chord.normalized() };
            var reuse: ?Entry = null;
            for (self.entries[0..self.count]) |entry| if (entry.binding.chord.same(canonical.chord)) {
                reuse = entry;
                break;
            };
            if (reuse) |entry| {
                next[index] = .{ .binding = canonical, .handle = entry.handle, .token = entry.token };
                continue;
            }
            if (self.next_token == std.math.maxInt(u64)) {
                for (added[0..added_count]) |handle| self.discard(handle);
                return error.Limit;
            }
            const token = self.next_token;
            self.next_token += 1;
            const handle = adapter.add(adapter.context, canonical.chord, token) catch |err| {
                if (adapter.diagnostic) |get| self.rememberError(get(adapter.context)) else self.rememberError(@errorName(err));
                for (added[0..added_count]) |previous| self.discard(previous);
                return err;
            };
            next[index] = .{ .binding = canonical, .handle = handle, .token = token };
            added[added_count] = handle;
            added_count += 1;
        }
        @memcpy(self.staged[0..bindings.len], next[0..bindings.len]);
        @memcpy(self.staged_added[0..added_count], added[0..added_count]);
        self.staged_count = bindings.len;
        self.staged_added_count = added_count;
        self.prepared = true;
    }
    /// UI-thread commit after a successful prepare; no fallible native add or
    /// validation occurs here. Failed removals remain muted cleanup orphans.
    pub fn commitPrepared(self: *Manager) Commit {
        std.debug.assert(self.prepared and !self.mutating and self.adapter != null);
        self.mutating = true;
        defer self.mutating = false;
        for (self.entries[0..self.count]) |entry| {
            var retained = false;
            for (self.staged[0..self.staged_count]) |other| if (other.handle == entry.handle) {
                retained = true;
                break;
            };
            if (!retained) self.discard(entry.handle);
        }
        @memcpy(self.entries[0..self.staged_count], self.staged[0..self.staged_count]);
        self.count = self.staged_count;
        self.prepared = false;
        self.staged_count = 0;
        self.staged_added_count = 0;
        if (self.orphan_count == 0) self.diagnostic[0] = 0 else self.rememberError("New global shortcuts applied; previous OS registrations still await cleanup");
        return .{ .cleanup_pending = self.orphan_count };
    }
    /// Cancel a reserved candidate after a failed save. Old table/handles stay
    /// published. Idempotent so error cleanup may call this unconditionally.
    pub fn rollbackPrepared(self: *Manager) void {
        std.debug.assert(!self.mutating);
        if (!self.prepared) return;
        self.mutating = true;
        defer self.mutating = false;
        for (self.staged_added[0..self.staged_added_count]) |handle| self.discard(handle);
        self.prepared = false;
        self.staged_count = 0;
        self.staged_added_count = 0;
        if (self.orphan_count != 0) self.rememberError("Reserved global shortcuts canceled; failed OS cleanup remains muted for retry");
    }
    pub fn dispatch(self: *Manager, token: u64) void {
        for (self.entries[0..self.count]) |entry| if (entry.token == token) {
            if (self.callback) |callback| callback(self.context, entry.binding.id);
            return;
        };
    }
    pub fn deinit(self: *Manager) void {
        std.debug.assert(!self.mutating);
        self.callback = null;
        self.rollbackPrepared();
        if (self.adapter) |adapter| {
            for (self.entries[0..self.count]) |entry| _ = adapter.remove(adapter.context, entry.handle);
            self.count = 0;
            self.cleanup();
            if (adapter.shutdown) |shutdown| shutdown(adapter.context);
        }
        self.adapter = null;
        self.orphan_count = 0;
    }
};

const Native = opaque {};
const NativeCallback = *const fn (?*anyopaque, u64) callconv(.c) void;
extern fn lt_hotkey_open(NativeCallback, ?*anyopaque, [*]u8, usize) ?*Native;
extern fn lt_hotkey_register(*Native, u32, u32, u64, *u64) c_int;
extern fn lt_hotkey_unregister(*Native, u64) c_int;
extern fn lt_hotkey_last_error(*const Native) [*:0]const u8;
extern fn lt_hotkey_close(*Native) void;
extern fn lt_hotkey_capability([*]u8, usize) c_int;
/// Passive capability query: no XOpenDisplay, no key registration. It does
/// load/unload the available system library and inspect desktop environment.
pub fn capability(diagnostic: []u8) RegisterError!void {
    try result(lt_hotkey_capability(diagnostic.ptr, diagnostic.len));
}
fn result(value: c_int) RegisterError!void {
    return switch (value) {
        0 => {},
        1 => error.Unsupported,
        2 => error.Unavailable,
        3 => error.Conflict,
        4 => error.Invalid,
        6 => error.Limit,
        else => error.System,
    };
}
fn nativeAdd(context: ?*anyopaque, chord: Chord, token: u64) RegisterError!u64 {
    const backend: *Native = @ptrCast(context.?);
    var handle: u64 = 0;
    try result(lt_hotkey_register(backend, chord.key, chord.modifiers, token, &handle));
    return handle;
}
fn nativeDiagnostic(context: ?*anyopaque) []const u8 {
    return std.mem.span(lt_hotkey_last_error(@ptrCast(context.?)));
}
fn nativeRemove(context: ?*anyopaque, handle: u64) bool {
    return lt_hotkey_unregister(@ptrCast(context.?), handle) == 0;
}
fn nativeShutdown(context: ?*anyopaque) void {
    lt_hotkey_close(@ptrCast(context.?));
}
fn nativeEvent(context: ?*anyopaque, token: u64) callconv(.c) void {
    const manager: *Manager = @ptrCast(@alignCast(context.?));
    manager.dispatch(token);
}
test {
    _ = @import("global_hotkey_check.zig");
}
