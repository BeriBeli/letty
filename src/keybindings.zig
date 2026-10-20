//! Small, explicitly supported Ghostty-style key binding vocabulary.
const std = @import("std");
const mac = @import("builtin").os.tag == .macos;
const actions = @import("actions.zig");
pub const Action = actions.Action;
pub const sequence_api = @import("binding_sequence.zig");
pub const Chord = sequence_api.Chord;
pub const Flags = struct {
    performable: bool = false,
    unconsumed: bool = false,
    all: bool = false,
    global: bool = false,
};
pub const Binding = struct {
    chord: Chord,
    sequence: sequence_api.Sequence = .{},
    flags: Flags = .{},
    action: Action,
    args: actions.Argument = .none,
    accelerator: []const u8,
    /// Legacy programmatic/default bindings keep sequence.len=0. Their
    /// explicit chord remains the single source of truth until compiled.
    pub fn trigger(v: *const Binding) sequence_api.Sequence {
        if (v.sequence.len != 0) return v.sequence;
        var result: sequence_api.Sequence = .{ .len = 1 };
        result.chords[0] = v.chord;
        return result;
    }
    pub fn nativeAccelerator(v: *const Binding) bool {
        return v.trigger().len == 1 and !v.flags.performable and
            !v.flags.unconsumed and !v.flags.all and !v.flags.global;
    }
    pub fn request(v: *const Binding) actions.Request {
        return (actions.Request{ .action = v.action, .args = v.args }).normalized();
    }
};
fn b(comptime key: u21, comptime ctrl: bool, comptime cmd: bool, comptime shift: bool, comptime action: Action, comptime label: []const u8) Binding {
    return .{ .chord = .{ .key = key, .ctrl = ctrl, .cmd = cmd, .shift = shift }, .action = action, .accelerator = label };
}
pub const defaults = (if (mac) [_]Binding{
    b(',', false, true, false, .open_settings, "Cmd+,"),
    b('o', false, true, false, .open_file_workspace, "Cmd+O"),
    b('o', false, true, true, .toggle_file_preview, "Cmd+Shift+O"),
    b('n', false, true, false, .new_window, "Cmd+N"),
    .{ .chord = .{ .key = 0xF702, .cmd = true, .alt = true }, .action = .focus_pane, .args = .{ .direction = .left }, .accelerator = "Cmd+Alt+Left" },
    .{ .chord = .{ .key = 0xF703, .cmd = true, .alt = true }, .action = .focus_pane, .args = .{ .direction = .right }, .accelerator = "Cmd+Alt+Right" },
    .{ .chord = .{ .key = 0xF700, .cmd = true, .alt = true }, .action = .focus_pane, .args = .{ .direction = .up }, .accelerator = "Cmd+Alt+Up" },
    .{ .chord = .{ .key = 0xF701, .cmd = true, .alt = true }, .action = .focus_pane, .args = .{ .direction = .down }, .accelerator = "Cmd+Alt+Down" },
    b('\r', false, true, true, .toggle_zoom, "Cmd+Shift+Enter"),
    b('k', false, true, false, .clear_screen, "Cmd+K"),
    b('a', false, true, false, .select_all, "Cmd+A"),
    b('g', false, true, false, .search_next, "Cmd+G"),
    b('g', false, true, true, .search_previous, "Cmd+Shift+G"),
    b(0xF729, false, true, false, .scroll_top, "Cmd+Home"),
    b(0xF72B, false, true, false, .scroll_bottom, "Cmd+End"),
    b('q', false, true, false, .quit, "Cmd+Q"),
    b('t', false, true, false, .tab, "Cmd+T"),
    b('d', false, true, false, .horizontal, "Cmd+D"),
    b('d', false, true, true, .vertical, "Cmd+Shift+D"),
    b('w', false, true, false, .close, "Cmd+W"),
    b('w', false, true, true, .close_window, "Cmd+Shift+W"),
    .{ .chord = .{ .key = 'w', .cmd = true, .alt = true }, .action = .close_tab, .accelerator = "Cmd+Alt+W" },
    b('c', false, true, false, .copy, "Cmd+C"),
    b('v', false, true, false, .paste, "Cmd+V"),
    b('f', false, true, false, .search, "Cmd+F"),
    b('p', false, true, true, .palette, "Cmd+Shift+P"),
    .{ .chord = .{ .key = 'i', .cmd = true, .alt = true }, .action = .inspector, .accelerator = "Cmd+Alt+I" },
    b('[', false, true, true, .previous_tab, "Cmd+Shift+["),
    b(']', false, true, true, .next_tab, "Cmd+Shift+]"),
    b(']', false, true, false, .next_pane, "Cmd+]"),
    b('=', false, true, false, .font_up, "Cmd+="),
    b('+', false, true, true, .font_up, "Cmd+Shift++"),
    b('-', false, true, false, .font_down, "Cmd+-"),
    b('0', false, true, false, .font_reset, "Cmd+0"),
    b('s', false, true, true, .save, "Cmd+Shift+S"),
    b(',', false, true, true, .reload, "Cmd+Shift+,"),
} else [_]Binding{}) ++ [_]Binding{
    b(',', true, false, false, .open_settings, "Ctrl+,"),
    b('o', true, false, true, .open_file_workspace, "Ctrl+Shift+O"),
    .{ .chord = .{ .key = 'o', .ctrl = true, .alt = true }, .action = .toggle_file_preview, .accelerator = "Ctrl+Alt+O" },
    .{ .chord = .{ .key = 0xF702, .ctrl = true, .alt = true }, .action = .focus_pane, .args = .{ .direction = .left }, .accelerator = "Ctrl+Alt+Left" },
    .{ .chord = .{ .key = 0xF703, .ctrl = true, .alt = true }, .action = .focus_pane, .args = .{ .direction = .right }, .accelerator = "Ctrl+Alt+Right" },
    .{ .chord = .{ .key = 0xF700, .ctrl = true, .alt = true }, .action = .focus_pane, .args = .{ .direction = .up }, .accelerator = "Ctrl+Alt+Up" },
    .{ .chord = .{ .key = 0xF701, .ctrl = true, .alt = true }, .action = .focus_pane, .args = .{ .direction = .down }, .accelerator = "Ctrl+Alt+Down" },
    b('\r', true, false, true, .toggle_zoom, "Ctrl+Shift+Enter"),
    b('a', true, false, true, .select_all, "Ctrl+Shift+A"),
    b('g', true, false, true, .search_next, "Ctrl+Shift+G"),
    b(0xF729, true, false, true, .scroll_top, "Ctrl+Shift+Home"),
    b(0xF72B, true, false, true, .scroll_bottom, "Ctrl+Shift+End"),
    b(0xF72C, true, false, true, .page_up, "Ctrl+Shift+PageUp"),
    b(0xF72D, true, false, true, .page_down, "Ctrl+Shift+PageDown"),
    b('t', true, false, true, .tab, "Ctrl+Shift+T"),
    b('d', true, false, true, .horizontal, "Ctrl+Shift+D"),
    b('e', true, false, true, .vertical, "Ctrl+Shift+E"),
    b('w', true, false, true, .close, "Ctrl+Shift+W"),
    b('c', true, false, true, .copy, "Ctrl+Shift+C"),
    b('v', true, false, true, .paste, "Ctrl+Shift+V"),
    b('f', true, false, true, .search, "Ctrl+Shift+F"),
    b('p', true, false, true, .palette, "Ctrl+Shift+P"),
    b('i', true, false, true, .inspector, "Ctrl+Shift+I"),
    b('s', true, false, true, .save, "Ctrl+Shift+S"),
    b('n', true, false, true, .new_window, "Ctrl+Shift+N"),
    b(']', true, false, true, .next_pane, "Ctrl+Shift+]"),
    b('[', true, false, true, .previous_pane, "Ctrl+Shift+["),
    b('\t', true, false, false, .next_tab, "Ctrl+Tab"),
    b('=', true, false, true, .font_up, "Ctrl+Shift+="),
    b('+', true, false, true, .font_up, "Ctrl+Shift++"),
    b('-', true, false, true, .font_down, "Ctrl+Shift+-"),
    b(',', true, false, true, .reload, "Ctrl+Shift+,"),
};
fn same(a: Chord, z: Chord) bool {
    return std.meta.eql(a.native(), z.native());
}
pub fn lookup(overrides: []const Binding, clear: bool, chord: Chord) ?Binding {
    var i = overrides.len;
    while (i > 0) {
        i -= 1;
        if (overrides[i].flags.global) continue;
        const trigger = overrides[i].trigger();
        if (trigger.len == 1 and same(trigger.chords[0], chord)) return overrides[i];
    }
    if (clear) return null;
    for (&defaults) |*binding| if (same(binding.chord, chord)) return binding.*;
    if (mac and chord.cmd and !chord.ctrl and !chord.alt and !chord.shift and chord.key >= '1' and chord.key <= '8') return .{ .chord = chord, .action = .goto_tab, .args = .{ .index = @intCast(chord.key - '0') }, .accelerator = "" };
    return null;
}
pub fn accelerator(overrides: []const Binding, clear: bool, action: Action) []const u8 {
    return acceleratorFor(overrides, clear, .{ .action = action });
}
pub fn acceleratorFor(overrides: []const Binding, clear: bool, request: actions.Request) []const u8 {
    var i = overrides.len;
    while (i > 0) {
        i -= 1;
        const binding = &overrides[i];
        if (binding.action == request.action and effectiveOverride(overrides, i) and binding.action != .unbind and
            binding.request().same(request)) return binding.accelerator;
    }
    if (!clear) for (&defaults) |*binding| {
        if (binding.action != request.action or !binding.request().same(request)) continue;
        var replaced = false;
        for (overrides) |*replacement| if (sameTrigger(binding, replacement)) {
            replaced = true;
            break;
        };
        if (!replaced) return binding.accelerator;
    };
    return "";
}
/// Native menu accelerators cannot implement a sequence or routing flags.
pub fn nativeAcceleratorFor(overrides: []const Binding, clear: bool, request: actions.Request) []const u8 {
    var i = overrides.len;
    while (i > 0) {
        i -= 1;
        const binding = &overrides[i];
        if (binding.action != request.action or !binding.nativeAccelerator()) continue;
        const effective = lookup(overrides, clear, binding.chord) orelse continue;
        if (binding.nativeAccelerator() and effective.nativeAccelerator() and !hasLongerPrefix(overrides, binding.chord) and
            binding.request().same(request) and effective.request().same(request)) return binding.accelerator;
    }
    if (!clear) for (&defaults) |*binding| {
        if (binding.action != request.action or !binding.nativeAccelerator()) continue;
        const effective = lookup(overrides, clear, binding.chord) orelse continue;
        if (binding.nativeAccelerator() and effective.nativeAccelerator() and !hasLongerPrefix(overrides, binding.chord) and
            binding.request().same(request) and effective.request().same(request)) return binding.accelerator;
    };
    return "";
}
fn hasLongerPrefix(overrides: []const Binding, chord: Chord) bool {
    for (overrides, 0..) |*binding, index| {
        if (binding.flags.global) continue;
        const trigger = binding.trigger();
        if (trigger.len > 1 and trigger.chords[0].same(chord) and
            binding.action != .unbind and effectiveOverride(overrides, index)) return true;
    }
    return false;
}

