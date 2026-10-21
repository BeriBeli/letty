# Local file and Markdown previews

Implemented on 2026-10-20. Validation/packages are governed by the corresponding release receipt; implementation scope does not establish target execution.

Open a local file as an independent workspace with **Open File in Workspace…**
in File or Commands, or Cmd+O / Linux Ctrl+Shift+O. It appears alongside terminals
in the sidebar or top tabs and fills the main content region. Opening the same
path again selects its existing file workspace in that window. Files open locked
and consume no PTY. Close, pin, rename, reorder, and workspace navigation retain
stable identity. Existing bindings can override or ignore the shortcut.

**Open File in Side Preview…** keeps the document beside the active terminal. The
dock's outward-arrow button or **Move Preview to Workspace** moves that document
to its own workspace while preserving selection, zoom, mode, and scroll. Modified
clicks and Preview Selected Path in terminals continue to open the side preview.
Drops onto documents open files; drops onto terminals retain quoted-path paste.

The macOS titlebar preview button, View menu, or Cmd+Shift+O / Linux Ctrl+Alt+O
opens or restores the side preview in a terminal workspace. In a file workspace
it opens another file. Hiding a side preview removes the entire dock and preserves
its reading state. There is no permanent right-hand File/Show rail.

Saved layouts use workspace format v6 and include file-workspace paths and stable
tab metadata; older v3/v4/v5 collections remain readable. Restart reopens files and
creates fresh terminal processes. Missing files remain visible with an error,
without creating a shell. Side-preview collections and reading state remain
memory-only. Windows, terminal/file workspaces, split panes and PTYs grow on demand without fixed count ceilings. File workspaces allocate no PTY. Memory, descriptors and OS resources determine available capacity; per-document byte/image limits and four concurrent read/transforms remain bounded.

Language SVG icons from the pinned MIT-licensed Material Icon Theme are shared
by file workspace rows, top tabs, and preview headers. Recognized types include
SystemVerilog/Verilog, Markdown, C and C++ source/headers, Python, Tcl, Bash/sh,
Makefile, Zig, JSON/YAML, Rust, JavaScript, and TypeScript. `.bashrc` and Makefile
names are recognized without ordinary extensions. Unknown types use a document
icon. This does not add syntax highlighting.

## Opening paths from terminal output

Hold Cmd (macOS) or Ctrl (Linux) and point at a path in terminal output: an openable path is underlined, the pointer becomes a hand, and a tooltip shows `Open Preview` with the resolved absolute path. Click to open it in the document dock. Markdown (`.md`, `.markdown`, `.mdown`) opens rendered; other UTF-8 text opens in Source with line numbers; PNG opens as an image. Without the modifier nothing is underlined and clicks select text as usual. Right-click on a path offers **Preview File** and **Copy Path**, which also work from the keyboard (arrows/Enter); Preview Selected Path remains in File, the palette and the terminal menu.

Recognised text, without touching the filesystem while hovering:

- OSC 8 hyperlinks whose target is a `file://` URI (a nonlocal host is refused when opening).
- Visible ASCII tokens (soft wraps joined, hard breaks not) that start with `/`, `./`, `../` or `~/`; relative tokens containing `/` whose last component has an extension or is a well-known name such as `Makefile`/`Dockerfile`/`README`; and bare names with an extension (`README.md`, `main.zig`).
- Trailing `:line[:column]` and compiler-style trailing `:` are accepted; the complete filename is still tried first.
- Not recognised: tokens with spaces, quotes, brackets or non-ASCII characters (select them and use Preview Selected Path), `key:value`, e-mail-like tokens, command-line flags, URLs with other schemes, and prose such as `and/or`. Heuristics can still underline a nonexistent name (for example `example.com`); opening then reports **File not found**.

Priority is fixed: HTTP(S) URLs and OSC 8 targets first (external opener), then file paths (in-app preview), then ordinary selection, multi-click selection and terminal mouse reporting. A modified click on a recognised target is consumed: it never starts a selection or sends a mouse report to a TUI, and the second click of a double click does not reopen it. A modified click elsewhere keeps its usual terminal behaviour. Linux Ctrl-click on unrecognised text therefore still reaches applications with mouse tracking.

