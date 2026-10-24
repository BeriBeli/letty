//! libc-backed font I/O for nanoui on the Linux 3.10 baseline, entirely in Zig.
const std = @import("std");
const c = @import("libc.zig");
export fn lt_open(path: [*:0]const u8) c_int {
    return c.open(path, c.O_RDONLY | c.O_CLOEXEC);
}
export fn lt_close(fd: c_int) void {
    _ = c.close(fd);
}
export fn lt_length(fd: c_int) i64 {
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or (st.mode & c.S_IFMT) != c.S_IFREG) return -1;
    return st.size;
}
export fn lt_pread(fd: c_int, bytes: [*]u8, len: usize, offset: u64) isize {
    if (offset > std.math.maxInt(i64)) return -1;
    return std.c.pread(fd, bytes, len, @intCast(offset));
}
export fn lt_scan_fonts(path: [*:0]const u8, ctx: ?*anyopaque, callback: *const fn (?*anyopaque, [*:0]const u8) callconv(.c) void) void {
    var budget: usize = 100000;
    scan(std.mem.span(path), ctx, callback, 0, &budget);
}
fn scan(path: []const u8, ctx: ?*anyopaque, callback: *const fn (?*anyopaque, [*:0]const u8) callconv(.c) void, depth: usize, budget: *usize) void {
    if (depth >= 8 or path.len >= 4095 or budget.* == 0) return;
    var buffer: [4096]u8 = undefined;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    const dir = std.c.opendir(@ptrCast(&buffer)) orelse return;
    defer _ = std.c.closedir(dir);
    while (budget.* > 0) {
        const entry = std.c.readdir(dir) orelse break;
        budget.* -= 1;
        const name = std.mem.sliceTo(&entry.name, 0);
        if (name.len == 0 or name[0] == '.') continue;
        if (path.len + name.len + 2 >= buffer.len) continue;
        buffer[path.len] = '/';
        @memcpy(buffer[path.len + 1 ..][0..name.len], name);
        const len = path.len + 1 + name.len;
        buffer[len] = 0;
        if (entry.type == 4) scan(buffer[0..len], ctx, callback, depth + 1, budget) else if (entry.type == 8 and (std.ascii.endsWithIgnoreCase(name, ".ttf") or std.ascii.endsWithIgnoreCase(name, ".otf") or std.ascii.endsWithIgnoreCase(name, ".ttc"))) callback(ctx, @ptrCast(&buffer));
    }
}
