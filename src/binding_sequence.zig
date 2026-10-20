//! Per-window, bounded chord matching. No allocation, timers, or borrowed data.
//! The host schedules `deadline_ms` once and calls `timeout`; cancellation must
//! be wired to focus loss, modal/editor entry, IME start and config replacement.
const std = @import("std");
const mac = @import("builtin").os.tag == .macos;
pub const max_chords = 8;
pub const default_timeout_ms = 1000;
pub const Chord = struct {
    key: u21,
    ctrl: bool = false,
    cmd: bool = false,
    alt: bool = false,
    shift: bool = false,

    pub fn native(chord: Chord) Chord {
        var value = chord;
        if (value.shift) value.key = switch (value.key) {
            '<' => ',',
            '>' => '.',
            '{' => '[',
            '}' => ']',
            '_' => '-',
            '+' => '=',
            else => value.key,
        };
        if (value.key >= 'A' and value.key <= 'Z') value.key += 'a' - 'A';
        if (!mac and value.cmd) {
            value.ctrl = true;
            value.cmd = false;
        }
        return value;
    }

    pub fn same(a: Chord, b: Chord) bool {
        return std.meta.eql(a.native(), b.native());
    }
};

pub const Sequence = struct {
    chords: [max_chords]Chord = @splat(.{ .key = 0 }),
    len: u8 = 0,

    pub fn parse(source: []const u8) !Sequence {
        var result: Sequence = .{};
        var parts = std.mem.splitScalar(u8, source, '>');
        while (parts.next()) |part| {
            if (result.len == max_chords) return error.SequenceTooLong;
            result.chords[result.len] = try parseChord(part);
            result.len += 1;
        }
        const first = result.chords[0];
        if (!first.ctrl and !first.cmd and !first.alt) return error.UnsupportedKeybindModifier;
        return result;
    }
};

pub const Binding = struct {
    sequence: Sequence,
    id: u16,
    /// Disabled performable bindings should be filtered by the host each event.
    enabled: bool = true,
    /// `unconsumed:` affects the final matched event; prefixes are consumed.
    consume: bool = true,
};
pub const CancelReason = enum { escape, timeout, mismatch, focus_lost, modal, editing, ime, reload };
pub const Guard = struct { focused: bool = true, modal: bool = false, editing: bool = false, ime: bool = false };
pub const Result = struct {
    action: ?u16 = null,
    consumed: bool = false,
    deadline_ms: ?u64 = null,
    cancelled: ?CancelReason = null,
};

pub const Matcher = struct {
    prefix: [max_chords]Chord = @splat(.{ .key = 0 }),
    len: u8 = 0,
    deadline_ms: ?u64 = null,
    fallback: ?u16 = null,
    timeout_ms: u16 = default_timeout_ms,

    pub fn init(timeout_ms: u16) !Matcher {
        if (timeout_ms < 50 or timeout_ms > 5000) return error.InvalidSequenceTimeout;
        return .{ .timeout_ms = timeout_ms };
    }

    pub fn active(self: *const Matcher) bool {
        return self.len != 0;
    }

    pub fn cancel(self: *Matcher, reason: CancelReason) Result {
        const was_active = self.active();
        self.len = 0;
        self.deadline_ms = null;
        self.fallback = null;
        return .{ .cancelled = if (was_active) reason else null };
    }

    /// Early or obsolete timer callbacks simply return the current deadline.
    /// Once expired, subsequent callbacks cannot dispatch the action again.
    pub fn timeout(self: *Matcher, now_ms: u64) Result {
        const deadline = self.deadline_ms orelse return .{};
        if (now_ms < deadline) return .{ .deadline_ms = deadline };
        const action = self.fallback;
        _ = self.cancel(.timeout);
        return .{ .action = action, .cancelled = .timeout };
    }

    /// On mismatch/expiry, a deferred complete action may be returned together
    /// with consumed=false. Route only this current key normally, exactly once;
    /// never replay earlier prefix keys or recursively feed this matcher.
    pub fn feed(self: *Matcher, bindings: []const Binding, chord: Chord, now_ms: u64, guard: Guard) Result {
        if (!guard.focused or guard.modal or guard.editing or guard.ime) {
            const reason: CancelReason = if (guard.ime) .ime else if (guard.modal) .modal else if (guard.editing) .editing else .focus_lost;
            return self.cancel(reason);
        }
        if (self.active() and chord.key == 0x1b) {
            var result = self.cancel(.escape);
            result.consumed = true;
            return result;
        }
        if (self.deadline_ms) |deadline| if (now_ms >= deadline) return self.timeout(now_ms);
        if (self.len == max_chords) return self.cancel(.mismatch);
        self.prefix[self.len] = chord;
        const length = self.len + 1;
        var exact: ?Binding = null;
        var longer = false;
        for (bindings) |binding| {
            if (!binding.enabled or binding.sequence.len < length) continue;
            var matches = true;
            for (self.prefix[0..length], binding.sequence.chords[0..length]) |a, b| {
                if (!a.same(b)) {
                    matches = false;
                    break;
                }
            }
            if (!matches) continue;
            if (binding.sequence.len == length) exact = binding else longer = true;
        }
        if (longer) {
            self.len = length;
            if (exact) |binding| {
                self.fallback = binding.id;
            }
            // One deadline belongs to the whole sequence. Intermediate
            // chords never extend it or ask the host for another idle timer.
            if (self.deadline_ms == null) self.deadline_ms = now_ms +| self.timeout_ms;
            return .{ .consumed = true, .deadline_ms = self.deadline_ms };
        }
        if (exact) |binding| {
            _ = self.cancel(.mismatch);
            return .{ .action = binding.id, .consumed = binding.consume };
        }
        const action = self.fallback;
        var result = self.cancel(.mismatch);
        result.action = action;
        return result;
    }
};

