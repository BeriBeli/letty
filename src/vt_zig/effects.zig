//! Native callbacks never recursively feed or mutate the VT. Metadata is copied
//! into Context-owned buffers; PTY reply bytes retain the old borrowed-callback
//! contract and must be synchronously copied into the caller's bounded queue.
const ghostty = @import("ghostty-vt");
const Context = @import("context.zig").Context;
const Handler = ghostty.TerminalStream.Handler;
fn owner(handler: *Handler) *Context {
    // Terminal was placed in the heap Context before stream creation.
    return @alignCast(@fieldParentPtr("terminal", handler.terminal));
}
pub fn install(self: *Context) void {
    self.stream.handler.core.effects = .readonly;
    const e = &self.stream.handler.core.effects;
    e.write_pty = writePty;
    e.bell = bell;
    e.title_changed = title;
    e.pwd_changed = pwd;
    e.progress_report = progress;
    e.semantic_prompt = semantic;
    e.reset = reset;
    e.size = size;
    e.device_attributes = attributes;
    // Clipboard reads/writes, desktop notifications and window resize remain
    // explicitly absent until their host policies are connected in N2.
}
fn writePty(handler: *Handler, bytes: []const u8) void {
    const self = owner(handler);
    if (self.fatal != null or bytes.len == 0) return;
    self.reply(self.reply_context, bytes.ptr, bytes.len);
}
fn bell(handler: *Handler) void {
    owner(handler).event_snapshot.bells +%= 1;
}
fn title(handler: *Handler) void {
    const self = owner(handler);
    self.copyMetadata(.title, handler.terminal.getTitle() orelse "");
}
fn pwd(handler: *Handler) void {
    const self = owner(handler);
    self.copyMetadata(.pwd, handler.terminal.getPwd() orelse "");
    self.event_snapshot.pwd +%= 1;
}
fn progress(handler: *Handler, report: ghostty.osc.Command.ProgressReport) void {
    const snapshot = &owner(handler).event_snapshot;
    snapshot.progress_state = @intCast(@backingInt(report.state));
    snapshot.progress = if (report.progress) |value| @intCast(value) else -1;
}
fn semantic(handler: *Handler, report: Handler.SemanticPrompt) void {
    const snapshot = &owner(handler).event_snapshot;
    switch (report.kind) {
        .prompt_start => if (report.prompt_kind == .primary) {
            snapshot.prompts +%= 1;
            snapshot.at_prompt = true;
        },
        .output_start => {
            snapshot.starts +%= 1;
            snapshot.at_prompt = false;
        },
        .command_end => {
            snapshot.ends +%= 1;
            snapshot.exit_code = report.exit_code orelse 0;
            snapshot.has_exit = report.exit_code != null;
        },
        else => {},
    }
}
fn reset(handler: *Handler) void {
    const self = owner(handler);
    // Native storage generations may restart on RIS. This host identity makes
    // the renderer discard keys even when an image ID/revision is reused.
    self.graphics_epoch +%= 1;
    self.title.len = 0;
    self.pwd.len = 0;
    self.title_truncated = false;
    self.pwd_overflow = false;
    // Keep event counter semantics aligned with the old bridge; explicit host
    // reset clears at_prompt in context.reset before parsing RIS.
}
fn size(handler: *Handler) ?ghostty.size_report.Size {
    const self = owner(handler);
    return .{ .rows = self.terminal.rows, .columns = self.terminal.cols, .cell_width = self.cell_width, .cell_height = self.cell_height };
}
fn attributes(_: *Handler) ghostty.device_attributes.Attributes {
    return .{};
}
