# Letty implementation scope

Letty is an independent Zig terminal application. Kero supplies reference code
and resources with retained attribution; its module layout and feature list do
not define Letty's identity or require full upstream feature parity. Owned source
lives under responsibility-based names, including `src/runtime/`,
`src/document_host.zig` and `src/interface_assets.zig`.

## Settings persistence

Settings choices and committed edits save and apply immediately. The active
window has no Cancel / Save and apply header. Validation and atomic persistence
finish before the candidate replaces the current configuration. Failed writes
and external changes retain the last saved values; successful edits survive
closing or reopening Settings. See [Settings](settings-window.md).

## Product and process boundary

User decision, 2026-10-23: Letty is a terminal emulator, not a terminal
multiplexer. Each Letty process owns its local PTYs, libghostty-vt terminals,
native renderer, windows and ordinary tab/split UI. On a remote Linux machine,
the application sends its GUI through X11 to the user's X server/VDI. No
terminal grid, mirror, or remote session protocol travels beside X11.

Do not implement Kero's kerod, terminal.Mirror, attach/detach, cross-client
resize arbitration, headless session server, persistent processes after GUI
exit, SSH/Tailscale session aggregation, or remote daemon installation/update.
An ordinary shell can still run OpenSSH. Saving UI preferences/layout does not
promise to restore a running process.

Letty's terminal scope includes local shell
launch and input, project-oriented navigation, terminal cards, configuration,
themes, menus/palette/find, status reports and agent detection, notifications,
local Git review, file/image interactions, settings and desktop integration.
The user also excludes browser functionality: do not add browser panes, embedded
webviews, address bars, ad blocking, favicons or browser CLI commands. Opening a
terminal link in the OS default application remains a terminal interaction.

## Source identity and recovery

Reference: egoist/kero `e95cbcc85be5c55dbc47630940257c9982a2a98b` (2.1.10).
Archive SHA-256:
`a1294b12a2ac298dbc8993a9b64fa87ea7c9425c8447c3976908e7318902bcd1`.
`reference-source-inventory.json` records every upstream Go file and its hash. Pending
entries are unfinished work, not implementations. Excluded multiplexer/server
entries must remain explicitly excluded.

The previous Letty checkout, including uncommitted changes, was captured in
`.cache/recovery/pre-kero-zig-20261023T061014Z.tar.gz` with SHA-256
`9cb529354908860612f1c5e800e6fcacd96ded83933b4fd3518c2fefacf2aa45`.
Selected preceding modules remain in the checkout as reference source. The
[cleanup record](archive/cleanup-2026-10-24.md) identifies disconnected files
removed after preserving their original bytes in a verified recovery archive. The replacement does not import the old application,
configuration or terminal backend. The bounded HarfBuzz leaf adapter
(`portable_text_bridge.zig`, `portable_shaper.zig`, `run_clusters.zig` and
`font_features.zig`) is explicitly reused for nanoui’s current CPU grid API.
Its pinned C ABI wrapper only bridges the third-party shaping library; VT
ownership and terminal behavior remain native Zig.
The abandoned daemon experiment is retained only in
`.cache/recovery/kero-daemon-experiment-before-local-only.tar.gz`.

## Engineering boundary

- Exactly Zig 0.17.0; native `ghostty-vt` module; SIMD disabled.
- Linux target `x86_64-linux.3.10-gnu.2.17`, baseline CPU, ReleaseSafe.
- Native toolkit rendering on macOS; portable CPU/GTK/X11 rendering on Linux.
- Event-driven PTY read/write and child completion; no redraw/OS polling at idle.
- Dynamic windows/workspaces/panes; bounded per-terminal history/input and active
  work; stable identities for deferred actions.
- Use the host-permitted file-descriptor allowance at GUI startup, preserving
  the hard limit. This avoids macOS's inherited 256-descriptor soft limit while
  document/VCS/image background jobs retain their existing concurrency bounds.