pub fn parseChord(source: []const u8) !Chord {
    var result: Chord = .{ .key = 0 };
    var has_key = false;
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, source, " \t"), '+');
    while (parts.next()) |part| {
        const p = std.mem.trim(u8, part, " \t");
        const eql = std.ascii.eqlIgnoreCase;
        const modifier = if (eql(p, "ctrl") or eql(p, "control")) &result.ctrl else if (eql(p, "super") or eql(p, "cmd") or eql(p, "command")) &result.cmd else if (eql(p, "alt") or eql(p, "option")) &result.alt else if (eql(p, "shift")) &result.shift else null;
        if (modifier) |value| {
            if (value.*) return error.InvalidChord;
            value.* = true;
            continue;
        }
        if (has_key or p.len == 0) return error.InvalidChord;
        has_key = true;
        const names = .{ .{ "home", 0xF729 }, .{ "end", 0xF72B }, .{ "page_up", 0xF72C }, .{ "pageup", 0xF72C }, .{ "page_down", 0xF72D }, .{ "pagedown", 0xF72D }, .{ "tab", 9 }, .{ "enter", 13 }, .{ "escape", 0x1b }, .{ "space", 32 }, .{ "plus", 43 }, .{ "comma", 44 }, .{ "period", 46 }, .{ "minus", 45 }, .{ "equal", 61 }, .{ "left_bracket", 91 }, .{ "right_bracket", 93 }, .{ "up", 0xF700 }, .{ "down", 0xF701 }, .{ "left", 0xF702 }, .{ "right", 0xF703 }, .{ "greater", 62 }, .{ "less", 60 }, .{ "backspace", 0x7f }, .{ "delete", 0xF728 } };
        var named = false;
        inline for (names) |name| {
            if (eql(p, name[0])) {
                result.key = name[1];
                named = true;
            }
        }
        if (!named) {
            if (p.len >= 2 and (p[0] == 'f' or p[0] == 'F')) {
                const number = std.fmt.parseInt(u8, p[1..], 10) catch 0;
                if (number >= 1 and number <= 35) {
                    result.key = 0xF703 + @as(u21, number);
                    continue;
                }
            }
            const size = std.unicode.utf8ByteSequenceLength(p[0]) catch return error.InvalidChord;
            if (size != p.len) return error.UnsupportedKey;
            result.key = std.unicode.utf8Decode(p) catch return error.InvalidChord;
            if (result.key < 32) return error.InvalidChord;
        }
    }
    if (!has_key) return error.InvalidChord;
    return result.native();
}

