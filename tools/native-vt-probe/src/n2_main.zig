//! Isolated host fixture for the real N2 leaf adapters; not a production
//! Context substitute. Root facade replay remains the integration gate.
const std = @import("std");
const ghostty = @import("ghostty-vt");
const adapters = @import("native-adapters");
const selection = adapters.selection;
const search = adapters.search;
const navigation = adapters.navigation;
const Info = struct { total: usize = 0, current: usize = 0, running: bool = false };
const Scroll = struct { total: u64 = 0, offset: u64 = 0, len: u64 = 0, alternate: bool = false };
var checks: usize = 0;
fn check(ok: bool, name: []const u8) !void {
    std.debug.print("{s}: {s}\n", .{ if (ok) "PASS" else "FAIL", name });
    if (!ok) return error.N2Check;
    checks += 1;
}

const Host = struct {
    gpa: std.mem.Allocator,
    terminal: ghostty.Terminal,
    stream: ghostty.TerminalStream,
    selection_state: selection.State = .{},
    search_state: search.State = .{},
    revision: u64 = 0,
    fatal: ?anyerror = null,
    // Deterministic regression hook for failures first discovered by leave,
    // independent of native allocator implementation or allocation sizes.
    leave_failure: ?anyerror = null,
    busy: bool = false,
    mouse_last_cell: ?ghostty.point.Coordinate = null,
    event_snapshot: struct { at_prompt: bool = false, progress_state: c_int = 0 } = .{},
    fn create(io: std.Io, gpa: std.mem.Allocator, cols: u16, rows: u16) !*Host {
        const self = try gpa.create(Host);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .terminal = try .init(io, gpa, .{ .cols = cols, .rows = rows, .max_scrollback_bytes = 2 * 1024 * 1024, .max_scrollback_lines = 100000 }), .stream = undefined };
        self.stream = self.terminal.vtStream();
        return self;
    }
    fn destroy(self: *Host) void {
        self.stream.deinit();
        self.selection_state.deinit(&self.terminal);
        self.search_state.deinit(&self.terminal);
        self.terminal.deinit(self.gpa);
        self.gpa.destroy(self);
    }
    pub fn enter(self: *Host) bool {
        if (self.busy or self.fatal != null) return false;
        self.busy = true;
        return true;
    }
    pub fn leave(self: *Host) void {
        if (self.stream.handler.semantic_failure) self.fail(error.SemanticFailure);
        if (self.leave_failure) |err| {
            self.leave_failure = null;
            self.fail(err);
        }
        self.busy = false;
    }
    pub fn fail(self: *Host, err: anyerror) void {
        self.fatal = err;
    }
    pub fn changed(self: *Host) void {
        self.revision +%= 1;
    }
    fn feed(self: *Host, bytes: []const u8) !void {
        self.stream.nextSlice(bytes);
        self.changed();
        if (self.stream.handler.semantic_failure) return error.SemanticFailure;
    }
    fn finish(self: *Host) !usize {
        var total: usize = 0;
        for (0..10000) |_| {
            const result = search.tick(self, &total);
            if (result < 0) return self.search_state.last_error orelse error.SearchTick;
            if (result == 0) return total;
        }
        return error.SearchNeverCompleted;
    }
    fn prepare(self: *Host) !void {
        if (!self.enter()) return error.ContextBusy;
        defer self.leave();
        selection.validateLocked(self);
        try search.prepareLocked(self);
    }
};
fn copied(self: *Host, buffer: []u8) ![]const u8 {
    var length: usize = 0;
    if (selection.copy(self, buffer.ptr, buffer.len, &length) != 0) return error.Copy;
    return buffer[0..length];
}
pub fn main(init: std.process.Init) !void {
    var dpa: std.heap.DebugAllocator(.{}) = .init;
    const gpa = dpa.allocator();
    try selectionChecks(init.io, gpa);
    try searchChecks(init.io, gpa);
    try lifecycleChecks(init.io, gpa);
    try failureChecks(init.io, gpa);
    try leaveChecks(init.io, gpa);
    try check(dpa.deinit() == .ok, "all N2 states, search results and tracked pins release without leaks");
    std.debug.print("{{\"suite\":\"native-vt-n2-leaves\",\"checks\":{d},\"status\":\"pass\",\"backend\":\"isolated native Zig adapters\",\"scope\":\"root facade integration and shell clear redraw still require separate acceptance\"}}\n", .{checks});
}

