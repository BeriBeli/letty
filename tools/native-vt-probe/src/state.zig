const std = @import("std");
pub const vt = @import("ghostty-vt");
const Handler = vt.TerminalStream.Handler;
pub const Teardown = struct { stages: [2]u8 = undefined, len: u8 = 0 };

/// Allocated before either Terminal or Stream is initialized; never moved.
/// The handler only resolves its stable terminal field back to this owner.
pub const Probe = struct {
    allocator: std.mem.Allocator,
    terminal: vt.Terminal,
    stream: vt.TerminalStream,
    replies: [4096]u8 = @splat(0),
    reply_len: usize = 0,
    reply_calls: usize = 0,
    reply_limit: usize = 4096,
    reply_overflow: bool = false,
    bells: usize = 0,
    title_changes: usize = 0,
    title: [256]u8 = @splat(0),
    title_len: usize = 0,
    pwd_changes: usize = 0,
    pwd: [4096]u8 = @splat(0),
    pwd_len: usize = 0,
    progress_changes: usize = 0,
    progress: ?u8 = null,
    progress_state: vt.osc.Command.ProgressReport.State = .remove,
    semantic_count: usize = 0,
    semantic_kinds: [16]vt.SemanticPrompt.Kind = undefined,
    exit_code: ?i32 = null,
    command: [256]u8 = @splat(0),
    command_len: usize = 0,
    callback_overflow: bool = false,

    pub fn create(io: std.Io, allocator: std.mem.Allocator, cols: u16, rows: u16, install_effects: bool) !*Probe {
        const self = try allocator.create(Probe);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .terminal = try .init(io, allocator, .{ .cols = cols, .rows = rows, .max_scrollback_bytes = 1024 * 1024, .max_scrollback_lines = 4096 }), .stream = undefined };
        self.stream = self.terminal.vtStream();
        if (install_effects) {
            // readonly is deliberately the starting point. Install every
            // supported host effect explicitly; no callbacks re-enter feed.
            var effects: Handler.Effects = .readonly;
            effects.write_pty = writePty;
            effects.bell = bell;
            effects.title_changed = onTitle;
            effects.pwd_changed = onPwd;
            effects.progress_report = onProgress;
            effects.semantic_prompt = semantic;
            effects.size = size;
            self.stream.handler.effects = effects;
        }
        return self;
    }
    pub fn destroy(self: *Probe, report: ?*Teardown) void {
        // Handler.deinit still needs its terminal allocator and state.
        self.stream.deinit();
        if (report) |r| {
            r.stages[r.len] = 's';
            r.len += 1;
        }
        self.terminal.deinit(self.allocator);
        if (report) |r| {
            r.stages[r.len] = 't';
            r.len += 1;
        }
        self.allocator.destroy(self);
    }
    pub fn feed(self: *Probe, bytes: []const u8) !void {
        self.stream.nextSlice(bytes);
        if (self.stream.handler.semantic_failure) return error.SemanticFailure;
        if (self.reply_overflow or self.callback_overflow) return error.CallbackCapacityExceeded;
    }
    pub fn resetReplies(self: *Probe) void {
        self.reply_len = 0;
        self.reply_calls = 0;
        self.reply_overflow = false;
    }
    pub fn response(self: *const Probe) []const u8 {
        return self.replies[0..self.reply_len];
    }
    pub fn text(self: *Probe) ![]const u8 {
        const value = try self.terminal.plainString(self.allocator);
        return value;
    }
    pub fn focus(self: *const Probe, event: vt.input.FocusEvent, writer: *std.Io.Writer) !void {
        if (self.terminal.modes.get(.focus_event)) try vt.input.encodeFocus(writer, event);
    }
    fn owner(handler: *Handler) *Probe {
        return @fieldParentPtr("terminal", handler.terminal);
    }
    fn writePty(handler: *Handler, bytes: []const u8) void {
        const self = owner(handler);
        self.reply_calls += 1;
        if (bytes.len > self.reply_limit - self.reply_len) {
            self.reply_overflow = true;
            return;
        }
        @memcpy(self.replies[self.reply_len..][0..bytes.len], bytes);
        self.reply_len += bytes.len;
    }
    fn bell(handler: *Handler) void {
        owner(handler).bells += 1;
    }
    fn onTitle(handler: *Handler) void {
        const self = owner(handler);
        self.title_changes += 1;
        const bytes = handler.terminal.getTitle() orelse "";
        if (bytes.len > self.title.len) {
            self.callback_overflow = true;
            return;
        }
        @memcpy(self.title[0..bytes.len], bytes);
        self.title_len = bytes.len;
    }
    fn onPwd(handler: *Handler) void {
        const self = owner(handler);
        self.pwd_changes += 1;
        const bytes = handler.terminal.getPwd() orelse "";
        if (bytes.len > self.pwd.len) {
            self.callback_overflow = true;
            return;
        }
        @memcpy(self.pwd[0..bytes.len], bytes);
        self.pwd_len = bytes.len;
    }
    fn onProgress(handler: *Handler, value: vt.osc.Command.ProgressReport) void {
        const self = owner(handler);
        self.progress_changes += 1;
        self.progress = value.progress;
        self.progress_state = value.state;
    }
    fn semantic(handler: *Handler, event: vt.SemanticPrompt) void {
        const self = owner(handler);
        if (self.semantic_count == self.semantic_kinds.len or event.command.len > self.command.len) {
            self.callback_overflow = true;
            return;
        }
        self.semantic_kinds[self.semantic_count] = event.kind;
        self.semantic_count += 1;
        if (event.kind == .command_end) self.exit_code = event.exit_code;
        if (event.command.len > 0) {
            @memcpy(self.command[0..event.command.len], event.command);
            self.command_len = event.command.len;
        }
    }
    fn size(handler: *Handler) ?vt.size_report.Size {
        return .{ .columns = handler.terminal.cols, .rows = handler.terminal.rows, .cell_width = 9, .cell_height = 18 };
    }
};