pub fn effectiveOverride(overrides: []const Binding, index: usize) bool {
    for (overrides[index + 1 ..]) |*later| if (sameTrigger(&overrides[index], later)) return false;
    return true;
}
pub fn formatAccelerator(a: std.mem.Allocator, original: Chord) ![]const u8 {
    const chord = original.native();
    var buf: [4]u8 = undefined;
    const key: []const u8 = switch (chord.key) {
        '\t' => "Tab",
        '\r' => "Enter",
        0x1b => "Escape",
        ' ' => "Space",
        '+' => "Plus",
        0x7f => "Backspace",
        0xF728 => "Delete",
        0xF700 => "Up",
        0xF701 => "Down",
        0xF702 => "Left",
        0xF703 => "Right",
        0xF729 => "Home",
        0xF72B => "End",
        0xF72C => "PageUp",
        0xF72D => "PageDown",
        0xF704...0xF726 => return std.fmt.allocPrint(a, "{s}{s}{s}{s}F{d}", .{ if (chord.cmd) "Cmd+" else "", if (chord.ctrl) "Ctrl+" else "", if (chord.alt) "Alt+" else "", if (chord.shift) "Shift+" else "", chord.key - 0xF703 }),
        else => buf[0..try std.unicode.utf8Encode(chord.key, &buf)],
    };
    return std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}", .{ if (chord.cmd) "Cmd+" else "", if (chord.ctrl) "Ctrl+" else "", if (chord.alt) "Alt+" else "", if (chord.shift) "Shift+" else "", key });
}
pub fn parse(spec: []const u8) !Binding {
    const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return error.InvalidKeybind;
    var keys = std.mem.trim(u8, spec[0..eq], " \t");
    const action = std.mem.trim(u8, spec[eq + 1 ..], " \t");
    var flags: Flags = .{};
    while (std.mem.indexOfScalar(u8, keys, ':')) |colon| {
        const name = keys[0..colon];
        const value = if (std.mem.eql(u8, name, "performable")) &flags.performable else if (std.mem.eql(u8, name, "unconsumed")) &flags.unconsumed else if (std.mem.eql(u8, name, "all")) &flags.all else if (std.mem.eql(u8, name, "global")) &flags.global else break;
        if (value.*) return error.DuplicateKeybindPrefix;
        value.* = true;
        keys = std.mem.trim(u8, keys[colon + 1 ..], " \t");
    }
    var sequence = try sequence_api.Sequence.parse(keys);
    if (flags.global and sequence.len == 1) {
        // The local parser intentionally maps Super to Ctrl on Linux. Recover
        // ONLY the explicit raw Ctrl/Super bits for OS registration identity.
        var ctrl = false;
        var cmd = false;
        var parts = std.mem.splitScalar(u8, keys, '+');
        while (parts.next()) |part| {
            const p = std.mem.trim(u8, part, " \t");
            const eql = std.ascii.eqlIgnoreCase;
            ctrl = ctrl or eql(p, "ctrl") or eql(p, "control");
            cmd = cmd or eql(p, "super") or eql(p, "cmd") or eql(p, "command");
        }
        sequence.chords[0].ctrl = ctrl;
        sequence.chords[0].cmd = cmd;
    }
    const request = try actions.parse(action);
    if (flags.all and request.action != .send_bytes) return error.UnsupportedAllAction;
    const binding: Binding = .{ .chord = sequence.chords[0], .sequence = sequence, .flags = flags, .action = request.action, .args = request.args, .accelerator = keys };
    try validate(&binding);
    return binding;
}

