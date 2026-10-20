//! Actual application document budgets; retains all pre-existing document IDs.
const ui = @import("nanoui").ui;
const application = @import("../application_preview.zig");
pub fn run(first: anytype, t: *ui.Tester, second: anytype, other: *ui.Tester, paths: [5][:0]u8, comptime check: anytype, comptime waitDocument: anytype) !void {
    const Saved = struct { window: u64, document: u64 };
    var saved: [16]Saved = undefined;
    var saved_count: usize = 0;
    for ([_]@TypeOf(first){ first, second }) |w| for (w.preview.documents) |opt| if (opt) |d| {
        saved[saved_count] = .{ .window = w.id, .document = d.id };
        saved_count += 1;
    };
    const first_tab = first.layout.tabs[first.layout.active_tab].id;
    const second_tab = second.layout.tabs[second.layout.active_tab].id;
    try first.add(.tab);
    const fourth_tab = first.layout.tabs[first.layout.active_tab].id;
    try first.add(.tab);
    const fifth_tab = first.layout.tabs[first.layout.active_tab].id;
    const Target = struct { window: @TypeOf(first), tester: *ui.Tester, tab: u64 };
    const targets = [_]Target{
        .{ .window = first, .tester = t, .tab = first_tab },
        .{ .window = first, .tester = t, .tab = first.layout.tabs[1].id },
        .{ .window = second, .tester = other, .tab = second_tab },
        .{ .window = first, .tester = t, .tab = fourth_tab },
    };
    for (targets, 0..) |target, index| {
        const w = target.window;
        w.activateTab(w.layout.tabIndex(target.tab).?);
        for (paths[0..4]) |path| {
            try application.open(w, path);
            try waitDocument(w, target.tester, w.preview.active(target.tab).?.id, "\n");
        }
        var owned: usize = 0;
        for (w.preview.documents) |opt| if (opt) |d| if (d.tab_id == target.tab) {
            owned += 1;
        };
        if (owned != 4) return error.PreviewCapacityWorkspaceCount;
        if (index == 0) {
            const before = application.documentCount(first.host);
            const active = w.preview.active(target.tab).?.id;
            const rejected = reject: {
                application.open(w, paths[4]) catch |err| break :reject err == error.WorkspaceDocumentLimit;
                break :reject false;
            };
            try check(rejected and application.documentCount(first.host) == before and w.preview.active(target.tab).?.id == active, "fifth document in one workspace rejects WorkspaceDocumentLimit without half-open or focus change");
        }
    }
    try check(application.documentCount(first.host) == 16, "four real workspace collections own exactly sixteen prepared documents");
    first.activateTab(first.layout.tabIndex(fifth_tab).?);
    try application.open(first, paths[4]);
    try waitDocument(first, t, first.preview.active(fifth_tab).?.id, "\n");
    try check(application.documentCount(first.host) == 17 and first.preview.active(fifth_tab) != null, "seventeenth document opens in another workspace without a global count ceiling");
    for ([_]@TypeOf(first){ first, second }) |w| for (w.preview.documents) |opt| if (opt) |d| {
        var original = false;
        for (saved[0..saved_count]) |item| if (item.window == w.id and item.document == d.id) {
            original = true;
            break;
        };
        if (!original) w.preview.close(w, d.id);
    };
    first.activateTab(first.layout.tabIndex(first_tab).?);
    second.activateTab(second.layout.tabIndex(second_tab).?);
    first.host.active_id = first.id;
    t.frame();
    other.frame();
    var preserved = application.documentCount(first.host) == saved_count;
    for (saved[0..saved_count]) |item| {
        const w = first.host.find(item.window) orelse return error.PreviewCapacityWindowLost;
        preserved = preserved and w.preview.find(item.document) != null;
    }
    try check(preserved, "capacity fixture closes only temporary documents and preserves original window document IDs");
}
