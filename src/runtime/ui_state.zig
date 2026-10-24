//! Presentation preferences only: no PTY, process or daemon persistence.
const std = @import("std");
pub const State = struct {
    pub const Name = struct { directory: []const u8, name: []const u8 };
    sidebar_hidden: bool = false,
    sidebar_width: f32 = 268,
    changes_width: f32 = 420,
    changes_open: bool = false,
    font_size: f32 = 0,
    collapsed: std.ArrayList([]const u8) = .empty,
    names: std.ArrayList(Name) = .empty,
    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        for (self.collapsed.items) |key| a.free(key);
        self.collapsed.deinit(a);
        for (self.names.items) |entry| {
            a.free(entry.directory);
            a.free(entry.name);
        }
        self.names.deinit(a);
        self.* = .{};
    }
    pub fn folded(self: *const State, key: []const u8) bool {
        for (self.collapsed.items) |value| if (std.mem.eql(u8, key, value)) return true;
        return false;
    }
    pub fn label(self: *const State, directory: []const u8) []const u8 {
        for (self.names.items) |entry| if (std.mem.eql(u8, entry.directory, directory)) return entry.name;
        return std.fs.path.basename(directory);
    }
    pub fn rename(self: *State, a: std.mem.Allocator, directory: []const u8, name: []const u8) !void {
        if (directory.len > 65536 or name.len > 16384 or !std.unicode.utf8ValidateSlice(name) or self.bytes() + directory.len + name.len > 512 * 1024) return error.PreferenceLimit;
        for (self.names.items, 0..) |entry, i| if (std.mem.eql(u8, entry.directory, directory)) {
            if (name.len == 0) {
                const removed = self.names.orderedRemove(i);
                a.free(removed.directory);
                a.free(removed.name);
            } else {
                const owned = try a.dupe(u8, name);
                a.free(self.names.items[i].name);
                self.names.items[i].name = owned;
            }
            return;
        };
        if (name.len == 0) return;
        const key = try a.dupe(u8, directory);
        errdefer a.free(key);
        const value = try a.dupe(u8, name);
        errdefer a.free(value);
        try self.names.append(a, .{ .directory = key, .name = value });
    }
    pub fn toggle(self: *State, a: std.mem.Allocator, key: []const u8) !void {
        for (self.collapsed.items, 0..) |value, i| if (std.mem.eql(u8, key, value)) {
            a.free(self.collapsed.orderedRemove(i));
            return;
        };
        if (key.len > 65536 or self.bytes() + key.len > 512 * 1024) return error.PreferenceLimit;
        const owned = try a.dupe(u8, key);
        errdefer a.free(owned);
        try self.collapsed.append(a, owned);
    }
    fn bytes(self: State) usize {
        var total: usize = 0;
        for (self.collapsed.items) |key| total += key.len;
        for (self.names.items) |entry| total += entry.directory.len + entry.name.len;
        return total;
    }
    const Data = struct { version: u8 = 1, sidebar_hidden: bool = false, sidebar_width: f32 = 268, changes_width: f32 = 420, changes_open: bool = false, font_size: f32 = 0, collapsed: []const []const u8 = &.{}, names: []const Name = &.{} };
    pub fn parse(a: std.mem.Allocator, text: []const u8) !State {
        if (text.len > 1024 * 1024) return error.PreferenceLimit;
        const data = try std.json.parseFromSlice(Data, a, text, .{ .ignore_unknown_fields = true });
        defer data.deinit();
        const v = data.value;
        if (v.version != 1 or !std.math.isFinite(v.sidebar_width) or !std.math.isFinite(v.changes_width) or !std.math.isFinite(v.font_size) or (v.font_size != 0 and (v.font_size < 6 or v.font_size > 72))) return error.InvalidPreferences;
        var out: State = .{ .sidebar_hidden = v.sidebar_hidden, .sidebar_width = std.math.clamp(v.sidebar_width, 200, 440), .changes_width = std.math.clamp(v.changes_width, 300, 1200), .changes_open = v.changes_open, .font_size = v.font_size };
        errdefer out.deinit(a);
        for (v.collapsed) |key| {
            if (!out.folded(key)) try out.toggle(a, key);
        }
        for (v.names) |entry| try out.rename(a, entry.directory, entry.name);
        return out;
    }
    pub fn json(self: *const State, a: std.mem.Allocator) ![]const u8 {
        return std.json.Stringify.valueAlloc(a, Data{ .sidebar_hidden = self.sidebar_hidden, .sidebar_width = self.sidebar_width, .changes_width = self.changes_width, .changes_open = self.changes_open, .font_size = self.font_size, .collapsed = self.collapsed.items, .names = self.names.items }, .{ .whitespace = .indent_2 });
    }
};
test "local UI preferences round trip without retaining JSON storage" {
    const a = std.testing.allocator;
    var state = try State.parse(a, "{\"sidebar_width\":900,\"collapsed\":[\"/private/项目\",\"/private/项目\"]}");
    defer state.deinit(a);
    try std.testing.expectEqual(@as(f32, 440), state.sidebar_width);
    const text = try state.json(a);
    defer a.free(text);
    var copy = try State.parse(a, text);
    defer copy.deinit(a);
    try std.testing.expect(copy.folded("/private/项目") and copy.collapsed.items.len == 1);
    try copy.toggle(a, "/private/项目");
    try std.testing.expect(!copy.folded("/private/项目"));
}
test "project labels round trip without renaming directories or losing an allocation failure" {
    const a = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(a);
    try state.rename(a, "/private/project", "本地 Project");
    const encoded = try state.json(a);
    defer a.free(encoded);
    var copy = try State.parse(a, encoded);
    defer copy.deinit(a);
    try std.testing.expectEqualStrings("本地 Project", copy.label("/private/project"));
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, state.rename(failing.allocator(), "/private/project", "replacement"));
    try std.testing.expectEqualStrings("本地 Project", state.label("/private/project"));
    try state.rename(a, "/private/project", "");
    try std.testing.expectEqualStrings("project", state.label("/private/project"));
}
