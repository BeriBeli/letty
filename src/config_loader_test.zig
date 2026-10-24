const std = @import("std");
const config = @import("config.zig");
const File = struct { path: []const u8, text: []const u8, alias: ?[]const u8 = null, denied: bool = false };
const Fs = struct {
    files: []const File,
    reads: usize = 0,
    fn canonical(raw: *anyopaque, a: std.mem.Allocator, path: []const u8) !?[]const u8 {
        const self: *Fs = @ptrCast(@alignCast(raw));
        const normalized = try std.fs.path.resolveAlloc(a, &.{path});
        for (self.files) |file| if (std.mem.eql(u8, file.path, normalized)) {
            if (file.denied) return error.AccessDenied;
            return try a.dupe(u8, file.alias orelse file.path);
        };
        return null;
    }
    fn read(raw: *anyopaque, a: std.mem.Allocator, path: []const u8, limit: usize) !?[]const u8 {
        const self: *Fs = @ptrCast(@alignCast(raw));
        self.reads += 1;
        for (self.files) |file| if (std.mem.eql(u8, file.path, path)) {
            if (file.denied) return error.AccessDenied;
            if (file.text.len > limit) return error.FileSize;
            return try a.dupe(u8, file.text);
        };
        return null;
    }
    fn reader(self: *Fs) config.includes.Reader {
        return .{ .context = self, .canonicalize = canonical, .read = read, .home = "/home/test" };
    }
};
fn load(a: std.mem.Allocator, fs: *Fs, diagnostic: ?*config.Diagnostic) !config.Config {
    return config.loadWithReaderDetailed(a, fs.reader(), "/cfg/config", .{}, diagnostic);
}

test "existing configurations without a theme load the complete Letty defaults" {
    var fs: Fs = .{ .files = &.{.{ .path = "/cfg/config", .text = "# Keep existing files without a theme directive.\nshell=/bin/sh\n" }} };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try load(arena.allocator(), &fs, null);
    try std.testing.expectEqualStrings("letty", cfg.theme);
    try std.testing.expectEqual(@as(u24, 0xffffff), cfg.background);
    try std.testing.expectEqual(@as(u24, 0xd3302f), cfg.palette[1]);
    try std.testing.expectEqual(@as(f32, 13), cfg.font_size);
}

test "included final theme resolves beside physical defining file and explicit colors override both branches" {
    var fs: Fs = .{ .files = &.{
        .{ .path = "/cfg/config", .text = "foreground=#123456\nconfig-file=child/options\nfont-size=19\nkeybind=ctrl+k>x=text:\\x00\\u{4e2d}\nbackground=#abcdef" },
        .{ .path = "/cfg/child/options", .text = "font-size=12\ntheme=light:day,dark:./night\nkeybind=ctrl+t=new_tab\nworking-directory=~/work\nkeybind-sequence-timeout=350" },
        .{ .path = "/cfg/child/themes/day", .text = "foreground=#111111\nbackground=#ffffff\nui-accent=#112233\npalette=1=#aabbcc" },
        .{ .path = "/cfg/child/night", .text = "foreground=#eeeeee\nbackground=#000000\nui-accent=#445566\npalette=1=#ddeeff" },
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg = try load(arena.allocator(), &fs, null);
    try std.testing.expectEqualStrings("day", cfg.theme);
    try std.testing.expectEqual(@as(f32, 19), cfg.font_size);
    try std.testing.expectEqual(@as(u16, 350), cfg.keybind_sequence_timeout);
    try std.testing.expectEqualStrings("/home/test/work", cfg.working_directory);
    try std.testing.expectEqual(@as(usize, 4), cfg.config_sources.len);
    try std.testing.expectEqualStrings("/cfg/child/themes/day", cfg.config_sources[2]);
    try std.testing.expectEqual(@as(usize, 2), cfg.keybinds.len);
    try std.testing.expectEqualStrings("Ctrl+k > x", cfg.keybinds[1].accelerator);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0xe4, 0xb8, 0xad }, cfg.keybinds[1].args.bytes.bytes());
    const reads = fs.reads;
    cfg.font_size = 27;
    const dark = cfg.forAppearance(true);
    try std.testing.expectEqual(@as(f32, 27), dark.font_size);
    try std.testing.expectEqualStrings("./night", dark.theme);
    try std.testing.expectEqual(@as(u24, 0x123456), dark.foreground);
    try std.testing.expectEqual(@as(u24, 0xabcdef), dark.background);
    try std.testing.expectEqual(@as(?u24, 0x445566), dark.ui_accent);
    try std.testing.expectEqual(@as(u24, 0xddeeff), dark.palette[1]);
    try std.testing.expectEqual(@as(u24, 0x123456), dark.cursor);
    try std.testing.expectEqual(@as(?u24, 0x112233), dark.forAppearance(false).ui_accent);
    try std.testing.expectEqual(reads, fs.reads);
}