- Retain Kero MIT notices and the separate Apache-2.0 detection-rule license.
- Fresh unit, PTY and hidden GUI evidence is required for the replacement.
  Previous Letty receipts do not certify it. Cross-builds do not establish real
  target X11/VDI performance or input-method acceptance.

## Current implementation boundary

The replacement builds from `src/runtime/main.zig`. Implemented paths include:

- Owned local PTYs and native VT state, bounded queues, windows, workspaces and
  split panes, with stable deferred action targets.
- Native cell-run rendering, Unicode selection, selection-aware copy,
  bracketed paste, mouse reporting/selection and fractional history scrolling.
- Incremental native history search, a fuzzy session/command palette, pane
  navigation/zoom and session rename.
- A shared Git/SVN Changes panel, local SVN BASE diffs and property/conflict
  status, with Unified/Split rendering and backend-specific comparison controls.
- Terminal repository badges show Git branch/change totals or SVN working-copy
  status and open Changes for the exact pane. The existing local process probe
  tracks shell cwd without requiring OSC 7; output bursts schedule one coalesced
  refresh after 250 ms, with no periodic idle scan. `git-status` controls badge
  visibility for both supported backends. SVN requires a discoverable local CLI.
- Validated key=value configuration, searchable setting controls, atomic persistence,
  explicit reload and environment values for newly created terminals. Some
  recognized settings still await their behavior; parsing is not feature parity.
- OSC 7501 records, the pinned agent detection rules compiled into a bounded Zig
  NFA (including region gates), foreground-process identification and a one-shot
  completion debounce. Six upstream Claude fixtures exercise the rule engine.
- OSC 52 text clipboard policies and private fixture clipboards, basic desktop
  notifications, built-in palettes and bundled JetBrains Mono Nerd Font.
- A pinned 771-theme Ghostty catalog, light/dark theme selection and custom local
  theme files, selection colors, minimum contrast, live scrollback limits and
  macOS translucency. Theme previews do not mutate terminal state.
- Minimum contrast preserves the original colors of Powerline, box/block and
  legacy-computing graphics, following the pinned Ghostty exemption. Adjacent
  ordinary text still receives contrast correction.
- Native application menus, close/quit confirmation, focus-mode reports and
  transactional pane restart, using product-owned adapters for current nanoui.
- English/Simplified Chinese catalogs, labeled/validated settings, shortcut
  recording with per-action unbind/reset, and repeated environment editing.
- Terminal context menus, copied OSC 8 targets, soft-wrapped printed links and
  paths, modifier-click OS opening, URI-authority validation and selection
  autoscroll. No embedded browser is involved.

The shared nanoui integration is described in [nanoui integration](nanoui-integration.md).
The current framework does not provide the retired application close callback:
Letty owns the platform close guard instead. CPU grid shaping is installed through
`TextSystem.setRunShaper`, with shared immutable font-source leases and bounded
HarfBuzz caches. Input edge state belongs to each `ui.Context`, and the terminal
advertises `FocusedText.editable = false` to retain control-key ownership.

The current local feature set also includes:

- Split-divider dragging and title dragging into edge/swap drop zones. Layout
  replacement is transactional; PTYs retain their original identities.
- Side-panel/sidebar width and visibility, font zoom and project folding in a
  separate bounded UI-preference file. It stores no processes or terminal grids.
- Bounded local image previews through a short-lived decoder process. macOS uses
  ImageIO; Linux uses the installed GdkPixbuf image loaders. The GUI accepts only
  PNG thumbnails up to 1024×1024; input is limited to 64 MiB, helper output to
  8 MiB and execution to three seconds, with four background jobs across the app.
- Clipboard file paths and PNG images, including bounded macOS TIFF-to-PNG
  conversion. Paths are shell quoted; pasted PNG files belong to their pane and
  are removed when it closes. Per-pane paste storage is limited to 64 files and
  128 MiB. Native AppKit/GTK file drops use product adapters.
- macOS notification activation, Dock badges and attention requests; Linux
  freedesktop notification default actions and sound suppression. Notifications
  carry bounded single-use tokens, resolved to live window/workspace/pane IDs.
