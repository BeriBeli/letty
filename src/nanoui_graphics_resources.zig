//! Managed Kitty images -> nanoui through the locked managed-image API.
//! One heap-stable Store per TextSystem; all its terminal Views share its keys.
//! No VT/Session ownership, UV cache, encoded-image insertion or OS operations.
const std = @import("std");
const ui = @import("nanoui").ui;
const graphics = @import("terminal_graphics_view.zig");

pub const TextSystem = @typeInfo(@FieldType(ui.Context, "text")).pointer.child;

/// View geometry can already be parent-local (preferred), or surface-relative.
/// In the latter case the host supplies the CURRENT parent's surface origin,
/// in points, not pixels. This module never guesses it from previous layout.
pub const Coordinates = union(enum) {
    parent_local,
    surface: ui.Point,
};
pub const Diagnostics = struct {
    uploads: usize = 0,
    removals: usize = 0,
    admission_rejections: usize = 0,
    upload_oom: usize = 0,
    draw_rejections: usize = 0,
};
const DrawScope = struct { context: *ui.Context, parent: u32, origin: ui.Point };

pub const Store = struct {
    /// Borrowed: TextSystem and its Images must outlive Store and every View.
    text: *TextSystem,
    keys: graphics.KeySource = .{},
    live_keys: usize = 0,
    diagnostics: Diagnostics = .{},
    drawing: ?DrawScope = null,

    /// The Store is the sole managed-key issuer for this TextSystem. Encoded
    /// images use a separate namespace and may continue using the same Images.
    /// Put this value in its final stable address BEFORE calling initView().
    pub fn init(text: *TextSystem) Store {
        std.debug.assert(text.images.managed.count() == 0);
        return .{ .text = text };
    }

    pub fn initView(self: *Store, gpa: std.mem.Allocator, limits: graphics.Limits) !graphics.View {
        return graphics.View.init(gpa, self.resources(), &self.keys, limits);
    }

    /// Only after EVERY View.deinit/deactivate and old Context tree/instances
    /// have been discarded. Does not destroy TextSystem or its shared atlas.
    /// An empty View still borrows this Store; it must not be used afterward.
    pub fn deinit(self: *Store) void {
        std.debug.assert(self.drawing == null);
        std.debug.assert(self.live_keys == 0 and self.text.images.managed.count() == 0);
        self.* = undefined;
    }

    pub fn resources(self: *Store) graphics.Resources {
        return .{ .ctx = self, .putRaw = putRaw, .remove = remove, .draw = draw };
    }

    /// Call at the actual pane background / cell background / text boundaries.
    /// View.sync (uploads/removes) must have finished BEFORE building its image
    /// nodes. This only enqueues nodes; paint later prepares the whole visible
    /// image set once and resolves current UVs. Layer/z order is View's order.
    /// The active Context borrow ends on return, including all error paths.
    pub fn drawLayer(self: *Store, view: *const graphics.View, context: *ui.Context, coordinates: Coordinates, layer: graphics.Layer) !usize {
        if (view.resources.ctx != @as(*anyopaque, @ptrCast(self))) return error.ForeignGraphicsStore;
        if (self.drawing != null) return error.NestedGraphicsDraw;
        if (context.text != self.text) return error.ForeignTextSystem;
        if (context.text.images.in_frame) return error.FrameLocked;
        if (context.stack.items.len == 0) return error.MissingGraphicsParent;
        const origin: ui.Point = switch (coordinates) {
            .parent_local => .{ .x = 0, .y = 0 },
            .surface => |value| value,
        };
        if (!std.math.isFinite(origin.x) or !std.math.isFinite(origin.y)) return error.InvalidGraphicsOrigin;
        self.drawing = .{ .context = context, .parent = context.stack.items[context.stack.items.len - 1], .origin = origin };
        defer self.drawing = null;
        return view.drawLayer(layer);
    }

    fn owner(ptr: *anyopaque) *Store {
        return @ptrCast(@alignCast(ptr));
    }
    fn putRaw(ptr: *anyopaque, raw: graphics.Raw) !void {
        const self = owner(ptr);
        if (self.drawing != null) return error.ResourceMutationDuringDraw;
        // Check before taking the old-key accounting snapshot: FrameLocked
        // does not remove an existing key, unlike failed replacement below.
        if (self.text.images.in_frame) return error.FrameLocked;
        const existed = self.text.images.rawInfo(raw.key) != null;
        self.text.images.putRaw(raw.key, raw.width, raw.height, raw.bgra) catch |err| {
            // Candidate putRaw removes a replacement before allocation or
            // admission; its failure contract leaves that key absent.
            if (existed and self.text.images.rawInfo(raw.key) == null) self.live_keys -= 1;
            switch (err) {
                error.ManagedBudgetExceeded, error.ManagedCountExceeded => self.diagnostics.admission_rejections +|= 1,
                error.OutOfMemory => self.diagnostics.upload_oom +|= 1,
                else => {},
            }
            return err;
        };
        if (!existed) self.live_keys += 1;
        self.diagnostics.uploads +|= 1;
        // Synchronous copy is owned by Images now. raw.bgra is not retained.
    }
    fn remove(ptr: *anyopaque, key: u64) void {
        const self = owner(ptr);
        std.debug.assert(self.drawing == null and !self.text.images.in_frame);
        const existed = self.text.images.rawInfo(key) != null;
        self.text.images.remove(key);
        if (existed) {
            std.debug.assert(self.live_keys > 0);
            self.live_keys -= 1;
            self.diagnostics.removals +|= 1;
        }
    }
    fn draw(ptr: *anyopaque, command: graphics.Draw) !void {
        const self = owner(ptr);
        const scope = self.drawing orelse return error.NoGraphicsDrawScope;
        const context = scope.context;
        if (context.stack.items.len == 0 or context.stack.items[context.stack.items.len - 1] != scope.parent) return error.GraphicsParentChanged;
        // Convert dimensions explicitly: model.Rect uses width/height whereas
        // ui.Rect uses w/h. Never rescale source_pixels a second time.
        context.imageRegion(.{
            .key = command.key,
            .destination = local(command.destination, scope.origin),
            .clip = local(command.clip, scope.origin),
            .source_pixels = .{ .x = command.source_pixels.x, .y = command.source_pixels.y, .w = command.source_pixels.width, .h = command.source_pixels.height },
            .sample_bounds = .{ .x = command.sample_bounds.x, .y = command.sample_bounds.y, .w = command.sample_bounds.width, .h = command.sample_bounds.height },
            .opacity = command.opacity,
        }) catch |err| {
            self.diagnostics.draw_rejections +|= 1;
            return err;
        };
        // imageRegion stores scalar geometry/key only. No command borrow,
        // placement pointer, pixel slice or atlas UV escapes this callback.
    }
    fn local(rect: graphics.Rect, origin: ui.Point) ui.Rect {
        return .{ .x = rect.x - origin.x, .y = rect.y - origin.y, .w = rect.width, .h = rect.height };
    }
};
