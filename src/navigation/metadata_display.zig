//! Pure display reduction of already delivered native provider values.
//! No work starts here. Unknown/stale/disabled results never become metadata.
const std = @import("std");
pub const PortSet = struct { values: [16 * 32]u16 = undefined, count: usize = 0 };
pub fn add(row: anytype, session: anytype, focused: bool, show_git: bool, show_ports: bool, ports: *PortSet) void {
    if (!show_git and !show_ports) return;
    const Session = @typeInfo(@TypeOf(session)).pointer.child;
    inline for (.{ "eof", "closing", "fatal" }) |field| {
        if (comptime @hasField(Session, field)) if (@field(session, field)) return;
    }
    if (comptime @hasField(Session, "status")) if (session.status != null) return;
    const snapshot = &(session.metadata.snapshot orelse return);
    if (!snapshot.currentFor(session.id, session.metadata.generation)) return;
    var scratch: [512]u8 = undefined;
    if (show_git and snapshot.git_state == .ok) {
        const summary = if (snapshot.git_detached)
            std.fmt.bufPrint(&scratch, "HEAD {s}{s}", .{ snapshot.headText(), if (snapshot.git_dirty) " *" else "" }) catch ""
        else
            std.fmt.bufPrint(&scratch, "{s}{s}", .{ snapshot.branchText(), if (snapshot.git_dirty) " *" else "" }) catch "";
        if (focused) row.git.set(summary);
        row.provider_partial = !append(&row.provider_sources, if (focused) "Active split Git: " else "Split Git: ") or row.provider_partial;
        row.provider_partial = !append(&row.provider_sources, summary) or row.provider_partial;
        row.provider_partial = !append(&row.provider_sources, "\n") or row.provider_partial;
    }
    if (show_ports and snapshot.ports_state == .ok) {
        row.provider_partial = row.provider_partial or snapshot.partial;
        for (snapshot.listeningPorts()) |port| {
            const source = std.fmt.bufPrint(&scratch, "PID {d} · :{d} · IPv{d}\n", .{ port.pid, port.port, port.family }) catch "";
            row.provider_partial = !appendComplete(&row.provider_sources, source) or row.provider_partial;
            if (std.mem.indexOfScalar(u16, ports.values[0..ports.count], port.port) != null) continue;
            if (ports.count == ports.values.len) {
                row.provider_partial = true;
                break;
            }
            ports.values[ports.count] = port.port;
            ports.count += 1;
            const value = std.fmt.bufPrint(&scratch, "{s}{d}", .{ if (row.ports.len > 0) ", " else "", port.port }) catch "";
            // Never truncate a port number into a different, invented port.
            row.provider_partial = !appendComplete(&row.ports, value) or row.provider_partial;
        }
    }
}
fn appendComplete(destination: anytype, source: []const u8) bool {
    if (source.len > destination.buf.len - destination.len) return false;
    return append(destination, source);
}
fn append(destination: anytype, source: []const u8) bool {
    var count = @min(source.len, destination.buf.len - destination.len);
    while (count > 0 and count < source.len and source[count] & 0xc0 == 0x80) count -= 1;
    @memcpy(destination.buf[destination.len..][0..count], source[0..count]);
    destination.len += count;
    return count == source.len;
}
