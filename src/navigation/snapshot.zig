//! Bounded owned display values, gathered from existing Layout/Session values.
//! No filesystem, process scans, history traversal, PTY or config ownership.
const std = @import("std");
const Text = @import("../fixed_text.zig").Text;
pub const Seen = struct { session: u64 = 0, bells: u64 = 0 };
pub const Row = struct {
    id: u64 = 0,
    title: Text(256) = .{},
    cwd: Text(4096) = .{},
    /// Other split paths, bounded, with no invented notification body.
    split_paths: Text(2048) = .{},
    git: Text(320) = .{},
    ports: Text(256) = .{},
    provider_sources: Text(2048) = .{},
    provider_partial: bool = false,
    pinned: bool = false,
    panes: usize = 0,
    running: usize = 0,
    done: usize = 0,
    failed: usize = 0,
    bells: u64 = 0,
    unread_bells: u64 = 0,
    progress_count: usize = 0,
    progress: i32 = -1,
    progress_error: bool = false,
    active: bool = false,
    document: bool = false,
    fn same(a: *const Row, b: *const Row) bool {
        inline for (.{ "id", "document", "pinned", "panes", "running", "done", "failed", "bells", "unread_bells", "progress_count", "progress", "progress_error", "active", "provider_partial" }) |field| if (@field(a, field) != @field(b, field)) return false;
        inline for (.{ "title", "cwd", "split_paths", "git", "ports", "provider_sources" }) |field| if (!std.mem.eql(u8, @field(a, field).text(), @field(b, field).text())) return false;
        return true;
    }
};
pub const Snapshot = struct {
    rows: []Row = &.{},
    count: usize = 0,
    generation: u64 = 0,
    pub fn refresh(self: *Snapshot, s: anytype, seen: []const Seen) bool {
        @import("../dynamic_storage.zig").ensure(Row, &self.rows, s.layout.tab_count, .{}) catch return false;
        var changed = self.count != s.layout.tab_count;
        const count: usize = @min(self.rows.len, s.layout.tab_count);
        for (0..count) |tab| {
            const metadata = s.layout.tabs[tab];
            var row: Row = .{ .document = s.layout.isDocument(tab), .id = metadata.id, .active = tab == s.layout.active_tab, .pinned = metadata.pinned };
            clean(&row.title, s.tabLabel(@intCast(tab)));
            if (comptime @hasField(@typeInfo(@TypeOf(s)).pointer.child, "preview")) if (row.document) if (s.preview.active(metadata.id)) |d| {
                clean(&row.cwd, d.panel.model.path.text());
            };
            var paths: [2048]u8 = undefined;
            var used: usize = 0;
            var path_truncated = false;
            var total_progress: u64 = 0;
            var known_progress: u64 = 0;
            var ports: @import("metadata_display.zig").PortSet = .{};
            for (s.sessions, 0..) |opt, slot| if (opt) |session| {
                if (!s.layout.contains(s.layout.roots[tab], @intCast(slot))) continue;
                row.panes += 1;
                row.running += @intFromBool(session.command_running or session.command_pending);
                row.done += @intFromBool(session.attention == .done);
                row.failed += @intFromBool(session.attention == .failed or session.fatal);
                row.bells +|= session.events.bells;
                const acknowledged = if (seen[slot].session == session.id) seen[slot].bells else 0;
                row.unread_bells +|= session.events.bells -| acknowledged;
                if (session.events.progress_state != 0) {
                    row.progress_count += 1;
                    row.progress_error = row.progress_error or session.events.progress_state == 2;
                    if (session.events.progress >= 0) {
                        known_progress += 1;
                        total_progress += @intCast(std.math.clamp(session.events.progress, 0, 100));
                    }
                }
                const path = session.cwd.text(); // Verified local OSC7 authority or kernel shell CWD.
                if (slot == metadata.focused) clean(&row.cwd, path);
                @import("metadata_display.zig").add(&row, session, slot == metadata.focused, s.cfg.sidebar_show_git, s.cfg.sidebar_show_ports, &ports);
                if (path.len > 0) {
                    const prefix = if (slot == metadata.focused) "Active split: " else "Split: ";
                    for ([_][]const u8{ prefix, path, "\n" }) |part| {
                        const n = @min(part.len, paths.len - used);
                        @memcpy(paths[used..][0..n], part[0..n]);
                        used += n;
                        path_truncated = path_truncated or n < part.len;
                    }
                }
            };
            if (path_truncated and used >= 3) @memcpy(paths[used - 3 ..][0..3], "...");
            clean(&row.split_paths, paths[0..used]);
            if (known_progress > 0) row.progress = @intCast(total_progress / known_progress);
            if (!row.same(&self.rows[tab])) changed = true;
            self.rows[tab] = row;
        }
        self.count = count;
        if (changed) self.generation +|= 1;
        return changed;
    }
};
/// Protocol-owned labels may contain control bytes; they never become markup
/// or terminal escapes in navigation. Preserve UTF-8 and replace C0/DEL.
pub fn clean(destination: anytype, source: []const u8) void {
    destination.len = 0;
    var at: usize = 0;
    while (at < source.len and destination.len < destination.buf.len) {
        const byte = source[at];
        if (byte < 32 or byte == 127) {
            destination.buf[destination.len] = ' ';
            destination.len += 1;
            at += 1;
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(byte) catch 0;
        if (length == 0 or length > source.len - at or !std.unicode.utf8ValidateSlice(source[at..][0..length])) {
            destination.buf[destination.len] = '?';
            destination.len += 1;
            at += 1;
            continue;
        }
        if (length > destination.buf.len - destination.len) break;
        @memcpy(destination.buf[destination.len..][0..length], source[at..][0..length]);
        destination.len += length;
        at += length;
    }
}
