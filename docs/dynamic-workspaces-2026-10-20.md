# Dynamic workspaces and file workspaces — 2026-10-20

This update removes fixed window, workspace, split-pane and PTY counts, adds independent file workspaces, and uses language-specific icons throughout file navigation. It preserves the native Zig VT boundary and the Linux delivery baseline.

## Behavior

- Windows, terminal/file workspaces, split nodes and PTYs grow on demand. Available memory, descriptors and OS process resources determine capacity. A failed allocation leaves existing sessions and topology intact.
- Cmd+O / Ctrl+Shift+O opens a file as an independent workspace. It appears beside terminal workspaces and occupies the main content area without creating a PTY. The side-preview header can move its current document into an independent workspace while preserving document identity and reading state.
- File workspaces participate in selection, pinning, renaming, reordering, closing and restart restoration. Missing restored files show a file error without starting a shell. Side previews retain their separate four-tab dock layout.
- File types use the pinned MIT-licensed Material Icon Theme SVG sources and reproducibly rendered PNG assets. SystemVerilog/Verilog, Markdown, C/C++ and headers, Python, Tcl, shell scripts, Makefiles and other supported extensions share the same icon in the sidebar, top tabs and preview headers.
- Workspace format v6 reads legacy collections and byte-string root arrays. Restore validates topology and ownership before starting processes. Per-session history/input, document byte/image budgets and four active file transforms remain bounded.

## Validation

Source SHA-256: `d908b46565f68af4b155c9c749059f90a90541086c5f0a0782fd8fdbc8412349`.

| Suite | Native macOS | Portable renderer on macOS |
| --- | ---: | ---: |
| Unit tests | 224 | 224 |
| Core checks | 49 | 49 |
| Hidden UI checks | 789 | 785 |
| VT replay | 9 | 9 |
| N2 checks | 24 | 24 |
| Protocol checks | 56 | 56 |
| Native VT boundary | 21 | 21 |
| Graphics boundary | 13 | 13 |

The checks include twelve real windows with independent PTYs, twelve-window configuration reload and save/restore, twenty-four simultaneous PTYs, complete Quit capture/cancellation, and injected allocation failure before new-session publication. Model tests cover 600 workspaces and high pane indices, cloning and JSON roundtrips, a 4096-pane deep split tree with iterative traversal/geometry, and 300-target close and broadcast preflight. Legacy v1 and v3 layouts, document-root migration, and stale identities are covered explicitly.

Standalone preview checks pass 71 assertions in each renderer, and Settings checks pass 80 in each renderer. The file-loader fixture passes 35 assertions, including 36 simultaneous document loaders with at most four active transforms and complete descriptor/content release. The narrow-toolbar assertion checks containment and non-overlap across font metrics, allowing controls to share a row when they fit.

The Linux cross-build uses `x86_64-linux.3.10-gnu.2.17`, baseline CPU, ReleaseSafe and VT SIMD disabled. All nine ELF files pass the ABI audit with a maximum required GLIBC version of 2.17. This is cross-build/static ABI evidence; it does not establish target Linux, X11/VDI or real IME acceptance.

Current machine-readable suite records, build manifests, component results, image hashes and package hashes are collected in [evidence.json](assets/dynamic-workspaces-2026-10-20/evidence.json). Original historical receipts and packages are retained.

## Actual UI captures

These are captures from the production views in owned hidden UI fixtures. The Tester captures application content, excluding native window titlebars. The portable renderer retains its existing emoji font-fallback limitations.

- [Native file workspace](assets/dynamic-workspaces-2026-10-20/file-workspace-native.png)
- [Portable file workspace](assets/dynamic-workspaces-2026-10-20/file-workspace-portable.png)
- [Overflowing terminal tabs](assets/dynamic-workspaces-2026-10-20/tabs-overflow-native.png)

The macOS application and versioned ZIP recorded in the evidence are local, ad-hoc-signed previews in `dist/dynamic-workspaces-d908b46565f6/`. They are excluded from Git and are not notarized distribution releases. To build a current local preview, follow the [macOS preview guide](macos-preview.md).