pub fn globalChord(c: Chord) @import("global_hotkey.zig").Chord {
    return (@import("global_hotkey.zig").Chord{ .key = c.key, .modifiers = @as(u32, @intFromBool(c.ctrl)) | (@as(u32, @intFromBool(c.alt)) << 1) | (@as(u32, @intFromBool(c.shift)) << 2) | (@as(u32, @intFromBool(c.cmd)) << 3) }).normalized();
}
pub fn sameTrigger(a: *const Binding, b_: *const Binding) bool {
    if (a.flags.global != b_.flags.global) return false;
    const left = a.trigger();
    const right = b_.trigger();
    if (left.len > sequence_api.max_chords or right.len > sequence_api.max_chords) return false;
    if (left.len != right.len) return false;
    for (left.chords[0..left.len], right.chords[0..right.len]) |x, y| {
        if (a.flags.global) {
            if (!globalChord(x).same(globalChord(y))) return false;
        } else if (!x.same(y)) return false;
    }
    return true;
}

/// Typed JSON bindings bypass parse; callers validate them before publication.
pub fn validate(binding: *const Binding) !void {
    const trigger = binding.trigger();
    if (trigger.len == 0 or trigger.len > sequence_api.max_chords) return error.InvalidTrigger;
    if (binding.flags.global and (trigger.len != 1 or binding.flags.performable or binding.flags.unconsumed or binding.flags.all)) return error.UnsupportedGlobalBinding;
    const first = trigger.chords[0];
    if (!first.ctrl and !first.cmd and !first.alt) return error.UnsupportedKeybindModifier;
    for (trigger.chords[0..trigger.len]) |chord| {
        if (chord.key == 0 or chord.key > 0x10ffff or (chord.key >= 0xd800 and chord.key <= 0xdfff) or
            (chord.key < 32 and chord.key != 9 and chord.key != 13 and chord.key != 0x1b)) return error.InvalidChord;
    }
    if (binding.action == .send_bytes and binding.args != .bytes) return error.InvalidByteAction;
    if (binding.args == .bytes and binding.args.bytes.len > @import("action_bytes.zig").capacity) return error.InvalidBytePayload;
    if (binding.flags.all and (binding.action != .send_bytes or binding.args != .bytes)) return error.UnsupportedAllAction;
}

