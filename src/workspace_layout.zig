//! Multi-window persistence; only serializable topology and placement, never PTYs.
const std = @import("std");
const Layout = @import("layout.zig").Layout;
pub const Frame = struct { x: f64 = 0, y: f64 = 0, width: f64 = 1000, height: f64 = 680 };
pub const Navigation = struct { width: f32 = 240, collapsed: bool = false };
pub const File = struct { tab: u64, path: []const u8 };
pub const Record = struct { files: []const File = &.{}, id: u64, title: []const u8 = "", layout: Layout, frame: ?Frame = null, navigation: Navigation = .{} };
pub const Document = struct {
    version: u32 = 6,
    active: u64 = 0,
    next_window_id: u64 = 1,
    windows: []const Record = &.{},
    pub fn validate(d: Document, profiles: usize) !void {
        if (d.version != 6 or d.next_window_id == 0 or d.next_window_id == std.math.maxInt(u64)) return error.InvalidWorkspace;
        for (d.windows, 0..) |w, i| {
            if (w.id == 0 or w.id >= d.next_window_id) return error.InvalidWindowIdentity;
            for (d.windows[0..i]) |prior| if (prior.id == w.id) return error.DuplicateWindow;
            try w.layout.validate(profiles);
            for (w.files, 0..) |file, file_index| {
                const tab = w.layout.tabIndex(file.tab) orelse return error.InvalidDocumentWorkspace;
                if (!w.layout.isDocument(tab) or file.path.len == 0 or file.path.len >= 4096 or !std.fs.path.isAbsolute(file.path) or std.mem.indexOfScalar(u8, file.path, 0) != null) return error.InvalidDocumentWorkspace;
                for (w.files[0..file_index]) |previous| if (previous.tab == file.tab) return error.InvalidDocumentWorkspace;
            }
            for (0..w.layout.tab_count) |tab| if (w.layout.isDocument(tab)) {
                var found = false;
                for (w.files) |file| if (file.tab == w.layout.tabs[tab].id) {
                    found = true;
                    break;
                };
                if (!found) return error.InvalidDocumentWorkspace;
            };
            if (!std.math.isFinite(w.navigation.width) or w.navigation.width < 160 or w.navigation.width > 360) return error.InvalidNavigationWidth;
            if (w.frame) |f| {
                for ([_]f64{ f.x, f.y, f.width, f.height }) |value| if (!std.math.isFinite(value)) return error.InvalidWindowFrame;
                if (f.width < 480 or f.height < 240 or f.width > 20000 or f.height > 20000) return error.InvalidWindowFrame;
            }
        }
        if (d.active != 0) {
            for (d.windows) |w| if (w.id == d.active) return;
            return error.InvalidActiveWindow;
        }
    }
};
pub fn decode(a: std.mem.Allocator, bytes: []const u8, profiles: usize) !Document {
    const tree = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    if (tree.value != .object) return error.InvalidWorkspace;
    // Older releases serialized all eight tab/root slots, including unused
    // entries. Pad only that known legacy shape, before typed parsing/validation.
    if (tree.value.object.getPtr("windows")) |windows| {
        if (windows.* != .array) return error.InvalidWorkspace;
        for (windows.array.items) |*window| {
            if (window.* != .object) return error.InvalidWorkspace;
            if (window.object.getPtr("layout")) |layout| try expandLegacyTabs(a, layout);
        }
        const normalized = try std.json.Stringify.valueAlloc(a, tree.value, .{});
        const parsed = try std.json.parseFromSlice(Document, a, normalized, .{});
        var document = parsed.value;
        if (document.version >= 3 and document.version <= 5) document.version = 6;
        for (@constCast(document.windows)) |*record| {
            try record.layout.validate(profiles);
            record.layout.migrate();
        }
        try document.validate(profiles);
        return document;
    }
    var value = tree.value;
    try expandLegacyTabs(a, &value);
    const normalized = try std.json.Stringify.valueAlloc(a, value, .{});
    const parsed = try std.json.parseFromSlice(Layout, a, normalized, .{});
    var layout = parsed.value;
    try layout.validate(profiles);
    layout.migrate();
    try layout.validate(profiles);
    const records = try a.alloc(Record, 1);
    records[0] = .{ .id = 1, .layout = layout };
    const document: Document = .{ .active = 1, .next_window_id = 2, .windows = records };
    try document.validate(profiles);
    return document;
}
test "workspace migrates legacy layout and validates global budget/identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var layout: Layout = .{};
    defer layout.deinit();
    try layout.newTab(0, 0);
    const bytes = try std.json.Stringify.valueAlloc(arena.allocator(), layout, .{});
    const migrated = try decode(arena.allocator(), bytes, 1);
    try std.testing.expectEqual(@as(usize, 1), migrated.windows.len);
    const bad = [_]Record{ .{ .id = 1, .layout = layout }, .{ .id = 1, .layout = layout } };
    try std.testing.expectError(error.DuplicateWindow, (Document{ .next_window_id = 2, .windows = &bad }).validate(1));
}
test "workspace v3 migrates sidebar defaults and v4 roundtrips pinned display state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var layout: Layout = .{};
    defer layout.deinit();
    try layout.newTab(0, 0);
    layout.togglePin(layout.tabs[0].id);
    const records = [_]Record{.{ .id = 1, .layout = layout, .navigation = .{ .width = 310, .collapsed = true } }};
    const bytes = try std.json.Stringify.valueAlloc(a, Document{ .active = 1, .next_window_id = 2, .windows = &records }, .{});
    const saved = try decode(a, bytes, 1);
    try std.testing.expect(saved.version == 6 and saved.windows[0].layout.tabs[0].pinned);
    try std.testing.expect(saved.windows[0].navigation.collapsed and saved.windows[0].navigation.width == 310);
    const old = try std.fmt.allocPrint(a, "{{\"version\":3,\"active\":1,\"next_window_id\":2,\"windows\":[{{\"id\":1,\"layout\":{s}}}]}}", .{try std.json.Stringify.valueAlloc(a, layout, .{})});
    const migrated = try decode(a, old, 1);
    try std.testing.expect(migrated.version == 6 and migrated.windows[0].navigation.width == 240 and !migrated.windows[0].navigation.collapsed);
    var invalid = records;
    invalid[0].navigation.width = std.math.nan(f32);
    try std.testing.expectError(error.InvalidNavigationWidth, (Document{ .next_window_id = 2, .windows = &invalid }).validate(1));
}

