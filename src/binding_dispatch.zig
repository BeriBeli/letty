//! Allocation-free binding resolution. Requests leave this module by value;
//! State retains only chord prefixes/IDs, never configuration-owned slices.
const std = @import("std");
const mac = @import("builtin").os.tag == .macos;
const keys = @import("keybindings.zig");
const sequence = @import("binding_sequence.zig");
const actions = @import("actions.zig");
pub const max_overrides = 128;

const max_entries = keys.defaults.len + max_overrides + 8;
pub const Scope = enum { active, all };
pub const Availability = struct {
    active: actions.Capabilities = .{},
};
pub const Result = struct {
    request: ?actions.Request = null,
    scope: Scope = .active,
    consumed: bool = false,
    deadline_ms: ?u64 = null,
    cancelled: ?sequence.CancelReason = null,
};
const Table = struct {
    entries: [max_entries]sequence.Binding = undefined,
    len: usize = 0,
    fn add(self: *Table, binding: *const keys.Binding, id: usize, availability: Availability) !void {
        if (binding.flags.global or binding.action == .unbind or !enabled(binding, availability)) return;
        const trigger = binding.trigger();
        if (trigger.len == 0 or trigger.len > sequence.max_chords) return error.InvalidTrigger;
        self.entries[self.len] = .{ .sequence = trigger, .id = @intCast(id), .consume = !binding.flags.unconsumed };
        self.len += 1;
    }
    fn has(self: *const Table, id: u16) bool {
        for (self.entries[0..self.len]) |entry| if (entry.id == id) return true;
        return false;
    }
};
fn enabled(binding: *const keys.Binding, availability: Availability) bool {
    if (!binding.flags.performable) return true;
    const request = binding.request();
    return availability.active.disabled(request) == null;
}
fn virtualTab(index: usize) keys.Binding {
    return .{ .chord = .{ .key = @intCast('1' + index), .cmd = true }, .action = .goto_tab, .args = .{ .index = @intCast(index + 1) }, .accelerator = "" };
}
fn shadowed(overrides: []const keys.Binding, binding: *const keys.Binding) bool {
    for (overrides) |*replacement| if (keys.sameTrigger(binding, replacement)) return true;
    return false;
}
fn compile(overrides: []const keys.Binding, clear: bool, availability: Availability) !Table {
    if (overrides.len > max_overrides) return error.TooManyKeybindings;
    for (overrides) |*binding| try keys.validate(binding);
    var table: Table = .{};
    if (!clear) for (&keys.defaults, 0..) |*binding, id| {
        if (!shadowed(overrides, binding)) try table.add(binding, id, availability);
    };
    // Resolve last declaration before checking performability. A disabled
    // override must fall through to the terminal, not resurrect old defaults.
    for (overrides, 0..) |*binding, index| {
        if (keys.effectiveOverride(overrides, index)) try table.add(binding, keys.defaults.len + index, availability);
    }
    if (mac and !clear) for (0..8) |index| {
        const binding = virtualTab(index);
        if (!shadowed(overrides, &binding)) try table.add(&binding, keys.defaults.len + overrides.len + index, availability);
    };
    return table;
}
fn bindingFor(overrides: []const keys.Binding, id: u16) ?*const keys.Binding {
    if (id < keys.defaults.len) return &keys.defaults[id];
    const index = id - keys.defaults.len;
    return if (index < overrides.len) &overrides[index] else null;
}
fn resolved(overrides: []const keys.Binding, table: *const Table, value: sequence.Result) Result {
    var result: Result = .{ .consumed = value.consumed, .deadline_ms = value.deadline_ms, .cancelled = value.cancelled };
    if (value.action) |id| if (table.has(id)) {
        if (bindingFor(overrides, id)) |binding| {
            result.request = binding.request();
            result.scope = if (binding.flags.all) .all else .active;
        } else {
            const binding = virtualTab(id - keys.defaults.len - overrides.len);
            result.request = binding.request();
        }
    };
    return result;
}
fn blocked(guard: sequence.Guard) ?sequence.CancelReason {
    return if (guard.ime) .ime else if (guard.modal) .modal else if (guard.editing) .editing else if (!guard.focused) .focus_lost else null;
}

