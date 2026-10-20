//! Terminal text -> local preview candidates. Classification is pure; trust only
//! queries the PTY foreground process table and never stats or reads a candidate,
//! so hovering cannot block on slow or remote filesystems.
const std = @import("std");
const paths = @import("preview/path.zig");
const url = @import("url.zig");
const Text = @import("fixed_text.zig").Text;

pub const Kind = enum { none, url, file };

/// OSC 8 metadata is classified as given; plain-text tokens must look like paths.
pub fn classify(target: []const u8, osc8: bool) Kind {
    if (url.allowed(target)) return .url;
    if (osc8) return if (fileUri(target)) .file else .none;
    return if (isPath(target)) .file else .none;
}

/// Compiler output commonly ends locations with ':' ("a.zig:3:9: error").
pub fn trimPlain(raw: []const u8) []const u8 {
    var value = raw;
    while (value.len > 1 and value[value.len - 1] == ':') value = value[0 .. value.len - 1];
    return value;
}

fn fileUri(value: []const u8) bool {
    return value.len > 7 and std.ascii.eqlIgnoreCase(value[0..7], "file://");
}

fn stripLocation(value: []const u8) []const u8 {
    var out = value;
    for (0..2) |_| {
        const colon = std.mem.lastIndexOfScalar(u8, out, ':') orelse break;
        if (colon == 0 or colon + 1 == out.len) break;
        for (out[colon + 1 ..]) |ch| if (!std.ascii.isDigit(ch)) return out;
        out = out[0..colon];
    }
    return out;
}

const extensionless = [_][]const u8{ "Makefile", "makefile", "GNUmakefile", "Dockerfile", "Containerfile", "Justfile", "justfile", "Gemfile", "Rakefile", "Procfile", "Vagrantfile", "README", "LICENSE", "COPYING", "CHANGELOG", "AUTHORS", "NOTICE", "CODEOWNERS" };

fn hasLetter(value: []const u8) bool {
    for (value) |ch| if (std.ascii.isAlphabetic(ch)) return true;
    return false;
}

fn extension(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    if (dot == 0) return name.len >= 2 and std.ascii.isAlphabetic(name[1]); // dotfiles
    const ext = name[dot + 1 ..];
    if (ext.len == 0 or ext.len > 12 or !hasLetter(ext)) return false;
    for (ext) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    for (name[0..dot]) |ch| if (std.ascii.isAlphanumeric(ch)) return true;
    return false;
}

/// Heuristic only: no filesystem access. Opening still reports missing files.
pub fn isPath(raw: []const u8) bool {
    const value = trimPlain(raw);
    if (value.len == 0 or value.len > 4095 or value[0] == '-') return false;
    if (fileUri(value)) return true;
    if (std.mem.indexOf(u8, value, "://") != null) return false;
    const path = stripLocation(value);
    if (path.len == 0 or path[path.len - 1] == '/') return false;
    const anchored = path[0] == '/' or std.mem.startsWith(u8, path, "./") or std.mem.startsWith(u8, path, "../") or std.mem.startsWith(u8, path, "~/");
    if (anchored) return path.len > 1 and !std.mem.startsWith(u8, path, "//");
    const slash = std.mem.indexOfScalar(u8, path, '/') != null;
    // Bare "key:value" and e-mail-like tokens are not filenames.
    if (std.mem.indexOfScalar(u8, path, ':') != null) return false;
    if (!slash and std.mem.indexOfScalar(u8, path, '@') != null) return false;
    const name = std.fs.path.basename(path);
    for (extensionless) |known| if (std.mem.eql(u8, name, known)) return true;
    return extension(name);
}

pub const Refusal = enum {
    explicit_command,
    remote_program,
    unverified,
    relative_base,
    home,
    pub fn message(self: Refusal) []const u8 {
        return switch (self) {
            .explicit_command => "Paths from command or SSH profile terminals are not opened as local files",
            .remote_program => "Paths shown by ssh, containers or multiplexers are not opened as local files",
            .unverified => "Cannot verify that this terminal's foreground process is local",
            .relative_base => "Relative path needs a local working directory; use an absolute path",
            .home => "HOME is unavailable for a ~/ path",
        };
    }
};

/// Snapshot taken when a target changes and again immediately before opening.
pub const Origin = struct {
    refusal: ?Refusal = null,
    cwd: Text(4096) = .{},
    program: Text(64) = .{},
};

