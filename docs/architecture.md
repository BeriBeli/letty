# Architecture and ownership

## Sessions and VT

The application owns dynamic window/layout/session registries. Window and Session objects retain stable heap addresses while their slot arrays grow. Live sessions receive monotonically increasing IDs; pane UI keys derive from IDs, so reused slots never reuse callback targets. Windows, workspaces, split nodes and PTYs have no fixed count ceiling. Allocation and OS process/file-descriptor failures reject creation without publishing a partial layout. Layout indices use `usize`; owned topology clones isolate creation and configuration transactions. Close confirmations, input broadcasts, drop geometry, sidebar snapshots and persistence cover the complete dynamic collections. Per-session history/TX and active background-work budgets remain bounded. Restored data is capped at 64 MiB and validated for duplicate identities/panes, cycles, orphans and active-pane ownership before spawning any processes. Legacy byte-string roots and eight/sixteen-slot arrays migrate to numeric index arrays.

`session.zig` owns one nonblocking PTY, one VT/history, and one bounded TX queue per session. GTK/GLib calls VT serially on the main thread. Reads use 1 KiB chunks with a 64 KiB callback budget; writes also stop at 64 KiB. TX capacity is 1 MiB plus a 64 KiB protocol-reply reserve inaccessible to user input. Queue pressure suspends PTY read sources until writes drain. Partial writes/EAGAIN preserve bytes and order. One callback queues each protocol reply exactly once and never recursively feeds VT.

Reply overflow explicitly fails the session; ordinary output uses PTY backpressure. Paste is fully encoded/preflighted before enqueue, preventing partial bracketed-paste framing. Hidden tabs continue parsing output/exits; ordinary output redraws only visible panes.

`vt.zig` is the public native Zig boundary; `vt_types.zig` contains Letty-owned fixed-size values and `platform_ffi.zig` holds platform interfaces. `vt_zig/` directly imports pinned `ghostty-vt`. Active builds have no C VT bridge/archive/backend selector. The independently restored [C archive](c-vt-recovery.md) retains the old baseline; platform C for PTYs/files/GTK/X11 remains.

Ghostty creates/releases its VT/render/search/iterator allocations. Borrowed text is valid only during controlled iteration; UI copies visible-cell UTF-8 for the frame and retains no borrowed pointers or history mirror. Tracked grid references keep selection anchors consistent through scrolling/pruning.

Native Context is heap-stable; stream construction follows terminal placement. Teardown: stream → selection/search → render → terminal. Production sessions pass application Io explicitly. Allocation/semantic failures propagate through the facade, including deferred leave handling. Reply effects only copy into bounded host queues.

## Rendering and input

`terminal_view.zig` builds visible cells with wide/combining text, colors, bold/italic, underline/strike, and cursor. Wide tail cells do not redraw glyphs. Linux uses nanoui portable text/CPU rendering and one shared framebuffer per OS window; macOS uses the same UI with CoreText/Metal.

`terminal_runs.zig` splits rows at style/link/selection/search/cursor boundaries. Per-frame UTF-8/cell mappings retain VT geometry; CoreText/pinned HarfBuzz supply glyphs/clusters without paragraph reordering. Draw order is backgrounds, glyphs, then overlays. Whole-grapheme fallback preserves diagnostics for missing glyphs/formats.

CoreText converts color fonts to monochrome masks retaining contrast. Portable rendering uses bounded TrueType resources and pinned HarfBuzz. Font/fallback/feature/source ownership survives configuration arena changes; failed candidates release immediately, published font sources remain stable until database teardown.

Linux CPU rendering keeps BGRA backing and compares actual instances plus glyph/image atlas generations to skip, partially repaint, or fully repaint. Damage clears rectangles and replays all intersecting instances in order without changing rounded clips. Resize/scale/theme/atlas-size/backing invalidation forces full rebuild; invalid backing is never presented. Actual X11 transport/presentation still needs measurement.

M7 input flows through `input_dispatch` → `binding_dispatch` / `binding_sequence` → owning Request → session queue. Each window has a cancellable one-shot timer delivered on AppKit libdispatch or GTK GLib. Cancellation/completion drops timer references. Ordinary text/idle frames skip action-availability work; pending sequences recheck per event. Broadcast snapshots stable IDs, preflights every queue, enqueues all, then flushes; completed OS writes cannot be undone.

Linux uses `g_unix_fd_add_full` for I/O and `g_child_watch_add` for exits. PTY and redraw-idle sources share priority so output cannot starve redraw; GDK input retains higher priority. Idle sessions have no polling timer. Search schedules bounded work only while active. Clipboard reads are asynchronous and retain the requesting Session ID. Resize updates VT before TIOCSWINSZ, including font pixel changes.

`platform/compat.c` centralizes libc file/directory I/O, forkpty, nonblocking operations, old-kernel compatibility, and diagnostics. Close cancels sources, terminates foreground/direct-child process groups, closes PTY, reaps children, and finally frees VT/queues. Sessions follow the GUI process; no daemon exists.

## Actions, configuration, and layouts

`actions.zig` defines typed Requests and shared availability. Bindings, native menus, and nanoui palette use one dispatcher and `command_catalogue.zig`. `app_menu`, `tabs`, `workspace_view`, and `search_overlay` handle their views; state orchestrates ownership/actions.

`config_include` performs bounded canonical-path expansion/source tracking. `config` validates both conditional themes in a candidate arena. `config_reload` checks all windows' profiles/layouts before replacing the shared owner. Appearance notifications select cached colors and preserve temporary zoom without rereading files or restarting PTYs. Failure in either theme rejects the candidate.

