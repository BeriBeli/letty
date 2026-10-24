# Local terminal architecture

The active Letty implementation is described by [the implementation scope](implementation-scope.md).
`src/runtime/main.zig` is the only application entry point selected by `build.zig`.
The older application modules outside `src/runtime/` are recovery/reference source.
Explicitly named modules reuse bounded HarfBuzz shaping helpers and the
document parser/editor/guarded-file leaf utilities. They do not import the older
application; see [nanoui integration](nanoui-integration.md).

## Ownership

`desktop.Runtime` owns heap-stable windows and queued actions. A window owns
dynamic workspaces. Each workspace owns a split layout and stable pane owners;
each pane owns one local PTY, child process and `terminal.Terminal`.
The latter owns the official native `ghostty-vt` Terminal, parser stream, render
state, status records and a bounded transmit queue. No other process owns or
mirrors this terminal state. No terminal socket, daemon or attach protocol exists.

A file workspace instead owns a dynamic document collection and no PTY. Terminal
workspaces can own side-preview documents. Document addresses stay stable while
moving between these owners. Deferred operations revalidate document identity
and generation. Read/transform, save and live-draft pools each bound active work;
live drafts coalesce revisions and accept only the latest result. Save owns a
submitted snapshot and advances its baseline without losing later source edits.
See [file and Markdown documents](file-markdown-documents.md).

PTY and libghostty-vt activity is serialized on the toolkit thread. PTY reads
and writes use 64 KiB callback budgets; descriptor readiness drives both.
Child completion wakes the loop through a self-pipe. There is no idle process
scan or redraw timer. Hidden workspaces still parse output; only visible output
or changed navigation metadata requests drawing.

Normal input has a 1 MiB queue budget plus a 64 KiB protocol reply reserve.
Deferred UI work is bounded to 256 actions and 2 MiB of owned input text, with
32 actions per loop wake. Window/workspace/pane collections have no fixed count
ceiling. Creation prepares allocations before publishing a new layout. Close
cancels descriptor watches before releasing PTY/VT ownership; master descriptors
close before waiting for exiting children.

## Input and rendering

Actions capture window, workspace and pane IDs and resolve them again after
the frame. Input additionally requires the same active workspace, focused pane
and terminal focus domain. Settings and closed/stale targets reject input.
The native input method's marked text stays outside the PTY until committed.
Key and paste encoding uses libghostty-vt's current terminal modes.

`render.zig` consumes native RenderState directly. It copies borrowed text into
the frame allocator, paints backgrounds before glyphs, and shapes style runs
against terminal cell boundaries. The Linux nanoui renderer retains its CPU
backing and damage presentation; macOS uses the native toolkit renderer.
X11 transports the resulting GUI. There is no serialized grid or Mirror layer.
Native font I/O uses a small Zig libc ABI adapter, including glibc 2.17's
versioned fstat boundary, without raising the kernel/library baseline.

OSC 7501 uses libghostty-vt's parser callback and owned bounded records.
Explicit blocked/working/error/done records have priority according to Kero's
reduction semantics. Shell command markers and query replies remain local.
The pinned agent screen rules run in a bounded Zig NFA on output-driven updates.
Notifications carry bounded, single-use activation tokens resolved to live IDs.
Image decoding runs in bounded owned helper processes, with no GUI/VT pointers
in child jobs. File editing keeps a copied snapshot and refuses externally
changed content; native UI uses current nanoui fields and focus metadata.

## Verification and remaining scope

The model/VT unit suite, private PTY fixture and hidden-window UI suite cover
the replacement's implemented subset. Their logs must bind to current source
and executables. Old release receipts and old optional tool targets do not
certify this source. The [source inventory](reference-source-inventory.json) distinguishes
pending, partial and explicitly excluded upstream modules. Full Kero parity is
not claimed. Real oldest-target Linux, X11/VDI, IME and performance acceptance
remain separate work.
