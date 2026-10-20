# System requirements and compatibility

## Linux runtime baseline

Requirements are expressed as Linux/kernel/library versions. No particular distribution release is required.

| Component | Documented baseline |
|---|---|
| Architecture / CPU | x86_64, baseline CPU instruction set |
| Linux kernel | 3.10 or newer |
| glibc (GNU C library) | 2.17 or newer |
| GTK | GTK 3, 3.22.30 or newer |
| GLib | 2.56.1 or newer |
| Cairo | 1.15.12 or newer |
| Display | Working GTK/X11 display, local or forwarded through SSH |
| Fonts | Maple Mono Normal NL NF CN is bundled; optional custom/fallback TTF/TTC families are read from the GUI host |
| Terminal environment | PTY support, a usable shell, and `xterm-256color` terminfo |

**glibc and GLib are separate dependencies.** glibc provides the C runtime; GLib provides event-loop and utility interfaces used by GTK. GUI-library versions above are the recorded target-environment baseline, not independently established lowest symbol versions for each library. Newer versions must retain the required ABI and behavior; version numbers alone do not certify a distribution.

The exact build target is `x86_64-linux.3.10-gnu.2.17`, CPU `baseline`, ReleaseSafe, VT SIMD disabled. ELF auditing checks architecture, interpreter, NEEDED libraries, version requirements (at most GLIBC_2.17), and RPATH. Runtime-loaded GTK 3, GLib, GDK, Cairo, and platform services also need probing and GUI acceptance. Runtime packages need no compiler, Python, sudo, or replacement system glibc.

Linux cross-builds and static ABI audits have passed. Target-kernel execution, GTK/X11 interaction, IME, and performance acceptance remain separate work. Follow the [Linux checklist](linux-testing.md). `tools/test-centos.sh`, `el7` artifact suffixes, and immutable historical receipts retain existing names for reproducibility; these names impose no distribution requirement.

## Build and dependency decisions

- All components use **Zig 0.17.0**. Ghostty is pinned to `5064b3265e500d55f5f44ff48ca59b8685543bb8` from the official [Zig 0.17 migration PR #14519](https://github.com/ghostty-org/ghostty/pull/14519), which was unmerged when originally checked. Native and Linux targets were actually built.
- nanoui is pinned to `e4d53be8b216efa66a800bf3093d6c1cb83bbd8d`. Archive hashes and toolchain URLs/digests are in `deps.lock.json`.
- Delivery settings are explicit; a host-native target cannot replace them. No cross-toolchain LTO is used.
- The active application imports the official `ghostty-vt` Zig module. The former C VT baseline survives in the [recovery archive](c-vt-recovery.md); platform C remains in use. Do not ship incidental upstream shared libraries.
- Zig 0.17's standard I/O support baseline is newer than Linux 3.10. Lowering the target does not supply every old-syscall fallback. CI `statx` ENOSYS injection covers one path; it cannot replace target execution.

## Local nanoui patches

`tools/patch_nanoui.py` applies patches to pinned source idempotently. Failed patches stop the build rather than selecting another dependency.

| Patch | Original issue | Scope | Validation |
|---|---|---|---|
| `nanoui-01-font-io.patch` | Font std.Io metadata/read paths may need statx | Linux directory/font I/O uses project libc helpers; common CJK fallback | Real font windows/offscreen preview, CI statx injection, target probe + GUI |
| `nanoui-02-legacy-io.patch` | Font database needs bounded reads | Local File adapter: open/fstat/pread/close, 256 MiB per file | Probe reads and application rendering |
| `nanoui-03-ime.patch` | Linux lacks preedit/candidate callbacks; shortcuts may intercept Ctrl-C | Preedit, async commit, IME release/positioning, terminal focus IDs, GDK cursor release | Offscreen text; real IME pending |
| `nanoui-04-mouse.patch` | Input lacks button numbers | Button tracking and VT encoding; right-click cannot activate left-click controls | SGR core checks; real tmux mouse pending |

`nanoui-10-shift-menu-accelerator.patch` keeps lowercase parser keys and registers uppercase letters with AppKit for Shift shortcuts. Hidden native checks exercise Cmd+Shift+P through keyDown, NSMenu performKeyEquivalent, and configured overrides.

These patches are preventative or feature integration changes. Target failures do not establish that every older Linux system needs every patch. They do not expand into a Zig standard-library fork or upgrade system libraries.

## Historical initial scope

The first candidate excluded a daemon, TSP/OMP, plugins, rich content/images, complex shaping, full Kitty key-release handling, draggable split ratios, and automatic SSH authentication management. Later milestones implement some of these; consult [configuration](configuration.md) and [release records](README.md#releases-and-validation). Ordinary TUIs use xterm-256color; IME, vim/less/tmux, and X11 disconnection each require acceptance.

## Ghostty and rich-layout patches

Bootstrap calls `tools/patch_ghostty.py` to replay `ghostty-01-osc-allocation-lifetime.patch` without changing the pinned commit. It fixes OSC Capture fallible-result placement and publication of an internal writer self-reference. An induced allocation failure originally asserted; after the fix, the host reports an error. The original 12 native boundary and C 25/46/146 regressions passed, as did locked-archive replay and a second idempotence pass. This is a targeted correctness fix.

`nanoui-17-rich-layout.patch` exposes existing precise `ui.rich` text layout so Markdown drawing, hit testing, and cross-block selection share glyph mapping. It adds no second renderer or C shim. The preview batch has 17 nanoui patches and 48 affected files checked against upstream replay; use that batch's evidence for platform builds and the 600-line check.

`nanoui-18-control-modifier-refresh.patch` publishes bare Control press/release on GTK (GDK reports the state before the key event) so Ctrl-hover link/path feedback appears and clears without pointer motion. It touches only `src/linux/surface.zig` (547 lines) and adds no dependency. It has been cross-compiled; target GTK/X11 behaviour is pending acceptance.

`nanoui-19-gtk-commit-lifetime.patch` clears committed text when a GTK key-press
handler returns, after its synchronous frame has consumed it. The matching
key-release event can still commit fresh IME text, but cannot resend the prior
press. The Xvfb smoke test types a real shell command and checks its exact file
output, covering the duplicated-character regression.
