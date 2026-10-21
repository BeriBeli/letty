# Performance measurement methodology

Target Linux/Konsole measurements have not been completed, so no memory-saving claim is established. The package's `/proc/PID/smaps` sampler supports the Linux baseline without smaps_rollup or cgroup v2.

```bash
# In another terminal, use the actual Letty GUI PID, not the shell/workload PID.
./tools/memory-sample.sh PID 30 1 >letty-idle.csv
# Inside Letty, substitute the actual package path.
/path/to/package/tools/workload.sh 100000
```

Compare on the same GUI host/display path, whether local or SSH X11: equal window pixels/font/size/rows/columns/independent PTYs/shell/retained history. Letty defaults to both 10000 lines and 16 MiB, with Ghostty page-granularity pruning. Check actual retained rows and align both budgets rather than pruning early to gain an advantage.

Workloads: one/four idle sessions, ANSI/CJK logs, saturated history, scrolling/search, vim/less/tmux, simultaneous output/input/resize, repeated creation/close. Run at least three times; report PSS median/range and supporting RSS. Separate shell/workload costs; do not sum shared-library RSS. After closure, record FDs and stabilized memory.

Measure observable SSH/Xorg/Xwayland/desktop transport overhead separately, disclosing noise/unmeasured GPU resources. Assess echo/scroll response and X11 traffic with memory. CPU framebuffer/damage costs require target measurements; executable size is not runtime memory.

## Linux tab startup and X11 presentation

Account shell/home/name are copied once into process-owned launch context, removing repeated NSS lookups from new tabs and splits. Linux children enumerate `/proc/self/fd` with the baseline `getdents64` syscall and close actual descriptors before exec, preserving standard I/O. If procfs enumeration fails, cleanup falls back to the descriptor limit. No `close_range`, `pidfd`, or newer glibc symbol is required.

`nanoui-24-x11-damage-presentation.patch` coalesces CPU rasterization in a cancellable GLib idle. Input and IME consumption remain synchronous. Unchanged pixels do not invalidate GTK; partial CPU damage is rounded outward into logical GTK coordinates and sent through `gtk_widget_queue_draw_area`. Resize/theme/backing invalidation still requests a full draw. Exposure paints current backing pixels through GTK's clip, including regions outside the last CPU damage; an exposure arriving before the presentation idle also schedules any remaining changed area.

Run `python3 tools/check-shell-launch.py` for launch semantics, owned account caching, actual child-fd closure (including descriptors above 65535 when allowed), and a local before/after cleanup microbenchmark. Framework presentation tests cover unchanged/full/partial invalidation and scaled edges. These checks do not establish a remote X11 latency or bandwidth improvement: compare new-tab-to-prompt, typing echo, scrolling, resize and expose on the actual Linux/X11 connection before claiming target performance.

Run `python3 tools/check-x11-presentation.py` with Zig 0.17.0, Xvfb, Cairo and GObject development libraries available. It uses only its own hidden GTK window on a private display, checks coalescing and pending-callback cancellation, and compares full/clipped Cairo exposure byte-for-byte with current CPU backing at 2× scale. The Linux CI workflow runs it alongside the settings and launch regressions.

## GTK input and font sizing

`nanoui-25-gtk-input-and-font-points.patch` copies IM commits and preedit updates into a bounded FIFO (4096 events / 1 MiB pending text). It delivers callbacks in order, detaches each payload before calling the view, and lets GTK IM consume modified keys before shortcut fallback. An input method returning false does not discard text it already committed. Allocation or queue-limit failures are logged; they are not reported as successful delivery. The deterministic regression feeds 62,000 rapid ASCII presses, mixed commit/key events, delayed/reentrant commits, preedit ordering, shortcuts and bounded-queue failure through the production handlers. It does not simulate a particular remote desktop client or installed IM engine.

A synchronous frame now consumes an already scheduled redraw, avoiding an extra full build/layout/paint of the same state. Rasterization continues to coalesce separately. `tools/check-x11-presentation.py` checks the real hidden GTK surface's build count for this case; `tools/check-gtk-input.py` runs without a display on macOS or Linux. No target latency percentage is established by these regressions.

Terminal `font-size` is in points. Linux now uses GTK font DPI to convert points to logical units (14 pt becomes about 18.67 logical pixels at 96 DPI), then applies monitor backing scale once. Grid metrics, text runs and IM preedit share that conversion. This fixes the previous size mismatch with point-based terminal settings. The portable rasterizer still uses grayscale outline coverage, without FreeType's bytecode hinting or LCD subpixel rendering, so equal font/point settings alone do not establish visual equivalence with Konsole. Compare at equal DPI, font, style and window scale.