pub const State = struct {
    matcher: sequence.Matcher = .{},
    pub fn active(self: *const State) bool {
        return self.matcher.active();
    }
    pub fn cancel(self: *State, reason: sequence.CancelReason) Result {
        const value = self.matcher.cancel(reason);
        return .{ .cancelled = value.cancelled };
    }
    /// The caller resolves UI/IME/field precedence before this call. An
    /// unmatched final event is routed normally once; never feed it twice.
    pub fn feed(self: *State, overrides: []const keys.Binding, clear: bool, chord: keys.Chord, now_ms: u64, guard: sequence.Guard, availability: Availability) !Result {
        const table = compile(overrides, clear, availability) catch |err| {
            _ = self.cancel(.reload);
            return err;
        };
        return resolved(overrides, &table, self.matcher.feed(table.entries[0..table.len], chord, now_ms, guard));
    }
    /// Guard and availability are checked again at the single timer deadline,
    /// so a now-disabled fallback cannot run from a stale timer callback.
    pub fn timeout(self: *State, overrides: []const keys.Binding, clear: bool, now_ms: u64, guard: sequence.Guard, availability: Availability) !Result {
        if (blocked(guard)) |reason| return self.cancel(reason);
        const table = compile(overrides, clear, availability) catch |err| {
            _ = self.cancel(.reload);
            return err;
        };
        return resolved(overrides, &table, self.matcher.timeout(now_ms));
    }
};

pub const Target = struct {
    id: u64,
    eligible: bool = true,
    capabilities: actions.Capabilities = .{},
    /// Host admission: target alive, TX has room for the whole payload, and
    /// any host resource needed by this exact request can be committed now.
    ready: bool = true,
};
pub const BroadcastPlan = struct {
    ids: []u64 = &.{},
    len: usize = 0,
};
/// Pure preflight, never sends bytes. The host must resolve these stable IDs
/// and commit without yielding/pumping events between admission and sends.
/// Invalid targets are skipped; refusal by any eligible target rejects all.
pub fn planAll(targets: []const Target, request: actions.Request) !BroadcastPlan {
    if (request.action != .send_bytes or request.args != .bytes) return error.UnsupportedAllAction;

    var result: BroadcastPlan = .{ .ids = try std.heap.page_allocator.alloc(u64, targets.len) };
    errdefer std.heap.page_allocator.free(result.ids);
    for (targets, 0..) |target, index| {
        if (target.id == 0) return error.InvalidBindingTarget;
        for (targets[0..index]) |prior| if (prior.id == target.id) return error.DuplicateBindingTarget;
        if (!target.eligible or target.capabilities.disabled(request) != null) continue;
        if (!target.ready) return error.BindingTargetNotReady;
        result.ids[result.len] = target.id;
        result.len += 1;
    }
    if (result.len == 0) return error.NoPerformableBindingTarget;
    return result;
}

test "dispatcher resolves sequences and mismatch routes the last key once" {
    const bindings = [_]keys.Binding{ try keys.parse("ctrl+b=new_tab"), try keys.parse("ctrl+b>t=new_split:right") };
    var state: State = .{};
    const prefix = try state.feed(&bindings, true, try sequence.parseChord("ctrl+b"), 0, .{}, .{});
    try std.testing.expect(prefix.consumed and prefix.request == null);
    const mismatch = try state.feed(&bindings, true, try sequence.parseChord("q"), 1, .{}, .{});
    try std.testing.expect(!mismatch.consumed and mismatch.request.?.action == .tab);
    try std.testing.expect((try state.timeout(&bindings, true, 5000, .{}, .{})).request == null);
}

test "performable filters before consuming and never revives a shadowed default" {
    const bindings = [_]keys.Binding{try keys.parse("performable:ctrl+shift+t=copy_to_clipboard")};
    var state: State = .{};
    const chord = try sequence.parseChord("ctrl+shift+t");
    const no_selection = try state.feed(&bindings, false, chord, 0, .{}, .{});
    try std.testing.expect(!no_selection.consumed and no_selection.request == null);
    const selected = try state.feed(&bindings, false, chord, 1, .{}, .{ .active = .{ .selection = true } });
    try std.testing.expect(selected.consumed and selected.request.?.action == .copy);
}

