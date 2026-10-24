const std = @import("std");
const svn = @import("svn.zig");
const vcs = @import("vcs.zig");
const jobs = @import("jobs.zig");
const t = std.testing;
const a = t.allocator;
const info = "<?xml version=\"1.0\"?><info><entry kind=\"dir\" path=\".\"><wc-info><wcroot-abspath>/tmp/wc &amp; test</wcroot-abspath></wc-info></entry></info>";
const status =
    "<status><target path=\".\">" ++
    "<entry path=\"space &amp; &#x6587;&#20214; @name.sv\"><wc-status item=\"modified\" props=\"none\"/></entry>" ++
    "<entry path=\".\"><wc-status item=\"normal\" props=\"modified\"/></entry>" ++
    "<entry path=\"copy\"><wc-status item=\"added\" props=\"normal\" copied=\"true\" moved-from=\"old\"/></entry>" ++
    "<entry path=\"old\"><wc-status item=\"deleted\" props=\"none\" moved-to=\"copy\"/></entry>" ++
    "<entry path=\"prop-conflict\"><wc-status item=\"normal\" props=\"conflicted\"/></entry>" ++
    "<entry path=\"tree-conflict\"><wc-status item=\"missing\" props=\"none\" tree-conflicted=\"true\"/></entry>" ++
    "<entry path=\"text-conflict\"><wc-status item=\"conflicted\" props=\"none\"/></entry>" ++
    "<entry path=\"missing\"><wc-status item=\"missing\" props=\"none\"/></entry>" ++
    "<entry path=\"unknown\"><wc-status item=\"unversioned\" props=\"none\"/></entry>" ++
    "<entry path=\"vendor\"><wc-status item=\"external\" props=\"none\"/></entry>" ++
    "<entry path=\"external.sv\"><wc-status item=\"modified\" props=\"none\" file-external=\"true\" switched=\"true\"/></entry>" ++
    "<entry path=\"clean\"><wc-status item=\"normal\" props=\"normal\"/></entry>" ++
    "<entry path=\"ignored\"><wc-status item=\"ignored\" props=\"none\"/></entry>" ++
    "</target><changelist name=\"work\"><entry path=\"replacement\"><wc-status item=\"replaced\" props=\"none\"/></entry></changelist></status>";

