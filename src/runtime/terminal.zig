//! One local terminal owns libghostty-vt state and a bounded PTY input queue.
const std = @import("std");
const ghostty = @import("ghostty-vt");
const proto = @import("model.zig");
const platform = @import("platform.zig");
const Records = @import("status.zig").Records;
pub const Terminal = struct {
    pub const Hooks = struct { ctx: *anyopaque, read: *const fn (*anyopaque, ghostty.clipboard.Read) void, write: *const fn (*anyopaque, ghostty.clipboard.Write) void };
    pub const Notice = struct { title: []const u8, body: []const u8 };
    alloc: std.mem.Allocator,
    terminal: ghostty.Terminal,
    stream: @import("graphics_stream.zig").Stream,
    quota: @import("graphics_quota.zig").Quota,
    graphics: @import("graphics.zig").State = .{},
    render: ghostty.RenderState = .empty,
    interaction: @import("interaction.zig").Interaction = .{},
    records: Records = .{},
    tx: std.ArrayList(u8) = .empty,
    tx_at: usize = 0,
    revision: u64 = 0,
    failed: bool = false,
    command_exit: ?i32 = null,
    at_prompt: bool = true,
    progress: i32 = -1,
    progress_state: u8 = 0,
    dark: ?bool = null,
    theme_stamp: u64 = 0,
    selection_background: ghostty.color.RGB = @import("themes.zig").rgb(0xcfdcfb),
    selection_foreground: ghostty.color.RGB = @import("themes.zig").rgb(0x1d1d1f),
    hooks: ?Hooks = null,
    notices: std.ArrayList(Notice) = .empty,
    bells: u64 = 0,
    pub fn create(a: std.mem.Allocator, io: std.Io, cols: u16, rows: u16, history: usize) !*Terminal {
        const self = try a.create(Terminal);
        errdefer a.destroy(self);
        self.* = .{ .alloc = a, .terminal = undefined, .stream = undefined, .quota = try .init(a, .{ .core_bytes = 160 * 1024 * 1024 }) };
        @import("graphics.zig").installDecoder();
        const native_alloc = self.quota.allocator();
        self.terminal = try ghostty.Terminal.init(io, native_alloc, .{ .cols = cols, .rows = rows, .max_scrollback_bytes = history, .kitty_image_storage_limit = 8 * 1024 * 1024, .kitty_image_loading_limits = .direct });
        errdefer self.terminal.deinit(native_alloc);
        var handler: ghostty.TerminalStream.Handler = .init(&self.terminal);
        handler.effects = .readonly;
        handler.effects.write_pty = reply;
        handler.effects.program_status = report;
        handler.effects.semantic_prompt = semantic;
        handler.effects.progress_report = progressReport;
        handler.effects.size = size;
        handler.effects.clipboard_read = clipboardRead;
        handler.effects.clipboard_write = clipboardWrite;
        handler.effects.desktop_notification = notification;
        handler.effects.bell = bell;
        handler.effects.color_scheme = colorScheme;
        handler.apc_handler.max_bytes.put(.kitty, 4 * 1024 * 1024 * 4 / 3 + 4096);
        self.stream = .init(.{ .handler = .{ .core = handler, .quota = &self.quota }, .allocator = native_alloc });
        self.stream.parser.osc_parser.max_allocating_bytes = 2 * 1024 * 1024;
        return self;
    }
    pub fn destroy(self: *Terminal) void {
        self.interaction.deinit(&self.terminal);
        self.stream.deinit();
        self.render.deinit(self.alloc);
        self.records.deinit(self.alloc);
        self.tx.deinit(self.alloc);
        self.clearNotices();
        self.notices.deinit(self.alloc);
        self.graphics.deinit(self.alloc);
        self.terminal.deinit(self.quota.allocator());
        std.debug.assert(self.quota.used() == 0);
        self.alloc.destroy(self);
    }
    fn owner(h: *ghostty.TerminalStream.Handler) *Terminal {
        return @alignCast(@fieldParentPtr("terminal", h.terminal));
    }
    fn clipboardRead(h: *ghostty.TerminalStream.Handler, request: ghostty.clipboard.Read) void {
        if (owner(h).hooks) |hooks| hooks.read(hooks.ctx, request) else request.reply(.denied);
    }
    fn clipboardWrite(h: *ghostty.TerminalStream.Handler, request: ghostty.clipboard.Write) void {
        if (owner(h).hooks) |hooks| hooks.write(hooks.ctx, request) else request.reply(.denied);
    }
    fn bell(h: *ghostty.TerminalStream.Handler) void {
        owner(h).bells +%= 1;
    }
    fn colorScheme(h: *ghostty.TerminalStream.Handler) ?ghostty.device_status.ColorScheme {
        return if (owner(h).dark orelse false) .dark else .light;
    }
    fn notification(h: *ghostty.TerminalStream.Handler, value: ghostty.StreamAction.ShowDesktopNotification) void {
        const self = owner(h);
        if (self.notices.items.len >= 8 or value.title.len > 512 or value.body.len > 4096) return;
        const title = self.alloc.dupe(u8, value.title) catch return;
        const body = self.alloc.dupe(u8, value.body) catch {
            self.alloc.free(title);
            return;
        };
        self.notices.append(self.alloc, .{ .title = title, .body = body }) catch {
            self.alloc.free(title);
            self.alloc.free(body);
        };
    }
    pub fn clearNotices(self: *Terminal) void {
        for (self.notices.items) |notice| {
            self.alloc.free(notice.title);
            self.alloc.free(notice.body);
        }
        self.notices.clearRetainingCapacity();
    }
    fn reply(h: *ghostty.TerminalStream.Handler, bytes: []const u8) void {
        owner(h).enqueue(bytes, true) catch {
            owner(h).failed = true;
        };
    }
    fn report(h: *ghostty.TerminalStream.Handler, r: ghostty.osc.Command.ProgramStatus.Report) void {
        const self = owner(h);
        self.records.report(self.alloc, r, platform.millis()) catch {
            self.failed = true;
        };
    }
    fn semantic(h: *ghostty.TerminalStream.Handler, event: ghostty.TerminalStream.Handler.SemanticPrompt) void {
        const self = owner(h);
        switch (event.kind) {
            .prompt_start => {
                self.at_prompt = true;
                self.records.dropLive(self.alloc);
            },
            .output_start => {
                self.at_prompt = false;
            },
            .command_end => {
                self.command_exit = event.exit_code;
                self.at_prompt = true;
                self.records.dropLive(self.alloc);
            },
            else => {},
        }
    }
    fn progressReport(h: *ghostty.TerminalStream.Handler, r: ghostty.osc.Command.ProgressReport) void {
        owner(h).progress = if (r.progress) |p| @intCast(p) else -1;
        owner(h).progress_state = @intCast(@backingInt(r.state));
    }
    fn size(h: *ghostty.TerminalStream.Handler) ?ghostty.size_report.Size {
        return .{ .rows = h.terminal.rows, .columns = h.terminal.cols, .cell_width = @intCast(h.terminal.width_px / h.terminal.cols), .cell_height = @intCast(h.terminal.height_px / h.terminal.rows) };
    }
    pub fn enqueue(self: *Terminal, bytes: []const u8, protocol: bool) !void {
        if (self.failed) return error.TerminalFailed;
        const limit: usize = 1024 * 1024 + if (protocol) @as(usize, 65536) else 0;
        if (bytes.len > limit -| (self.tx.items.len - self.tx_at)) return error.InputBackpressure;
        if (self.tx_at > 0) {
            std.mem.copyForwards(u8, self.tx.items, self.tx.items[self.tx_at..]);
            self.tx.items.len -= self.tx_at;
            self.tx_at = 0;
        }
        try self.tx.appendSlice(self.alloc, bytes);
    }
    pub fn feed(self: *Terminal, bytes: []const u8) !void {
        if (self.failed) return error.TerminalFailed;
        const before = self.quota.checkpoint();
        self.stream.nextSlice(bytes);
        if (self.quota.outcome(before) == .fatal) self.failed = true;
        self.revision +%= 1;
        if (self.failed) return error.TerminalFailed;
    }
    pub fn resize(self: *Terminal, cols: u16, rows: u16) !void {
        if (cols < 2 or rows < 2 or cols > 1000 or rows > 1000) return error.InvalidSize;
        try self.stream.handler.resize(.{ .cols = cols, .rows = rows, .cell_size_px = .{ .width = 8, .height = 18 } });
        self.revision +%= 1;
    }
    pub fn applyTheme(self: *Terminal, dark: bool) !void {
        return self.applyColors(@import("themes.zig").builtin(dark), dark);
    }
    pub fn applyColors(self: *Terminal, colors: @import("themes.zig").Colors, dark: bool) !void {
        const stamp = colors.fingerprint();
        if (self.dark != null and self.dark.? == dark and self.theme_stamp == stamp) return;
        const rgb = @import("themes.zig").rgb;
        var palette = self.terminal.colors.palette.original.*;
        for (colors.palette, 0..) |value, i| palette[i] = rgb(value);
        try self.terminal.colors.palette.changeDefault(self.quota.allocator(), palette);
        self.terminal.colors.foreground.default = rgb(colors.foreground);
        self.terminal.colors.background.default = rgb(colors.background);
        self.terminal.colors.cursor.default = rgb(colors.cursor);
        self.selection_background = rgb(colors.selection);
        self.selection_foreground = rgb(colors.selection_text);
        self.terminal.flags.dirty.palette = true;
        self.dark = dark;
        self.theme_stamp = stamp;
        self.revision +%= 1;
    }
    pub fn text(self: *Terminal, a: std.mem.Allocator, all: bool) ![]const u8 {
        if (!all) return self.terminal.screens.active.dumpStringAlloc(a, .{ .viewport = .{} });
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        const fmt: ghostty.formatter.TerminalFormatter = .init(&self.terminal, .{ .emit = .plain });
        try fmt.format(&out.writer);
        return out.toOwnedSlice();
    }
};

