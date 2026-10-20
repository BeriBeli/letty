//! Independently runnable feature batches; all native surfaces remain hidden.
const std = @import("std");
pub const Batch = enum { M9, M10, M11, SIDEBAR, SETTINGS, PREVIEW };
pub fn run(s: anytype, batch: Batch) !void {
    if (!s.app.flags.hidden) return error.FeatureChecksRequireHidden;
    std.debug.print("BATCH_BEGIN {s}\n", .{@tagName(batch)});
    switch (batch) {
        .M9 => {
            try @import("terminal_graphics_ui_check.zig").run(s);
            try @import("atlas_ownership_ui_check.zig").run(s);
        },
        .M10 => {
            try @import("osc52_ui_check.zig").run(s);
            try @import("terminal_inspector_ui_check.zig").run(s);
            try @import("drop_native_ui_check.zig").run(s);
            try @import("theme_browser_ui_check.zig").run(s);
        },
        .M11 => {
            try @import("services_ui_check.zig").run(s);
            try @import("services_hotkeys_ui_check.zig").run(s);
        },
        .SIDEBAR => {
            try @import("sidebar_ui_check.zig").run(s);
            try @import("sidebar_provider_ui_check.zig").run(s);
        },
        .PREVIEW => try @import("preview/application_check.zig").run(s),
        .SETTINGS => try @import("settings/application_check.zig").run(s),
    }
    std.debug.print("BATCH_END {s}\nFeature checks passed: {s}\n", .{ @tagName(batch), @tagName(batch) });
}