test "SVN XML preserves paths, properties, conflicts, copies, moves and external markers" {
    var data = try svn.Data.status(a, status);
    defer data.deinit();
    try t.expectEqual(@as(usize, 12), data.files.items.len);
    try t.expectEqualStrings("space & 文件 @name.sv", data.files.items[0].path);
    try t.expectEqualStrings("modified", data.find(".").?.status);
    try t.expectEqualStrings("normal", data.find(".").?.text_status);
    try t.expectEqualStrings("modified", data.find(".").?.property_status);
    try t.expect(data.find("copy").?.copied);
    try t.expectEqualStrings("old", data.find("copy").?.moved_from);
    try t.expectEqualStrings("copy", data.find("old").?.moved_to);
    for ([_][]const u8{ "prop-conflict", "tree-conflict", "text-conflict" }) |path| try t.expectEqualStrings("conflicted", data.find(path).?.status);
    try t.expect(data.find("tree-conflict").?.tree_conflicted);
    try t.expectEqualStrings("missing", data.find("missing").?.status);
    try t.expectEqualStrings("untracked", data.find("unknown").?.status);
    try t.expect(data.find("vendor").?.external);
    try t.expect(data.find("external.sv").?.external and data.find("external.sv").?.switched);
    try t.expectEqualStrings("replaced", data.find("replacement").?.status);
}
test "SVN roots use local wcroot metadata and decode split text without trimming filenames" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    try t.expectEqualStrings("/tmp/wc & test", try svn.workingCopyRoot(arena.allocator(), info));
    try t.expectEqualStrings("/tmp/ x ", try svn.workingCopyRoot(arena.allocator(), "<info><entry><wc-info><wcroot-abspath>/tmp/<!-- split --> x </wcroot-abspath></wc-info></entry></info>"));
    try t.expectError(error.NotSvnWorkingCopy, svn.workingCopyRoot(arena.allocator(), "<info><entry><url>https://server/repo</url></entry></info>"));
    try t.expectError(error.InvalidSvnOutput, svn.workingCopyRoot(arena.allocator(), "<info><entry><wc-info><wcroot-abspath>relative</wcroot-abspath></wc-info></entry></info>"));
}
test "SVN XML rejects malformed documents, entities, duplicate attributes and traversal" {
    for ([_][]const u8{
        "",                                                                                                             "<status>",                                                                                            "<status></wrong>",                                            "<status/><status/>",                                     "<!DOCTYPE status [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><status/>",
        "<status><entry path='x'/></status>",                                                                           "<status><target><entry path='x' path='y'/></target></status>",                                        "<status><target><entry path='&unknown;'/></target></status>", "<status><target><entry path='&#0;'/></target></status>", "<status><target><entry path='../escape'><wc-status item='modified' props='none'/></entry></target></status>",
        "<status><target><entry path='.svn/wc.db'><wc-status item='modified' props='none'/></entry></target></status>", "<status><target><entry path='x'><wc-status item='invented' props='none'/></entry></target></status>",
    }) |source| {
        if (svn.Data.status(a, source)) |result| {
            var data = result;
            data.deinit();
            return error.AcceptedInvalidXml;
        } else |_| {}
    }
    var data = try svn.Data.status(a, "<status><target><entry path='&quot;&apos;&#9;&#10;'><wc-status item='modified' props='none'/></entry></target></status>");
    defer data.deinit();
    try t.expectEqualStrings("\"'\t\n", data.files.items[0].path);
    const huge = try a.alloc(u8, (4 << 20) + 1);
    defer a.free(huge);
    try t.expectError(error.SvnOutputLimit, svn.Data.status(a, huge));
}
fn deliver(state: *svn.State, source: []const u8, exit: i32, failure: ?jobs.Job.Failure) !void {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const spec = try state.command(arena.allocator());
    state.active = spec.target;
    state.running = true;
    if (state.stage == .patch) {
        if (state.loading.len > 0) a.free(state.loading);
        state.loading = try a.dupe(u8, state.selected);
    }
    var pool: jobs.Pool = .{ .a = a, .wake_fd = -1 };
    var job: jobs.Job = undefined;
    job = .{ .pool = &pool, .target = spec.target, .status = exit, .failure = failure, .output = .{ .job = &job, .limit = 4 << 20 }, .errors = .{ .job = &job, .limit = 32768 } };
    try job.output.bytes.appendSlice(a, source);
    defer job.output.bytes.deinit(a);
    try state.consume(a, &job);
}
test "SVN state opens, refreshes, selects and clears clean diffs with explicit capabilities" {
    var state: svn.State = .{};
    defer state.deinit(a);
    try state.request(a, .{ .window = 1, .workspace = 2, .pane = 3 }, "/tmp/wc & test/subdirectory", true);
    try deliver(&state, info, 0, null);
    try t.expectEqualStrings("/tmp/wc & test", state.root);
    try t.expectEqual(svn.Stage.status, state.stage);
    try deliver(&state, status, 0, null);
    try t.expectEqual(svn.Stage.patch, state.stage);
    try deliver(&state, "--- old\n+++ new\n@@ -1 +1 @@\n-old\n+new\n", 0, null);
    try t.expect(std.mem.indexOf(u8, state.patch, "+new") != null);
    const version = state.patch_version;
    try state.select(a, "copy");
    try t.expect(state.patch_version > version);
    try t.expectEqualStrings("", state.patch);
    try deliver(&state, "copy patch", 0, null);
    try t.expectEqualStrings("copy patch", state.patch);
    try state.request(a, .{ .window = 1, .workspace = 2, .pane = 3 }, state.directory, true);
    try deliver(&state, "<status><target path='.'/></status>", 0, null);
    try t.expectEqualStrings("", state.selected);
    try t.expectEqualStrings("", state.patch);
    try t.expectEqual(svn.Stage.idle, state.stage);
    try t.expectError(error.SvnSelectionMissing, state.select(a, "gone"));
    var common: vcs.State = .{ .backend = .svn };
    defer common.deinit(a);
    try t.expect(common.supportsBase(.head));
    try t.expect(!common.supportsBase(.turn) and !common.supportsBase(.branch));
    try t.expectEqual(@as(usize, 0), common.files().len);
    const svn_version = common.patchVersion();
    common.backend = .git;
    try t.expect(common.patchVersion() != svn_version);
}
test "SVN command arguments are local, bounded and literal including peg and option-like names" {
    var state: svn.State = .{};
    defer state.deinit(a);
    try state.request(a, .{ .window = 1 }, "/tmp/wc", true);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const open = try state.command(alloc);
    try t.expectEqualStrings(".@", open.args[open.args.len - 1]);
    try t.expectEqual(@as(usize, 4 << 20), open.limit);
    try t.expectEqual(@as(u32, 15000), open.timeout_ms);
    state.stage = .status;
    const scan = try state.command(alloc);
    for (scan.args) |arg| try t.expect(!std.mem.eql(u8, arg, "-u"));
    for ([_][]const u8{ "-flags.sv", "name@42.sv", "https:thing", "space & 文件.sv" }) |path| {
        state.stage = .patch;
        state.selected = try a.dupe(u8, path);
        const spec = try state.command(alloc);
        try t.expectEqualStrings(try std.fmt.allocPrint(alloc, "./{s}", .{path}), spec.args[spec.args.len - 1]);
        a.free(state.selected);
        state.selected = "";
    }
    try t.expect(!svn.validPath("../x") and !svn.validPath("a/.svn/wc.db") and !svn.validPath("/absolute") and !svn.validPath("null\x00name"));
}
test "SVN ignores stale owner and generation responses while allowing a new directory request" {
    var state: svn.State = .{};
    defer state.deinit(a);
    try state.request(a, .{ .window = 1, .workspace = 2, .pane = 3 }, "/tmp/old", true);
    state.running = true;
    state.active = state.target;
    state.active.tag = @backingInt(state.stage);
    var pool: jobs.Pool = .{ .a = a, .wake_fd = -1 };
    var job: jobs.Job = undefined;
    job = .{ .pool = &pool, .target = state.active, .status = 0, .output = .{ .job = &job, .limit = 4096 }, .errors = .{ .job = &job, .limit = 4096 } };
    try job.output.bytes.appendSlice(a, info);
    defer job.output.bytes.deinit(a);
    try state.request(a, .{ .window = 4, .workspace = 5, .pane = 6 }, "/tmp/new", true);
    job.target.pane = 999;
    try state.consume(a, &job);
    try t.expect(state.running);
    job.target = state.active;
    try state.consume(a, &job);
    try t.expect(!state.running);
    try t.expectEqualStrings("", state.root);
    try t.expectEqualStrings("/tmp/new", state.directory);
    try t.expectEqual(svn.Stage.open, state.stage);
}
test "SVN failed and limited jobs clear stale previews and allow retry" {
    var state: svn.State = .{};
    defer state.deinit(a);
    try state.request(a, .{ .window = 1 }, "/tmp/wc", true);
    try deliver(&state, info, 0, null);
    try deliver(&state, status, 0, null);
    try deliver(&state, "patch", 0, null);
    for ([_]jobs.Job.Failure{ .timeout, .output_limit, .cancelled }) |failure| {
        try state.select(a, "copy");
        try deliver(&state, "partial", 0, failure);
        try t.expectEqualStrings("", state.patch);
        try t.expectEqualStrings(@tagName(failure), state.message);
    }
    try state.request(a, .{ .window = 1 }, state.directory, true);
    try deliver(&state, "", 1, null);
    try t.expect(state.data == null);
    try t.expectEqualStrings("", state.root);
    try state.request(a, .{ .window = 1 }, state.directory, true);
    try t.expectEqual(svn.Stage.open, state.stage);
}
test "SVN unavailable path kinds report why instead of displaying an empty diff" {
    var state: svn.State = .{};
    defer state.deinit(a);
    try state.request(a, .{ .window = 1 }, "/tmp/wc", true);
    try deliver(&state, info, 0, null);
    try deliver(&state, status, 0, null);
    var pool: jobs.Pool = .{ .a = a, .wake_fd = -1 };
    defer pool.deinit();
    for ([_][]const u8{ "unknown", "missing", "vendor", "external.sv" }) |path| {
        try state.select(a, path);
        try state.pump(a, &pool);
        try t.expectEqual(svn.Stage.idle, state.stage);
        try t.expect(state.message.len > 0 and state.patch.len == 0);
        try t.expectEqual(@as(usize, 0), pool.jobs.items.len);
    }
}

