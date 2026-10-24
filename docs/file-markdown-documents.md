# File and Markdown documents in the active port

This guide describes the `src/runtime/main.zig` application. The
[preceding preview guide](file-markdown-preview.md) and its release receipts
describe an earlier application and do not certify this port.

## Opening and arranging documents

Use **Open File in Workspace** (Cmd+O on macOS, Ctrl+Shift+O on Linux) to open
a local file in its own workspace. A file workspace owns no PTY. Opening the
same path in the same window selects the existing file workspace. Missing files
remain visible with an explicit error and do not start a shell.

**Open File in Side Preview** uses Cmd+Alt+O / Ctrl+Alt+Shift+O. The preview
toggle uses Cmd+Shift+O / Ctrl+Alt+O. Hiding a side preview retains its document
collection. Moving a preview to a file workspace retains the same document,
selection, scroll, zoom and editing state. The divider resizes the dock; narrow
windows give the document the available content region. Dropping files onto a
document opens them; terminal drops retain the terminal's quoted-path behavior.

Terminal local-file actions resolve paths against a verified local foreground
shell directory. Explicit-command, SSH, container and multiplexer origins are
refused when the application cannot establish a trusted local origin. Web links
use the system browser. Local Markdown links resolve against the document's
directory; network images and embedded HTML execution are not supported.

Documents use the current Kero card layout, 44-point header and shared language
icons. Window, workspace and document collections use dynamic storage without a
fixed count ceiling. Memory and OS resources still constrain capacity.

## Reading and editing

Markdown opens directly in its rendered editable form. It renders headings, emphasis, lists, quotes, fenced
code, tables, links and local PNG images, with bounded math and Mermaid flowchart
subsets. **Source** shows numbered UTF-8 source. Find, selection, copy and zoom
operate on the active document rather than the terminal.

Click rendered text to place the caret and type. Paragraphs, headings, list-item
text, quotes, links and individual table cells edit in place with their existing
font and layout. Edits patch mapped source bytes, retaining surrounding emphasis
markers, link destinations and block prefixes. Native input-method preedit is
drawn at the rich caret and commits as one edit. Keyboard undo and redo operate
on the shared source history. There is no lock or permanent edit toolbar.
Spaces at emphasis boundaries stay outside their delimiters when needed, and
caret-adjacent whitespace survives background reconciliation and paused typing.

Editing a selection across blocks, table structure, fenced code, formulas,
diagrams and image references uses **Source**. These resources retain their
native rendering and copy controls. Cmd-click / Ctrl-click follows safe links;
ordinary clicks edit link labels. Empty list items and Enter preserve list and
quote structure; splitting inside an existing inline formatted span uses Source.
This is a bounded native text editor, not a full CommonMark
authoring system or a formatting-toolbar implementation.

Reading layout uses the actual card width after sidebar changes, side-preview
dragging, split preview and zoom. Nested quotes share one subtle gray rule;
their indentation compresses to at most 30% of the reading width so it cannot
push the text outside a narrow card. Paragraphs, headings, links, inline code
and table cells wrap at native glyph/grapheme boundaries. Code blocks, wide
tables, diagrams and oversized atomic formulas keep horizontal access through
the trackpad, Shift-wheel or a draggable/clickable scrollbar. A focused scroll
track accepts arrows, Home/End and Page Up/Down. Horizontal resource scrolling
does not move ordinary prose carets, IME candidates or fitted images.

**Source** enables continuous source editing. Source edits update
the rendered Markdown after a short debounce. The wide-card **Source + Preview**
mode shows both at document widths of at least 900 points; narrower cards use
the source/rendered switch. The separate live-preview card remains a reading
surface; use the main rendered view for direct text edits. Plain text files keep
their existing explicit source-editor unlock action.

Markdown edits save automatically to the original file after 500 ms without
committed changes, in both rendered and Source modes. The footer shows only
Saved / Pending auto-save / Saving; it has no Save button. Cmd+S / Ctrl+S remains
an optional way to flush immediately. Each background write owns an immutable
snapshot. The editor keeps its caret and undo history; newer input stays pending
and schedules another write after the submitted baseline advances. Undo and redo
are changes too and follow the same automatic save mechanism.

