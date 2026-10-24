//! A terminal context menu drawn with nanoui's current fixed/layer API.
const std = @import("std");
const ui = @import("nanoui").ui;
const Menu = @import("menu.zig");
pub const State = struct {
    open: bool = false,
    workspace: u64 = 0,
    pane: u64 = 0,
    point: ui.Point = .{},
    frame: u64 = 0,
    link: []const u8 = "",
    has_selection: bool = false,
    menu: Menu.State = .{},
    pub fn close(self: *State, a: std.mem.Allocator) void {
        a.free(self.link);
        self.* = .{};
    }
    pub fn show(self: *State, a: std.mem.Allocator, workspace: u64, pane: u64, point: ui.Point, frame: u64, link: []const u8, selected: bool) !void {
        const owned = try a.dupe(u8, link);
        self.close(a);
        self.* = .{ .open = true, .workspace = workspace, .pane = pane, .point = point, .frame = frame, .link = owned, .has_selection = selected };
    }
};
pub const Event = union(enum) { command: []const u8, open_link, copy_link, close };
pub fn view(self: *State, ctx: *ui.Context) ?Event {
    if (!self.open) return null;
    var items: std.ArrayList(Menu.Item) = .empty;
    const a = ctx.alloc();
    if (self.link.len > 0) {
        items.appendSlice(a, &.{
            .{ .label = if (@import("paths.zig").web(self.link)) "Open link" else "Preview File" },
            .{ .label = if (@import("paths.zig").web(self.link)) "Copy link" else "Copy Path" },
            .{ .separator = true },
        }) catch return null;
    }
    const entries = .{ .{ "Copy selection", "edit.copy" }, .{ "Paste", "edit.paste" }, .{ "Select all", "edit.selectAll" }, .{ "Clear terminal", "terminal.clear" }, .{ "Find…", "find.open" }, .{ "Split Right", "pane.split.right" }, .{ "Split Down", "pane.split.down" }, .{ "Restart Pane", "pane.restart" }, .{ "Close", "pane.close" } };
    inline for (entries) |entry| items.append(a, .{ .label = entry[0], .disabled = std.mem.eql(u8, entry[1], "edit.copy") and !self.has_selection }) catch return null;
    const bounds = Menu.place(ctx.size, self.point, Menu.contentWidth(ctx, items.items, 192), Menu.contentHeight(items.items));
    if (ctx.input.key == .escape or (ctx.input.pressed and ctx.frame != self.frame and !bounds.contains(ctx.input.mouse))) {
        ctx.input.clearEdges();
        return .close;
    }
    ui.key(ctx, "terminal-context-menu");
    if (Menu.draw(&self.menu, ctx, bounds, items.items, true)) |index| {
        if (self.link.len > 0) {
            if (index == 0) return .open_link;
            if (index == 1) return .copy_link;
        }
        const offset: usize = if (self.link.len > 0) 3 else 0;
        inline for (entries, 0..) |entry, i| if (index == i + offset) return .{ .command = entry[1] };
    }
    return null;
}
