//! Owned-by-backend change records shared by Git and SVN consumers.
pub const File = struct {
    path: []const u8,
    old_path: []const u8 = "",
    status: []const u8,
    added: usize = 0,
    removed: usize = 0,
    binary: bool = false,
    // SVN keeps text and property status separate, including property conflicts.
    text_status: []const u8 = "",
    property_status: []const u8 = "",
    copied: bool = false,
    tree_conflicted: bool = false,
    switched: bool = false,
    external: bool = false,
    moved_from: []const u8 = "",
    moved_to: []const u8 = "",
};
