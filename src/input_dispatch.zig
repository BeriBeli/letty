//! Window-owned binding state, one-shot deadlines and admitted PTY broadcasts.
const std = @import("std");
const nano = @import("nanoui");
const ui = nano.ui;
const keys = @import("keybindings.zig");
const dispatch = @import("binding_dispatch.zig");
const sequence = @import("binding_sequence.zig");
const c = @import("platform_ffi.zig");
const TerminalView = @import("terminal_view.zig").View;
const Session = @import("session.zig").Session;
const Request = @import("actions.zig").Request;

pub fn cancel(s: anytype, reason: sequence.CancelReason) void {
    _ = s.binding_state.cancel(reason);
    if (s.binding_timer_pending) {
        s.binding_timer_pending = false;
        const handle = s.binding_timer;
        s.binding_timer = .{};
        handle.cancel();
        s.release();
    }
}
fn composing(s: anytype, ctx: *ui.Context) bool {
    return @import("application_preview.zig").composing(s, ctx);
}
fn guard(s: anytype, ctx: ?*ui.Context) sequence.Guard {
    return .{ .focused = s.window_focused, .modal = s.modalOpen(), .editing = s.search_open or @import("application_preview.zig").focused(s), .ime = if (ctx) |value| composing(s, value) else s.views[s.layout.active_pane].preedit.items.len > 0 };
}
fn queue(s: anytype, result: dispatch.Result) void {
    const request = result.request orelse return;
    if (result.scope == .all) {
        broadcast(s, request);
    } else if (s.menu_action_count < s.menu_actions.len) {
        s.menu_actions[s.menu_action_count] = request;
        s.menu_action_count += 1;
    } else s.status = "Too many pending commands";
    if (s.window) |window| window.redraw();
}
fn timer(comptime Window: type, data: ?*anyopaque) void {
    const s: *Window = @ptrCast(@alignCast(data.?));
    s.binding_timer_pending = false;
    const handle = s.binding_timer;
    s.binding_timer = .{};
    handle.fired();
    defer s.release();
    if (s.host_deinitialized or s.closing or s.deinitialized) return;
    const result = s.binding_state.timeout(s.cfg.keybinds, s.cfg.clear_default_keybinds, c.lt_millis(), guard(s, null), .{ .active = s.binding_capabilities }) catch {
        cancel(s, .reload);
        return;
    };
    queue(s, result);
    arm(s);
}
fn arm(s: anytype) void {
    if (!s.binding_state.active()) {
        cancel(s, .timeout);
        return;
    }
    if (s.binding_timer_pending) return;
    const deadline = s.binding_state.matcher.deadline_ms orelse return;
    s.binding_timer = @import("one_shot.zig").start(@max(1, deadline -| c.lt_millis()), s, struct {
        fn call(data: ?*anyopaque) callconv(.c) void {
            timer(@TypeOf(s.*), data);
        }
    }.call) catch {
        _ = s.binding_state.cancel(.timeout);
        s.status = "Cannot schedule key sequence deadline";
        return;
    };
    s.binding_timer_pending = true;
    s.retain();
}
pub fn broadcast(s: anytype, request: Request) void {
    if (request.action != .send_bytes or request.args != .bytes) {
        s.status = "Broadcast currently supports text/csi/esc actions";
        return;
    }
    const bytes = request.args.bytes.bytes();
    var scratch = std.heap.ArenaAllocator.init(s.gpa);
    defer scratch.deinit();
    const targets = scratch.allocator().alloc(dispatch.Target, s.host.paneCount()) catch {
        s.status = "Cannot allocate broadcast";
        return;
    };
    const sessions = scratch.allocator().alloc(*Session, targets.len) catch {
        s.status = "Cannot allocate broadcast";
        return;
    };
    var count: usize = 0;
    for (s.host.windows) |entry| if (entry) |window| if (!window.closing) {
        for (window.sessions) |opt| if (opt) |session| {
            if (session.eof or session.fatal) continue;
            targets[count] = .{ .id = session.id, .ready = session.canSend(bytes.len) };
            sessions[count] = session;
            count += 1;
        };
    };
    const plan = dispatch.planAll(targets[0..count], request) catch {
        s.status = "Broadcast rejected: a target input queue is busy; no bytes admitted";
        return;
    };
    defer std.heap.page_allocator.free(plan.ids);
    if (plan.len == 0) {
        s.status = "No live terminal for broadcast";
        return;
    }
    // No event-loop yield or PTY write between admission checks and enqueue.
    for (sessions[0..count], plan.ids[0..plan.len]) |session, id| {
        std.debug.assert(session.id == id);
        if (!session.enqueue(bytes)) unreachable;
    }
    for (sessions[0..count]) |session| session.flush();
}
fn apply(s: anytype, ctx: *ui.Context, result: dispatch.Result) void {
    if (result.request) |request| {
        if (result.scope == .all) broadcast(s, request) else {
            s.pending = request;
            s.perform(ctx);
        }
    }
}
fn normal(s: anytype, ctx: *ui.Context, sc: ui.Shortcut) void {
    if (ctx.shortcut_taken or sc.cmd or s.search_open or s.modalOpen()) return;
    const session = s.active() orelse return;
    const special: u32 = switch (sc.key) {
        ui.Shortcut.up => 0x104,
        ui.Shortcut.down => 0x105,
        ui.Shortcut.left => 0x102,
        ui.Shortcut.right => 0x103,
        ui.Shortcut.enter => 0x108,
        ui.Shortcut.tab => 0x109,
        ui.Shortcut.escape => 0x10a,
        else => sc.key,
    };
    var text: [4]u8 = undefined;
    const len = if (sc.key < 0x100 and !sc.ctrl) std.unicode.utf8Encode(sc.key, &text) catch 0 else 0;
    if (!TerminalView.key(session, special, (if (sc.shift) @as(u32, 1) else 0) | (if (sc.ctrl) @as(u32, 2) else 0) | (if (sc.alt) @as(u32, 4) else 0), text[0..len])) s.status = "Input queue busy; retry after drain";
    ctx.shortcut_taken = true;
}
fn plain(ctx: *ui.Context) ?keys.Chord {
    if (ctx.input.key) |key| return .{ .key = switch (key) {
        .enter => 13,
        .tab => 9,
        .escape => 27,
        .backspace => 127,
        .delete => 0xF728,
        .left => 0xF702,
        .right => 0xF703,
        .up => 0xF700,
        .down => 0xF701,
        .home => 0xF729,
        .end => 0xF72B,
        .page_up => 0xF72C,
        .page_down => 0xF72D,
        else => return null,
    }, .shift = ctx.input.shift, .ctrl = ctx.input.ctrl, .alt = ctx.input.alt };
    var text = ctx.input.chars;
    if (ctx.input.ops.len == 1) switch (ctx.input.ops[0]) {
        .insert => |value| text = value,
        .command => |command| return .{ .key = switch (command) {
            .insert_newline => 13,
            .insert_tab => 9,
            .cancel => 27,
            .delete_backward => 127,
            .delete_forward => 0xF728,
            .move_left => 0xF702,
            .move_right => 0xF703,
            .move_line_start => 0xF729,
            .move_line_end => 0xF72B,
            else => return null,
        } },
        else => return null,
    };
    if (text.len == 0) return null;
    const length = std.unicode.utf8ByteSequenceLength(text[0]) catch return null;
    if (length != text.len) return null;
    return .{ .key = std.unicode.utf8Decode(text) catch return null, .shift = ctx.input.shift };
}
pub fn shortcuts(s: anytype, ctx: *ui.Context) void {
    if (s.search_open and !@import("application_preview.zig").focused(s) and (ctx.input.key == .escape or (ctx.input.shortcut != null and ctx.input.shortcut.?.key == 27)) and !composing(s, ctx)) {
        s.search_open = false;
        s.clearSearch();
        cancel(s, .editing);
        if (ctx.input.shortcut) |sc| _ = ctx.shortcut(sc);
        ctx.input.key = null;
        ctx.input.ops = &.{};
        return;
    }
    // Ordinary text/idle frames need no binding table or capability queries.
    // Pending sequences still recheck guards and availability on every event.
    if (ctx.input.shortcut == null and !s.binding_state.active()) return;
    s.binding_capabilities = s.capabilities(ctx);
    s.binding_state.matcher.timeout_ms = s.cfg.keybind_sequence_timeout;
    const flags = guard(s, ctx);
    if (!flags.focused or flags.modal or flags.editing or flags.ime) {
        cancel(s, if (flags.ime) .ime else if (!flags.focused) .focus_lost else if (flags.modal) .modal else .editing);
        // Ordinary application shortcuts remain available beside text editing;
        // byte actions and chord sequences never intercept an editor or IME.
        if (!flags.ime and flags.focused) if (ctx.input.shortcut) |sc| {
            const binding = keys.lookup(s.cfg.keybinds, s.cfg.clear_default_keybinds, .{ .key = sc.key, .cmd = sc.cmd, .ctrl = sc.ctrl, .alt = sc.alt, .shift = sc.shift }) orelse return;
            const field_edit = binding.action == .copy or binding.action == .paste or binding.action == .select_all;
            if (field_edit or binding.action == .send_bytes or binding.action == .unbind) return;
            if (flags.modal and !(s.palette.open and binding.action == .palette)) return;
            if (binding.flags.performable and s.binding_capabilities.disabled(binding.request()) != null) return;
            if (!binding.flags.unconsumed) _ = ctx.shortcut(sc);
            s.pending = binding.request();
        };
        return;
    }
    if (ctx.input.shortcut) |sc| {
        const result = s.binding_state.feed(s.cfg.keybinds, s.cfg.clear_default_keybinds, .{ .key = sc.key, .cmd = sc.cmd, .ctrl = sc.ctrl, .alt = sc.alt, .shift = sc.shift }, c.lt_millis(), flags, .{ .active = s.binding_capabilities }) catch {
            s.status = "Cannot resolve binding";
            return;
        };
        if (result.consumed) {
            _ = ctx.shortcut(sc);
            ctx.input.key = null;
            ctx.input.chars = "";
            ctx.input.ops = &.{};
        }
        apply(s, ctx, result);
        arm(s);
        if (!result.consumed) normal(s, ctx, sc);
    } else if (s.binding_state.active()) {
        if (plain(ctx)) |chord| {
            const result = s.binding_state.feed(s.cfg.keybinds, s.cfg.clear_default_keybinds, chord, c.lt_millis(), flags, .{ .active = s.binding_capabilities }) catch return;
            if (result.consumed) {
                ctx.input.key = null;
                ctx.input.chars = "";
                ctx.input.ops = &.{};
            }
            apply(s, ctx, result);
            arm(s);
        } else if (ctx.input.chars.len > 0 or ctx.input.ops.len > 0) cancel(s, .ime);
    }
}
