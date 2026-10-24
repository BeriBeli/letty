//! Local SVN working-copy changes. Read-only CLI jobs, never wc.db or a shell.
const std = @import("std");
const jobs = @import("jobs.zig");
const xml = @import("svn_xml.zig");
const A = std.mem.Allocator;
pub const File = @import("changes.zig").File;
pub const Data = struct {
    arena: std.heap.ArenaAllocator,
    files: std.ArrayList(File) = .empty,
    pub fn deinit(self: *Data) void {
        self.arena.deinit();
    }
    pub fn status(a: A, source: []const u8) !Data {
        var self: Data = .{ .arena = .init(a) };
        errdefer self.deinit();
        const alloc = self.arena.allocator();
        var reader = try xml.Reader.init(source);
        var path: ?[]const u8 = null;
        var entry_depth: usize = 0;
        var seen_status = false;
        while (try reader.next(alloc)) |token| {
            if (token.kind == .start) {
                if (token.depth == 0 and !std.mem.eql(u8, token.name, "status")) return error.InvalidSvnOutput;
                if (std.mem.eql(u8, token.name, "entry")) {
                    if (path != null or token.depth != 2 or
                        !(std.mem.eql(u8, reader.stack[1], "target") or std.mem.eql(u8, reader.stack[1], "changelist"))) return error.InvalidSvnOutput;
                    path = token.attr("path") orelse return error.InvalidSvnOutput;
                    if (!validPath(path.?)) return error.InvalidSvnPath;
                    entry_depth = token.depth;
                    seen_status = false;
                } else if (std.mem.eql(u8, token.name, "wc-status")) {
                    if (path == null or token.depth != entry_depth + 1 or seen_status) return error.InvalidSvnOutput;
                    seen_status = true;
                    const item = token.attr("item") orelse return error.InvalidSvnOutput;
                    const props = token.attr("props") orelse return error.InvalidSvnOutput;
                    if (!knownStatus(item) or !knownStatus(props)) return error.InvalidSvnOutput;
                    const tree = try flag(&token, "tree-conflicted");
                    const conflict = tree or eq(item, "conflicted") or eq(props, "conflicted");
                    if ((eq(item, "normal") or eq(item, "none") or eq(item, "ignored")) and
                        (eq(props, "normal") or eq(props, "none")) and !conflict) continue;
                    if (self.files.items.len == 16384) return error.SvnFileLimit;
                    const from = token.attr("moved-from") orelse "";
                    const to = token.attr("moved-to") orelse "";
                    if ((from.len > 0 and !validPath(from)) or (to.len > 0 and !validPath(to))) return error.InvalidSvnPath;
                    try self.files.append(alloc, .{
                        .path = path.?,
                        .status = if (conflict) "conflicted" else if (eq(item, "unversioned")) "untracked" else if (eq(item, "normal") or eq(item, "none")) "modified" else item,
                        .text_status = item,
                        .property_status = props,
                        .copied = try flag(&token, "copied"),
                        .tree_conflicted = tree,
                        .switched = try flag(&token, "switched"),
                        .external = eq(item, "external") or try flag(&token, "file-external"),
                        .moved_from = from,
                        .moved_to = to,
                    });
                }
            } else if (token.kind == .end and std.mem.eql(u8, token.name, "entry")) {
                if (path == null or !seen_status) return error.InvalidSvnOutput;
                path = null;
            }
        }
        return self;
    }
    pub fn find(self: *const Data, path: []const u8) ?File {
        for (self.files.items) |file| if (eq(file.path, path)) return file;
        return null;
    }
};
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn knownStatus(value: []const u8) bool {
    for ([_][]const u8{ "none", "normal", "added", "missing", "incomplete", "deleted", "replaced", "modified", "merged", "conflicted", "obstructed", "ignored", "external", "unversioned" }) |name| if (eq(value, name)) return true;
    return false;
}
fn flag(token: *const xml.Token, name: []const u8) !bool {
    const value = token.attr(name) orelse return false;
    if (eq(value, "true")) return true;
    if (eq(value, "false")) return false;
    return error.InvalidSvnOutput;
}
/// `a` must be an arena; the result and all decoded XML live in that arena.
pub fn workingCopyRoot(a: A, source: []const u8) ![]const u8 {
    var reader = try xml.Reader.init(source);
    var result: ?[]const u8 = null;
    var text: std.ArrayList(u8) = .empty;
    var collecting = false;
    var entries: usize = 0;
    while (try reader.next(a)) |token| {
        if (token.kind == .start) {
            if (token.depth == 0 and !eq(token.name, "info")) return error.InvalidSvnOutput;
            if (eq(token.name, "entry")) {
                entries += 1;
                if (token.depth != 1 or entries != 1) return error.InvalidSvnOutput;
            }
            if (collecting) return error.InvalidSvnOutput;
            if (eq(token.name, "wcroot-abspath")) {
                if (token.depth != 3 or !eq(reader.stack[1], "entry") or !eq(reader.stack[2], "wc-info") or result != null) return error.InvalidSvnOutput;
                collecting = true;
            }
        } else if (token.kind == .text and collecting) {
            try text.appendSlice(a, token.value);
        } else if (token.kind == .end and eq(token.name, "wcroot-abspath")) {
            collecting = false;
            result = text.items;
        }
    }
    const root = result orelse return error.NotSvnWorkingCopy;
    if (entries != 1 or !std.fs.path.isAbsolute(root) or std.mem.indexOfScalar(u8, root, 0) != null) return error.InvalidSvnOutput;
    return root;
}
pub fn validPath(path: []const u8) bool {
    if (path.len == 0 or path.len > 65500 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (eq(part, "..") or std.ascii.eqlIgnoreCase(part, ".svn") or std.ascii.eqlIgnoreCase(part, ".git")) return false;
    return true;
}
// The upper half of job tags belongs to SVN; Git's existing tags stay intact.
pub const Stage = enum(u8) { idle = 128, open, status, patch };
pub const State = struct {
    directory: []const u8 = "",
    root: []const u8 = "",
    data: ?Data = null,
    message: []const u8 = "",
    selected: []const u8 = "",
    loading: []const u8 = "",
    patch: []const u8 = "",
    patch_version: u64 = 0,
    context_lines: u32 = 3,
    loading_context: u32 = 3,
    generation: u64 = 0,
    target: jobs.Target = .{ .window = 0 },
    active: jobs.Target = .{ .window = 0 },
    stage: Stage = .idle,
    running: bool = false,
    initialized: bool = false,
    review: bool = false,
    pub fn deinit(self: *State, a: A) void {
        if (self.data) |*data| data.deinit();
        for ([_][]const u8{ self.directory, self.root, self.message, self.selected, self.loading, self.patch }) |bytes| if (bytes.len > 0) a.free(bytes);
    }
    fn set(a: A, dst: *[]const u8, value: []const u8) !void {
        const replacement = if (value.len > 0) try a.dupe(u8, value) else "";
        if (dst.len > 0) a.free(dst.*);
        dst.* = replacement;
    }
    fn setPatch(self: *State, a: A, value: []const u8) !void {
        if (eq(self.patch, value)) return;
        try set(a, &self.patch, value);
        self.patch_version +%= 1;
    }
    /// Explicit refresh; callers debounce filesystem/foreground events. No timer
    /// or server query. Requests during a job coalesce to the newest generation.
    pub fn request(self: *State, a: A, target: jobs.Target, directory: []const u8, review: bool) !void {
        if (!std.fs.path.isAbsolute(directory) or std.mem.indexOfScalar(u8, directory, 0) != null) return error.InvalidSvnPath;
        const changed = !eq(self.directory, directory) or target.window != self.target.window or target.workspace != self.target.workspace or target.pane != self.target.pane;
        if (changed) {
            try set(a, &self.directory, directory);
            try set(a, &self.root, "");
            try set(a, &self.selected, "");
            if (self.data) |*data| data.deinit();
            self.data = null;
        }
        self.generation +%= 1;
        self.target = target;
        self.target.generation = self.generation;
        self.review = review;
        self.initialized = true;
        try set(a, &self.message, "");
        try self.setPatch(a, "");
        self.stage = if (self.root.len == 0) .open else .status;
    }
    pub fn select(self: *State, a: A, path: []const u8) !void {
        if (!validPath(path)) return error.InvalidSvnPath;
        const data = &(self.data orelse return error.SvnSelectionMissing);
        _ = data.find(path) orelse return error.SvnSelectionMissing;
        try set(a, &self.selected, path);
        try self.setPatch(a, "");
        try set(a, &self.message, "");
        if (self.stage == .idle) self.stage = .patch;
    }
    /// Exposed for fixture verification. Strings are owned by the supplied arena.
    pub fn command(self: *const State, a: A) !jobs.Spec {
        var target = self.target;
        target.tag = @backingInt(self.stage);
        const args: []const []const u8 = switch (self.stage) {
            .open => &.{ "info", "--xml", "--non-interactive", "--no-auth-cache", "--depth", "empty", "--", ".@" },
            .status => &.{ "status", "--xml", "--non-interactive", "--no-auth-cache", "--ignore-externals", "--", "." },
            .patch => blk: {
                if (!validPath(self.selected)) return error.InvalidSvnPath;
                // ./ prevents URL/option interpretation. Local BASE-to-WORKING
                // diff does not parse peg revisions: @ stays literal here.
                const path = try std.fmt.allocPrint(a, "./{s}", .{self.selected});
                const args = try a.dupe([]const u8, &.{ "diff", "--internal-diff", "--non-interactive", "--no-auth-cache", "--depth", "empty", "--extensions", try std.fmt.allocPrint(a, "-U{d}", .{self.context_lines}), "--", path });
                break :blk args;
            },
            .idle => return error.SvnIdle,
        };
        return .{ .target = target, .executable = "svn", .args = args, .directory = if (self.root.len > 0) self.root else self.directory };
    }
    pub fn pump(self: *State, a: A, pool: *jobs.Pool) !void {
        if (self.running or self.stage == .idle) return;
        if (self.stage == .patch) {
            const file = if (self.data) |*data| data.find(self.selected) else null;
            const unavailable = if (file) |f| unavailablePreview(f) else "Selected path is no longer in the working-copy changes";
            if (unavailable) |reason| {
                try set(a, &self.message, reason);
                try self.setPatch(a, "");
                self.stage = .idle;
                return;
            }
            try set(a, &self.loading, self.selected);
        }
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const spec = try self.command(arena.allocator());
        pool.launch(spec) catch |err| {
            if (err == error.BackgroundBusy) return;
            self.stage = .idle;
            try set(a, &self.message, if (err == error.ExecutableNotFound) "SVN executable not found in PATH" else @errorName(err));
            return err;
        };
        self.loading_context = self.context_lines;
        self.active = spec.target;
        self.running = true;
    }
    pub fn consume(self: *State, a: A, job: *const jobs.Job) !void {
        if (!self.running or !sameTarget(self.active, job.target) or !job.complete()) return;
        self.running = false;
        // A directory/owner/refresh change supersedes the in-flight result.
        if (job.target.generation != self.generation) return;
        const stage: Stage = @fromBackingInt(@intCast(job.target.tag));
        self.stage = .idle;
        errdefer {
            self.setPatch(a, "") catch {};
            set(a, &self.message, "Invalid SVN response") catch {};
        }
        if (!job.ok()) {
            try self.setPatch(a, "");
            if (stage == .open or stage == .status) {
                if (self.data) |*data| data.deinit();
                self.data = null;
                try set(a, &self.root, "");
            }
            if (stage == .patch and !eq(self.selected, self.loading)) {
                self.stage = .patch;
                return;
            }
            try set(a, &self.message, if (job.failure) |failure| @tagName(failure) else if (job.errors.bytes.items.len > 0) job.errors.bytes.items else "SVN command failed");
            return;
        }
        switch (stage) {
            .open => {
                var arena: std.heap.ArenaAllocator = .init(a);
                defer arena.deinit();
                const root = try workingCopyRoot(arena.allocator(), job.output.bytes.items);
                try set(a, &self.root, root);
                self.stage = .status;
            },
            .status => {
                var replacement = try Data.status(a, job.output.bytes.items);
                errdefer replacement.deinit();
                if (replacement.find(self.selected) == null) try set(a, &self.selected, if (replacement.files.items.len > 0) replacement.files.items[0].path else "");
                if (self.data) |*old| old.deinit();
                self.data = replacement;
                if (self.review and self.selected.len > 0) self.stage = .patch;
            },
            .patch => {
                if (eq(self.selected, self.loading) and self.loading_context == self.context_lines) {
                    try self.setPatch(a, job.output.bytes.items);
                    try set(a, &self.message, "");
                } else if (self.selected.len > 0) self.stage = .patch;
            },
            .idle => {},
        }
    }
};
fn sameTarget(a: jobs.Target, b: jobs.Target) bool {
    return a.window == b.window and a.workspace == b.workspace and a.pane == b.pane and a.generation == b.generation and a.tag == b.tag;
}
fn unavailablePreview(file: File) ?[]const u8 {
    if (file.external) return "External working copy: open it separately to review its changes";
    if (eq(file.text_status, "unversioned")) return "Unversioned path: no SVN BASE diff is available";
    if (eq(file.text_status, "missing")) return "Missing path: restore it or schedule its deletion with SVN";
    if (eq(file.text_status, "obstructed") or eq(file.text_status, "incomplete")) return "Working-copy path is obstructed or incomplete";
    return null;
}
