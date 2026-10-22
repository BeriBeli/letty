# Performance measurement methodology

A controlled Linux/Konsole benchmark with matched fonts, grids and history budgets has not been completed, so no memory advantage over Konsole is established. A current-profile remote spot check is recorded below. The package's `/proc/PID/smaps` sampler supports the Linux baseline without smaps_rollup or cgroup v2.

The [2026-10-22 memory breakdown and cache report](performance-memory-2026-10-22.md)
compares the same Letty workloads before and after font-source sharing and frame
arena recovery. Its process RSS, requested buffer categories and offscreen tab
timings have separate scopes; they do not establish Linux PSS or remote latency.

```bash
# In another terminal, use the actual Letty GUI PID, not the shell/workload PID.
./tools/memory-sample.sh PID 30 1 >letty-idle.csv
# Inside Letty, substitute the actual package path.
/path/to/package/tools/workload.sh 100000
```

Compare on the same GUI host/display path, whether local or SSH X11: equal window pixels/font/size/rows/columns/independent PTYs/shell/retained history. Letty defaults to both 10000 lines and 16 MiB, with Ghostty page-granularity pruning. Check actual retained rows and align both budgets rather than pruning early to gain an advantage.

Workloads: one/four idle sessions, ANSI/CJK logs, saturated history, scrolling/search, vim/less/tmux, simultaneous output/input/resize, repeated creation/close. Run at least three times; report PSS median/range and supporting RSS. Separate shell/workload costs; do not sum shared-library RSS. After closure, record FDs and stabilized memory.

Measure observable SSH/Xorg/Xwayland/desktop transport overhead separately, disclosing noise/unmeasured GPU resources. Assess echo/scroll response and X11 traffic with memory. CPU framebuffer/damage costs require target measurements; executable size is not runtime memory.

The [2026-10-22 portable raster report](performance-cpu-raster-2026-10-22.md)
records measured opaque-fill and transparent-overlay improvements, exact pixel
checks, and a rejected allocator experiment. Its local CPU timings do not replace
the remote latency and memory comparison below.

## Linux tab startup and X11 presentation

Account shell/home/name are copied once into process-owned launch context, removing repeated NSS lookups from new tabs and splits. Linux children enumerate `/proc/self/fd` with the baseline `getdents64` syscall and close actual descriptors before exec, preserving standard I/O. If procfs enumeration fails, cleanup falls back to the descriptor limit. No `close_range`, `pidfd`, or newer glibc symbol is required.

`nanoui-24-x11-damage-presentation.patch` coalesces CPU rasterization in a cancellable GLib idle. Input and IME consumption remain synchronous. Unchanged pixels do not invalidate GTK; partial CPU damage is rounded outward into logical GTK coordinates and sent through `gtk_widget_queue_draw_area`. Resize/theme/backing invalidation still requests a full draw. Exposure paints current backing pixels through GTK's clip, including regions outside the last CPU damage; an exposure arriving before the presentation idle also schedules any remaining changed area.

Run `python3 tools/check-shell-launch.py` for launch semantics, owned account caching, actual child-fd closure (including descriptors above 65535 when allowed), and a local before/after cleanup microbenchmark. Framework presentation tests cover unchanged/full/partial invalidation and scaled edges. These checks do not establish a remote X11 latency or bandwidth improvement: compare new-tab-to-prompt, typing echo, scrolling, resize and expose on the actual Linux/X11 connection before claiming target performance.

Run `python3 tools/check-x11-presentation.py` with Zig 0.17.0, Xvfb, Cairo and GObject development libraries available. It uses only its own hidden GTK window on a private display, checks coalescing and pending-callback cancellation, and compares full/clipped Cairo exposure byte-for-byte with current CPU backing at 2× scale. The Linux CI workflow runs it alongside the settings and launch regressions.

## GTK input and font sizing

`nanoui-25-gtk-input-and-font-points.patch` copies IM commits and preedit updates into a bounded FIFO (4096 events / 1 MiB pending text). It delivers callbacks in order, detaches each payload before calling the view, and lets GTK IM consume modified keys before shortcut fallback. An input method returning false does not discard text it already committed. Allocation or queue-limit failures are logged; they are not reported as successful delivery. The deterministic regression feeds 62,000 rapid ASCII presses, mixed commit/key events, delayed/reentrant commits, preedit ordering, shortcuts and bounded-queue failure through the production handlers. It does not simulate a particular remote desktop client or installed IM engine.

A synchronous frame now consumes an already scheduled redraw, avoiding an extra full build/layout/paint of the same state. Rasterization continues to coalesce separately. `tools/check-x11-presentation.py` checks the real hidden GTK surface's build count for this case; `tools/check-gtk-input.py` runs without a display on macOS or Linux. No target latency percentage is established by these regressions.

Terminal `font-size` is in points. Linux now uses GTK font DPI to convert points to logical units (14 pt becomes about 18.67 logical pixels at 96 DPI), then applies monitor backing scale once. Grid metrics, text runs and IM preedit share that conversion. This fixes the previous size mismatch with point-based terminal settings. The portable rasterizer still uses grayscale outline coverage, without FreeType's bytecode hinting or LCD subpixel rendering, so equal font/point settings alone do not establish visual equivalence with Konsole. Compare at equal DPI, font, style and window scale.