test "last unbind, unconsumed final chord and byte-only all scope keep their semantics" {
    const bindings = [_]keys.Binding{ try keys.parse("ctrl+b>t=new_tab"), try keys.parse("ctrl+b>t=unbind"), try keys.parse("unconsumed:all:ctrl+x>c=text:hello\\x00") };
    var state: State = .{};
    try std.testing.expect(!(try state.feed(&bindings, true, try sequence.parseChord("ctrl+b"), 0, .{}, .{})).consumed);
    _ = try state.feed(&bindings, true, try sequence.parseChord("ctrl+x"), 0, .{}, .{});
    const done = try state.feed(&bindings, true, try sequence.parseChord("c"), 1, .{}, .{});
    try std.testing.expect(!done.consumed and done.scope == .all and done.request.?.action == .send_bytes);
    try std.testing.expectEqualSlices(u8, "hello\x00", done.request.?.args.bytes.bytes());
}

test "timeout rechecks active availability and IME before running a fallback" {
    const bindings = [_]keys.Binding{ try keys.parse("performable:ctrl+b=copy_to_clipboard"), try keys.parse("ctrl+b>t=new_tab") };
    var state: State = .{};
    _ = try state.feed(&bindings, true, try sequence.parseChord("ctrl+b"), 0, .{}, .{ .active = .{ .selection = true } });
    const disabled = try state.timeout(&bindings, true, 1000, .{}, .{});
    try std.testing.expect(disabled.request == null);
    _ = try state.feed(&bindings, true, try sequence.parseChord("ctrl+b"), 2000, .{}, .{ .active = .{ .selection = true } });
    const ime = try state.timeout(&bindings, true, 3000, .{ .ime = true }, .{ .active = .{ .selection = true } });
    try std.testing.expect(ime.request == null and ime.cancelled == .ime);
}

test "broadcast preflight selects valid IDs and any admission refusal rejects all" {
    const request = try actions.parse("text:a\\x00b");
    var targets = [_]Target{ .{ .id = 1, .eligible = false }, .{ .id = 2 }, .{ .id = 3 } };
    const plan = try planAll(&targets, request);
    defer std.heap.page_allocator.free(plan.ids);
    try std.testing.expectEqualSlices(u64, &.{ 2, 3 }, plan.ids[0..plan.len]);
    targets[2].ready = false;
    try std.testing.expectError(error.BindingTargetNotReady, planAll(&targets, request));
    targets[2].ready = true;
    targets[2].id = 2;
    try std.testing.expectError(error.DuplicateBindingTarget, planAll(&targets, request));
    try std.testing.expectError(error.UnsupportedAllAction, planAll(&targets, .{ .action = .copy }));
}

test "queued byte request owns its Unicode ESC NUL payload after config replacement" {
    var source = "ctrl+x=text:中\\x1b\\x00end".*;
    var bindings = [_]keys.Binding{try keys.parse(&source)};
    @memset(&source, 'z');
    var state: State = .{};
    const result = try state.feed(&bindings, true, try sequence.parseChord("ctrl+x"), 0, .{}, .{});
    @memset(&bindings[0].args.bytes.data, 'q');
    try std.testing.expectEqualSlices(u8, "中\x1b\x00end", result.request.?.args.bytes.bytes());
}

test "typed binding bounds are rejected before indexing or consuming input" {
    var bindings = [_]keys.Binding{try keys.parse("ctrl+b>t=text:a")};
    var state: State = .{};
    _ = try state.feed(&bindings, true, try sequence.parseChord("ctrl+b"), 0, .{}, .{});
    bindings[0].sequence.len = 9;
    try std.testing.expectError(error.InvalidTrigger, state.feed(&bindings, true, try sequence.parseChord("t"), 1, .{}, .{}));
    try std.testing.expect(!state.active());
    bindings[0] = try keys.parse("ctrl+x=text:a");
    bindings[0].args.bytes.len = 4097;
    try std.testing.expectError(error.InvalidBytePayload, state.feed(&bindings, true, try sequence.parseChord("ctrl+x"), 2, .{}, .{}));
    bindings[0] = try keys.parse("ctrl+x=text:a");
    bindings[0].args = .none;
    try std.testing.expectError(error.InvalidByteAction, state.feed(&bindings, true, try sequence.parseChord("ctrl+x"), 3, .{}, .{}));
}

test "broadcast preflight covers all targets beyond byte indices and rejects a busy final target" {
    var targets: [300]Target = undefined;
    for (&targets, 0..) |*target, i| target.* = .{ .id = i + 1 };
    const request = try actions.parse("text:x");
    const plan = try planAll(&targets, request);
    defer std.heap.page_allocator.free(plan.ids);
    try std.testing.expect(plan.len == 300 and plan.ids[299] == 300);
    targets[299].ready = false;
    try std.testing.expectError(error.BindingTargetNotReady, planAll(&targets, request));
}