test "semantic include errors retain canonical path line and include chain after document destruction" {
    var fs: Fs = .{ .files = &.{
        .{ .path = "/cfg/config", .text = "# root\nconfig-file=child/a" },
        .{ .path = "/cfg/child/a", .text = "config-file=../bad" },
        .{ .path = "/cfg/bad", .text = "# comment\nkeybind-sequence-timeout=49" },
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: config.Diagnostic = .{};
    try std.testing.expectError(error.InvalidSequenceTimeout, load(arena.allocator(), &fs, &diagnostic));
    try std.testing.expectEqualStrings("/cfg/bad", diagnostic.path[0..diagnostic.path_len]);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expectEqualStrings("keybind-sequence-timeout", diagnostic.key[0..diagnostic.key_len]);
    try std.testing.expectEqualStrings("/cfg/config:2\n/cfg/child/a:1\n", diagnostic.chain[0..diagnostic.chain_len]);
}

test "inactive missing or malformed theme rejects candidate and preserves previous owned config" {
    var fs: Fs = .{ .files = &.{.{ .path = "/cfg/config", .text = "font-family=Owned Previous\nbackground=#102030" }} };
    var previous_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer previous_arena.deinit();
    const previous = try load(previous_arena.allocator(), &fs, null);
    var candidate_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer candidate_arena.deinit();
    fs.files = &.{.{ .path = "/cfg/config", .text = "theme=light:paper,dark:missing" }};
    var diagnostic: config.Diagnostic = .{};
    try std.testing.expectError(error.ConfigNotFound, load(candidate_arena.allocator(), &fs, &diagnostic));
    try std.testing.expectEqualStrings("/cfg/themes/missing", diagnostic.path[0..diagnostic.path_len]);
    try std.testing.expectEqualStrings("/cfg/config:1\n", diagnostic.chain[0..diagnostic.chain_len]);
    fs.files = &.{
        .{ .path = "/cfg/config", .text = "config-file=child" },
        .{ .path = "/cfg/child", .text = "theme=light:paper,dark:night" },
        .{ .path = "/cfg/themes/night", .text = "config-file=bad-colors" },
        .{ .path = "/cfg/themes/bad-colors", .text = "background=invalid" },
    };
    try std.testing.expectError(error.InvalidColor, load(candidate_arena.allocator(), &fs, &diagnostic));
    try std.testing.expectEqualStrings("/cfg/themes/bad-colors", diagnostic.path[0..diagnostic.path_len]);
    try std.testing.expectEqualStrings("/cfg/config:1\n/cfg/child:1\n/cfg/themes/night:1\n", diagnostic.chain[0..diagnostic.chain_len]);
    try std.testing.expectEqualStrings("Owned Previous", previous.font);
    try std.testing.expectEqual(@as(u24, 0x102030), previous.forAppearance(true).background);
}

test "JSON profiles legacy binding and explicit colors survive conditional themes" {
    var fs: Fs = .{ .files = &.{
        .{ .path = "/cfg/config", .text = "{\"font-family\":\"JSON Font\",\"theme\":\"light:paper,dark:night\",\"background\":1193046,\"profiles\":[{\"name\":\"Local JSON\",\"cwd\":\"~/dir\"}],\"keybind_sequence_timeout\":5000,\"keybinds\":[{\"chord\":{\"key\":116,\"ctrl\":true},\"action\":\"tab\",\"accelerator\":\"Ctrl+t\"}]}" },
        .{ .path = "/cfg/themes/night", .text = "foreground=#eeeeee\nbackground=#000000" },
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try load(arena.allocator(), &fs, null);
    try std.testing.expectEqualStrings("JSON Font", cfg.font);
    try std.testing.expectEqualStrings("Local JSON", cfg.profiles[0].name);
    try std.testing.expectEqualStrings("/home/test/dir", cfg.profiles[0].cwd);
    try std.testing.expectEqual(@as(u16, 5000), cfg.keybind_sequence_timeout);
    try std.testing.expectEqual(@as(u24, 0x123456), cfg.forAppearance(true).background);
    try std.testing.expectEqual(@as(u24, 0xeeeeee), cfg.forAppearance(true).foreground);
    try std.testing.expectEqual(@as(usize, 1), cfg.keybinds.len);
}

test "config and both theme documents share aggregate byte and file limits" {
    var fs: Fs = .{ .files = &.{
        .{ .path = "/cfg/config", .text = "theme=light:day,dark:night" },
        .{ .path = "/cfg/themes/day", .text = "background=#ffffff" },
        .{ .path = "/cfg/themes/night", .text = "background=#000000" },
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: config.Diagnostic = .{};
    const bytes = fs.files[0].text.len + fs.files[1].text.len + fs.files[2].text.len;
    try std.testing.expectError(error.ConfigTotalSize, config.loadWithReaderDetailed(arena.allocator(), fs.reader(), "/cfg/config", .{ .total_bytes = bytes - 1 }, &diagnostic));
    try std.testing.expectError(error.TooManyConfigFiles, config.loadWithReaderDetailed(arena.allocator(), fs.reader(), "/cfg/config", .{ .files = 2 }, &diagnostic));
    _ = try config.loadWithReaderDetailed(arena.allocator(), fs.reader(), "/cfg/config", .{ .total_bytes = bytes, .files = 3 }, &diagnostic);
}

test "text timeout bounds and typed JSON flags validate before publication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try config.parseText(a, "keybind-sequence-timeout=50\nkeybind=all:ctrl+k=text:hello");
    try std.testing.expectError(error.InvalidSequenceTimeout, config.parseText(a, "keybind-sequence-timeout=5001"));
    var fs: Fs = .{ .files = &.{.{ .path = "/cfg/config", .text = "{\"keybinds\":[{\"chord\":{\"key\":116,\"ctrl\":true},\"action\":\"tab\",\"accelerator\":\"Ctrl+t\",\"flags\":{\"all\":true}}]}" }} };
    try std.testing.expectError(error.UnsupportedAllAction, load(a, &fs, null));
}

fn allocationFailureCandidate(backing: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    var fs: Fs = .{ .files = &.{
        .{ .path = "/cfg/config", .text = "config-file=child/options\nfont-family=Owned Font\nkeybind=ctrl+k>x=text:\\x00\\u{4e2d}" },
        .{ .path = "/cfg/child/options", .text = "theme=light:day,dark:night\nworking-directory=~/work" },
        .{ .path = "/cfg/child/themes/day", .text = "background=#ffffff\nforeground=#123456" },
        .{ .path = "/cfg/child/themes/night", .text = "background=#000000\nforeground=#abcdef" },
    } };
    const cfg = try load(arena.allocator(), &fs, null);
    try std.testing.expectEqualStrings("Owned Font", cfg.font);
    try std.testing.expectEqualStrings("night", cfg.forAppearance(true).theme);
    try std.testing.expectEqual(@as(u24, 0xabcdef), cfg.forAppearance(true).foreground);
    try std.testing.expectEqualStrings("/cfg/child/options", cfg.config_sources[1]);
}
test "every candidate allocation failure rolls back all config themes and binding storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureCandidate, .{});
}

test "equal conditional names read one theme and repeated includes preserve clear semantics" {
    var fs: Fs = .{ .files = &.{
        .{ .path = "/cfg/config", .text = "keybind=ctrl+a=new_tab\nconfig-file=child\nkeybind=ctrl+k>x=ignore\nconfig-file=?missing\ntheme=dark:night,light:night" },
        .{ .path = "/cfg/child", .text = "keybind=clear\nkeybind=ctrl+t=new_tab" },
        .{ .path = "/cfg/themes/night", .text = "background=#000000\ncursor-color=#abcdef" },
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try load(arena.allocator(), &fs, null);
    try std.testing.expectEqual(@as(usize, 3), fs.reads);
    try std.testing.expectEqual(@as(usize, 2), cfg.keybinds.len);
    try std.testing.expect(cfg.clear_default_keybinds);
    try std.testing.expectEqualStrings("/cfg/missing", cfg.config_sources[2]);
    try std.testing.expectEqual(cfg.cursor, cfg.forAppearance(true).cursor);
    try std.testing.expectEqual(@as(u24, 0xabcdef), cfg.forAppearance(false).cursor);
}

test "theme features merge by tag in both cached appearances and force off wins without changing font families" {
    var fs: Fs = .{ .files = &.{
        .{ .path = "/cfg/config", .text = "font-family=First Base\nfont-family=Final Base\nfont-family-fallback=Noto Sans CJK SC\nfont-family-fallback=Symbols Nerd Font\nfont-feature=ss01=3\ntheme=light:day,dark:night\nfont-feature=liga=1\nfont-ligatures=false\nfont-size=19" },
        .{ .path = "/cfg/themes/day", .text = "font-feature=ss01=1,calt=2,cv01=4\nbackground=#ffffff" },
        .{ .path = "/cfg/themes/night", .text = "font-feature=ss01=2,calt=3,cv01=12\nbackground=#000000" },
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg = try load(arena.allocator(), &fs, null);
    try std.testing.expectEqualStrings("Final Base", cfg.font);
    try std.testing.expectEqual(@as(usize, 2), cfg.font_fallbacks.len);
    try std.testing.expectEqualStrings("Noto Sans CJK SC", cfg.font_fallbacks[0]);
    cfg.font_size = 31;
    const reads = fs.reads;
    for ([_]bool{ false, true, false }) |dark| {
        const selected = cfg.forAppearance(dark);
        try std.testing.expectEqual(@as(?u32, 3), selected.font_features.get("ss01".*));
        try std.testing.expectEqual(@as(?u32, if (dark) 12 else 4), selected.font_features.get("cv01".*));
        try std.testing.expectEqual(@as(?u32, 1), selected.font_features.get("liga".*));
        const effective = try selected.font_features.effective(selected.font_ligatures);
        for ([_][4]u8{ "liga".*, "calt".*, "dlig".* }) |tag| try std.testing.expectEqual(@as(?u32, 0), effective.get(tag));
        try std.testing.expectEqual(@as(f32, 31), selected.font_size);
        try std.testing.expectEqualStrings("Final Base", selected.font);
        try std.testing.expectEqualStrings("Symbols Nerd Font", selected.font_fallbacks[1]);
    }
    try std.testing.expectEqual(reads, fs.reads);
}

test "font feature clear and ligature true restore defaults while retaining explicit disables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try config.parseText(a, "font-ligatures=false\nfont-feature=-liga\nfont-ligatures=true");
    const effective = try text.font_features.effective(text.font_ligatures);
    try std.testing.expectEqual(@as(?u32, 0), effective.get("liga".*));
    try std.testing.expect(effective.get("calt".*) == null and effective.get("dlig".*) == null);
    var fs: Fs = .{ .files = &.{
        .{ .path = "/cfg/config", .text = "theme=light:day,dark:night\nfont-feature=\nfont-feature=ss01=9\nfont-ligatures=true" },
        .{ .path = "/cfg/themes/day", .text = "font-feature=liga=1,cv01=3\nfont-ligatures=false" },
        .{ .path = "/cfg/themes/night", .text = "font-feature=calt=3,ss02=2\nfont-ligatures=false" },
    } };
    const cfg = try load(a, &fs, null);
    for ([_]bool{ false, true }) |dark| {
        const selected = cfg.forAppearance(dark);
        const applied = try selected.font_features.effective(selected.font_ligatures);
        try std.testing.expectEqual(@as(u8, 1), applied.len);
        try std.testing.expectEqual(@as(?u32, 9), applied.get("ss01".*));
        try std.testing.expect(applied.get("liga".*) == null and applied.get("calt".*) == null);
    }
    fs.files = &.{
        .{ .path = "/cfg/config", .text = "theme=light:day,dark:night" },
        .{ .path = "/cfg/themes/day", .text = "font-feature=-liga\nfont-ligatures=true" },
        .{ .path = "/cfg/themes/night", .text = "font-feature=ss02=2\nfont-ligatures=false" },
    };
    const themed = try load(a, &fs, null);
    try std.testing.expect(themed.forAppearance(false).font_ligatures);
    try std.testing.expect(!themed.forAppearance(true).font_ligatures);
}

test "fallback extension appends across includes resets explicitly and leaves legacy family last wins" {
    var fs: Fs = .{ .files = &.{
        .{ .path = "/cfg/config", .text = "font-family=Base 1\nfont-family-fallback=Earlier\nconfig-file=child\nfont-family=Base 2\nfont-family-fallback=\nfont-family-fallback=Final Fallback" },
        .{ .path = "/cfg/child", .text = "font-family-fallback=Child\nfont-feature=ss01=2\nfont-feature=ss01=4" },
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try load(arena.allocator(), &fs, null);
    try std.testing.expectEqualStrings("Base 2", cfg.font);
    try std.testing.expectEqual(@as(usize, 1), cfg.font_fallbacks.len);
    try std.testing.expectEqualStrings("Final Fallback", cfg.font_fallbacks[0]);
    try std.testing.expectEqual(@as(?u32, 4), cfg.font_features.get("ss01".*));
    const sixteen: [16][]const u8 = @splat("Fallback");
    try (config.Config{ .font_fallbacks = &sixteen }).validate();
    const seventeen: [17][]const u8 = @splat("Fallback");
    try std.testing.expectError(error.TooManyFontFallbacks, (config.Config{ .font_fallbacks = &seventeen }).validate());
    try std.testing.expectError(error.InvalidFontFamily, (config.Config{ .font_fallbacks = &.{""} }).validate());
    try std.testing.expectError(error.InvalidFontFamily, (config.Config{ .font_fallbacks = &.{"bad\x00name"} }).validate());
    try std.testing.expectError(error.InvalidFontFamily, (config.Config{ .font = "bad\xffname" }).validate());
    try std.testing.expectError(error.UnsupportedThemeKey, config.parseTheme(arena.allocator(), "font-family-fallback=No Theme Family"));
}

test "typed JSON font features override themes per tag and empty set explicitly resets both" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoded = try std.json.Stringify.valueAlloc(a, .{
        .theme = "light:day,dark:night",
        .font_features = try config.features.Set.parseList("ss01=9,liga=1"),
        .font_ligatures = false,
        .font_fallbacks = [_][]const u8{ "Noto Sans CJK SC", "Symbols Nerd Font" },
    }, .{});
    var fs: Fs = .{ .files = &.{
        .{ .path = "/cfg/config", .text = encoded },
        .{ .path = "/cfg/themes/day", .text = "font-feature=ss01=1,cv01=3" },
        .{ .path = "/cfg/themes/night", .text = "font-feature=ss01=2,cv01=4" },
    } };
    const cfg = try load(a, &fs, null);
    for ([_]bool{ false, true }) |dark| {
        const selected = cfg.forAppearance(dark);
        try std.testing.expectEqual(@as(?u32, 9), selected.font_features.get("ss01".*));
        try std.testing.expectEqual(@as(?u32, if (dark) 4 else 3), selected.font_features.get("cv01".*));
        try std.testing.expectEqual(@as(?u32, 0), (try selected.font_features.effective(selected.font_ligatures)).get("liga".*));
        try std.testing.expectEqualStrings("Noto Sans CJK SC", selected.font_fallbacks[0]);
    }
    const reset = try std.json.Stringify.valueAlloc(a, .{ .theme = "light:day,dark:night", .font_features = config.features.Set{} }, .{});
    fs.files = &.{
        .{ .path = "/cfg/config", .text = reset },
        .{ .path = "/cfg/themes/day", .text = "font-feature=liga=1,ss01=3\nfont-ligatures=false" },
        .{ .path = "/cfg/themes/night", .text = "font-feature=calt=2\nfont-ligatures=true" },
    };
    const cleared = try load(a, &fs, null);
    try std.testing.expectEqual(@as(u8, 0), cleared.forAppearance(false).font_features.len);
    try std.testing.expectEqual(@as(u8, 0), cleared.forAppearance(true).font_features.len);
    try std.testing.expect(!cleared.forAppearance(false).font_ligatures and cleared.forAppearance(true).font_ligatures);
}

test "bad inactive theme font feature and malformed typed set reject whole config with source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fs: Fs = .{ .files = &.{
        .{ .path = "/cfg/config", .text = "theme=light:paper,dark:night" },
        .{ .path = "/cfg/themes/night", .text = "# invalid feature\nfont-feature=liga=4294967296" },
    } };
    var diagnostic: config.Diagnostic = .{};
    try std.testing.expectError(error.InvalidValue, load(a, &fs, &diagnostic));
    try std.testing.expectEqualStrings("/cfg/themes/night", diagnostic.path[0..diagnostic.path_len]);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expectEqualStrings("font-feature", diagnostic.key[0..diagnostic.key_len]);
    try std.testing.expectEqualStrings("/cfg/config:1\n", diagnostic.chain[0..diagnostic.chain_len]);
    const bad_json = try std.json.Stringify.valueAlloc(a, .{ .font_features = config.features.Set{ .len = 33 } }, .{});
    fs.files = &.{.{ .path = "/cfg/config", .text = bad_json }};
    try std.testing.expectError(error.TooManyFeatures, load(a, &fs, null));
}
