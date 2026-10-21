//! Owned draft; no WindowState pointers or borrowed config-arena strings.
const std = @import("std");
const ui = @import("nanoui").ui;
const config = @import("../config.zig");
const edit = @import("../config_edit.zig");
const keys = @import("../keybindings.zig");
const schema = @import("schema.zig");
const doc = @import("document.zig");
const adapter = @import("adapter.zig");
const Text = @import("../fixed_text.zig").Text;
pub const Value = struct {
    input: ui.TextBuffer = .{},
    original: []const u8 = "",
    locked: bool = false,
    pub fn dirty(self: *const Value) bool {
        return !self.locked and !std.mem.eql(u8, self.input.text(), self.original);
    }
    pub fn text(self: *const Value) []const u8 {
        return if (self.locked) self.original else self.input.text();
    }
};
pub const Dependency = doc.Dependency;
pub const Model = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    home: []const u8,
    root: ?edit.Snapshot = null,
    dependencies: []const Dependency = &.{},
    baseline: config.Config = .{},
    // nanoui 0.4 text buffers are 16 KiB each; keep the field set out of
    // stack-resident Model temporaries and owned by the draft arena.
    values: []Value = &.{},
    binding_edits: std.ArrayList([]const u8) = .empty,
    diagnostic: config.Diagnostic = .{},
    notice: Text(1024) = .{},
    notice_error: bool = true,
    read_only: bool = false,
    metadata_unavailable: bool = false,
    json: bool = false,
    last_error_field: ?schema.Field = null,
    pub fn init(gpa: std.mem.Allocator, path: []const u8, home: []const u8) !Model {
        return initWithMetadataReader(gpa, path, home, edit.native_metadata_reader);
    }
    pub fn initWithMetadataReader(gpa: std.mem.Allocator, path: []const u8, home: []const u8, reader: edit.MetadataReader) !Model {
        var self: Model = .{ .gpa = gpa, .arena = .init(gpa), .path = undefined, .home = undefined };
        errdefer self.deinit();
        const a = self.arena.allocator();
        self.values = try a.alloc(Value, schema.fields.len);
        for (self.values) |*v| v.* = .{};
        self.path = try a.dupe(u8, path);
        self.home = try a.dupe(u8, home);
        self.root = edit.Native.captureForDisplay(gpa, path, reader) catch |err| if (err == error.ConfigNotFound) null else return err;
        const source = if (self.root) |root| root.bytes else "";
        self.json = doc.isJson(source);
        self.read_only = self.json;
        // Parse directly into the draft arena; errors still open a diagnostic UI.
        var frozen: doc.FrozenReader = .{ .a = a, .base = config.includes.nativeReader(home), .display_metadata_reader = reader };
        var redirect: doc.Redirect = .{ .base = frozen.reader(), .path = if (self.root) |r| r.path else path, .bytes = source };
        self.baseline = config.loadWithReaderDetailed(a, redirect.reader(), redirect.path, .{}, &self.diagnostic) catch |err| blk: {
            self.read_only = true;
            self.notice.set(@errorName(err));
            redirect.bytes = "";
            break :blk try config.loadWithReaderDetailed(a, redirect.reader(), redirect.path, .{}, null);
        };
        for (schema.fields, 0..) |field, i| {
            const text = try schema.format(a, field.id, self.baseline);
            self.values[i].original = text;
            self.values[i].locked = text.len > self.values[i].input.buf.len;
            self.values[i].input.set(text);
        }
        self.dependencies = frozen.dependencies.items;
        if (self.root) |root| self.noteMetadata(root);
        for (self.dependencies) |dependency| if (dependency.snapshot) |snapshot| self.noteMetadata(snapshot);
        return self;
    }
    fn noteMetadata(self: *Model, snapshot: edit.Snapshot) void {
        const err = snapshot.metadata_error orelse return;
        self.metadata_unavailable = true;
        self.read_only = true;
        var message: [1024]u8 = undefined;
        self.notice.set(std.fmt.bufPrint(&message, "Read-only: {s} in {s}. File attributes could not be verified. Open Config to edit externally; reopen Settings after resolving the metadata error.", .{ @errorName(err), snapshot.path }) catch @errorName(err));
        self.diagnostic.setPath(snapshot.path);
        self.diagnostic.fail(0, "", err);
    }
    pub fn deinit(self: *Model) void {
        if (self.root) |*root| root.deinit();
        self.binding_edits.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn value(self: *Model, id: schema.Field) *Value {
        return &self.values[@backingInt(id)];
    }
    /// Display the active inherited theme value without creating an edit.
    /// Existing drafts stay independent of later system appearance events.
    pub fn syncAppearance(self: *Model, dark: bool) void {
        const current = self.value(.ligatures);
        if (current.dirty()) return;
        const text = schema.boolean(self.baseline.forAppearance(dark).font_ligatures);
        if (std.mem.eql(u8, current.original, text)) return;
        current.original = text;
        current.input.set(text);
    }
    pub fn dirtyCount(self: *const Model) usize {
        var count = self.binding_edits.items.len;
        for (self.values) |*v| count += @intFromBool(v.dirty());
        return count;
    }
    pub fn reset(self: *Model, id: schema.Field) !void {
        if (self.read_only) return error.ReadOnlySetting;
        const default = try schema.format(self.gpa, id, .{});
        defer self.gpa.free(default);
        self.value(id).input.set(default);
        self.value(id).locked = false;
    }
    pub fn checkSources(self: *Model) !void {
        if (self.root) |root| {
            var current = edit.Native.capture(self.gpa, self.path) catch return error.ConcurrentChange;
            defer current.deinit();
            if (!root.matches(current)) return error.ConcurrentChange;
        } else if (config.exists(self.path)) return error.ConcurrentChange;
        try doc.checkDependencies(self.gpa, self.dependencies);
    }
    pub fn replacement(self: *Model, a: std.mem.Allocator) ![]const u8 {
        if (self.read_only) return if (self.json) error.UnsupportedJsonRoot else error.InvalidConfiguration;
        var changes: std.ArrayList(doc.Change) = .empty;
        defer changes.deinit(a);
        for (schema.fields, 0..) |field, i| {
            if (!self.values[i].dirty() or field.id == .dark_theme) continue;
            if (field.id == .theme) continue;
            try changes.append(a, .{ .key = field.key, .value = self.values[i].input.text() });
        }
        if (self.value(.theme).dirty() or self.value(.dark_theme).dirty()) {
            const light = self.value(.theme).text();
            const dark = self.value(.dark_theme).text();
            const theme = if (dark.len == 0) light else try std.fmt.allocPrint(a, "light:{s},dark:{s}", .{ light, dark });
            try changes.append(a, .{ .key = "theme", .value = theme });
        }
        for (self.binding_edits.items) |binding| try changes.append(a, .{ .key = "keybind", .value = binding });
        return doc.append(a, if (self.root) |r| r.bytes else "", changes.items);
    }
    pub fn candidate(self: *Model) !doc.Candidate {
        self.last_error_field = null;
        self.diagnostic = .{};
        self.diagnostic.setPath(if (self.root) |root| root.path else self.path);
        for (schema.fields, 0..) |field, index| if (self.values[index].dirty()) {
            const encoded = doc.encodeValue(self.gpa, self.values[index].text()) catch |err| {
                self.last_error_field = field.id;
                self.diagnostic.fail(0, field.key, err);
                return err;
            };
            self.gpa.free(encoded);
        };
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const bytes = try self.replacement(scratch.allocator());
        return doc.Candidate.load(self.gpa, if (self.root) |r| r.path else self.path, bytes, self.home, &self.diagnostic) catch |err| {
            for (schema.fields) |field| if (std.mem.eql(u8, field.key, self.diagnostic.key[0..self.diagnostic.key_len])) {
                self.last_error_field = field.id;
                break;
            };
            return err;
        };
    }
    /// Incomplete edits keep the last valid preview without changing save diagnostics.
    pub fn previewCandidate(self: *Model) !doc.Candidate {
        const diagnostic = self.diagnostic;
        const field = self.last_error_field;
        defer {
            self.diagnostic = diagnostic;
            self.last_error_field = field;
        }
        return self.candidate();
    }
    /// Returns false without touching disk or host when unchanged.
    /// After success caller closes/reopens this draft (never reuse old snapshot).
    pub fn save(self: *Model, host: adapter.Host) !?edit.SaveResult {
        if (self.dirtyCount() == 0) return null;
        if (self.read_only) return error.ReadOnlySetting;
        try self.checkSources();
        var next = try self.candidate();
        var owned = true;
        defer if (owned) next.deinit();
        const ticket = try host.prepare(host.context, &next);
        var reserved = true;
        defer if (reserved) host.abort(host.context, ticket);
        try self.checkSources();
        try doc.checkDependencies(self.gpa, next.dependencies);
        const result = if (self.root) |root| try edit.Native.save(self.gpa, root, next.replacement) else try doc.create(self.gpa, self.path, next.replacement);
        host.commit(host.context, ticket, next);
        reserved = false;
        owned = false;
        return result;
    }
    /// A changed trigger retires the old binding in the same draft transaction.
    /// Roll back both edits if validation, capacity, or allocation fails.
    pub fn editBinding(self: *Model, old_trigger: []const u8, spec: []const u8, replace: bool) !void {
        if (old_trigger.len == 0) return self.addBinding(spec, replace);
        const removed = try std.fmt.allocPrint(self.gpa, "{s}=unbind", .{old_trigger});
        defer self.gpa.free(removed);
        const old = try keys.parse(removed);
        const next = try keys.parse(spec);
        if (keys.sameTrigger(&old, &next)) return self.addBinding(spec, true);
        const before = self.binding_edits.items.len;
        errdefer self.binding_edits.shrinkRetainingCapacity(before);
        try self.addBinding(spec, replace);
        try self.addBinding(removed, true);
    }

    pub fn addBinding(self: *Model, spec: []const u8, replace: bool) !void {
        if (self.read_only) return error.ReadOnlySetting;
        if (spec.len > 1024 or std.mem.indexOfAny(u8, spec, "\r\n\x00") != null) return error.InvalidKeybind;
        const parsed = try keys.parse(spec);
        for (self.binding_edits.items) |prior| {
            const binding = try keys.parse(prior);
            if (keys.sameTrigger(&parsed, &binding) and !replace) return error.ShortcutConflict;
        }
        for (self.baseline.keybinds) |*binding| if (keys.sameTrigger(&parsed, binding) and !replace) return error.ShortcutConflict;
        if (!self.baseline.clear_default_keybinds) for (&keys.defaults) |*binding| if (keys.sameTrigger(&parsed, binding) and !replace) return error.ShortcutConflict;
        if (self.binding_edits.items.len == 64) return error.TooManyKeybindings;
        const owned = try self.arena.allocator().dupe(u8, spec);
        try self.binding_edits.append(self.gpa, owned);
    }
};