fn makeBinding(source: []const u8, id: u16) !Binding {
    return .{ .sequence = try Sequence.parse(source), .id = id };
}

test "sequence parser bounds chords and requires an explicit first modifier" {
    try std.testing.expectEqual(@as(u8, 3), (try Sequence.parse("ctrl+b > t > 中")).len);
    try std.testing.expectError(error.UnsupportedKeybindModifier, Sequence.parse("b>t"));
    try std.testing.expectError(error.UnsupportedKeybindModifier, Sequence.parse("shift+b>t"));
    try std.testing.expectError(error.InvalidChord, Sequence.parse("ctrl+b>"));
    try std.testing.expectError(error.SequenceTooLong, Sequence.parse("ctrl+b>a>b>c>d>e>f>g>h"));
    try std.testing.expectError(error.InvalidChord, Sequence.parse("ctrl+ctrl+b"));
    try std.testing.expectError(error.InvalidSequenceTimeout, Matcher.init(0));
    try std.testing.expectEqual(@as(u21, 0xF70F), (try parseChord("F12")).key);
}

test "prefix is consumed and completion dispatches once without replay" {
    const bindings = [_]Binding{try makeBinding("ctrl+b>t", 1)};
    var state: Matcher = .{};
    const prefix = state.feed(&bindings, try parseChord("ctrl+b"), 10, .{});
    try std.testing.expect(prefix.consumed and prefix.action == null);
    try std.testing.expectEqual(@as(?u64, 1010), prefix.deadline_ms);
    const complete = state.feed(&bindings, try parseChord("t"), 20, .{});
    try std.testing.expect(complete.consumed);
    try std.testing.expectEqual(@as(?u16, 1), complete.action);
    try std.testing.expect(!state.active());
    try std.testing.expect(state.timeout(2000).action == null);
    const repeated = state.feed(&bindings, try parseChord("t"), 30, .{});
    try std.testing.expect(!repeated.consumed and repeated.action == null);
}

test "ambiguous prefix waits and longest complete action wins" {
    const bindings = [_]Binding{ try makeBinding("ctrl+b", 1), try makeBinding("ctrl+b>t", 2), try makeBinding("ctrl+b>t>x", 3) };
    var state: Matcher = .{};
    _ = state.feed(&bindings, try parseChord("ctrl+b"), 0, .{});
    const middle = state.feed(&bindings, try parseChord("t"), 50, .{});
    try std.testing.expect(middle.action == null and middle.consumed);
    try std.testing.expectEqual(@as(?u64, 1000), middle.deadline_ms);
    try std.testing.expectEqual(@as(?u64, 1000), state.timeout(999).deadline_ms);
    const expiry = state.timeout(1000);
    try std.testing.expectEqual(@as(?u16, 2), expiry.action);
    try std.testing.expect(state.timeout(1051).action == null);
    _ = state.feed(&bindings, try parseChord("ctrl+b"), 2000, .{});
    _ = state.feed(&bindings, try parseChord("t"), 2050, .{});
    try std.testing.expectEqual(@as(?u16, 3), state.feed(&bindings, try parseChord("x"), 2100, .{}).action);
}

test "mismatch dispatches deferred action but routes only unmatched key onward" {
    const bindings = [_]Binding{ try makeBinding("ctrl+b", 1), try makeBinding("ctrl+b>t", 2) };
    var state: Matcher = .{};
    _ = state.feed(&bindings, try parseChord("ctrl+b"), 0, .{});
    const unmatched = state.feed(&bindings, try parseChord("q"), 5, .{});
    try std.testing.expect(!unmatched.consumed);
    try std.testing.expectEqual(@as(?u16, 1), unmatched.action);
    try std.testing.expectEqual(@as(?CancelReason, .mismatch), unmatched.cancelled);
    try std.testing.expect(state.fallback == null and state.len == 0);
    _ = state.feed(bindings[1..], try parseChord("ctrl+b"), 10, .{});
    const without_fallback = state.feed(bindings[1..], try parseChord("q"), 15, .{});
    try std.testing.expect(!without_fallback.consumed and without_fallback.action == null);
}