- A native, virtualized review editor with a 1 MiB UTF-8 limit, grapheme-aware
  movement, sticky display-column navigation, undo/redo, find, inline IME preedit
  and guarded atomic saves. Preedit retains the original selection, uses
  nanoui byte selection offsets and candidate geometry, and commits as one undo
  entry; cancellation leaves the document unchanged. Undo and redo together
  retain at most 64 snapshots / 8 MiB. Native grapheme segmentation streams
  through long combining sequences without a fixed codepoint cutoff. Worktree
  directory traversal uses no-follow handles. External content changes reject a
  save; ordinary file mode bits are retained. ACL/xattr preservation is not
  asserted. The hash checks precede rename rather than providing a kernel CAS.
- Agent-turn hunk Keep/Revert controls. Revert verifies the current hunk's exact
  text and the file hash before writing; edits outside the hunk are retained.
  Keep is a local review marker. Working agents disable these writes.
- Local launch commands (`-- COMMAND`, `-e COMMAND`) and `config
  path|show|check|edit`. Shell paths resolve through an absolute PATH entry;
  environment construction happens before `forkpty`, leaving no allocator or
  environment mutation between fork and exec.

The current port additionally provides:

- Shared Git/SVN context controls: add 20 lines, request the whole bounded file,
  or restore three-line context. Git reads the same private snapshot; SVN reads
  local BASE-to-WORKING. Results retain the 8 MiB job-output and 100000-line model
  limits. Expanded context can merge adjacent hunks, just as the backend CLI
  does; hunk actions apply to the hunk currently displayed.
- Diff-local case-insensitive ASCII / exact Unicode search, wraparound navigation,
  match backgrounds and native scroll positioning in Unified and Split views.
  Search stores at most 8192 matches. Lexical colors cover common C-like, Zig,
  Go, Rust, JavaScript, Python, shell and configuration files. They are bounded
  lexical hints, not a full language grammar; state restarts at omitted gaps.
  Search backgrounds and token colors are composed into nanoui's current sorted,
  disjoint rich-text spans.
- Unique project groups even when sessions are noncontiguous, session grip
  dragging, project reordering, per-project new/close controls and a session
  context menu. Moving a session between projects changes its presentation
  group and the starting directory for future panes; existing shells retain
  their identities and working directories. Closing a project validates every
  member before destroying any. Deferred moves reject closed target IDs.
- Compact content-sized sidebar and terminal menus, keyboard navigation,
  scrolling and viewport clamping. File workspaces expose document actions
  rather than terminal metadata. Project headers support display-name editing
  and whole-group dragging; rename completion cannot enter text into a PTY.
  Empty command palettes show No matches and shrink to content.
- Native Kitty graphics through Ghostty's official stream, image storage and
  render-state placement API. Direct RGB/RGBA/PNG, chunked transmission, source
  cropping, alpha, three z layers, relative placements, Unicode placeholders and
  alternate-screen ownership feed nanoui's current `ui.texture` API. Animated
  images use Ghostty's ticker and request frames only while visible and playing.
  Native physical-pixel placements map once to logical nanoui coordinates at
  the window scale; replacing one image preserves other cached pixel copies.

Graphics use direct transmission only: filesystem, temporary-file and shared
memory media are disabled. Resident native storage is 8 MiB per screen. PNG
input and each drawn image are limited to 4 MiB, with a 2048-pixel side limit;
PNG scratch is 16 MiB. APC allocations have a separate 48 MiB requested-heap
quota, retaining ordinary terminal allocation headroom. Quota rejection abandons
only the incomplete upload, allowing subsequent terminal text to proceed.
The core VT requested-heap cap is 160 MiB. These figures exclude Ghostty's
separately bounded history mmap, backing-allocator metadata and renderer memory;
they are not process RSS claims. The renderer retains at most 32 image copies /
8 MiB and 512 placements, scanning at most 2048 native placements per frame.
PNG decoding, geometry and quota leaves were brought into `src/runtime/` explicitly;
no preceding application module or C VT backend is loaded.