fn expandLegacyTabs(a: std.mem.Allocator, value: *std.json.Value) !void {
    if (value.* != .object) return error.InvalidLayout;
    const version = if (value.object.get("version")) |v| if (v == .integer) v.integer else return error.InvalidLayout else 1;
    if (version < 1 or version > 4) return error.InvalidLayout;
    if (value.object.getPtr("roots")) |roots| {
        if (roots.* == .string) {
            var array: std.array_list.Managed(std.json.Value) = .init(a);
            for (roots.string) |index| try array.append(.{ .integer = index });
            roots.* = .{ .array = array };
        }
        if (roots.* != .array) return error.InvalidLayout;
        if (version == 3) for (roots.array.items) |*entry| {
            if (entry.* == .integer and entry.integer == 31) entry.* = .{ .number_string = try std.fmt.allocPrint(a, "{d}", .{@import("layout.zig").document_root}) };
        };
    }
    // v1 omitted tab metadata. Allocate only enough default records to migrate.
    if (value.object.get("tabs") == null) {
        const count = value.object.get("tab_count") orelse return error.InvalidLayout;
        if (count != .integer or count.integer < 0 or count.integer > 16) return error.InvalidLayout;
        var tabs: std.array_list.Managed(std.json.Value) = .init(a);
        for (0..@intCast(count.integer)) |_| try tabs.append(.{ .object = .{} });
        try value.object.put(a, "tabs", .{ .array = tabs });
    }
}