Trust is evaluated from the terminal's PTY foreground process when the target changes and again when it is opened, using the stable session ID captured at click time:

- Sessions started with an explicit command (including SSH profiles and `--command`) never open terminal paths locally.
- If the foreground program is `ssh`, `mosh`, `telnet`, a container/VM client (`docker`, `podman`, `kubectl`, `vagrant`, …), a multiplexer (`tmux`, `screen`, `zellij`) or `chroot`/`nsenter`, paths are refused because they may describe another host or root.
- Relative paths resolve against the foreground process's kernel working directory (macOS `proc_pidinfo`, Linux `/proc/<pid>/cwd`), falling back to the shell's local OSC 7 directory only when the shell itself is in the foreground. Without either, use an absolute path. `~/` expands to the local `HOME`.
- Refused hovers show the reason in a muted tooltip without an underline, and the click falls through to the terminal.

Paths that scrolled into history from an earlier remote session cannot be told apart from local output; if such a path also exists locally, the local file is what opens. The program list is best effort: unknown remote launchers (for example `sudo ssh`) are classified by the foreground program name.

Documents dock to the workspace's right, with independent tabs, close/collapse, and width dragging. The single dock header contains document tabs, collapse, a **Source view** (`</>`) toggle for Markdown, search, and **More document actions** (`…`). Selected tabs use a subtle accent, each tab shows a close button on hover/selection, and the chevron hides the dock completely and restores its width to the terminal. On macOS, the titlebar preview icon opens or restores the dock; the adjacent ellipsis opens Commands. Other platforms retain the command palette, menu and shortcut entry points. Titlebar callbacks revalidate the active workspace, document and generation before acting. Esc in the document body returns keyboard focus to the terminal. While a document has keyboard focus, the terminal under the pointer still shows modifier-hover feedback and scrolls, but keys, text and IME never reach the PTY. A drag that starts in a terminal keeps receiving its release over the dock. Narrow windows show the full document region; collapse restores the terminal. Side-preview docks allow four document tabs each. There is no application-wide document count ceiling. Same-workspace paths reuse documents. Workspace changes retain mode/scroll; window close releases documents. Side-preview state is memory-only; independent file-workspace paths persist.

## Files and paths

Supported: UTF-8 text/code, BOM, CRLF, empty files, and PNG. Text includes line numbers, horizontal/vertical scrolling, find, selection/copy, Copy Path, and refresh. Text opens locked and can be explicitly unlocked for editing; no content is executed. Missing files, permission errors, directories/devices, binary or non-UTF-8 files, files over the limits below, and symlinked paths show an explicit state and hint in the document body instead of empty content. PDF/media/JPEG and other unsupported formats offer explicit external opening.

The header stays compact until search or **More document actions** is opened. More reveals the path field, Open/Browse, Copy, Copy Path, Refresh and External; PNG Fit/Actual/zoom also live there. These actions wrap at narrow widths. Status and the edit lock sit below the document. Errors and stale content use the theme's danger colour. The source toggle is highlighted while original Markdown text is shown; click it again to return to rendered content.

Paths accept local absolute paths, relative paths based on trusted local terminal CWD, and local file URIs. Remote OSC 7 CWD never resolves local relative paths. Try the complete filename first; only a not-found result enables `:line[:column]` parsing, preserving real colon-containing names. Reject controls, nonlocal URI authorities, special files, and symlinks in any component. On macOS, `/tmp` and `/var` are aliases; use `/private/tmp` and `/private/var`.

The path field starts with the current document path. Submitting another path restores the original document field before opening or selecting the destination, including failed attempts. Copy Path, Refresh and External always use the document model identity.

The opening pipeline accepts 4095-byte paths. Manual input is limited to 1024 bytes; longer paths show a warning and disable submit until edited. Copy Path retains the full path, and file picking/drop bypass input truncation.

## Markdown