test "native VT parses local output, OSC status and retained text" {
    const a = std.testing.allocator;
    const vt = try Terminal.create(a, std.testing.io, 80, 24, 4 * 1024 * 1024);
    defer vt.destroy();
    try vt.feed("hello\r\n\x1b]7501;state=blocked:kind=permission:msg=QXBwcm92ZQ==\x1b\\");
    try std.testing.expectEqualStrings("Approve", vt.records.leading().?.msg);
    const text = try vt.text(a, false);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "hello") != null);
}

test "theme palette reloads retain terminal allocator ownership through teardown" {
    const vt = try Terminal.create(std.testing.allocator, std.testing.io, 80, 24, 4096);
    defer vt.destroy();
    const before = vt.quota.core_used;
    try vt.applyTheme(false);
    try std.testing.expect(vt.quota.core_used > before);
    try vt.applyTheme(true);
    try vt.applyTheme(false);
}

test "OSC status works across chunks and terminal queries stay in local reply queue" {
    const a = std.testing.allocator;
    const vt = try Terminal.create(a, std.testing.io, 80, 24, 4096);
    defer vt.destroy();
    try vt.feed("\x1b]7501;state=blocked:kind=permission:msg=QXBw");
    try std.testing.expect(vt.records.leading() == null);
    try vt.feed("cm92ZQ==\x1b\\\x1b]7501;?\x1b\\");
    try std.testing.expectEqualStrings("Approve", vt.records.leading().?.msg);
    try std.testing.expect(std.mem.indexOf(u8, vt.tx.items, "7501;?") != null);
}