fn selectionChecks(io: std.Io, gpa: std.mem.Allocator) !void {
    const self = try Host.create(io, gpa, 16, 4);
    defer self.destroy();
    try self.feed("alpha 中é beta\r\nsecond row");
    selection.select(self, 6, 0, 0);
    selection.select(self, 8, 0, 1);
    var text: [4096]u8 = undefined;
    try check(std.mem.eql(u8, try copied(self, &text), "中é"), "inclusive cell drag copies CJK and combining cluster exactly");
    selection.select(self, 2, 0, 2);
    try check(std.mem.eql(u8, try copied(self, &text), "alpha"), "word click uses native boundary semantics");
    selection.select(self, 12, 0, 1);
    try check(std.mem.eql(u8, try copied(self, &text), "alpha 中é beta"), "word drag expands to complete native words");
    selection.select(self, 2, 0, 3);
    try check(std.mem.eql(u8, try copied(self, &text), "alpha 中é beta"), "line click trims written line using native formatter");
    var too_small: [2]u8 = undefined;
    var len: usize = 99;
    try check(selection.copy(self, &too_small, too_small.len, &len) != 0 and len == 0, "small clipboard buffer never reports partial success");
    selection.clear(self);
    try check(!selection.has(self) and self.selection_state.anchor == null, "clear selection releases tracked anchor");
    navigation.reset(self);
    try self.stream.handler.resize(.{ .cols = 6, .rows = 4 });
    self.changed();
    try self.feed("a_soft_wrapped_line");
    try check(selection.all(self) == 0 and std.mem.eql(u8, try copied(self, &text), "a_soft_wrapped_line"), "select-all copy unwraps soft rows without a text mirror");
}

fn searchChecks(io: std.Io, gpa: std.mem.Allocator) !void {
    const self = try Host.create(io, gpa, 16, 4);
    defer self.destroy();
    for (0..40) |_| try self.feed("hit 中é hit\r\n");
    try check(selection.all(self) == 0, "native ordinary selection covers scrollback");
    var before: [4096]u8 = undefined;
    const before_text = try copied(self, &before);
    try check(search.set(self, "hit", 3) == 0 and try self.finish() == 80, "incremental native search finds all active/history matches");
    var info: Info = .{};
    search.info(self, &info);
    try check(info.total == 80 and info.current > 0 and info.current <= info.total and !info.running, "search reports total and one-based selected index");
    try self.prepare();
    var matched: usize = 0;
    var current: usize = 0;
    for (0..self.terminal.rows) |y| for (0..self.terminal.cols) |x| {
        const flag = search.flags(self, x, y);
        if (flag & 32 != 0) matched += 1;
        if (flag & 64 != 0) current += 1;
    };
    try check(matched > current and current > 0, "viewport-only mask separates all matches and current match");
    search.next(self, true);
    _ = try self.finish();
    var after: [4096]u8 = undefined;
    try check(std.mem.eql(u8, before_text, try copied(self, &after)), "search navigation never replaces ordinary terminal selection");
    search.close(self);
    try check(selection.has(self) and self.search_state.audit.live == 0, "search close preserves normal selection and releases all search memory");
    try check(search.set(self, "中é", "中é".len) == 0 and try self.finish() == 40, "wide and combining search counts real grapheme matches");
    try self.prepare();
    matched = 0;
    for (0..self.terminal.rows) |y| for (0..self.terminal.cols) |x| if (search.flags(self, x, y) & 32 != 0) {
        matched += 1;
    };
    try check(matched >= 2, "wide and combining matches reach visible cell mask");
    const revision = self.revision;
    _ = try self.finish();
    try check(self.revision == revision, "completed unchanged search does not dirty idle frames");
    try check(search.set(self, "hit", 3) == 0 and try self.finish() == 80, "replacement query restarts actual search transaction");
    try self.feed("new hit\r\n");
    try check(try self.finish() == 81, "new output invalidates completed search once");
    try self.stream.handler.resize(.{ .cols = 13, .rows = 3 });
    self.changed();
    try check(try self.finish() == 81, "resize and reflow rebuild native search without stale page pointers");
    try self.feed("\x1b[?1049h\x1b[Hhit ALT");
    try check(try self.finish() == 1, "alternate screen has isolated search result set");
    try self.feed("\x1b[?1049l");
    try check(try self.finish() == 81, "primary search results reconcile after alternate return");
    try check(search.set(self, "\xff", 1) != 0 and std.mem.eql(u8, self.search_state.engine.?.needle(), "hit"), "invalid UTF8 query cannot partially replace accepted query");
    navigation.scrollTo(self, 0);
    var bar: Scroll = .{};
    navigation.scrollInfo(self, &bar);
    try check(bar.offset == 0, "absolute native history scroll reaches first row");
    try self.feed("background\r\n");
    navigation.scrollInfo(self, &bar);
    try check(bar.offset == 0, "background output preserves historical viewport");
    navigation.scrollTo(self, std.math.maxInt(u64));
    navigation.scrollInfo(self, &bar);
    try check(bar.offset + bar.len == bar.total, "absolute native history scroll clamps at active bottom");
    try self.feed("\x1b[?2004h");
    try check(navigation.clearScreen(self) == 0 and self.terminal.modes.get(.bracketed_paste), "clear-screen preserves modes and differs from reset");
    navigation.scrollInfo(self, &bar);
    try check(bar.total == bar.len and !selection.has(self) and try self.finish() == 0, "clear-screen trims history and invalidates selection/search highlights");
    navigation.reset(self);
    try check(!self.terminal.modes.get(.bracketed_paste) and self.terminal.rows == 3 and self.search_state.engine == null and self.search_state.audit.live == 0, "full reset drops search, releases resources and preserves dimensions");
}

