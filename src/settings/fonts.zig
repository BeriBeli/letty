//! Bounded bundled and system font families. No subprocess or network access.
const std = @import("std");
const nano = @import("nanoui");
const TextSystem = @typeInfo(@FieldType(nano.ui.Context, "text")).pointer.child;
pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    names: []const []const u8,
    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn contains(self: *const Catalog, name: []const u8) bool {
        for (self.names) |item| if (std.ascii.eqlIgnoreCase(item, name)) return true;
        return false;
    }
    pub fn scan(gpa: std.mem.Allocator) !Catalog {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var list: std.ArrayList([]const u8) = .empty;
        if (@hasField(TextSystem, "db")) {
            var system: TextSystem = .init(gpa);
            defer system.deinit();
            @import("../bundled_fonts.zig").install(&system);
            system.db.scan();
            for (system.db.faces.items) |face| try add(a, &list, face.style.name());
        } else if (@import("builtin").os.tag == .macos) {
            const array = CTFontManagerCopyAvailableFontFamilyNames() orelse return error.FontCatalogUnavailable;
            defer CFRelease(array);
            const count = CFArrayGetCount(array);
            var i: isize = 0;
            while (i < count and i < 4096) : (i += 1) {
                const string = CFArrayGetValueAtIndex(array, i) orelse continue;
                var bytes: [1024]u8 = undefined;
                if (CFStringGetCString(string, &bytes, bytes.len, 0x08000100) != 0) try add(a, &list, std.mem.sliceTo(&bytes, 0));
            }
        }
        const names = try list.toOwnedSlice(a);
        std.mem.sort([]const u8, names, {}, struct {
            fn less(_: void, left: []const u8, right: []const u8) bool {
                return std.ascii.lessThanIgnoreCase(left, right);
            }
        }.less);
        return .{ .arena = arena, .names = names };
    }
    fn add(a: std.mem.Allocator, list: *std.ArrayList([]const u8), name: []const u8) !void {
        if (name.len == 0 or name.len > 255 or list.items.len >= 512) return;
        for (list.items) |prior| if (std.mem.eql(u8, prior, name)) return;
        try list.append(a, try a.dupe(u8, name));
    }
};
extern "c" fn CTFontManagerCopyAvailableFontFamilyNames() ?*const anyopaque;
extern "c" fn CFArrayGetCount(*const anyopaque) isize;
extern "c" fn CFArrayGetValueAtIndex(*const anyopaque, isize) ?*const anyopaque;
extern "c" fn CFStringGetCString(*const anyopaque, [*]u8, isize, u32) u8;
extern "c" fn CFRelease(*const anyopaque) void;