test "terminal input preflight preserves complete queued bytes under backpressure" {
    const a = std.testing.allocator;
    const vt = try Terminal.create(a, std.testing.io, 80, 24, 4096);
    defer vt.destroy();
    const full = try a.alloc(u8, 1024 * 1024);
    defer a.free(full);
    @memset(full, 'x');
    try vt.enqueue(full, false);
    try std.testing.expectError(error.InputBackpressure, vt.enqueue("rejected", false));
    try std.testing.expectEqualSlices(u8, full, vt.tx.items);
    try vt.enqueue("reply", true);
    try std.testing.expectEqual(@as(usize, full.len + 5), vt.tx.items.len);
}

test "Kitty direct RGB, chunked RGBA and PNG reach bounded native textures" {
    const a = std.testing.allocator;
    const vt = try Terminal.create(a, std.testing.io, 20, 5, 4096);
    defer vt.destroy();
    try vt.resize(20, 5);
    try vt.feed("\x1b_Ga=T,f=24,s=1,v=1,i=11,c=2,r=1,C=1;/wAA\x1b\\");
    try vt.render.update(a, &vt.terminal);
    try vt.graphics.prepare(a, &vt.terminal, &vt.render, 8, 18, 1);
    try std.testing.expect(vt.graphics.images.items.len == 1 and vt.graphics.placements.items.len == 1);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, vt.graphics.images.items[0].pixels);
    const generation = vt.graphics.images.items[0].generation;
    try vt.feed("\x1b_Ga=T,f=32,s=1,v=1,i=11,c=2,r=1,C=1,m=1;AP8A\x1b\\\x1b_Gm=0;gA==\x1b\\");
    try vt.render.update(a, &vt.terminal);
    try vt.graphics.prepare(a, &vt.terminal, &vt.render, 8, 18, 1);
    try std.testing.expect(vt.graphics.images.items[0].generation != generation);
    try std.testing.expectEqualSlices(u8, &.{ 0, 128, 0, 128 }, vt.graphics.images.items[0].pixels);
    try vt.feed("\x1b_Ga=T,f=100,i=12,c=1,r=1,C=1;iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==\x1b\\");
    try std.testing.expect(vt.terminal.screens.active.kitty_images.imageById(12) != null);
    try vt.feed("\x1b_Ga=d,d=A\x1b\\");
    try vt.render.update(a, &vt.terminal);
    try vt.graphics.prepare(a, &vt.terminal, &vt.render, 8, 18, 1);
    try std.testing.expect(vt.graphics.images.items.len == 0 and vt.graphics.bytes == 0);
}
test "Kitty file media and quota exhaustion leave ordinary terminal output usable" {
    const a = std.testing.allocator;
    // Keep the recovery marker on one row: text(false) preserves visual wraps.
    const vt = try Terminal.create(a, std.testing.io, 40, 5, 4096);
    defer vt.destroy();
    try vt.feed("\x1b_Ga=T,t=f,f=24,s=1,v=1,i=90;L2V0Yy9wYXNzd2Q=\x1b\\");
    try std.testing.expect(vt.terminal.screens.active.kitty_images.imageById(90) == null);
    try vt.quota.reconfigure(.{ .core_bytes = 160 * 1024 * 1024, .graphics_bytes = @max(4096, vt.quota.graphics_used + 4096) });
    try vt.feed("\x1b_Ga=T,f=100,i=12;iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==\x1b\\AFTER_REJECT");
    const text = try vt.text(a, false);
    defer a.free(text);
    try std.testing.expect(vt.quota.soft_rejections > 0);
    try std.testing.expect(!vt.failed);
    try std.testing.expect(vt.terminal.screens.active.kitty_images.loading == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "AFTER_REJECT") != null);
}

