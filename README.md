# Letty

Letty is a Zig terminal application built on Ghostty's native `ghostty-vt`
module and nanoui. [Kero](https://github.com/egoist/kero) is a reference for
selected implementations and resources; Letty is an independent project.
The active entry point is `src/runtime/main.zig`. Selected preceding modules remain as reference source, with complete snapshots
in recovery archives. They are not linked as a second application.
Explicitly named modules reuse bounded HarfBuzz utilities for CPU grid shaping
and document parsing, editing and guarded-file leaf utilities for previews.

**The current implementation is a development build, not a release.**
The pinned reference source is Kero 2.1.10 at
`e95cbcc85be5c55dbc47630940257c9982a2a98b`.

## Local terminal architecture

Each Letty process owns its PTYs, libghostty-vt state, native renderer and GUI.
Linux can display the GUI through X11 forwarding to an X server/VDI. There is
no kerod, terminal.Mirror, detach/reattach, terminal-state network protocol,
shared remote-session service or multi-client terminal-size arbitration.
Closing the application ends its terminal processes. Embedded browser functionality
is also excluded; terminal links open in the system default application.

Ordinary windows, workspaces and split panes remain local terminal UI. Their
collections grow with available resources; per-terminal history/input and active
background work remain bounded. The new core includes local PTY launch/read/write,
native VT rendering, built-in light/dark palettes adapted from Kero, bundled
JetBrains Mono Nerd Font, workspace navigation, splits, native input, selection-aware copy, native history
search, a fuzzy command palette, configuration persistence, OSC 52 clipboard
policies, OSC 7501 records and bounded agent detection.
Implementation status and remaining Letty work are described in the
[scope and implementation boundaries](docs/implementation-scope.md) and
[per-source inventory](docs/reference-source-inventory.json).

Linux delivery remains `x86_64-linux.3.10-gnu.2.17`, baseline CPU and ReleaseSafe,
with Ghostty SIMD disabled. Runtime requirements remain GTK 3.22.30+, GLib
2.56.1+ and Cairo 1.15.12+. macOS is the development preview. Cross-compilation
and ABI checks do not establish real target X11/VDI, IME or performance acceptance.

## Build and check

Use exactly Zig 0.17.0 and Python 3. Run serially from the repository root:

```sh
python3 tools/bootstrap.py
python3 tools/build.py --native --skip-bootstrap
python3 tools/verify-ui.py --prefix=native
```

An existing compiler can be passed as `--zig=/path/to/zig`. For Linux:

```sh
python3 tools/build.py --skip-bootstrap
python3 tools/audit-elf.py zig-out/linux/bin
```

Run UI checks under `xvfb-run -a` on headless Linux. Native and portable
screenshots/checks use hidden owned windows, private configuration and PTYs.
The previous release/package gates remain historical and do not certify the port.

## Configuration and controls

Letty reads `~/.config/letty/config`, or `LETTY_CONFIG`, in
`key = value` format. `XDG_CONFIG_HOME` overrides the configuration base.
Existing `letty/kero-config` files remain a compatibility fallback when
`config` is absent. The built-in theme is named `letty`; the previous
`kero` selector remains an alias for existing configurations.
`--check-config` validates it; `--cwd=/absolute/path` and `--shell=/path/to/shell`
select the initial local shell. `--help` lists current launch options.

On macOS: Cmd+T new workspace, Cmd+N window, Cmd+D split right,
Cmd+Shift+D split down, Cmd+W close pane, Cmd+, settings, Cmd+C copy the
selection and Cmd+V paste. Cmd+F opens find and Cmd+P opens the palette.
Linux uses Ctrl+Shift+T/N/W/C/V, Ctrl+Shift+F/P and Ctrl+,. Splits use
Alt+Shift+= (right) and Alt+Shift+- (down), preserving shell Ctrl+D/T/W.
Native menus, Git/SVN Changes, 771 pinned themes, English/Chinese settings,
shortcut recording, environment editing, context menus and external terminal
links are implemented. Pane dragging/resizing, local UI preferences, image
previews, file/image paste and drop adapters, notification targets and native
review editing are integrated. Remaining parity details and platform acceptance
are tracked in the scope document. See the
[shared nanoui integration](docs/nanoui-integration.md) for the current API boundary.
The [Changes panel](docs/svn-backend.md) automatically selects Git or SVN for
the focused terminal's working directory and shares Unified/Split Diff views.
SVN shows local working-copy changes and hides Git-only comparison controls.
The [file and Markdown document guide](docs/file-markdown-documents.md)
describes PTY-free file workspaces, side previews, direct rendered Markdown text
editing, continuous source editing, live rendering and guarded automatic Markdown saves.

Kero's MIT notice, JetBrains Mono's OFL and Herdr's detection-rule Apache-2.0
license are retained under `assets/terminal/`.