fn lifecycleChecks(io: std.Io, gpa: std.mem.Allocator) !void {
    // Standard page capacity at 215 columns ensures this workload really
    // crosses historical page boundaries; narrow pages can retain 3000 rows.
    const self = try Host.create(io, gpa, 215, 3);
    defer self.destroy();
    for (0..40) |_| try self.feed("old line\r\n");
    navigation.scrollTo(self, 0);
    selection.select(self, 0, 0, 0);
    self.terminal.setScrollbackMaxLines(4);
    self.terminal.setScrollbackMaxBytes(65536);
    for (0..3000) |_| try self.feed("trim\r\n");
    try check(self.selection_state.anchor.?.garbage, "pruning workload actually retires the anchored native page");
    selection.select(self, 3, 0, 1);
    try check(self.selection_state.anchor == null, "history pruning invalidates tracked drag anchor safely");
    selection.select(self, 0, 0, 0);
    try self.feed("\x1b[?1049h\x1b[Halternate");
    selection.select(self, 2, 0, 1);
    try check(self.selection_state.anchor == null, "screen generation/active key prevents cross-screen drag");
    try check(navigation.clearScreen(self) != 0, "alternate clear-screen is explicitly rejected");
    try self.feed("\x1b[?1049l\x1b]133;A\x07$ \x1b]133;B\x07");
    try check(navigation.promptClearPlan(self) == .shell_form_feed_required, "prompt-preserving clear is identified as an unvalidated shell redraw transaction");
    for (0..30) |_| try self.feed("\x1b]133;C\x07x\r\n\x1b]133;D;0\x07\x1b]133;A\x07$ \x1b]133;B\x07");
    navigation.bottom(self);
    var before: Scroll = .{};
    navigation.scrollInfo(self, &before);
    navigation.promptJump(self, -1);
    var after: Scroll = .{};
    navigation.scrollInfo(self, &after);
    try check(after.offset < before.offset, "prompt jump uses native semantic rows");
}

fn failureChecks(io: std.Io, gpa: std.mem.Allocator) !void {
    const self = try Host.create(io, gpa, 20, 4);
    defer self.destroy();
    try self.feed("hit hit hit");
    self.search_state.audit.limit = 1;
    try check(search.set(self, "hit", 3) < 0 and (self.search_state.last_error orelse error.NoSearchError) == error.SearchMemoryLimit and self.search_state.audit.live == 0, "query allocation quota failure is explicit and leak-free");
    self.search_state.audit.limit = search.max_search_bytes;
    try check(search.set(self, "hit", 3) == 0 and try self.finish() == 3, "new accepted query recovers after a quota failure");
    search.close(self);
    try check(search.set(self, "hit", 3) == 0, "query setup succeeds before deliberate feed quota exhaustion");
    self.search_state.audit.limit = self.search_state.audit.live;
    var total: usize = 99;
    try check(search.tick(self, &total) < 0 and total == 0 and (self.search_state.last_error orelse error.NoSearchError) == error.SearchMemoryLimit and self.fatal == null, "upstream swallowed feed OOM is exposed as failed search without killing VT");
    search.close(self);
    self.search_state.audit.limit = search.max_search_bytes;
    try check(self.search_state.audit.live == 0, "closing failed search releases partially initialized native state");
}

fn leaveChecks(io: std.Io, gpa: std.mem.Allocator) !void {
    const Operation = enum { select_all, copy, query, empty_query, tick, clear_screen };
    inline for (std.enums.values(Operation)) |operation| {
        const self = try Host.create(io, gpa, 20, 4);
        defer self.destroy();
        try self.feed("hit hit");
        if (selection.all(self) != 0 or search.set(self, "hit", 3) != 0) return error.FixtureSetup;
        _ = try self.finish();
        self.leave_failure = error.InjectedLeaveFailure;
        var buffer: [64]u8 = undefined;
        var output_len: usize = 77;
        const result = switch (operation) {
            .select_all => selection.all(self),
            .copy => selection.copy(self, &buffer, buffer.len, &output_len),
            .query => search.set(self, "hit", 3),
            .empty_query => search.set(self, "", 0),
            .tick => search.tick(self, &output_len),
            .clear_screen => navigation.clearScreen(self),
        };
        try check(result < 0 and !self.busy and
            (self.fatal orelse error.NoFailure) == error.InjectedLeaveFailure and
            (operation != .copy and operation != .tick or output_len == 0), @tagName(operation) ++ " exposes failure discovered during leave before returning success");
    }
}
