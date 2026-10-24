//! Kero/Herdr's priority gates and screen regions, executed by a Zig NFA.
//! Rules retain their Apache-2.0 provenance in assets/terminal/manifests/LICENSE.
const std = @import("std");
const A = std.mem.Allocator;
pub const State = enum { idle, working, blocked, unknown };
pub const Result = struct { state: State = .unknown, rule: []const u8 = "", visible: bool = false, skip: bool = false };
pub const Input = struct { screen: []const u8 = "", title: []const u8 = "", progress: []const u8 = "" };
const Category = enum { digit, not_digit, space, not_space, word, not_word };
const Op = struct {
    op: enum { char, class, any, split, match, begin, begin_string, end, end_string, boundary, not_boundary },
    next: u16 = 0,
    other: u16 = 0,
    cp: u21 = 0,
    ranges: []const [2]u21 = &.{},
    categories: []const Category = &.{},
    invert: bool = false,
};
const Program = struct { start: u16, instructions: []const Op, insensitive: bool = false, multiline: bool = false, dotall: bool = false };
const Gate = struct { contains: []const []const u8 = &.{}, regex: []const usize = &.{}, line_regex: []const usize = &.{}, all: []const Gate = &.{}, any: []const Gate = &.{}, not: []const Gate = &.{} };
const Rule = struct { id: []const u8, state: State, priority: i32, region: []const u8 = "whole_recent", visible_idle: bool = false, visible_working: bool = false, visible_blocker: bool = false, skip_state_update: bool = false, gate: Gate };
const Agent = struct { name: []const u8, aliases: []const []const u8 = &.{}, rules: []const Rule };
const Catalog = struct { agents: []const Agent, programs: []const Program, fold: []const [2]u21 };
pub const Engine = struct {
    a: A,
    parsed: std.json.Parsed(Catalog),
    lists: [2][]u16,
    stack: []u16,
    seen: []u32,
    generation: u32 = 0,
    pub fn init(a: A) !Engine {
        const parsed = try std.json.parseFromSlice(Catalog, a, @embedFile("detection_rules"), .{ .ignore_unknown_fields = true });
        errdefer parsed.deinit();
        var count: usize = 1;
        for (parsed.value.programs) |p| {
            if (p.instructions.len > 4096 or p.start >= p.instructions.len) return error.InvalidDetectionProgram;
            for (p.instructions) |op| if (op.next >= p.instructions.len or op.other >= p.instructions.len) return error.InvalidDetectionProgram;
            count = @max(count, p.instructions.len);
        }
        const first = try a.alloc(u16, count);
        errdefer a.free(first);
        const second = try a.alloc(u16, count);
        errdefer a.free(second);
        const stack = try a.alloc(u16, count);
        errdefer a.free(stack);
        const seen = try a.alloc(u32, count);
        @memset(seen, 0);
        return .{ .a = a, .parsed = parsed, .lists = .{ first, second }, .stack = stack, .seen = seen };
    }
    pub fn deinit(self: *Engine) void {
        for (self.lists) |list| self.a.free(list);
        self.a.free(self.stack);
        self.a.free(self.seen);
        self.parsed.deinit();
    }
    pub fn known(self: *Engine, name: []const u8) bool {
        return self.agent(name) != null;
    }
    fn agent(self: *Engine, raw: []const u8) ?Agent {
        const name = if (std.mem.eql(u8, raw, "cursor-agent")) "cursor" else if (std.mem.eql(u8, raw, "copilot")) "github-copilot" else if (std.mem.eql(u8, raw, "kiro-cli")) "kiro" else raw;
        for (self.parsed.value.agents) |item| {
            if (std.mem.eql(u8, item.name, name)) return item;
            for (item.aliases) |alias| if (std.mem.eql(u8, alias, name)) return item;
        }
        return null;
    }
    pub fn detect(self: *Engine, name: []const u8, input: Input) !Result {
        const item = self.agent(name) orelse return .{};
        if (input.screen.len > 65536 or input.title.len > 8192) return error.DetectionInputLimit;
        var arena: std.heap.ArenaAllocator = .init(self.a);
        defer arena.deinit();
        var budget: usize = 8_000_000;
        var winner: ?Rule = null;
        for (item.rules) |rule| {
            if (winner != null and winner.?.priority >= rule.priority) continue;
            const text = try region(arena.allocator(), input, rule.region);
            if (try self.matches(rule.gate, text, &budget)) winner = rule;
        }
        const rule = winner orelse return .{ .state = .idle };
        return .{ .state = rule.state, .rule = rule.id, .skip = rule.skip_state_update, .visible = switch (rule.state) {
            .idle => rule.visible_idle,
            .working => rule.visible_working,
            .blocked => rule.visible_blocker,
            else => false,
        } };
    }
    fn matches(self: *Engine, gate: Gate, text: []const u8, budget: *usize) error{ DetectionBudget, InvalidDetectionProgram }!bool {
        for (gate.contains) |needle| if (!contains(text, needle)) return false;
        for (gate.regex) |index| if (!try self.regex(index, text, budget)) return false;
        for (gate.line_regex) |index| {
            var found = false;
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| if (try self.regex(index, std.mem.trimEnd(u8, line, "\r"), budget)) {
                found = true;
                break;
            };
            if (!found) return false;
        }
        for (gate.all) |child| if (!try self.matches(child, text, budget)) return false;
        if (gate.any.len > 0) {
            var found = false;
            for (gate.any) |child| if (try self.matches(child, text, budget)) {
                found = true;
                break;
            };
            if (!found) return false;
        }
        for (gate.not) |child| if (try self.matches(child, text, budget)) return false;
        return true;
    }
    fn lower(self: *Engine, cp: u21) u21 {
        const pairs = self.parsed.value.fold;
        var lo: usize = 0;
        var hi = pairs.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (pairs[mid][0] < cp) lo = mid + 1 else hi = mid;
        }
        return if (lo < pairs.len and pairs[lo][0] == cp) pairs[lo][1] else cp;
    }
    fn fresh(self: *Engine) void {
        self.generation +%= 1;
        if (self.generation == 0) {
            @memset(self.seen, 0);
            self.generation = 1;
        }
    }
    fn add(self: *Engine, p: Program, target: u16, position: usize, length: usize, previous: ?u21, next_cp: ?u21, output: []u16, used: *usize, budget: *usize) error{DetectionBudget}!bool {
        if (self.seen[target] == self.generation) return false;
        self.seen[target] = self.generation;
        self.stack[0] = target;
        var n: usize = 1;
        while (n > 0) {
            if (budget.* == 0) return error.DetectionBudget;
            budget.* -= 1;
            n -= 1;
            const pc = self.stack[n];
            const op = p.instructions[pc];
            if (op.op == .match) return true;
            if (op.op == .char or op.op == .class or op.op == .any) {
                output[used.*] = pc;
                used.* += 1;
                continue;
            }
            const follow = switch (op.op) {
                .begin => position == 0 or (p.multiline and previous != null and previous.? == '\n'),
                .begin_string => position == 0,
                .end => position == length or (p.multiline and next_cp != null and next_cp.? == '\n'),
                .end_string => position == length,
                .boundary => word(previous) != word(next_cp),
                .not_boundary => word(previous) == word(next_cp),
                .split => true,
                else => false,
            };
            if (!follow) continue;
            for ([_]u16{ op.next, if (op.op == .split) op.other else op.next }) |destination| {
                if (self.seen[destination] == self.generation) continue;
                self.seen[destination] = self.generation;
                self.stack[n] = destination;
                n += 1;
            }
        }
        return false;
    }
    pub fn regex(self: *Engine, index: usize, text: []const u8, budget: *usize) error{ DetectionBudget, InvalidDetectionProgram }!bool {
        if (index >= self.parsed.value.programs.len) return error.InvalidDetectionProgram;
        const p = self.parsed.value.programs[index];
        const view = std.unicode.Utf8View.init(text) catch return false;
        var it = view.iterator();
        var previous: ?u21 = null;
        var cp = it.nextCodepoint();
        var current = self.lists[0];
        var next = self.lists[1];
        var used: usize = 0;
        var position: usize = 0;
        self.fresh();
        if (try self.add(p, p.start, 0, text.len, null, cp, current, &used, budget)) return true;
        while (cp) |value| {
            const after = it.i;
            const next_cp = it.nextCodepoint();
            var next_used: usize = 0;
            self.fresh();
            const normalized = if (p.insensitive) self.lower(value) else value;
            for (current[0..used]) |pc| {
                const op = p.instructions[pc];
                const yes = switch (op.op) {
                    .char => normalized == op.cp,
                    .any => p.dotall or value != '\n',
                    .class => accepts(op, normalized),
                    else => false,
                };
                if (yes and try self.add(p, op.next, after, text.len, value, next_cp, next, &next_used, budget)) return true;
            }
            std.mem.swap([]u16, &current, &next);
            used = next_used;
            position = after;
            previous = value;
            cp = next_cp;
            if (try self.add(p, p.start, position, text.len, previous, cp, current, &used, budget)) return true;
        }
        return false;
    }
};
fn word(cp: ?u21) bool {
    const c = cp orelse return false;
    return c == '_' or (c < 128 and std.ascii.isAlphanumeric(@intCast(c)));
}
fn accepts(op: Op, cp: u21) bool {
    var yes = false;
    var lo: usize = 0;
    var hi = op.ranges.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (op.ranges[mid][1] < cp) lo = mid + 1 else hi = mid;
    }
    if (lo < op.ranges.len and op.ranges[lo][0] <= cp) yes = true;
    for (op.categories) |category| yes = yes or switch (category) {
        .digit => cp >= '0' and cp <= '9',
        .not_digit => cp < '0' or cp > '9',
        .word => word(cp),
        .not_word => !word(cp),
        .space => cp < 128 and std.ascii.isWhitespace(@intCast(cp)),
        .not_space => cp >= 128 or !std.ascii.isWhitespace(@intCast(cp)),
    };
    return if (op.invert) !yes else yes;
}
fn contains(text: []const u8, needle: []const u8) bool {
    if (needle.len > text.len) return false;
    for (0..text.len - needle.len + 1) |i| if (std.ascii.eqlIgnoreCase(text[i..][0..needle.len], needle)) return true;
    return false;
}
fn prompt(line: []const u8) bool {
    return std.mem.eql(u8, line, "›") or std.mem.startsWith(u8, line, "› ");
}
fn block(line: []const u8) bool {
    for ([_][]const u8{ "•", "■", "✗", "✓" }) |prefix| if (std.mem.startsWith(u8, line, prefix)) return true;
    return false;
}
fn horizontal(line: []const u8) bool {
    var text = std.mem.trim(u8, line, " \t\r");
    var count: usize = 0;
    while (std.mem.startsWith(u8, text, "─")) {
        text = text["─".len..];
        count += 1;
    }
    return count > 0 and (std.mem.trim(u8, text, " \t\r").len == 0 or count >= 3);
}
fn currentPrompt(lines: []const []const u8) ?usize {
    var index = lines.len;
    while (index > 0) {
        index -= 1;
        if (block(lines[index])) return null;
        if (prompt(lines[index])) return index;
    }
    return null;
}
fn joined(a: A, lines: []const []const u8) ![]const u8 {
    if (lines.len == 0) return "";
    return std.fmt.allocPrint(a, "{s}\n", .{try std.mem.join(a, "\n", lines)});
}
fn counted(spec: []const u8, name: []const u8) ?usize {
    if (!std.mem.startsWith(u8, spec, name) or spec.len <= name.len + 2 or spec[name.len] != '(' or spec[spec.len - 1] != ')') return null;
    const n = std.fmt.parseInt(usize, spec[name.len + 1 .. spec.len - 1], 10) catch return null;
    return if (n > 0) n else null;
}
pub fn region(a: A, input: Input, spec: []const u8) ![]const u8 {
    if (std.mem.eql(u8, spec, "osc_title")) return input.title;
    if (std.mem.eql(u8, spec, "osc_progress")) return input.progress;
    const screen = input.screen;
    if (std.mem.eql(u8, spec, "whole_recent")) return screen;
    var storage: std.ArrayList([]const u8) = .empty;
    const trimmed = if (std.mem.endsWith(u8, screen, "\n")) screen[0 .. screen.len - 1] else screen;
    if (trimmed.len > 0) {
        var it = std.mem.splitScalar(u8, trimmed, '\n');
        while (it.next()) |line| try storage.append(a, line);
    }
    const lines = storage.items;
    if (counted(spec, "bottom_lines")) |n| return joined(a, lines[lines.len -| n..]);
    if (counted(spec, "bottom_non_empty_lines")) |n| {
        var left = n;
        var i = lines.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.trim(u8, lines[i], " \t\r").len > 0) {
                left -= 1;
                if (left == 0) return joined(a, lines[i..]);
            }
        }
        return screen;
    }
    if (counted(spec, "top_non_empty_lines")) |n| {
        var left = n;
        for (lines, 0..) |line, i| if (std.mem.trim(u8, line, " \t\r").len > 0) {
            left -= 1;
            if (left == 0) return joined(a, lines[0 .. i + 1]);
        };
        return joined(a, lines);
    }
    if (std.mem.eql(u8, spec, "after_last_prompt_marker")) {
        var i = lines.len;
        while (i > 0) {
            i -= 1;
            if (prompt(lines[i])) return joined(a, lines[i + 1 ..]);
        }
        return screen;
    }
    if (std.mem.eql(u8, spec, "before_current_prompt_marker")) return if (currentPrompt(lines)) |i| joined(a, lines[0..i]) else screen;
    if (std.mem.eql(u8, spec, "whole_recent_without_current_prompt_marker")) return if (currentPrompt(lines) != null) "" else screen;
    if (std.mem.eql(u8, spec, "current_prompt_block_marker") or std.mem.eql(u8, spec, "after_current_prompt_block_marker")) {
        var i = currentPrompt(lines) orelse return "";
        while (i > 0) {
            i -= 1;
            if (block(lines[i])) return if (std.mem.eql(u8, spec, "current_prompt_block_marker")) lines[i] else joined(a, lines[i..]);
        }
        return "";
    }
    if (std.mem.eql(u8, spec, "after_last_horizontal_rule")) {
        var i = lines.len;
        while (i > 0) {
            i -= 1;
            if (horizontal(lines[i])) return joined(a, lines[i + 1 ..]);
        }
        return screen;
    }
    var top: ?usize = null;
    var found: usize = 0;
    var i = lines.len;
    while (i > 0) {
        i -= 1;
        if (horizontal(lines[i])) {
            found += 1;
            if (found == 2) {
                top = i;
                break;
            }
        }
    }
    if (std.mem.eql(u8, spec, "prompt_box_body")) {
        const start = top orelse return "";
        var end = lines.len;
        for (lines[start + 1 ..], start + 1..) |line, j| if (horizontal(line)) {
            end = j;
            break;
        };
        return joined(a, lines[start + 1 .. end]);
    }
    if (std.mem.eql(u8, spec, "above_prompt_box")) return if (top) |start| joined(a, lines[0..start]) else screen;
    if (std.mem.eql(u8, spec, "last_non_empty_above_prompt_box")) {
        var j = top orelse lines.len;
        while (j > 0) {
            j -= 1;
            if (std.mem.trim(u8, lines[j], " \t\r").len > 0) return lines[j];
        }
        return "";
    }
    return "";
}