pub fn formatBindingAccelerator(a: std.mem.Allocator, binding: Binding) ![]const u8 {
    const trigger = binding.trigger();
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    if (binding.flags.global) try result.appendSlice(a, "Global ");
    for (trigger.chords[0..trigger.len], 0..) |chord, index| {
        if (index > 0) try result.appendSlice(a, " > ");
        var display = chord;
        if (binding.flags.global and !mac and chord.cmd) {
            try result.appendSlice(a, "Super+");
            display.cmd = false;
        }
        const label = try formatAccelerator(a, display);
        defer a.free(label);
        try result.appendSlice(a, label);
    }
    return result.toOwnedSlice(a);
}

test "last keybind overrides defaults, unbind and clear are effective" {
    const values = [_]Binding{ try parse("super+t=ignore"), try parse("super+t=new_split:right"), try parse("ctrl+shift+w=unbind") };
    try std.testing.expectEqual(Action.horizontal, lookup(&values, false, .{ .key = 't', .cmd = mac, .ctrl = !mac }).?.action);
    try std.testing.expectEqual(Action.unbind, lookup(&values, false, .{ .key = 'w', .ctrl = true, .shift = true }).?.action);
    try std.testing.expect(lookup(&.{}, true, .{ .key = 't', .ctrl = true, .shift = true }) == null);
    try std.testing.expectError(error.UnsupportedKeybindAction, parse("super+k=not_implemented"));
    try std.testing.expectError(error.InvalidKeybind, parse("super+k=increase_font_size:nan"));
}