test "eight-slot legacy arrays migrate and sixteen tabs roundtrip with bounded IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var layout: Layout = .{};
    defer layout.deinit();
    for (0..16) |i| try layout.newTab(@intCast(i), 0);
    try layout.validate(1);

    const bytes = try std.json.Stringify.valueAlloc(a, layout, .{});
    const restored = try decode(a, bytes, 1);
    try std.testing.expectEqual(@as(u8, 16), restored.windows[0].layout.tab_count);
    layout.activate(7);
    while (layout.tab_count > 8) layout.close(layout.firstPane(layout.roots[8]));
    const legacy = try std.json.parseFromSlice(std.json.Value, a, try std.json.Stringify.valueAlloc(a, layout, .{}), .{});
    legacy.value.object.getPtr("tabs").?.array.shrinkRetainingCapacity(8);
    const roots = legacy.value.object.getPtr("roots").?;
    roots.array.shrinkRetainingCapacity(8);
    const old = try std.json.Stringify.valueAlloc(a, legacy.value, .{});
    const migrated = try decode(a, old, 1);
    try std.testing.expectEqual(@as(u8, 8), migrated.windows[0].layout.tab_count);
    try std.testing.expectEqual(layout.tabs[7].id, migrated.windows[0].layout.tabs[7].id);
    var reopened = try restored.windows[0].layout.clone();
    defer reopened.deinit();
    const retired = reopened.tabs[15].id;
    reopened.close(15);
    try reopened.newTab(15, 0);
    try reopened.validate(1);
    try std.testing.expect(reopened.tabs[15].id > retired);
}

test "file workspaces roundtrip without PTYs and reject missing duplicate or unsafe path ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var layout: Layout = .{};
    defer layout.deinit();
    const id = try layout.newDocument();
    const files = [_]File{.{ .tab = id, .path = "/tmp/README.md" }};
    var records = [_]Record{.{ .id = 1, .layout = layout, .files = &files }};
    var document: Document = .{ .active = 1, .next_window_id = 2, .windows = &records };
    const restored = try decode(a, try std.json.Stringify.valueAlloc(a, document, .{}), 0);
    try std.testing.expect(restored.windows[0].layout.isDocument(0));
    try std.testing.expectEqualStrings(files[0].path, restored.windows[0].files[0].path);
    records[0].files = &.{};
    try std.testing.expectError(error.InvalidDocumentWorkspace, document.validate(0));
    records[0].files = &.{ files[0], files[0] };
    try std.testing.expectError(error.InvalidDocumentWorkspace, document.validate(0));
    records[0].files = &.{.{ .tab = id, .path = "relative.md" }};
    try std.testing.expectError(error.InvalidDocumentWorkspace, document.validate(0));
    records[0].files = &.{.{ .tab = id + 1, .path = "/tmp/README.md" }};
    try std.testing.expectError(error.InvalidDocumentWorkspace, document.validate(0));
}

test "legacy v3 document byte roots migrate without becoming a terminal node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const legacy = "{\"version\":5,\"active\":1,\"next_window_id\":2,\"windows\":[{\"id\":1,\"layout\":{\"version\":3,\"tabs\":[{\"id\":1}],\"next_tab_id\":2,\"roots\":\"\\u001f\",\"tab_count\":1},\"files\":[{\"tab\":1,\"path\":\"/tmp/README.md\"}]}]}";
    const document = try decode(a, legacy, 0);
    try std.testing.expect(document.version == 6 and document.windows[0].layout.isDocument(0));
    var clone = try document.windows[0].layout.clone();
    defer clone.deinit();
    _ = try clone.newDocument();
    try clone.validate(0);
    try std.testing.expect(document.windows[0].layout.tab_count == 1);
}
test "legacy v1 byte roots and absent metadata migrate before restoration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const document = try decode(arena.allocator(), "{\"version\":1,\"nodes\":[{\"kind\":\"pane\"}],\"roots\":\"\\u0000\",\"tab_count\":1}", 1);
    try std.testing.expect(document.windows[0].layout.tabs[0].id == 1);
    try document.validate(1);
}
test "hundreds of workspaces roundtrip complete topology and high pane indices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var layout: Layout = .{};
    defer layout.deinit();
    for (0..600) |i| try layout.newTab(i, 0);
    const records = [_]Record{.{ .id = 1, .layout = layout }};
    const original: Document = .{ .active = 1, .next_window_id = 2, .windows = &records };
    const bytes = try std.json.Stringify.valueAlloc(a, original, .{});
    const restored = try decode(a, bytes, 1);
    try std.testing.expect(restored.windows[0].layout.same(layout));
}