test "all Kero agent programs compile; native NFA and regions reproduce upstream fixtures" {
    const a = std.testing.allocator;
    var engine = try Engine.init(a);
    defer engine.deinit();
    for ([_][]const u8{ "claude", "codex", "gemini", "opencode", "amp", "cursor-agent", "droid", "qwen", "copilot", "kiro-cli", "cline", "kimi", "pi" }) |name| try std.testing.expect(engine.known(name));
    try std.testing.expect(!engine.known("bash"));
    try std.testing.expectEqual(State.working, (try engine.detect("kiro-cli", .{ .progress = "4;3" })).state);
    try std.testing.expectEqual(State.idle, (try engine.detect("kiro-cli", .{ .progress = "4;0" })).state);
    try std.testing.expectEqual(State.working, (try engine.detect("claude", .{ .title = "⠐ Probe" })).state);
    const Case = struct { name: []const u8, screen: []const u8, title: []const u8, state: State };
    const cases = try std.json.parseFromSlice([]Case, a, @embedFile("detection_fixtures"), .{});
    defer cases.deinit();
    for (cases.value) |case| {
        const result = try engine.detect("claude", .{ .screen = case.screen, .title = case.title });
        if (result.state != case.state) std.debug.print("Agent fixture {s}: rule {s}\n", .{ case.name, result.rule });
        try std.testing.expectEqual(case.state, result.state);
    }
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const text = "a\n\nb\n───\nbox\n───\nfoot\n";
    try std.testing.expectEqualStrings("box\n", try region(arena.allocator(), .{ .screen = text }, "prompt_box_body"));
    try std.testing.expectEqualStrings("a\n\nb\n", try region(arena.allocator(), .{ .screen = text }, "above_prompt_box"));
    try std.testing.expectEqualStrings("───\nfoot\n", try region(arena.allocator(), .{ .screen = text }, "bottom_non_empty_lines(2)"));
}