test "menu accelerators follow named keys and parameter overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const reload = try parse("super+shift+comma=reload_config");
    try std.testing.expectEqualStrings(if (mac) "Cmd+Shift+," else "Ctrl+Shift+,", try formatAccelerator(arena.allocator(), reload.chord));
    const values = [_]Binding{ try parse("super+k=increase_font_size:1"), try parse("super+k=increase_font_size:2"), try parse("super+equal=ignore"), try parse("ctrl+shift+equal=ignore"), try parse("ctrl+shift+plus=ignore"), try parse("super+shift+plus=ignore") };
    try std.testing.expectEqual(@as(f32, 2), lookup(&values, true, .{ .key = 'k', .cmd = true }).?.request().amount());
    try std.testing.expectEqualStrings("", accelerator(&values, true, .font_up));
}

test "shifted punctuation resolves the same configured chord" {
    const values = [_]Binding{try parse("ctrl+shift+comma=reload_config")};
    try std.testing.expectEqual(Action.reload, lookup(&values, false, .{ .key = '<', .ctrl = true, .shift = true }).?.action);
}

test "command palette defaults and custom binding" {
    try std.testing.expectEqual(Action.palette, lookup(&.{}, false, .{ .key = 'p', .cmd = mac, .ctrl = !mac, .shift = true }).?.action);
    const values = [_]Binding{ try parse("super+k=toggle_command_palette"), try parse("super+shift+p=ignore") };
    try std.testing.expectEqual(Action.palette, lookup(&values, true, .{ .key = 'k', .cmd = mac, .ctrl = !mac }).?.action);
    try std.testing.expectEqualStrings("super+k", accelerator(&values, true, .palette));
}

