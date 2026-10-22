//! Explicit diagnostics only: walking pages must never enter the draw path.
const Context = @import("context.zig").Context;
pub const Info = struct {
    heap_core: usize = 0,
    heap_graphics: usize = 0,
    page_virtual: usize = 0,
    page_resident_estimate: usize = 0,
    pages: usize = 0,
};
pub fn info(v: *const Context) Info {
    var out: Info = .{ .heap_core = v.quota.core_used, .heap_graphics = v.quota.graphics_used };
    inline for (.{ .primary, .alternate }) |key| if (v.terminal.screens.all.get(key)) |screen| {
        const usage = screen.pages.memoryUsage();
        out.page_virtual += usage.virtual_bytes;
        out.page_resident_estimate += usage.resident_bytes;
        out.pages += usage.pages;
    };
    return out;
}