/// Programs whose output may describe another host, container root or session.
const remote_programs = [_][]const u8{ "ssh", "slogin", "autossh", "sshpass", "mosh", "mosh-client", "et", "telnet", "rlogin", "rsh", "docker", "podman", "nerdctl", "kubectl", "oc", "lxc", "incus", "vagrant", "multipass", "limactl", "colima", "toolbox", "distrobox", "distrobox-enter", "wsl", "gcloud", "az", "aws", "tsh", "boundary", "kitten", "tmux", "screen", "zellij", "abduco", "dtach", "chroot", "nsenter", "systemd-nspawn", "machinectl", "nc", "ncat", "socat", "cu", "minicom", "picocom" };

pub fn remoteProgram(raw: []const u8) bool {
    const name = std.mem.trimStart(u8, std.fs.path.basename(raw), "-");
    for (remote_programs) |known| if (std.mem.eql(u8, name, known)) return true;
    return false;
}

/// Pure trust decision; `origin` supplies live process facts.
pub fn decide(explicit_command: bool, program: ?[]const u8, kernel_cwd: []const u8, shell_foreground: bool, reported_cwd: []const u8) Origin {
    var out: Origin = .{};
    if (explicit_command) {
        out.refusal = .explicit_command;
        return out;
    }
    const name = program orelse {
        out.refusal = .unverified;
        return out;
    };
    out.program.set(name);
    if (remoteProgram(name)) {
        out.refusal = .remote_program;
        return out;
    }
    if (kernel_cwd.len > 0 and kernel_cwd[0] == '/') out.cwd.set(kernel_cwd) else if (shell_foreground and reported_cwd.len > 0 and reported_cwd[0] == '/') out.cwd.set(reported_cwd);
    return out;
}

pub fn origin(session: anytype) Origin {
    if (session.explicit_command) return decide(true, null, "", false, "");
    var name: [64]u8 = @splat(0);
    var cwd: [4096]u8 = @splat(0);
    const group = @import("platform_ffi.zig").lt_foreground_process(session.fd, &name, name.len, &cwd, cwd.len);
    if (group <= 0) return decide(false, null, "", false, "");
    const shell = group == session.shell_group or (session.shell_group == 0 and group == session.pid);
    return decide(false, std.mem.sliceTo(&name, 0), std.mem.sliceTo(&cwd, 0), shell, session.cwd.text());
}

extern "c" fn gethostname([*]u8, usize) c_int;
pub fn hostname() Text(256) {
    var out: Text(256) = .{};
    if (gethostname(&out.buf, out.buf.len) == 0) out.len = std.mem.sliceTo(&out.buf, 0).len;
    return out;
}
pub fn home() []const u8 {
    return std.mem.span(@import("platform_ffi.zig").lt_env("HOME"));
}

pub const Outcome = union(enum) { path: paths.Resolved, refused: Refusal, invalid: anyerror };

/// Live origin + resolution for one session, as used by hover and execution.
pub fn resolveFor(session: anytype, target: []const u8) Outcome {
    const host = hostname();
    return resolve(target, origin(session), home(), host.text());
}

pub fn resolve(target: []const u8, o: Origin, home_dir: []const u8, host: []const u8) Outcome {
    if (o.refusal) |reason| return .{ .refused = reason };
    var value = target;
    var expanded: [8192]u8 = undefined;
    if (std.mem.startsWith(u8, value, "~/")) {
        if (home_dir.len == 0 or home_dir[0] != '/') return .{ .refused = .home };
        value = std.fmt.bufPrint(&expanded, "{s}/{s}", .{ home_dir, value[2..] }) catch return .{ .invalid = error.PreviewPathTooLong };
    }
    if (value.len > 0 and value[0] != '/' and !fileUri(value) and o.cwd.len == 0) return .{ .refused = .relative_base };
    return .{ .path = paths.resolve(value, o.cwd.text(), host) catch |err| return .{ .invalid = err } };
}