test "sequence parser accepts routing flags and rejects unsupported all semantics" {
    const binding = try parse("performable:unconsumed:all:ctrl+b>t=text:中\\x00");
    try std.testing.expect(binding.flags.performable and binding.flags.unconsumed and binding.flags.all);
    try std.testing.expectEqual(@as(u8, 2), binding.trigger().len);
    try std.testing.expectEqualSlices(u8, "中\x00", binding.args.bytes.bytes());
    try std.testing.expectError(error.UnsupportedAllAction, parse("all:ctrl+b=new_tab"));
    try std.testing.expect((try parse("global:ctrl+b=new_tab")).flags.global);
    try std.testing.expectError(error.UnsupportedGlobalBinding, parse("global:ctrl+b>t=new_tab"));
    try std.testing.expectError(error.UnsupportedGlobalBinding, parse("global:performable:ctrl+b=new_tab"));
    const global = try parse("global:super+b=new_tab");
    const local = try parse("super+b=new_tab");
    try std.testing.expect(!sameTrigger(&global, &local));
    try std.testing.expect(!global.nativeAccelerator());
    try std.testing.expect(lookup(&.{global}, true, global.chord) == null);
    try std.testing.expectError(error.DuplicateKeybindPrefix, parse("all:all:ctrl+b=text:a"));
    try std.testing.expectError(error.UnsupportedKeybindModifier, parse("b>t=new_tab"));
    try std.testing.expectEqual(@as(u21, ':'), (try parse("ctrl+:=new_tab")).chord.key);
}

test "display accelerators retain full sequence while native menus never bypass matching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const binding = try parse("ctrl+shift+t>x=new_split:right");
    try std.testing.expectEqualStrings("Ctrl+Shift+t > x", try formatBindingAccelerator(arena.allocator(), binding));
    const values = [_]Binding{binding};
    try std.testing.expectEqualStrings("ctrl+shift+t>x", acceleratorFor(&values, false, .{ .action = .horizontal }));
    try std.testing.expectEqualStrings("", nativeAcceleratorFor(&values, true, .{ .action = .horizontal }));
    try std.testing.expect(hasLongerPrefix(&values, binding.chord));
    const tab_accelerator = nativeAcceleratorFor(&values, false, .{ .action = .tab });
    try std.testing.expect(!std.mem.eql(u8, tab_accelerator, "Ctrl+Shift+T"));
    const flags = [_]Binding{try parse("performable:ctrl+q=copy_to_clipboard")};
    try std.testing.expectEqualStrings("ctrl+q", acceleratorFor(&flags, true, .{ .action = .copy }));
    try std.testing.expectEqualStrings("", nativeAcceleratorFor(&flags, true, .{ .action = .copy }));
}
