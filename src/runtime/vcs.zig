//! Shared local-change ownership and capabilities for the Changes UI.
const std = @import("std");
const jobs = @import("jobs.zig");
const A = std.mem.Allocator;
pub const git = @import("git.zig");
pub const svn = @import("svn.zig");
pub const File = @import("changes.zig").File;
pub const Backend = enum { none, git, svn };
/// Nearest enclosing metadata wins, with Git preferred on a same-directory tie.
/// Only a marker check: each backend validates it through its CLI. Resolve the
/// input first so symlinked project directories use their actual ancestors.
pub fn detect(a: A, directory: []const u8) !Backend {
    if (!std.fs.path.isAbsolute(directory) or std.mem.indexOfScalar(u8, directory, 0) != null) return error.InvalidVcsDirectory;
    const input = try a.dupeSentinel(u8, directory, 0);
    defer a.free(input);
    var resolved: [std.fs.max_path_bytes]u8 = undefined;
    const canonical = std.c.realpath(input.ptr, &resolved) orelse return error.InvalidVcsDirectory;
    var path: []const u8 = std.mem.span(canonical);
    while (true) {
        inline for (.{ .{ ".git", Backend.git }, .{ ".svn", Backend.svn } }) |marker| {
            const full = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ path, marker[0] }, 0);
            defer a.free(full);
            if (std.c.access(full.ptr, 0) == 0) return marker[1];
        }
        path = std.fs.path.dirname(path) orelse return .none;
    }
}
pub const State = struct {
    backend: Backend = .none,
    git_state: git.State = .{},
    svn_state: svn.State = .{},
    directory: []const u8 = "",
    target: jobs.Target = .{ .window = 0 },
    initialized: bool = false,
    epoch: u64 = 0,
    pending: bool = false,
    review: bool = false,
    capture_requested: bool = false,
    discovery_failed: bool = false,
    pub fn deinit(self: *State, a: A) void {
        self.git_state.deinit(a);
        self.svn_state.deinit(a);
        if (self.directory.len > 0) a.free(self.directory);
    }
    pub fn request(self: *State, a: A, target: jobs.Target, directory: []const u8, review: bool) !void {
        const backend = detect(a, directory) catch |err| {
            self.backend = .none;
            self.initialized = true;
            self.discovery_failed = true;
            self.epoch +%= 1;
            return err;
        };
        const changed = !self.initialized or self.discovery_failed or backend != self.backend or !std.mem.eql(u8, self.directory, directory) or
            target.window != self.target.window or target.workspace != self.target.workspace or target.pane != self.target.pane;
        const replacement = try a.dupe(u8, directory);
        if (self.directory.len > 0) a.free(self.directory);
        self.directory = replacement;
        self.backend = backend;
        self.target = target;
        self.review = review;
        self.initialized = true;
        self.discovery_failed = false;
        // This stamp owns deferred UI actions. Same-owner refreshes must not
        // discard a click already queued from the current file list. Backend
        // job generations and patch versions separately reject stale results.
        if (changed) self.epoch +%= 1;
        self.pending = self.pending or changed;
        if (self.pending) {
            if (!self.git_state.running and !self.svn_state.running) try self.activate(a);
            return;
        }
        try self.refresh(a);
    }
    fn activate(self: *State, a: A) !void {
        const git_generation = self.git_state.generation;
        const svn_generation = self.svn_state.generation;
        const git_base = self.git_state.base;
        self.git_state.deinit(a);
        self.svn_state.deinit(a);
        self.git_state = .{ .generation = git_generation, .base = git_base };
        self.svn_state = .{ .generation = svn_generation };
        self.pending = false;
        try self.refresh(a);
    }
    fn refresh(self: *State, a: A) !void {
        if (self.backend == .git and self.capture_requested) self.git_state.capture = true;
        self.capture_requested = false;
        switch (self.backend) {
            .git => try self.git_state.request(a, self.target, self.directory, self.review),
            .svn => try self.svn_state.request(a, self.target, self.directory, self.review),
            .none => {},
        }
    }
    pub fn select(self: *State, a: A, path: []const u8) !void {
        _ = self.find(path) orelse return error.VcsSelectionMissing;
        switch (self.backend) {
            .git => try self.git_state.select(a, path),
            .svn => try self.svn_state.select(a, path),
            .none => return error.NoVcsBackend,
        }
    }
    pub fn contextLines(self: *const State) u32 {
        return if (self.backend == .svn) self.svn_state.context_lines else self.git_state.context_lines;
    }
    pub fn setContext(self: *State, a: A, lines: u32) !void {
        if (self.busy() or self.selected().len == 0) return;
        const bounded = @min(lines, 100000);
        switch (self.backend) {
            .git => self.git_state.context_lines = bounded,
            .svn => self.svn_state.context_lines = bounded,
            .none => return,
        }
        // select makes an owned copy before clearing the previous patch.
        try self.select(a, self.selected());
    }
    pub fn pump(self: *State, a: A, pool: *jobs.Pool) !void {
        if (self.pending) {
            // A child only owns copied arguments and IDs. Reap it before
            // destroying backend data/private Git indexes or changing owners.
            if (self.git_state.running or self.svn_state.running) {
                for (pool.jobs.items) |job| {
                    const active = if (job.target.tag >= 128) self.svn_state.active else self.git_state.target;
                    if (job.target.window == active.window and job.target.workspace == active.workspace and job.target.pane == active.pane and job.target.generation == active.generation and job.failure == null) job.cancel(.cancelled);
                }
                return;
            }
            try self.activate(a);
        }
        switch (self.backend) {
            .git => try self.git_state.pump(a, pool),
            .svn => try self.svn_state.pump(a, pool),
            .none => {},
        }
    }
    /// Owners must resolve window/workspace/pane IDs before calling consume.
    /// Inactive backend completions finish ownership bookkeeping but never
    /// appear through the active accessors or launch more inactive work.
    pub fn consume(self: *State, a: A, job: *const jobs.Job) !void {
        if (job.target.tag >= 128) try self.svn_state.consume(a, job) else try self.git_state.consume(a, job);
    }
    pub fn files(self: *const State) []const File {
        if (self.pending or self.discovery_failed) return &.{};
        return switch (self.backend) {
            .git => if (self.git_state.data) |*data| data.files.items else &.{},
            .svn => if (self.svn_state.data) |*data| data.files.items else &.{},
            .none => &.{},
        };
    }
    pub fn patch(self: *const State) []const u8 {
        if (self.pending or self.discovery_failed) return "";
        return switch (self.backend) {
            .git => self.git_state.patch,
            .svn => self.svn_state.patch,
            .none => "",
        };
    }
    /// Include the backend identity so switching Git/SVN invalidates a cached
    /// diff even when both backend counters happen to have the same value.
    pub fn patchVersion(self: *const State) u64 {
        const key = [_]u64{ @backingInt(self.backend), switch (self.backend) {
            .git => self.git_state.patch_version,
            .svn => self.svn_state.patch_version,
            .none => 0,
        }, @intFromBool(self.pending), self.target.window, self.target.workspace, self.target.pane };
        return std.hash.Wyhash.hash(self.epoch, std.mem.sliceAsBytes(&key));
    }
    pub fn root(self: *const State) []const u8 {
        if (self.pending or self.discovery_failed) return "";
        return switch (self.backend) {
            .git => self.git_state.root,
            .svn => self.svn_state.root,
            .none => "",
        };
    }
    pub fn selected(self: *const State) []const u8 {
        if (self.pending or self.discovery_failed) return "";
        return switch (self.backend) {
            .git => self.git_state.selected,
            .svn => self.svn_state.selected,
            .none => "",
        };
    }
    pub fn busy(self: *const State) bool {
        return self.pending or switch (self.backend) {
            .git => self.git_state.running or self.git_state.stage != .idle or self.git_state.dirty,
            .svn => self.svn_state.running or self.svn_state.stage != .idle,
            .none => false,
        };
    }
    pub fn hasData(self: *const State) bool {
        if (self.pending or self.discovery_failed) return false;
        return switch (self.backend) {
            .git => self.git_state.data != null,
            .svn => self.svn_state.data != null,
            .none => false,
        };
    }
    pub fn label(self: *const State) []const u8 {
        return switch (self.backend) {
            .git => if (self.git_state.data) |data| if (data.branch.len > 0) data.branch else "detached" else "Git",
            .svn => "SVN",
            .none => "Changes",
        };
    }
    pub fn base(self: *const State) git.Base {
        return if (self.backend == .git) self.git_state.base else .head;
    }
    pub fn setBase(self: *State, value: git.Base) !void {
        if (!self.supportsBase(value)) return error.UnsupportedVcsBase;
        if (self.backend == .git) self.git_state.base = value;
    }
    pub fn find(self: *const State, path: []const u8) ?File {
        for (self.files()) |file| if (std.mem.eql(u8, file.path, path)) return file;
        return null;
    }
    pub fn canOpen(self: *const State, path: []const u8) bool {
        const file = self.find(path) orelse return false;
        if (self.root().len == 0 or file.external) return false;
        for ([_][]const u8{ "deleted", "missing", "obstructed", "incomplete" }) |status| if (std.mem.eql(u8, file.status, status) or std.mem.eql(u8, file.text_status, status)) return false;
        return if (self.backend == .svn) svn.validPath(path) else git.validPath(path);
    }
    pub fn openPath(self: *const State, a: A, path: []const u8) ![]const u8 {
        if (!self.canOpen(path)) return error.VcsSelectionMissing;
        return std.fs.path.resolve(a, &.{ self.root(), path });
    }
    pub fn stop(self: *State) void {
        self.pending = false;
        switch (self.backend) {
            .git => {
                self.git_state.stage = .idle;
                self.git_state.dirty = false;
            },
            .svn => self.svn_state.stage = .idle,
            .none => {},
        }
    }
    pub fn message(self: *const State) []const u8 {
        if (self.discovery_failed) return "Working directory is unavailable";
        if (self.pending) return "";
        return switch (self.backend) {
            .git => self.git_state.message,
            .svn => self.svn_state.message,
            .none => "No Git or SVN working copy",
        };
    }
    pub fn supportsBase(self: *const State, value: git.Base) bool {
        return self.backend == .git or (self.backend == .svn and value == .head);
    }
};