Markdown opens rendered with an optional Source view. Native nanoui handles headings, paragraphs, bold/italic/strike, inline/fenced code, quotes, rules, lists/read-only tasks, GFM-style tables, links, anchors, and local PNGs inside the document directory. Paragraphs, headings, quotes and list bodies wrap to the available dock width. One cached visual-row map drives painting, hit testing, links, selection and search reveal; resizing and preview zoom rebuild that map. Tables use measured native cell widths, grid borders and a shaded header. Long cell content wraps within its column; left, center and right delimiter alignment applies to both headers and body cells. Wide tables retain horizontal scrolling with a position indicator. Code retains horizontal scrolling and has no syntax highlighting.

Blockquotes use native vertical rails, shaded backgrounds and depth-based insets. Consecutive quoted prose and lazy paragraph continuation join and wrap together; blank quoted lines, explicit hard breaks, headings, lists, code and nested quotes preserve their block structure. Rail characters are not inserted into copied text.

Fenced `mermaid` blocks render an inert native flowchart subset: `flowchart`/`graph`, `LR`/`RL`/`TD`/`TB`/`BT`, rectangular `[label]`, rounded `(label)` and decision `{label}` nodes, chains, `-->`/`---`/`-.->` edges, pipe labels and `-- label -->` / `-. label .->` labels. Feedback edges route around nodes. Wide diagrams scroll horizontally; Find reveals matching node text, and the diagram's Copy button copies exact multiline Mermaid source. Selecting an entire diagram does the same; selection spanning multiple blocks uses the flattened rendered text. Subgraphs, custom styling, HTML labels, other Mermaid diagram types and executable directives are not supported: the complete block remains code with an **Unsupported Mermaid · source** label. No JavaScript, browser runtime, network fetch or external renderer is used.

Math supports inline `$...$` and `\(...\)`, plus standalone `$$...$$` and `\[...\]` (single-line or separate opening/closing lines). Native boxes typeset grouped expressions, fractions (`\frac`, `\dfrac`, `\tfrac`), square roots, subscripts/superscripts, Greek letters, common operators, sums/integrals with side scripts, and plain `\text`, `\mathrm` and `\operatorname` groups. Formula boxes wrap atomically with surrounding prose and table cells reserve their full width and height. Oversized formulas scroll horizontally. Copy and Find use the underlying TeX, without delimiter markers; Source retains the original delimiters. This is not a complete TeX/KaTeX engine: matrices/environments, macros, indexed radicals, scalable delimiters and other unsupported commands retain their source with an explicit **Unsupported math** notice. Code spans/fences and escaped dollar signs are not interpreted as formulas.

Table header and delimiter column counts must match. Optional outer pipes and one-or-more-hyphen delimiter cells are accepted; missing body cells are empty and excess body cells are ignored. Copy uses tabs between cells and newlines between rows, without inserting visual-wrap newlines. Selection, links and Find use the same cached cell fragments as painting.

Selection/copy spans paragraphs/lists/code and never inserts soft-wrap newlines. Find applies to the current mode and updates as committed text is edited, scanning at most 64 KiB of candidate starts per UI pass and retaining at most 512 matches. During scanning the counter reports partial progress; marked IME text reports composition instead of a false zero-result count. Enter/Shift+Enter and Next/Prev navigate matches, revealing the selected range on both axes. Oversized matches reveal their beginning. UTF-8/grapheme indexing preserves CJK/emoji boundaries. Anchors navigate; sibling relative documents use the common open pipeline. HTTP(S) opens only after a user click through the existing opener. HTML/MDX is literal text, without script execution or automatic remote images.

This is a bounded CommonMark/GFM subset: reference-style links, HTML entity expansion, all emphasis delimiter rules, and complete nesting syntax are unsupported. Source always retains original text. Images must be relative PNGs inside the document directory without symlinks, absolute paths, parent traversal, or remote sources.

## Updates, resources, and limits

Reading/parsing/decoding runs in workers, applying only the current generation. macOS file/parent events and Linux parent-directory inotify handle writes, atomic replacement, deletion, and recreation without idle polling. Failed refresh preserves readable old content with explicit stale/error state. Unavailable watching permits manual refresh. Close removes watches before release; late results free themselves rather than affecting another window.