/// User-facing reasons for resolution errors; never shows raw error identifiers.
pub fn invalidMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.RemotePreviewUnsupported => "File URI names another host; only local files can be previewed",
        error.UnsupportedPreviewScheme => "Only local paths and file:// URIs can be previewed",
        error.PreviewPathTooLong, error.PreviewPathTooDeep => "Path is too long to preview",
        error.WorkspaceDocumentLimit => "This workspace already has four documents; close one first",
        error.InvalidPreviewPath, error.InvalidFileUri, error.InvalidPreviewEscape => "Not a valid local file path",
        error.LocalPreviewBaseRequired => "Relative path needs a local working directory; use an absolute path",
        error.PreviewResourceOutsideDirectory => "Linked file is outside the document directory",
        error.PreviewWorkspaceUnavailable => "Open a terminal tab before previewing a file",
        error.PreviewNotificationUnavailable => "File change notifications are unavailable; preview not opened",
        error.OutOfMemory => "Not enough memory to open the preview",
        else => "Cannot open the file preview",
    };
}

test "terminal path classification is conservative and filesystem-free" {
    for ([_][]const u8{ "/etc/hosts", "./build.zig", "../docs/README.md", "~/notes.md", "src/main.zig", "src/main.zig:12:3", "src/main.zig:12:3:", "README.md", "docs/a-b_c.v2.txt", "Makefile", "tools/Dockerfile", ".zshrc", "file:///tmp/a%20b.md", "/private/tmp/x:12" }) |good| {
        if (!isPath(good)) {
            std.debug.print("expected path: {s}\n", .{good});
            return error.TestExpectedPath;
        }
    }
    for ([_][]const u8{ "", "and/or", "1.2.3", "v1.2", "--config=a.md", "user@example.com", "https://example.com/a.md", "ftp://host/a.md", "key:value.md", "dir/", "/", "//network/share", "...", "a", "12:30" }) |bad| {
        if (isPath(bad)) {
            std.debug.print("unexpected path: {s}\n", .{bad});
            return error.TestUnexpectedPath;
        }
    }
    try std.testing.expectEqual(Kind.url, classify("https://example.com/x.md", false));
    try std.testing.expectEqual(Kind.file, classify("file:///tmp/x.md", true));
    try std.testing.expectEqual(Kind.none, classify("mailto:a@b", true));
    try std.testing.expectEqual(Kind.none, classify("plain", false));
    try std.testing.expectEqualStrings("a.zig:3:9", trimPlain("a.zig:3:9::"));
}

test "terminal path trust refuses remote and explicit-command origins" {
    try std.testing.expectEqual(Refusal.explicit_command, decide(true, "zsh", "/home/a", true, "/home/a").refusal.?);
    try std.testing.expectEqual(Refusal.unverified, decide(false, null, "", true, "/home/a").refusal.?);
    for ([_][]const u8{ "ssh", "-ssh", "/usr/bin/mosh-client", "docker", "kubectl", "tmux" }) |remote| try std.testing.expectEqual(Refusal.remote_program, decide(false, remote, "/home/a", false, "/home/a").refusal.?);
    const shell = decide(false, "zsh", "", true, "/home/a");
    try std.testing.expect(shell.refusal == null and std.mem.eql(u8, shell.cwd.text(), "/home/a"));
    const job = decide(false, "make", "/home/a/sub", false, "/home/a");
    try std.testing.expect(job.refusal == null and std.mem.eql(u8, job.cwd.text(), "/home/a/sub"));
    // A job without a kernel CWD never borrows the shell's reported directory.
    try std.testing.expectEqual(@as(usize, 0), decide(false, "make", "", false, "/home/a").cwd.len);
}

test "terminal path resolution uses the trusted origin only" {
    const local = decide(false, "zsh", "/work/repo", true, "");
    try std.testing.expectEqualStrings("/work/repo/src/a.md", resolve("src/a.md", local, "/home/me", "host").path.path.text());
    try std.testing.expectEqualStrings("/work/a.md:3", resolve("../a.md:3", local, "/home/me", "host").path.path.text());
    try std.testing.expectEqualStrings("/home/me/n.md", resolve("~/n.md", local, "/home/me", "host").path.path.text());
    try std.testing.expectEqual(Refusal.home, resolve("~/n.md", local, "", "host").refused);
    const no_base = decide(false, "make", "", false, "");
    try std.testing.expectEqual(Refusal.relative_base, resolve("src/a.md", no_base, "/home/me", "host").refused);
    try std.testing.expectEqualStrings("/etc/hosts", resolve("/etc/hosts", no_base, "", "host").path.path.text());
    try std.testing.expect(resolve("file://other/etc/hosts", local, "", "host") == .invalid);
    try std.testing.expectEqual(Refusal.remote_program, resolve("/etc/hosts", decide(false, "ssh", "/", false, ""), "", "host").refused);
}