test "deadline passed before a key resolves pending action without eating key" {
    const bindings = [_]Binding{ try makeBinding("ctrl+b", 1), try makeBinding("ctrl+b>t", 2) };
    var state: Matcher = .{};
    _ = state.feed(&bindings, try parseChord("ctrl+b"), 0, .{});
    const expired = state.feed(&bindings, try parseChord("t"), 1000, .{});
    try std.testing.expectEqual(@as(?u16, 1), expired.action);
    try std.testing.expect(!expired.consumed and !state.active());
}

test "Esc, focus, modal, editor, IME and reload cancel without fallback" {
    const bindings = [_]Binding{ try makeBinding("ctrl+b", 1), try makeBinding("ctrl+b>t", 2) };
    var state: Matcher = .{};
    _ = state.feed(&bindings, try parseChord("ctrl+b"), 0, .{});
    const escaped = state.feed(&bindings, try parseChord("escape"), 10, .{});
    try std.testing.expect(escaped.consumed and escaped.action == null);
    try std.testing.expectEqual(@as(?CancelReason, .escape), escaped.cancelled);
    const guards = [_]Guard{ .{ .focused = false }, .{ .modal = true }, .{ .editing = true }, .{ .ime = true } };
    const reasons = [_]CancelReason{ .focus_lost, .modal, .editing, .ime };
    for (guards, reasons) |guard, reason| {
        _ = state.feed(&bindings, try parseChord("ctrl+b"), 100, .{});
        const cancelled = state.feed(&bindings, try parseChord("t"), 110, guard);
        try std.testing.expect(!cancelled.consumed and cancelled.action == null);
        try std.testing.expectEqual(@as(?CancelReason, reason), cancelled.cancelled);
        try std.testing.expect(state.timeout(2000).action == null);
    }
    _ = state.feed(&bindings, try parseChord("ctrl+b"), 3000, .{});
    try std.testing.expectEqual(@as(?CancelReason, .reload), state.cancel(.reload).cancelled);
}

test "each window owns prefix state and disabled bindings do not consume" {
    const bindings = [_]Binding{try makeBinding("ctrl+b>t", 1)};
    var first: Matcher = .{};
    var second: Matcher = .{};
    _ = first.feed(&bindings, try parseChord("ctrl+b"), 0, .{});
    try std.testing.expect(second.feed(&bindings, try parseChord("t"), 1, .{}).action == null);
    try std.testing.expectEqual(@as(?u16, 1), first.feed(&bindings, try parseChord("t"), 1, .{}).action);
    var disabled = bindings;
    disabled[0].enabled = false;
    const result = first.feed(&disabled, try parseChord("ctrl+b"), 2, .{});
    try std.testing.expect(!result.consumed and !first.active());
}

test "last duplicate binding and final unconsumed semantics" {
    var bindings = [_]Binding{ try makeBinding("ctrl+b>t", 1), try makeBinding("ctrl+b>t", 2) };
    bindings[1].consume = false;
    var state: Matcher = .{};
    try std.testing.expect(state.feed(&bindings, try parseChord("ctrl+b"), 0, .{}).consumed);
    const result = state.feed(&bindings, try parseChord("t"), 1, .{});
    try std.testing.expectEqual(@as(?u16, 2), result.action);
    try std.testing.expect(!result.consumed);
    try std.testing.expect((try parseChord("ctrl+shift+comma")).same(.{ .key = '<', .ctrl = true, .shift = true }));
}

test "deep prefixes preserve pending action and maximum depth completes" {
    const bindings = [_]Binding{ try makeBinding("alt+b", 1), try makeBinding("alt+b>a>b>c>d>e>f>g", 8) };
    var state: Matcher = .{};
    _ = state.feed(&bindings, try parseChord("alt+b"), 0, .{});
    _ = state.feed(&bindings, try parseChord("a"), 10, .{});
    try std.testing.expectEqual(@as(?u16, 1), state.timeout(1010).action);
    _ = state.feed(&bindings, try parseChord("alt+b"), 2000, .{});
    for ("abcdef") |key| {
        const result = state.feed(&bindings, .{ .key = key }, 2001, .{});
        try std.testing.expect(result.consumed and result.action == null);
    }
    try std.testing.expectEqual(@as(?u16, 8), state.feed(&bindings, .{ .key = 'g' }, 2002, .{}).action);
}