Remaining parity details include per-separator directional diff expansion,
full editor grammar and release/platform integration
acceptance. The native editor is intentionally bounded; files larger than 1 MiB
remain readable as patches or through the system default application. Numeric
font weights map to nanoui's four supported weights; hardware-key release
reporting is limited by its current input API. Linux has no standardized Dock
badge/bounce equivalent wired here. Menus on Linux are accelerator-backed and
available through the command palette because nanoui does not build native Linux
menu bars.
The source inventory remains conservative: `partial` identifies applicable
behavior with remaining differences rather than asserting line-for-line source
parity. No source is left unclassified as `pending`, but this does **not** mean
that every Kero/mygo behavior has passed acceptance or reached exact parity.
Browser and terminal-multiplexer behavior are explicitly excluded. Kero's
`internal/update` is a **kero-server/kerod updater**, so it is excluded too.
Real Linux X11/VDI/IME, native notification delivery and native file-drop
acceptance remain separate from hidden fixtures and cross-build evidence.

## Letty configuration

The active format is `key = value` in `LETTY_CONFIG` or
`~/.config/letty/config` (under `XDG_CONFIG_HOME` when set). Existing
`letty/kero-config` files remain a compatibility fallback until moved; the
canonical file takes precedence. Legacy configuration documentation describes the
recovery implementation, rather than the active entry point.

- `theme = letty`, a catalog name, or `light:Name,dark:Name`. The previous `kero`
  selector remains a compatibility alias. Custom names are
  searched under `LETTY_THEME_DIR` and Ghostty's XDG/home theme directories;
  absolute paths are accepted. The catalog is generated reproducibly with
  `tools/compile-themes.py` from Ghostty's pinned theme package.
- `language = system`, `en` or `zh-Hans`; settings and menus update on apply.
- Repeated `keybind = Ctrl+F5=session.new`. Explicit assignments displace default
  collisions. `keybind = none=session.new` unbinds an action; Reset removes its
  overrides. The recorder disables native menu shortcuts while listening.
- Repeated `env = NAME=value` apply to newly launched PTYs. The native editor has
  a 16 KiB form limit and directs larger lists to the configuration file instead
  of truncating existing values. The full parser accepts at most 1 MiB.
- `right-click-action = context-menu`, `paste` or `copy-or-paste`.
  Application mouse-reporting modes retain mouse ownership; Shift allows local
  interaction. Cmd on macOS or Ctrl on Linux opens a terminal link externally.

Settings writes validate the entire candidate, retain comments/unrelated list
entries and reject an external edit until Reload. Theme files and configuration
are read at initialization or deferred actions, outside terminal rendering.

## Local interaction details

UI preferences live beside the active configuration as `<config>.ui.json`.
Malformed files fall back to presentation defaults. Changes are written by
coalesced deferred actions; shell/process lifetime never depends on that file.
Project aliases are bounded owned UTF-8 strings stored in the same preferences;
renaming a project changes only its displayed name, never a filesystem path.
At narrow widths the sidebar hides automatically; its shortcut reveals it on
the first press. See the [current UI audit](terminal-ui-audit-2026-10-24.md) for
captured behavior and acceptance limits.

Dragging a terminal title past the movement threshold shows a side/swap target;
only a live pane in the same workspace can receive the move. Divider ratios stay
between 0.12 and 0.88. Deferred resize/move actions validate both pane IDs again.

A local terminal file link may carry `:line[:column]`; the path is stripped of
that suffix before asking the OS default application to open it. File URI
hosts must be empty, localhost or this machine's hostname. PNG clipboard data
must declare nonzero dimensions with at most 16 million pixels and occupy at most
32 MiB. A new image never silently evicts a pasted file another program may still
need; a full per-pane store rejects the next image paste.

The review editor and hunk actions never stage or commit changes. Temporary Git
indexes and atomic editor files are private and removed on their owned paths.
No test uses the system clipboard, posts native notifications or launches an
external application. Hidden checks use private files and explicit text input
operations; they do not certify real input-method or native drag/drop behavior.
