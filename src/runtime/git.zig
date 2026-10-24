//! Kero's local Git reader/snapshot workflow, driven by bounded child jobs.
//! Snapshot indexes are private; commands never lock or replace the user's index.
const std = @import("std");
const os = @import("platform.zig");
const jobs = @import("jobs.zig");
const A = std.mem.Allocator;
pub const File = @import("changes.zig").File;
pub const Data = struct {
    arena: std.heap.ArenaAllocator,
    branch: []const u8 = "",
    head: []const u8 = "",
    upstream: []const u8 = "",
    ahead: usize = 0,
    behind: usize = 0,
    files: std.ArrayList(File) = .empty,
    pub fn deinit(self: *Data) void {
        self.arena.deinit();
    }
    pub fn status(a: A, bytes: []const u8) !Data {
        var self: Data = .{ .arena = .init(a) };
        errdefer self.deinit();
        const alloc = self.arena.allocator();
        const source = try alloc.dupe(u8, bytes);
        var fields = std.mem.splitScalar(u8, source, 0);
        while (fields.next()) |field| {
            if (field.len == 0) continue;
            if (std.mem.startsWith(u8, field, "# branch.head ")) {
                self.branch = field[14..];
                if (std.mem.eql(u8, self.branch, "(detached)")) self.branch = "";
            } else if (std.mem.startsWith(u8, field, "# branch.oid ")) {
                self.head = field[13..];
                if (std.mem.eql(u8, self.head, "(initial)")) self.head = "";
            } else if (std.mem.startsWith(u8, field, "# branch.upstream ")) self.upstream = field[18..] else if (std.mem.startsWith(u8, field, "# branch.ab ")) {
                var parts = std.mem.tokenizeScalar(u8, field[12..], ' ');
                while (parts.next()) |part| {
                    if (part.len < 2) continue;
                    const n = std.fmt.parseInt(usize, part[1..], 10) catch continue;
                    if (part[0] == '+') self.ahead = n else if (part[0] == '-') self.behind = n;
                }
            } else if (field[0] == '?') {
                if (field.len > 2) try self.files.append(alloc, .{ .path = field[2..], .status = "untracked" });
            } else if (field[0] == '1' or field[0] == '2' or field[0] == 'u') {
                const path = afterFields(field, if (field[0] == '1') 8 else if (field[0] == '2') 9 else 10) orelse return error.InvalidGitOutput;
                const xy = if (field.len >= 4) field[2..4] else return error.InvalidGitOutput;
                const old = if (field[0] == '2') fields.next() orelse return error.InvalidGitOutput else "";
                try self.files.append(alloc, .{ .path = path, .old_path = old, .status = if (field[0] == 'u') "conflicted" else if (field[0] == '2') "renamed" else if (std.mem.indexOfScalar(u8, xy, 'D') != null) "deleted" else if (std.mem.indexOfScalar(u8, xy, 'A') != null) "added" else if (std.mem.indexOfScalar(u8, xy, 'T') != null) "type" else "modified" });
            }
            if (self.files.items.len > 16384) return error.GitFileLimit;
        }
        return self;
    }
    pub fn changes(self: *Data, bytes: []const u8) !void {
        const a = self.arena.allocator();
        const source = try a.dupe(u8, bytes);
        self.files.clearRetainingCapacity();
        var fields = std.mem.splitScalar(u8, source, 0);
        while (fields.next()) |code| {
            if (code.len == 0) continue;
            var path = fields.next() orelse return error.InvalidGitOutput;
            var old: []const u8 = "";
            if (code[0] == 'R' or code[0] == 'C') {
                old = path;
                path = fields.next() orelse return error.InvalidGitOutput;
            }
            try self.files.append(a, .{ .path = path, .old_path = old, .status = switch (code[0]) {
                'A', 'C' => "added",
                'D' => "deleted",
                'R' => "renamed",
                'T' => "type",
                else => "modified",
            } });
            if (self.files.items.len > 16384) return error.GitFileLimit;
        }
    }
    pub fn numstat(self: *Data, bytes: []const u8) void {
        var fields = std.mem.splitScalar(u8, bytes, 0);
        while (fields.next()) |field| {
            const t1 = std.mem.indexOfScalar(u8, field, '\t') orelse continue;
            const t2 = t1 + 1 + (std.mem.indexOfScalar(u8, field[t1 + 1 ..], '\t') orelse continue);
            var path = field[t2 + 1 ..];
            if (path.len == 0) {
                _ = fields.next() orelse break;
                path = fields.next() orelse break;
            }
            for (self.files.items) |*file| if (std.mem.eql(u8, file.path, path)) {
                file.binary = std.mem.eql(u8, field[0..t1], "-");
                file.added = std.fmt.parseInt(usize, field[0..t1], 10) catch 0;
                file.removed = std.fmt.parseInt(usize, field[t1 + 1 .. t2], 10) catch 0;
                break;
            };
        }
    }
};
fn afterFields(bytes: []const u8, n: usize) ?[]const u8 {
    var at: usize = 0;
    for (0..n) |_| {
        at += (std.mem.indexOfScalar(u8, bytes[at..], ' ') orelse return null) + 1;
    }
    return bytes[at..];
}
pub const Base = enum { head, branch, turn };
const Stage = enum(u8) { idle, open, status, status_counts, snapshot_add, snapshot_tree, empty_tree, branch_base, changes, counts, patch };
pub const State = struct {
    directory: []const u8 = "",
    root: []const u8 = "",
    git_dir: []const u8 = "",
    common: []const u8 = "",
    data: ?Data = null,
    message: []const u8 = "",
    generation: u64 = 0,
    target: jobs.Target = .{ .window = 0 },
    stage: Stage = .idle,
    running: bool = false,
    initialized: bool = false,
    review: bool = false,
    capture: bool = false,
    dirty: bool = false,
    next_directory: []const u8 = "",
    base: Base = .head,
    branch_attempt: u8 = 0,
    revision: []const u8 = "HEAD",
    snapshot: []const u8 = "",
    turn: []const u8 = "",
    temporary: []const u8 = "",
    selected: []const u8 = "",
    loading: []const u8 = "",
    patch: []const u8 = "",
    patch_version: u64 = 0,
    context_lines: u32 = 3,
    loading_context: u32 = 3,
    pub fn deinit(self: *State, a: A) void {
        if (self.data) |*data| data.deinit();
        self.cleanup(a);
        for ([_][]const u8{ self.directory, self.root, self.git_dir, self.common, self.message, self.snapshot, self.turn, self.selected, self.loading, self.patch, self.next_directory }) |s| if (s.len > 0) a.free(s);
        if (!std.mem.eql(u8, self.revision, "HEAD") and self.revision.len > 0) a.free(self.revision);
    }
    fn set(a: A, dst: *[]const u8, value: []const u8) !void {
        const replacement = try a.dupe(u8, value);
        if (dst.len > 0) a.free(dst.*);
        dst.* = replacement;
    }
    pub fn request(self: *State, a: A, target: jobs.Target, directory: []const u8, review: bool) !void {
        const destination = try a.dupe(u8, directory);
        defer a.free(destination);
        self.review = review;
        try set(a, &self.next_directory, destination);
        if (self.running or self.stage != .idle) {
            self.dirty = true;
            return;
        }
        if (!std.mem.eql(u8, self.directory, destination)) {
            try set(a, &self.directory, destination);
            try set(a, &self.root, "");
            try set(a, &self.turn, "");
            if (self.data) |*data| data.deinit();
            self.data = null;
        }
        self.target = target;
        self.generation +%= 1;
        self.target.generation = self.generation;
        self.initialized = true;
        try set(a, &self.message, "");
        self.stage = if (self.root.len == 0) .open else .status;
    }
    pub fn select(self: *State, a: A, path: []const u8) !void {
        if (!validPath(path)) return error.InvalidGitPath;
        try set(a, &self.selected, path);
        try set(a, &self.patch, "");
        self.patch_version +%= 1;
        if (!self.running and self.stage == .idle and self.snapshot.len > 0) self.stage = .patch;
    }
    pub fn pump(self: *State, a: A, pool: *jobs.Pool) !void {
        if (self.stage == .idle and self.dirty and !self.running) {
            self.dirty = false;
            try self.request(a, self.target, self.next_directory, self.review);
        }
        if (self.running or self.stage == .idle) return;
        errdefer {
            self.stage = .idle;
            self.cleanup(a);
        }
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const ta = arena.allocator();
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(ta, &.{ "--no-optional-locks", "--literal-pathspecs", "-c", "core.quotepath=false", "-c", "color.ui=false", "-c", "core.fsmonitor=false" });
        const env = &[_][]const u8{ "GIT_OPTIONAL_LOCKS=0", "GIT_TERMINAL_PROMPT=0" };
        var environment: std.ArrayList([]const u8) = .empty;
        try environment.appendSlice(ta, env);
        switch (self.stage) {
            .open => try args.appendSlice(ta, &.{ "rev-parse", "--show-toplevel", "--absolute-git-dir", "--git-common-dir" }),
            .status => try args.appendSlice(ta, &.{ "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all" }),
            .status_counts => try args.appendSlice(ta, &.{ "diff", "--no-ext-diff", "--no-textconv", "--numstat", "-z", "HEAD" }),
            .snapshot_add => {
                if (self.temporary.len == 0) {
                    const template = try ta.dupeSentinel(u8, "/tmp/letty-index-XXXXXX", 0);
                    _ = os.c.mkdtemp(template.ptr) orelse return error.GitTemporary;
                    errdefer _ = os.c.rmdir(template.ptr);
                    self.temporary = try a.dupe(u8, template);
                    const index = try std.fmt.allocPrint(ta, "{s}/index", .{self.git_dir});
                    const original = os.readFile(ta, index, 16 << 20) catch |err| blk: {
                        if (err != error.OpenFile) return err;
                        break :blk null;
                    };
                    if (original) |bytes| try os.atomicFile(ta, try std.fmt.allocPrint(ta, "{s}/index", .{self.temporary}), bytes);
                }
                try environment.append(ta, try std.fmt.allocPrint(ta, "GIT_INDEX_FILE={s}/index", .{self.temporary}));
                try args.appendSlice(ta, &.{ "-c", "core.hooksPath=/dev/null", "add", "--all", "--", "." });
            },
            .snapshot_tree => {
                try environment.append(ta, try std.fmt.allocPrint(ta, "GIT_INDEX_FILE={s}/index", .{self.temporary}));
                try args.append(ta, "write-tree");
            },
            .empty_tree => try args.appendSlice(ta, &.{ "hash-object", "-t", "tree", "--stdin" }),
            .branch_base => {
                const branch = try self.defaultBranch(ta);
                const ref = try std.fmt.allocPrint(ta, "{s}{s}", .{ if (self.branch_attempt == 0) "refs/remotes/origin/" else "refs/heads/", branch });
                try args.appendSlice(ta, &.{ "merge-base", "HEAD", ref });
            },
            .changes => try args.appendSlice(ta, &.{ "diff", "--no-ext-diff", "--no-textconv", "-M", "-z", "--name-status", self.revision, self.snapshot }),
            .counts => try args.appendSlice(ta, &.{ "diff", "--no-ext-diff", "--no-textconv", "-M", "-z", "--numstat", self.revision, self.snapshot }),
            .patch => {
                try set(a, &self.loading, self.selected);
                self.loading_context = self.context_lines;
                try args.appendSlice(ta, &.{ "diff", "--no-ext-diff", "--no-textconv", "-M", try std.fmt.allocPrint(ta, "--unified={d}", .{self.context_lines}), self.revision, self.snapshot, "--", self.loading });
            },
            .idle => unreachable,
        }
        var target = self.target;
        target.tag = @backingInt(self.stage);
        pool.launch(.{ .target = target, .executable = "git", .args = args.items, .directory = if (self.root.len > 0) self.root else self.directory, .env = environment.items, .clean_git_env = true }) catch |err| {
            if (err == error.BackgroundBusy) return;
            self.stage = .idle;
            self.cleanup(a);
            return err;
        };
        self.running = true;
    }
    pub fn consume(self: *State, a: A, job: *const jobs.Job) !void {
        if (job.target.generation != self.generation) return;
        self.running = false;
        const stage: Stage = @fromBackingInt(@intCast(job.target.tag));
        self.stage = .idle;
        if (!job.ok()) {
            if (stage == .status_counts) return self.afterStatus(a);
            if (stage == .branch_base) {
                self.branch_attempt += 1;
                if (self.branch_attempt < 2) {
                    self.stage = .branch_base;
                    return;
                }
                self.stage = .changes;
                return;
            }
            self.cleanup(a);
            try set(a, &self.message, if (job.failure) |failure| @tagName(failure) else if (job.errors.bytes.items.len > 0) job.errors.bytes.items else "Not a Git worktree");
            return;
        }
        const source = job.output.bytes.items;
        switch (stage) {
            .open => {
                var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, source, "\r\n"), '\n');
                const root = lines.next() orelse return error.InvalidGitOutput;
                const git_dir = lines.next() orelse return error.InvalidGitOutput;
                const common = lines.next() orelse return error.InvalidGitOutput;
                if (lines.next() != null or !std.fs.path.isAbsolute(root) or !std.fs.path.isAbsolute(git_dir)) return error.InvalidGitOutput;
                try set(a, &self.root, root);
                try set(a, &self.git_dir, git_dir);
                const full = if (std.fs.path.isAbsolute(common)) try a.dupe(u8, common) else try std.fs.path.resolve(a, &.{ self.directory, common });
                defer a.free(full);
                try set(a, &self.common, full);
                self.stage = .status;
            },
            .status => {
                var replacement = try Data.status(a, source);
                errdefer replacement.deinit();
                if (self.data) |*old| old.deinit();
                self.data = replacement;
                if (replacement.head.len > 0) self.stage = .status_counts else try self.afterStatus(a);
            },
            .status_counts => {
                if (self.data) |*data| data.numstat(source);
                try self.afterStatus(a);
            },
            .snapshot_add => self.stage = .snapshot_tree,
            .snapshot_tree => {
                const tree = std.mem.trim(u8, source, " \r\n");
                if (!objectId(tree)) return error.InvalidGitOutput;
                try set(a, &self.snapshot, tree);
                self.cleanup(a);
                if (self.capture) {
                    try set(a, &self.turn, tree);
                    self.capture = false;
                    if (!self.review) return;
                }
                if (!std.mem.eql(u8, self.revision, "HEAD")) a.free(self.revision);
                self.revision = "HEAD";
                if (self.base == .turn and self.turn.len > 0) self.revision = try a.dupe(u8, self.turn) else if (self.data != null and self.data.?.head.len == 0) {
                    self.stage = .empty_tree;
                    return;
                }
                if (self.base == .branch) {
                    self.branch_attempt = 0;
                    self.stage = .branch_base;
                } else self.stage = .changes;
            },
            .empty_tree => {
                const revision = std.mem.trim(u8, source, " \r\n");
                if (!objectId(revision)) return error.InvalidGitOutput;
                if (!std.mem.eql(u8, self.revision, "HEAD")) a.free(self.revision);
                self.revision = try a.dupe(u8, revision);
                self.stage = .changes;
            },
            .branch_base => {
                const revision = std.mem.trim(u8, source, " \r\n");
                if (!objectId(revision)) return error.InvalidGitOutput;
                if (!std.mem.eql(u8, self.revision, "HEAD")) a.free(self.revision);
                self.revision = try a.dupe(u8, revision);
                self.stage = .changes;
            },
            .changes => {
                if (self.data) |*data| try data.changes(source);
                self.stage = .counts;
            },
            .counts => {
                if (self.data) |*data| {
                    data.numstat(source);
                    var found = false;
                    for (data.files.items) |file| if (std.mem.eql(u8, file.path, self.selected)) {
                        found = true;
                        break;
                    };
                    if (!found and data.files.items.len > 0) try set(a, &self.selected, data.files.items[0].path);
                    if (data.files.items.len == 0) try set(a, &self.selected, "");
                }
                if (self.selected.len > 0) self.stage = .patch else {
                    try set(a, &self.patch, "");
                    self.patch_version +%= 1;
                }
            },
            .patch => {
                if (std.mem.eql(u8, self.selected, self.loading) and self.loading_context == self.context_lines) {
                    try set(a, &self.patch, source);
                    self.patch_version +%= 1;
                } else if (self.selected.len > 0) self.stage = .patch;
            },
            .idle => {},
        }
    }
    fn afterStatus(self: *State, a: A) !void {
        if (self.review or self.capture) self.stage = .snapshot_add;
        _ = a;
    }
    fn defaultBranch(self: *State, a: A) ![]const u8 {
        const path = try std.fmt.allocPrint(a, "{s}/refs/remotes/origin/HEAD", .{self.common});
        const source = os.readFile(a, path, 4096) catch "";
        const prefix = "ref: refs/remotes/origin/";
        if (std.mem.startsWith(u8, source, prefix)) return std.mem.trim(u8, source[prefix.len..], " \r\n");
        const main = try std.fmt.allocPrintSentinel(a, "{s}/refs/heads/main", .{self.common}, 0);
        if (std.c.access(main.ptr, 4) == 0) return "main";
        const packed_refs = os.readFile(a, try std.fmt.allocPrint(a, "{s}/packed-refs", .{self.common}), 1 << 20) catch "";
        if (std.mem.indexOf(u8, packed_refs, " refs/heads/main\n") != null) return "main";
        return "master";
    }
    fn cleanup(self: *State, a: A) void {
        if (self.temporary.len == 0) return;
        for ([_][]const u8{ "index", "index.lock" }) |name| {
            const file = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ self.temporary, name }, 0) catch continue;
            _ = os.c.unlink(file.ptr);
            a.free(file);
        }
        const directory = a.dupeSentinel(u8, self.temporary, 0) catch return;
        defer a.free(directory);
        _ = os.c.rmdir(directory.ptr);
        a.free(self.temporary);
        self.temporary = "";
    }
};
pub fn validPath(path: []const u8) bool {
    if (path.len == 0 or path.len > 65536 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..") or std.ascii.eqlIgnoreCase(part, ".git")) return false;
    return true;
}
fn objectId(value: []const u8) bool {
    if (value.len != 40 and value.len != 64) return false;
    for (value) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}
test "Git porcelain preserves spaces, renames, conflicts and detached/unborn metadata" {
    const a = std.testing.allocator;
    var data = try Data.status(a, "# branch.oid (initial)\x00# branch.head main\x00# branch.ab +3 -2\x001 .M N... 100644 100644 100644 a b space name\x002 R. N... 100644 100644 100644 a b R100 new name\x00old name\x00u UU N... 100644 100644 100644 100644 a b c conflict\x00? tab\tname\x00");
    defer data.deinit();
    try std.testing.expectEqualStrings("main", data.branch);
    try std.testing.expectEqual(@as(usize, 3), data.ahead);
    try std.testing.expectEqual(@as(usize, 4), data.files.items.len);
    try std.testing.expectEqualStrings("space name", data.files.items[0].path);
    try std.testing.expectEqualStrings("old name", data.files.items[1].old_path);
    data.numstat("12\t4\tspace name\x00-\t-\t\x00old name\x00new name\x00");
    try std.testing.expectEqual(@as(usize, 12), data.files.items[0].added);
    try std.testing.expect(data.files.items[1].binary);
    try std.testing.expect(!validPath("../escape") and !validPath(".git/config") and validPath("space name"));
}
