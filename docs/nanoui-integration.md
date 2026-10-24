# Shared nanoui integration

The active application uses the shared checkout's pinned nanoui fork, revision
`e68e577db963cf003dacd9aa8da3b00b4cf8f71c` (upstream v0.6.4 basis). The managed
revision and archive hash remain in `deps.lock.json`; the application does not
restore the preceding v0.4 API. The five active patches are replayed by
`tools/patch_nanoui.py`; the first four retain the shared dependency work, and
`nanoui-05-image-sink-lifetime.patch` fixes native image-atlas initialization.

## Text and rendering

`fonts.install` installs `TextSystem.setRunShaper` when the selected text backend
provides it. This is mandatory for CPU `gridLayout`. The explicitly named
`terminal-shaper` module reuses the bounded HarfBuzz leaf utilities rather than
loading the preceding application. Fonts retain independent immutable source
leases across windows; the cache has at most 16 fonts / 64 MiB of font sources,
with at most 4096 glyphs per shaped run. UTF-8 clusters are placed against native
VT cell spans, including wide and combining cells. CoreText keeps its native
shaping path.

`tools/build.py` prepares the checksum-pinned static HarfBuzz kit before portable
or Linux builds. It uses Zig 0.17.0 and preserves the Linux baseline CPU and
glibc 2.17 target. Direct `zig build -Dportable=true` requires the corresponding
kit from `tools/build-shaper.py`. Verification hashes include all reused Zig/C
leaf inputs and the shaping builder/lock; historical application receipts are
not reused.

Search viewport highlights refresh their native search feed before rendering,
so viewport-only scrolling can update the visible match cache. No serialized
terminal frame or Mirror is involved.

Terminal graphics use current `ui.texture` BGRA frame sources and UV rectangles,
including the portable renderer. The product owns premultiplied pixel copies,
clips source/destination together and draws Ghostty's three image layers around
cell backgrounds and glyphs. Native storage generation invalidates changed
pixels; viewport movement refreshes placement geometry without re-decoding an
unchanged image. Unicode placeholder geometry comes from `RenderState`.

Native image sinks bind before AppKit/UIKit can call back into the published
view. `Images.bindSink` migrates an already populated CPU atlas before releasing
its storage; Metal's CPU-atlas synchronizer skips sink mode. This prevents a
late PNG's direct GPU upload from being overwritten with stale CPU rows. The
isolated [image-atlas check](../tools/image-atlas-check/README.md) verifies actual
hidden Surface pixels and CPU-to-sink transitions without clearing the atlas.

Diff highlighting uses current `ui.richText` with sorted, disjoint spans; search
backgrounds are composed with lexical colors in the product. Sidebar menus use
fixed/layered nodes and current pointer edge state. Reordering and project
assignment are deferred stable-ID operations, with no PTY recreation.

## Input and lifecycle

- The terminal sets `FocusedText.editable = false`. Native fields use the default
  true value; terminal control keys remain terminal input.
- Keyboard and pointer edge deduplication lives in each `ui.Context`, including
  rebuild passes. A native surface and a hidden tester can share product state
  without sharing frame counters or suppressing each other's events.
- Discrete `scroll_lines` represents native detents. Letty applies its three-row
  history policy once; precise pixel deltas retain fractional accumulation.
- The removed window-close callback is replaced by a product-owned native guard:
  a derived AppKit delegate or GTK `delete-event` handler. It retains nanoui's
  teardown and revalidates product ownership through the window callback.
- Native dialog reentrancy is bounded by the product modal owner. Deferred input
  requires a current window/workspace/pane and the terminal input domain.
- Exited PTYs still allow their retained native VT screen to resize/reflow.

Application/window close, focus and quit behavior now use product-owned AppKit
and GTK adapters. Dock notifications, file drops and window materials also stay
in the product layer. No retired nanoui API or vendor downgrade is restored.
The virtualized file editor consumes current `Input.ops` and publishes current
`FocusedText` metadata; undo storage and retained text are owned and bounded.
The `document-native` module uses public native text layout for disjoint rich
runs and `ui.texture` for decoded BGRA images. Continuous source editing and
latest-only Markdown drafts keep preedit separate from committed text. Focus
and pointer isolation prevent document input from entering a terminal. The
[document guide](file-markdown-documents.md) records save and filesystem limits.
Direct Markdown text editing uses the same native rich glyph hit geometry and
stable body focus ID as its reader. Reversible source ranges preserve hidden
formatting and link destinations. Marked text retains its projection through
layout and painting. Only explicit Save writes disk; close continuation uses the
editor lifetime epoch, since filesystem watches advance read generations after
the application's own atomic replacement.
All delayed pane moves, file operations and notification activations carry stable
IDs and revalidate ownership before use.

## Verification boundary

Use `tools/build.py --native`, `tools/build.py --native --portable`, and
`tools/verify-ui.py --prefix=...` serially. Hidden checks use owned windows,
private configuration and clipboard storage, and non-login shell fixtures.
They first execute real PTY input and reap those children, then feed deterministic
VT content for search, selection and screenshots. Search-induced viewport
resizing is separated from the visible selection fixture, since native reflow
can move a former top line into history. Command-palette tests use a partial
query, so the editable query text is not confused with the result button.

Cross-build and ELF ABI checks do not execute the actual Linux GTK/X11 path.
Oldest-target Linux, VDI performance and IME acceptance require target evidence.

The latest checkpoint and per-suite counts are recorded in
`.cache/verification/kero-port-current.json`. They must match the current source
hash and binaries; this document does not promote older receipts to current
acceptance. Native notification delivery and native file-drop adapters require
platform testing beyond the owned hidden fixtures. The development preview is
`dist/LettyPort.app`; the packaging script retains the preceding preview.