test "Kitty Unicode placeholders use native source rectangles and alternate-screen ownership" {
    const a = std.testing.allocator;
    const vt = try Terminal.create(a, std.testing.io, 20, 5, 4096);
    defer vt.destroy();
    try vt.resize(20, 5);
    vt.terminal.modes.set(.grapheme_cluster, true);
    try vt.feed("\x1b_Ga=T,f=24,s=1,v=1,i=1,p=1,U=1,c=2,r=2;/wAA\x1b\\\x1b[38;5;1m\x1b[58;5;1m\u{10EEEE}\u{0305}\u{0305}\u{10EEEE}\x1b[0m");
    try vt.render.update(a, &vt.terminal);
    try vt.graphics.prepare(a, &vt.terminal, &vt.render, 8, 18, 1);
    try std.testing.expect(vt.graphics.placements.items.len > 0 and vt.graphics.images.items.len == 1);
    try vt.feed("\x1b[?1049h");
    try vt.render.update(a, &vt.terminal);
    try vt.graphics.prepare(a, &vt.terminal, &vt.render, 8, 18, 1);
    try std.testing.expectEqual(@as(usize, 0), vt.graphics.images.items.len);
    try vt.feed("\x1b[?1049l");
    try vt.render.update(a, &vt.terminal);
    try vt.graphics.prepare(a, &vt.terminal, &vt.render, 8, 18, 1);
    try std.testing.expect(vt.graphics.images.items.len == 1);
}