Switching workspaces, hiding a side preview or moving a document keeps its
pending write alive. Closing flushes the latest committed revision and waits
until it is saved; typing during that write is checked again before closing.
Uncommitted input-method text prevents closing or switching its destination.
Preedit stays outside source and disk, while appearing at the rendered caret.

Failed writes retain the draft and show Auto-save paused with the error. A
conflict pauses automatic writes rather than overwriting another writer's file;
More offers **Reload disk version** as an explicit discard action. Repeated idle
frames do not retry a failed revision. New source changes can retry non-conflict
failures, and Cmd+S can retry explicitly. Only failed/conflicted closes use the
**Save / Discard / Cancel** recovery choice. Plain text files retain explicit
source saves.

Text is limited to 2 MiB and 50,000 lines; Markdown transformation has its own
1 MiB input limit. Undo/redo retain at most 64 entries and 8 MiB of history.
Image preparation and rendering retain the loader and decoder's per-document
byte and dimension bounds. Unsupported files and failed resources show explicit
fallbacks rather than executing content.

## Ownership, background work and disk behavior

The explicitly named `document-native` module reuses bounded parsing, text and
guarded-file leaf utilities. It does not import the preceding application.
Current nanoui text layout, texture, input and focus APIs provide the UI. Native
glyph hit geometry also positions the editable caret and input-method candidate
rectangle. Ordinary typing shifts an owned optimistic display projection; a
structural Enter reparses only the affected block (at most 128 KiB). The existing
background job reconciles the full Markdown. Undo/redo rebuild a bounded pure
projection. Temporary marked-text projections outlive native layout and paint.

File read/transform, save and live-draft work have separate bounded pools of four
active jobs. Each document has at most one active live-draft snapshot. A 120 ms
debounce coalesces newer revisions; stable IDs, generations and draft revisions
reject stale results. Hidden documents do not run periodic draft work. Native
file watches, manual Refresh and a coalesced refresh on focus regain drive disk
checks; there is no idle polling loop.

Saving uses the guarded native snapshot/replace path. It verifies original
identity, metadata and exact bytes, and preserves supported ownership, mode,
ACLs and extended attributes. External changes produce a conflict instead of
overwriting the draft. NFS-style unsupported-xattr behavior is covered with an
ENOTSUP fixture; a real NFS mount has not been accepted. ACL availability, server
locking, watch delivery and durability still depend on the mounted filesystem.
POSIX has no atomic compare-and-rename operation, so an uncooperative writer can
race the final comparison and rename. No force-overwrite operation is provided.

`<config path>.documents.json` stores version-1 file-workspace metadata: window
grouping, paths, names and active selection. Its serialized size is bounded to
1 MiB. It stores no unsaved draft. Restoring additional file-only windows starts
no PTY; a missing file restores its error state. Side-preview collections and
reading state remain in memory only.

## Verification

The native build runs the document module as a separate source-bound
`native-document-unit` suite, since Zig does not collect a named dependency's
tests into the main root runner. `tools/document-check` includes the migrated
document and guarded-file fixtures, including concurrent
save/edit baselines, stale live results, external conflicts and unsupported
xattrs. The current application's hidden UI suite exercises file and side
workspaces, actual rendered PNG pixels, source and rendered editing, native-menu
paste into link labels, rich heading preedit/commit, undo/redo, table-cell boundary
hits, delayed automatic saves, preedit exclusion, hidden-document saves,
save-in-flight input, external conflicts, close-time flushes, failure recovery,
moves and metadata restore.
Its screenshots cover light, dark, narrow, side, live and preedit states.

Run the repository's native build and `tools/verify-ui.py` serially against
unchanged source. Receipts must match the current source and executable hashes.
Hidden input-operation fixtures do not establish system IME, real NFS or target
Linux/X11/VDI acceptance, and historical receipts retain their original scope.