v2 introduced stable tab IDs, title overrides, and focus memory, migrating validated v1 data before spawn. Workspace format v6 includes file-workspace paths in addition to window collections, pinned groups, and sidebar metadata; prior formats migrate. Layout v4 uses the maximum `usize` value as a validated document-root sentinel outside the node array; legacy v3 sentinel 31 is normalized on decode, so file workspaces consume no split nodes or PTY slots. Geometry and session lookup exclude that sentinel; file records must match each file workspace exactly once. `layout_geometry` chooses directional neighbors by shared projection, equalizes by leaf count, and resizes the nearest same-axis ancestor. Zoom changes presentation, not topology/ratios; obscured panes parse without ordinary-output redraw.

`vt_zig/search` keeps viewport hit markers separate from selection with a 64 MiB quota and visible errors. `selection` owns tracked anchors; `navigation` handles scroll/reset. `prompt_clear` follows pinned Ghostty Termio. Session reserves TX before mutation, then sends one FF after leaving VT to redraw the shell edit buffer. Scrollbars use total/offset/length without copying history.

`application_commands`, `close_request`, and `message_dialog` own cancellable stable-ID close transactions, configuration creation/diagnostics, and failure paths. nanoui-05 allows veto before native destruction. O_EXCL protects creation; failed reload preserves configuration/PTYs.

## Clipboard, shell, and feedback

`clipboard.zig` owns bounded async delivery/confirmation. PRIMARY/CLIPBOARD are separate; no PTY bytes precede confirmation. `vt_zig/links` reads OSC 8 metadata, bounded URLs, or (`lt_vt_token_at`) bounded visible tokens only for visible hits; `link_view` caches by VT revision and `url` centralizes HTTP(S) opener policy. `terminal_paths` classifies path-like tokens without filesystem access and derives trust from the PTY foreground process (`lt_foreground_process`: name and kernel CWD); `application_preview.openTerminalPath` revalidates the captured session ID and trust before opening.

`vt_zig/effects` callbacks copy scalars/counts without reentry. After feed, Session copies borrowed PWD. `cwd.zig` decodes authority and the platform validates local directories. Shell scripts are injected only through child environment and located relative to the executable; explicit commands/disabled integration receive none.

`feedback` aggregates pane BEL/completion/failure/progress per tab. Hidden ordinary output does not repaint, while feedback transitions can wake UI. nanoui-08 unifies native focus callbacks. State revokes old focus before granting new; Session deduplicates mode-1004 reports. Protocol reports bypass user-input scroll/selection/busy side effects.

Host launch behavior follows pinned Ghostty `termio/Exec.zig::execCommand`, `Config.probableCliEnvironment`, `WorkingDirectory`, and `os/desktop.zig`, adapted through nanoui/PTY boundaries. macOS login's watched PID differs from the shell foreground group recorded at the first reliable prompt. Linux directly launches non-login shells. Window/tab/split inheritance uses independent switches.

## Windows, Settings, and sidebar

`AppState` owns global IDs, the dynamic window registry, shared configuration and the persistence lock. `WindowState` owns one layout/views/overlays/input. Menu callbacks retain AppState and resolve the active Window ID. Session IDs are application-wide; tab IDs are namespaced by Window ID.

Window close is cancellable, with native destruction deferred to the next event. Async reads retain WindowState; late clipboard responses discard on shutting_down and final references release state. Close/reap tickets are individually allocated and released after their callbacks. A separate host lifetime guard prevents queued callbacks dereferencing dead hosts. Workspace/configuration transactions validate complete sets and budgets before spawn/publication.

AppState owns a singleton Settings window outside terminal registries/PTY budgets. Settings Save and Reload share `config_transaction`: validate candidate → reserve services → checked file save → infallible publication. Failure rolls back reservations; old arenas release only after all windows/theme leases rebind. Native callbacks enqueue rather than showing blocking permission dialogs during parsing/platform callbacks.

`navigation/geometry` supplies the shared content rectangle for panes/search/splits/drop/IME/AX/images. The sidebar presents the existing Tab/split tree rather than a second workspace/session model. Event-triggered `session_metadata` workers publish owned snapshots through completion FDs after generation/process-identity validation. Static frames never query the OS; disable/exit cancels nonblockingly and removes watches.

## Graphics and local previews

Images and OSC 52 writes are integrated; graphics defaults off, OSC 52 writes deny, reads unsupported. M9 captures owned protocol snapshots with managed keys. CPU/Metal share source crops/clips and clamp bilinear sampling to original crop pixel centers to prevent 2× bleed. Viewport clipping never tightens original sampling bounds.

`application_preview.Runtime(WindowState)` owns documents by stable workspace/document IDs independently of Session/PTY. Geometry subtracts the document dock for terminal/drop/search/IME/AX. `preview/model.zig` and separate `platform/file_preview.c` use workers, generations, and file/parent events for owned snapshots. Markdown parsing/PNG decoding run in the same worker via prepare hooks. UI transfers results only at a new frame, avoiding nested native-picker runloops freeing text borrowed by the current frame. Document and Kitty images share the Store's unique key source.

Queued services capture window/session/tab and, for document actions, focus domain/document ID/generation, revalidating before execution. AX/drop reject stale targets. Preview IME blocks document switching/close/global zoom. Resize captures original tab/document and rolls back on workspace switch/focus loss. See [preview capabilities](file-markdown-preview.md).

Migration gates and remaining target execution are documented in the [native plan](native-zig-vt-adaptation-plan.md). Build/package metadata must report the actual backend. Cross-builds do not establish target Linux, IME, or display acceptance.
