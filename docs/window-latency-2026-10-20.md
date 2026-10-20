# macOS window latency measurements (2026-10-20)

The change fixes consecutive rendering inside nanoui resize callbacks exhausting drawables and blocking the main thread. Following Ghostty's latest-state/size-validation principles, resize work coalesces to display refresh while preserving AppKit minimization animations.

## Method

- macOS 27.0.1/Apple Silicon, Zig 0.17.0 ReleaseSafe, real independent AppKit/Metal windows.
- Baseline/candidate share the async state machine, telemetry, and application source; baseline restores only earlier surface/metal scheduling. Each tests zero/10000 history lines and repeats each operation three times: 108 operations overall.
- Actions/observations return to normal NSApplication events rather than nested CFRunLoop transaction substitutes. Observation lasts 700 ms; baseline synchronous blocking is counted separately as call_us.
- No usable left/right/fill system menu was found: geometry tests use real NSWindow.setFrame for half/work-area sizing, excluding menu/tiling animation. Zoom/minimize/restore use actual NSWindow APIs.
- resize_burst issues sixteen setSize calls in one event. live_resize_burst also invokes viewWillStartLiveResize/viewDidEndLiveResize; it is callback stress, not physical-drag sampling.
- Update VT while minimized, restore, verify no terminal failure and final Context/drawable dimensions. Drawing operations require drawable callbacks. Both versions passed correctness checks.
- CAMetalDrawable callback and presentedTime are separate. Fill/restore can report presentedTime=0; retain -1/unavailable rather than substituting callback time. Same-size right-half movement needs no redraw.
- Geometry/frame/build intervals nest and cannot all be summed. Three-run medians locate this regression, not broad hardware distributions.

## Synchronous main-thread calls

10000 history lines; milliseconds. Shorter calls return to the event loop sooner, without implying all pixels are displayed.

| Operation | Baseline | Optimized |
|---|---:|---:|
| Left half, geometry change | 6.73 | 1.07 |
| Right half, movement only | 0.41 | 0.33 |
| Fill work area | 8.93 | 1.12 |
| Zoom | 1057.39 | 45.25 |
| Restore Zoom | 1059.59 | 45.54 |
| Sixteen resizes | 138.94 | 9.78 |
| Sixteen live-resize callbacks | 1062.17 | 10.76 |
| Minimize call | 0.13 | 0.13 |
| Restore call | 0.09 | 0.07 |

Without history: Zoom 1059.24→45.34 ms, resize burst 130.86→12.54, live-resize stress 1038.73→10.58.

## Blocking location

10000 history lines; time in ms except counts:

| Operation/interval | Baseline | Optimized |
|---|---:|---:|
| Zoom / maximum nextDrawable wait | 1001.61 | 0.61 |
| Zoom / frames built | 6.00 | 1.00 |
| Sixteen resizes / frames built | 16.00 | 1.00 |
| Sixteen resizes / total VT reflow | 30.46 | 1.95 |
| Sixteen resizes / total PTY resize | 0.25 | 0.03 |
| Live resize / maximum nextDrawable wait | 1001.59 | 0.40 |

Baseline builds several frames during one Zoom and requests another drawable before AppKit transaction submission, waiting ~1000 ms. Candidate handles final size only. GPU in-flight acquisition is nonblocking, with retry on the next refresh if submission fails. Hidden windows pause and resume with latest state.

## Frames and system animation

| With 10000 history lines | Baseline | Optimized |
|---|---:|---:|
| Left half / first valid presentedTime ms | 33.28 | 37.44 |
| Zoom / first valid presentedTime ms | Unavailable | 82.78 |
| Minimize / completion notification ms | 558.42 | 556.86 |
| Restore / completion notification ms | 545.30 | 545.29 |
| Restore / drawable callback ms, not hardware presentation | 575.88 | 567.51 |

Minimize calls remain below 1 ms. ~560/545 ms completion notifications largely reflect unchanged system animation. No global animation preference changed. Hidden refresh pauses and latest content submits on restore.

## Source references

- [LatestFrame](../vendor/ghostty/src/renderer/generic.zig): single-slot/latest-wins, inspiring coalescing without porting Ghostty's entire renderer thread.
- [IOSurfaceLayer](../vendor/ghostty/src/renderer/metal/IOSurfaceLayer.zig): top-left alignment and rejection of wrong-size surfaces.
- [BaseTerminalController](../vendor/ghostty/macos/Sources/Features/Terminal/BaseTerminalController.swift): window.zoom(nil); [Terminal.xib](<../vendor/ghostty/macos/Sources/Features/Terminal/Window Styles/Terminal.xib>): default animation.
- [nanoui Surface](../vendor/nanoui/src/ui/surface.zig): geometry_dirty, refresh coalescing, async post-live-resize frame, hide/resume.
- [nanoui Metal](../vendor/nanoui/src/ui/metal.zig): nonblocking in-flight/retry/size validation/alignment.
- [Reproducible patch](../patches/nanoui-12-window-timing.patch). Bounded telemetry defaults off; enable with `--window-perf=N`.

## Evidence and reproduction

```sh
python3 tools/measure-window.py --binary=.cache/window-baseline-release/bin/letty --label=baseline-verified --allow-failed-checks --output=<new-baseline-directory>
python3 tools/measure-window.py --binary=zig-out/native/bin/letty --label=optimized-verified --output=<new-candidate-directory>
```

- Preserved [baseline](window-latency-data/baseline.json), [candidate](window-latency-data/optimized.json), [manifest](window-latency-data/manifest.json), and raw logs do not depend on temporary directories.
- Reports contain operation count/total/max/p95, presentation availability, raw-log hashes, commands, binary/direct-vendor hashes. Each version measured 54 operations without correctness failures.
- Application/managed-patch identity: `47e9cf0c4c76e8642398128a69c7c535051bc29905d16270498aee642b34a8fd`. Only direct surface/metal hashes differ; baseline telemetry sources are retained as build overlays.
- Baseline binary: `7f05d369fc520cf0a27c0ce45f192575875e516385eedc3fa3affbec3ea04486`.
- Candidate binary: `16175892ae20c9d3a69c1f485032c1bdd6302909f96381ba2aa527c34e7b9388`.
- Early nested-CFRunLoop experiments are marked SUPERSEDED; other iteration data stays in .cache. This report uses final verified versions only.

## Regression scope

Native checks passed: 87 unit, 46 core, 359 hidden UI, nine replay, 24 N2, 56 protocol, 21 boundary, without leak reports. Four new hidden-window checks cover nonblocking GPU pressure, retry, final burst geometry, and hidden pending-state/paused refresh.

Linux x86_64/glibc 2.17 app/unit binaries and framework aarch64-linux-gnu/x86_64-windows-gnu examples/tests cross-built. All 123 framework files met the 600-line limit. No local Docker was available. Linux/Windows execution and target display acceptance were not performed; this preview's local checks are not the complete release gate.