test "SVN parsing rolls back every allocation failure" {
    try t.checkAllAllocationFailures(a, struct {
        fn parse(alloc: std.mem.Allocator) !void {
            var data = try svn.Data.status(alloc, status);
            defer data.deinit();
        }
    }.parse, .{});
}

test "SVN XML nesting and change lists have explicit limits" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    try source.appendSlice(a, "<status>");
    for (0..32) |_| try source.appendSlice(a, "<nested>");
    for (0..32) |_| try source.appendSlice(a, "</nested>");
    try source.appendSlice(a, "</status>");
    try t.expectError(error.InvalidSvnXml, svn.Data.status(a, source.items));
    source.clearRetainingCapacity();
    try source.appendSlice(a, "<status><target>");
    for (0..16385) |_| try source.appendSlice(a, "<entry path='file'><wc-status item='modified' props='none'/></entry>");
    try source.appendSlice(a, "</target></status>");
    try t.expectError(error.SvnFileLimit, svn.Data.status(a, source.items));
}

test "SVN selection changes during a running patch discard both old success and failure" {
    var state: svn.State = .{};
    defer state.deinit(a);
    try state.request(a, .{ .window = 1 }, "/tmp/wc", true);
    try deliver(&state, info, 0, null);
    try deliver(&state, status, 0, null);
    var pool: jobs.Pool = .{ .a = a, .wake_fd = -1 };
    var job: jobs.Job = undefined;
    job = .{ .pool = &pool, .target = state.target, .status = 0, .output = .{ .job = &job, .limit = 4096 }, .errors = .{ .job = &job, .limit = 4096 } };
    job.target.tag = @backingInt(svn.Stage.patch);
    try job.output.bytes.appendSlice(a, "old patch");
    defer job.output.bytes.deinit(a);
    for ([_]i32{ 0, 1 }) |exit| {
        state.running = true;
        state.active = job.target;
        if (state.loading.len > 0) a.free(state.loading);
        state.loading = try a.dupe(u8, "old selection");
        try state.select(a, "copy");
        job.status = exit;
        try state.consume(a, &job);
        try t.expectEqual(svn.Stage.patch, state.stage);
        try t.expectEqualStrings("", state.patch);
        try t.expectEqualStrings("", state.message);
    }
    try deliver(&state, "new patch", 0, null);
    try t.expectEqualStrings("new patch", state.patch);
}
