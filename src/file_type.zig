//! Filename-only classification: no IO, parsing, or borrowed VT text.
const std = @import("std");
pub const Kind = enum { generic, verilog, markdown, c, h, cpp, hpp, python, tcl, console, makefile, zig, json, yaml, rust, javascript, typescript };
fn one(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.ascii.eqlIgnoreCase(value, choice)) return true;
    return false;
}
pub fn classify(path: []const u8) Kind {
    const name = std.fs.path.basename(path);
    if (one(name, &.{ "makefile", "gnumakefile", "bsdmakefile", "kbuild" })) return .makefile;
    if (one(name, &.{ ".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".profile", ".zshrc", ".zshenv", ".zprofile" })) return .console;
    const ext = std.fs.path.extension(name);
    // Uppercase .C/.H traditionally mean C++ on case-sensitive hosts.
    if (std.mem.eql(u8, ext, ".C")) return .cpp;
    if (std.mem.eql(u8, ext, ".H")) return .hpp;
    if (one(ext, &.{ ".sv", ".svh", ".v", ".vh", ".vhd", ".vhdl" })) return .verilog;
    if (one(ext, &.{ ".md", ".markdown", ".mdown", ".mkd" })) return .markdown;
    if (one(ext, &.{".c"})) return .c;
    if (one(ext, &.{".h"})) return .h;
    if (one(ext, &.{ ".cpp", ".cc", ".cxx", ".c++", ".ipp" })) return .cpp;
    if (one(ext, &.{ ".hpp", ".hh", ".hxx", ".h++" })) return .hpp;
    if (one(ext, &.{ ".py", ".pyw", ".pyi" })) return .python;
    if (one(ext, &.{ ".tcl", ".tk", ".do" })) return .tcl;
    if (one(ext, &.{ ".bash", ".sh", ".zsh", ".ksh", ".fish", ".csh" })) return .console;
    if (one(ext, &.{ ".mk", ".mak" })) return .makefile;
    if (one(ext, &.{ ".zig", ".zon" })) return .zig;
    if (one(ext, &.{ ".json", ".jsonc" })) return .json;
    if (one(ext, &.{ ".yaml", ".yml" })) return .yaml;
    if (one(ext, &.{".rs"})) return .rust;
    if (one(ext, &.{ ".js", ".mjs", ".cjs", ".jsx" })) return .javascript;
    if (one(ext, &.{ ".ts", ".tsx" })) return .typescript;
    return .generic;
}
test "language filename associations preserve source/header distinctions and fallback" {
    const cases = .{ .{ "rtl/top.sv", Kind.verilog }, .{ "pkg.svh", Kind.verilog }, .{ "README.MD", Kind.markdown }, .{ "main.c", Kind.c }, .{ "api.h", Kind.h }, .{ "main.C", Kind.cpp }, .{ "api.H", Kind.hpp }, .{ "x.c++", Kind.cpp }, .{ "x.hpp", Kind.hpp }, .{ "x.py", Kind.python }, .{ "flow.tcl", Kind.tcl }, .{ "run.bash", Kind.console }, .{ "run.sh", Kind.console }, .{ ".bashrc", Kind.console }, .{ "Makefile", Kind.makefile }, .{ "GNUmakefile", Kind.makefile }, .{ "rules.mk", Kind.makefile }, .{ "readme.txt", Kind.generic }, .{ "README", Kind.generic } };
    inline for (cases) |case| try std.testing.expectEqual(case[1], classify(case[0]));
}