| Resource | Limit |
|---|---|
| Text | 2 MiB, 50000 lines, 16384 bytes/line |
| Markdown | 1 MiB source, 16384 layout lines, 32768 spans, 2048 links, 32768 table cells, depth 16, 32 MiB parse work |
| Flowchart | 16 KiB source, 128 nodes, 256 edges per block; labels ≤512 bytes; visible strokes clipped before tessellation |
| Math | 256 expressions/document; 4096 bytes, 512 syntax nodes and depth 24 per expression |
| Wrapped Markdown visual rows | 131072 prose rows and 131072 table fragments; cached by width, preview zoom and font identity |
| PNG | 4 MiB encoded, 1 megapixel, side ≤2048; upload side ≤1024 |
| Inline images | At most eight attempts/document; 4 MiB total BGRA |
| Global encoded snapshots | 32 MiB |
| Concurrency | Four active read/transforms; document watcher lifetimes grow on demand and release on close |

Excess is explicitly rejected, never presented as complete truncated content. These are separate quotas, not a total RSS ceiling; source, layout/AST, BGRA, and decoder scratch also consume memory. Images use the shared Store's unique keys; switch/refresh/hide/close release managed resources.

Document focus owns input/IME/selection/find/zoom. Terminal input, queued services, and drops revalidate actual targets. Accessibility exposes a read-only document, bounded visible text, visible path and find fields, the selected Source view toggle, More, Open/Browse, Find navigation, Copy/Copy Path, Refresh, External and image controls. Deferred actions revalidate document ID, generation, active workspace and active document before execution. Tab/Shift+Tab follows the visible preview control sequence; text fields retain Enter and composition handling. Target Linux, native IME, and screen-reader end-to-end checks remain pending.

Portable screenshots depend on installed fonts; this host's ZWJ emoji may show missing glyph boxes. Correct character boundaries/copy do not imply color-emoji parity. PNG pixel comparisons use separate text-free scenes.

Code blocks have a copy icon that copies only that block to the clipboard. The action supports pointer, keyboard, and accessibility activation and revalidates document revision before deferred execution. Rendered headings, code containers, and reading margins use the Paper layout; Source view preserves original text and whitespace.

The footer lock is a button. Hover reveals “Unlock to edit”; the same action is available to assistive technology. Clicking it captures the current file and opens a monospaced source editor for UTF-8 text or Markdown. PNG remains read-only. The file type remains at the left.

## Editing and saving

Unlocking creates an independent in-memory draft. Return inserts a newline; native selection, copy/paste and IME composition work in the editor. Cmd/Ctrl+Z undoes and Cmd/Ctrl+Shift+Z redoes, with at most 64 snapshots and 8 MiB of history per document. Markdown is edited as source.

**Save** or Cmd/Ctrl+S explicitly writes the draft and locks the document again, returning Markdown to rendered preview. **Discard** drops the draft and refreshes from disk. Clicking the lock with unsaved changes keeps the editor open and asks for Save or Discard. Closing the document, its workspace or window, and quitting are blocked while there are unsaved changes or an active file operation. Hiding or switching documents preserves drafts. Drafts are not persisted across forced process termination.

Reads and saves run in bounded background jobs, with descriptor notifications rather than idle polling. Automatic preview refresh never overwrites a draft. Saves compare file identity, metadata and exact bytes against the unlock snapshot, preserve mode/ownership/ACLs/xattrs, and atomically replace the file. External changes or a failed save leave the draft available; there is no force-overwrite action. POSIX cannot eliminate the final comparison/rename race with an uncooperative writer.

The editor preserves a UTF-8 BOM and uniform LF or CRLF newlines. Mixed or bare-CR newlines, symlinked paths and unsupported/binary formats are refused for editing. The existing 2 MiB text limit applies to the encoded saved file, with fewer than 50,000 newline characters. Oversized input is rejected without deleting the current selection. Find and rendered/source switching are available again after locking.

For an offscreen regression capture of a local report, build `tools/preview-check/build.zig`
and run `letty-preview-check --markdown /absolute/report.md --screenshot /absolute/output.png 0 900`.
Use `--diagram-screenshot` to select a zero-based flowchart or `--row-screenshot` to select a logical rendered row instead.
The last two arguments select the zero-based item and viewport width in points. This
reads the report without changing it and renders through the selected native or
portable backend. The capture fixture uses a private clipboard and no visible window.
