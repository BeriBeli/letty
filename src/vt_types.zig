//! Letty-owned VT values. No upstream terminal types cross this boundary.
//! Cell.text is borrowed until the next iterator step, feed, resize, frame end,
//! or destroy. Copy text before retaining it beyond that scope.
pub const Reply = *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void;
pub const Cell = extern struct { x: c_uint, y: c_uint, width: c_uint, flags: c_uint, fg: u32, bg: u32, text: ?[*]const u8, len: usize, underline: u8 = 0, underline_color: u32 = 0 };
pub const Cursor = extern struct { x: c_uint = 0, y: c_uint = 0, style: c_uint = 0, visible: bool = false, blinking: bool = false, color: u32 = 0, bg: u32 = 0 };
pub const Scroll = extern struct { total: u64 = 0, offset: u64 = 0, len: u64 = 0, alternate: bool = false };
pub const SearchInfo = extern struct { total: usize = 0, current: usize = 0, running: bool = false };
pub const Link = extern struct { first: c_uint = 0, last: c_uint = 0, osc8: bool = false };
pub const Events = extern struct {
    bells: u64 = 0,
    pwd: u64 = 0,
    prompts: u64 = 0,
    starts: u64 = 0,
    ends: u64 = 0,
    progress_state: c_int = 0,
    progress: c_int = -1,
    exit_code: c_int = 0,
    has_exit: bool = false,
    at_prompt: bool = false,
};

pub const Capabilities = struct {
    basic: bool = false,
    frame: bool = false,
    input: bool = false,
    events: bool = false,
    history: bool = false,
    selection: bool = false,
    search: bool = false,
    links: bool = false,
    graphics: bool = false,
};
