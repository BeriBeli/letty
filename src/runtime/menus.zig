//! One action catalog supplies the native menu, Linux accelerators and palette.
const std = @import("std");
const nano = @import("nanoui");
const actions = @import("actions.zig");
pub fn install(host: anytype) !void {
    var arena: std.heap.ArenaAllocator = .init(host.a);
    defer arena.deinit();
    const a = arena.allocator();
    var groups: [6]std.ArrayList(nano.MenuItem) = @splat(.empty);
    const callback = struct {
        fn click(runtime: @TypeOf(host), item: *nano.menu.Item) void {
            runtime.menuCommand(item.id);
        }
    }.click;
    for (actions.all, 0..) |action, index| {
        if (!action.implemented) continue;
        const group: usize = if (std.mem.eql(u8, action.menu, "Letty")) 0 else if (std.mem.eql(u8, action.menu, "Session")) 1 else if (std.mem.eql(u8, action.menu, "Edit")) 2 else if (std.mem.eql(u8, action.menu, "Pane")) 3 else if (std.mem.eql(u8, action.menu, "View")) 4 else 5;
        try groups[group].append(a, .{ .id = action.id, .label = @import("locale.zig").t(action.title), .accelerator = actions.keys(index, host.bindings, @import("builtin").os.tag == .macos), .click = .of(host, callback) });
    }
    try groups[0].insertSlice(a, 0, &.{ .{ .role = .about }, .separator });
    try groups[0].appendSlice(a, &.{ .separator, .{ .role = .hide }, .{ .role = .hide_others }, .{ .role = .unhide } });
    try groups[2].insertSlice(a, 0, &.{ .{ .role = .undo }, .{ .role = .redo }, .separator });
    try groups[5].appendSlice(a, &.{ .separator, .{ .role = .minimize }, .{ .role = .zoom }, .{ .role = .front } });
    var template: [6]nano.MenuItem = undefined;
    for ([_][]const u8{ "Letty", "Session", "Edit", "Pane", "View", "Window" }, 0..) |label, i| template[i] = .{ .label = @import("locale.zig").t(label), .submenu = groups[i].items };
    try host.app.setMenu(&template);
}

pub fn enabled(host: anytype, value: bool) void {
    if (host.app.main_menu) |menu| for (menu.items.items) |*item| item.setEnabled(value);
}