test "Kitty physical pixels map once to logical cells on high-DPI displays" {
    const a = std.testing.allocator;
    const vt = try Terminal.create(a, std.testing.io, 20, 5, 4096);
    defer vt.destroy();
    try vt.stream.handler.resize(.{ .cols = 20, .rows = 5, .cell_size_px = .{ .width = 16, .height = 36 } });
    try vt.feed("\x1b[2;3H\x1b_Ga=T,f=24,s=1,v=1,i=1,c=2,r=1,X=2,Y=3,C=1;/wAA\x1b\\");
    try vt.render.update(a, &vt.terminal);
    try vt.graphics.prepare(a, &vt.terminal, &vt.render, 8, 18, 2);
    try std.testing.expectEqual(@as(usize, 1), vt.graphics.placements.items.len);
    const placed = vt.graphics.placements.items[0];
    try std.testing.expectEqual(@as(f32, 17), placed.x);
    try std.testing.expectEqual(@as(f32, 19.5), placed.y);
    try std.testing.expectEqual(@as(f32, 15), placed.width);
    try std.testing.expectEqual(@as(f32, 16.5), placed.height);
    try std.testing.expectError(error.InvalidPixelScale, vt.graphics.prepare(a, &vt.terminal, &vt.render, 8, 18, 0));
}
test "replacing one Kitty image retains unchanged renderer-owned pixel copies" {
    const a = std.testing.allocator;
    const vt = try Terminal.create(a, std.testing.io, 20, 5, 4096);
    defer vt.destroy();
    try vt.resize(20, 5);
    try vt.feed("\x1b_Ga=T,f=24,s=1,v=1,i=1,C=1;/wAA\x1b\\\x1b[2;1H\x1b_Ga=T,f=24,s=1,v=1,i=2,C=1;AP8A\x1b\\");
    try vt.render.update(a, &vt.terminal);
    try vt.graphics.prepare(a, &vt.terminal, &vt.render, 8, 18, 1);
    var retained: ?[*]const u8 = null;
    for (vt.graphics.images.items) |image_| if (image_.id == 2) {
        retained = image_.pixels.ptr;
    };
    try std.testing.expect(retained != null);
    try vt.feed("\x1b[1;1H\x1b_Ga=T,f=24,s=1,v=1,i=1,C=1;AAD/\x1b\\");
    try vt.render.update(a, &vt.terminal);
    try vt.graphics.prepare(a, &vt.terminal, &vt.render, 8, 18, 1);
    var unchanged = false;
    for (vt.graphics.images.items) |image_| if (image_.id == 2) {
        unchanged = image_.pixels.ptr == retained.?;
    };
    try std.testing.expect(unchanged);
}

test "native Kitty animation schedules visible frames and sleeps when scrolled away" {
    const a = std.testing.allocator;
    const vt = try Terminal.create(a, std.testing.io, 20, 5, 4096);
    defer vt.destroy();
    try vt.resize(20, 5);
    try vt.feed("\x1b_Ga=T,f=24,s=1,v=1,i=1,c=2,r=1,C=1;/wAA\x1b\\\x1b_Ga=f,i=1,f=24,s=1,v=1,z=50;AAD/\x1b\\\x1b_Ga=a,i=1,r=1,z=50,s=3\x1b\\");
    try vt.render.update(a, &vt.terminal);
    try vt.graphics.prepare(a, &vt.terminal, &vt.render, 8, 18, 1);
    try std.testing.expectEqual(@as(?u64, 50), vt.graphics.tick(&vt.terminal, 100));
    const generation = vt.terminal.screens.active.kitty_images.imageById(1).?.generation;
    try std.testing.expectEqual(@as(?u64, 50), vt.graphics.tick(&vt.terminal, 150));
    try std.testing.expect(vt.terminal.screens.active.kitty_images.imageById(1).?.generation != generation);
    try vt.render.update(a, &vt.terminal);
    try vt.graphics.prepare(a, &vt.terminal, &vt.render, 8, 18, 1);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, vt.graphics.images.items[0].pixels);
    try vt.feed("\r\nline\r\nline\r\nline\r\nline\r\nline\r\nline");
    try vt.render.update(a, &vt.terminal);
    try vt.graphics.prepare(a, &vt.terminal, &vt.render, 8, 18, 1);
    try std.testing.expectEqual(@as(?u64, null), vt.graphics.tick(&vt.terminal, 200));
    try std.testing.expect(vt.terminal.screens.active.kitty_images.imageById(1) != null);
}