`nanoui-26-gtk-modified-commits.patch` recovers a shortcut when an IM context
synchronously commits the exact printable ASCII character of a Ctrl keypress
outside composition. For example, an IM-consumed comma must still reach the
Ctrl+, Settings binding rather than insert a literal comma into the terminal.
The queued text is replaced with one key event; it cannot also be delivered as
text or duplicated by an unconsumed fallback. Preedit, transformed/multicharacter
text, delayed commits and Ctrl+Alt/AltGr remain input-method owned. Run
`python3 tools/check-gtk-input.py` for these regressions.

## Remote 0.2.2 spot check, 2026-10-21

The installed Letty 0.2.2 was exercised through Maspice 0.5.6 on macOS, with
Letty on a remote Linux GUI host through an X11 forwarding path. Five PTYs and
four Markdown workspaces were open during sampling. This is a small operational
spot check, not the controlled Konsole comparison described above.

`top -b -d 1 -n 3 -p PID` reported Letty RSS of 136732, 136792 and 136824 KiB
(about 133.5–133.6 MiB), and CPU of 0%, 6% and 1%. The sampler itself writes
into the visible Letty terminal, so these are light-output samples, not a clean
idle baseline. Separate client samples reported Maspice RSS of 264992 and
253088 KiB, with CPU of 0% and 0.3%. Client and server RSS are separate costs.

The command palette opened, and its Settings and Font Size: Increase commands
worked. Ctrl+, and Ctrl+Shift+= failed in the installed build. An owned `xev`
window received comma with Ctrl (state 0x14, including NumLock), and plus with
Ctrl+Shift (state 0x15). Letty inserted a literal comma for Ctrl+, in a terminal,
which is consistent with the GTK direct-commit bypass covered by patch 26.
The fix still requires acceptance in this same remote environment after installing
a new build; these observations certify the installed version only.

`time seq 10000` completed and displayed the final line without a crash; the
shell reported 0.06 seconds for the producer in that loaded instance.

### Two-terminal comparison

Separate owned instances of Letty (`--no-restore`) and Konsole
(`--nofork --show-tabbar -e /bin/csh -i`) were then opened on the same GUI
host/display path. Each had two independent PTYs and no Markdown. Both windows
were maximized, but their current profile fonts and terminal grids differed;
retained-history budgets were not aligned. Konsole reported version 2.10.5,
Qt 4.8.7 and KDE 4.14.8. Its launcher also warned about the profile's variable-width
font. This comparison describes those installed profiles, not current Konsole
releases or a controlled renderer ranking.

Three consecutive `/proc/PID/smaps` samples before the output workload gave:

| GUI process | PSS median (range), KiB | RSS median (range), KiB |
| --- | ---: | ---: |
| Letty 0.2.2 | 81825 (81659–82005) | 92144 (91976–92324) |
| Konsole 2.10.5 | 27435 (27435–27435) | 47800 (47800–47800) |

That is about 79.9 MiB PSS / 90.0 MiB RSS for Letty and 26.8 MiB PSS /
46.7 MiB RSS for Konsole. These are GUI-process values, excluding child shells,
X server and Maspice. Other Letty and Konsole instances remained running, which
affects shared-library PSS attribution. Letty did not demonstrate a memory saving
in this sample; the three nearby observations do not establish long-run stability.

Each clean instance ran `time seq 10000` three times and visibly reached line
10000 without a crash. Reported producer wall times were 0.01, 0.01 and 0.04 s
for Letty, and 0.01, 0.01 and 0.01 s for Konsole. These measure producer
completion and PTY backpressure, not the time the final pixels reached the client.
The short workload and unmatched history budgets do not support a throughput
ranking.

### New tabs and switching

Both applications showed a new terminal before its shell prompt appeared.
Isolating shell initialization with `time csh -i -c exit` took 0.66 s, while
`time csh -f -i -c exit` rounded to 0.00 s. Startup files therefore contribute
to new-tab-to-prompt delay. They were not modified. This does not measure or
exclude additional application/transport delay.

For three round trips between the two terminal tabs (six switches), `strace -c`
on the respective GUI processes reported:

| GUI process | `writev` calls | `writev` kernel time | Total syscall kernel time |
| --- | ---: | ---: | ---: |
| Letty | 1062 | 0.023864 s | 0.030076 s |
| Konsole | 498 | 0.007401 s | 0.013783 s |

These single traces include focus/exposure and background activity over unequal
observation intervals; tracing adds overhead. They count calls, not transferred
bytes, and kernel CPU time is not switch latency. They suggest investigating
Letty redraw/submission work, but do not establish its cause or a speed ratio.
Letty's six `fsync` calls totaled only 0.000030 s of kernel time in this trace.
Separate `strace -T -e fsync` observations in the loaded instance showed wall
durations of 0.000255 and 0.000228 s, so slow persistence was not demonstrated.
The loaded instance's inspector reported a completed frame with build/layout/paint
of 0.372/0.398/0.345 ms; these exclude CPU rasterization, GTK/X11 presentation and
remote delivery, and cannot certify visible responsiveness.

Transport bandwidth, precise echo/frame/switch latency, sustained ANSI/CJK output
and long-run memory behavior remain unmeasured. Automation text/paste introduced
delayed display and repeated input, so its timing is excluded from latency claims;
subsequent remote commands used individually checked ASCII key input. Tracers,
owned comparison windows and temporary terminal tabs were closed afterward.
