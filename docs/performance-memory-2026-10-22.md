# Memory breakdown and cache recovery, 2026-10-22

This compares Letty with itself before and after sharing portable font sources
and reclaiming exceptional frame-arena capacity. Measurements use macOS on Apple
Silicon, Zig 0.17.0, ReleaseSafe, the portable TrueType/HarfBuzz path, actual VT
instances and owned PTYs. The UI and persistent CPU raster run offscreen at
1000 by 680 pixels, scale 1. They exclude GTK/X11, remote presentation and child
shell RSS. This is not a Linux PSS or Konsole comparison. The installed remote
0.2.2 has not been replaced.

## Diagnostic categories

`--memory-checks` is opt-in and requires a portable build on macOS. It records:

- Process current RSS and peak RSS; Linux also sums `/proc/self/smaps` PSS, so
  neither `smaps_rollup` nor cgroup v2 is required. PSS is null on macOS. Missing
  process measurements fail the diagnostic rather than reporting a zero saving.
- VT charged core/graphics heap, reserved page mappings and estimated resident
  page bytes. Reading page metadata never decompresses or restores pages.
- Per-session TX allocation capacity.
- Logical font references, unique shared font-source bytes and loaded faces.
- HarfBuzz-owned and borrowed source lengths, measured separately from its
  internal shaping allocations. Borrowed lengths overlap the shared sources.
- Glyph pixels, image pixels/cache payloads, frame-arena capacity, shaped-glyph
  payloads, instance-array capacity and CPU framebuffer bytes.

These categories describe requested buffers and engine estimates. They are not
an exhaustive heap census and must not be summed as RSS: allocator metadata,
rounding, libraries, framework resources and OS residency differ. Reserved page
address space and allocator capacity are distinct from resident physical memory.
Snapshots are taken between workloads; page walks and process queries never run
in ordinary input, rendering, or tab-switch paths.

## Changes

`nanoui-28-font-sources-and-arena-retention.patch` gives portable font databases
independent references to immutable content-addressed source snapshots. Equal
contents share bytes across windows and TTC faces; fresh reads still detect
changed files. Each database retains its own parsed face objects and lookup
state. Failed loads/probes release unpublished references. The final reference
frees the bytes and pool lookup storage.

The existing process-wide HarfBuzz cache was already shared across windows, but
copied font bytes independently of the databases. It now holds an explicit
source lease and uses a read-only constructor. Cache eviction destroys HarfBuzz
before releasing its lease. A source outside the shared pool still uses the
copying constructor; the public copying C/Zig APIs retain their old contracts.
Window or configuration teardown cannot invalidate another consumer's bytes.
Cache hits and lease release perform no file I/O. The main application allocator
and the existing font/cache budgets remain unchanged.

Frame arenas keep warm capacity for ordinary workloads. Above 8 MiB, two seconds
of demand below one quarter of capacity request a recovery frame through the
existing cancellable one-shot frame scheduler. Reclamation happens only at the
normal arena-reset boundary and retains at least 8 MiB or twice the observed
low-demand peak. High demand cancels recovery. There is no recurring memory
timer, per-tab cache purge or cleanup in the tab action itself.

## Memory comparison

Each binary ran three times under a private HOME/config directory. The same
16 tabs, font resources, dimensions and default history budgets were used. The
history phase feeds each VT 1000 identical ASCII/CJK/combining-character lines;
it does not reduce retained history to lower memory. The four-window phase keeps
those 16 PTYs and adds three one-PTY windows. Closing returns to one surviving
tab with its history intact.

| Phase | Before RSS, MiB | After RSS, MiB |
| --- | ---: | ---: |
| One initially idle tab | 86.31 | 86.61 |
| Sixteen idle tabs | 135.28 | 135.59 |
| Sixteen tabs with history | 157.44 | 138.05 |
| Four windows, nineteen PTYs | 289.92 | 209.27 |
| Closed back to one tab | 109.28 | 89.88 |

Values are medians of three process snapshots; per-run values remain in the
[baseline](performance-data/memory-2026-10-22/baseline.json) and
[optimized](performance-data/memory-2026-10-22/optimized.json) records. The cold
idle cases do not show a saving. The history phase saves about 19.4 MiB and the
four-window phase about 80.6 MiB (27.8%).

The four-window logical font references remain 81.62 MiB, while unique source
storage falls to 20.40 MiB. The 19.67 MiB HarfBuzz source copy becomes a lease on
those existing bytes. Each window still has its own approximately 16 MiB image
atlas; this change does not optimize that fixed cost or the TX queues.

The controlled 32 MiB temporary allocation leaves **48.39 MiB of retained frame
arena capacity before, versus 8 MiB after recovery**. This is a capacity saving,
not another measured RSS saving: the original arena reset already releases the
touched large backing in this fixture. Recovered RSS remains approximately the
same as the pre-peak closed-tab phase in each version.

## Tab latency

The final binary and preserved baseline were interleaved in `before, after,
after, before` order three times: six independent processes per version, no
outlier exclusion. Each process measures 15 new-tab operations and 120 switches
per switch workload. An operation includes the action, UI layout/shaping and
persistent CPU raster through the first frame; it excludes presentation and
time until the shell prompt. Each p95 is the lower order statistic at
`floor((n - 1) * 0.95)`; maxima and individual run summaries are also retained.
Table values are medians of the six per-run statistics.

| `/bin/sh` workload | Median before/after, ms | p95 before/after, ms |
| --- | ---: | ---: |
| New tab, first frame | 3.450 / 3.286 | 3.944 / 3.751 |
| Switch among sixteen tabs | 0.559 / 0.560 | 0.718 / 0.732 |
| Switch after the peak/recovery phase | 3.588 / 3.624 | 3.984 / 3.997 |

The same schedule also ran real interactive `/bin/csh` with a private HOME and
no command override or user startup files:

| csh workload | Median before/after, ms | p95 before/after, ms |
| --- | ---: | ---: |
| New tab, first frame | 3.402 / 3.360 | 3.874 / 3.887 |
| Switch among sixteen tabs | 0.561 / 0.565 | 4.080 / 4.104 |
| Switch after the peak/recovery phase | 3.807 / 3.770 | 4.173 / 4.090 |

This does not show a millisecond-scale regression. Small positive differences
remain visible rather than being reported as a speedup: sh switching p95 rises
14 microseconds, and csh switching p95 rises 24.5 microseconds. User csh startup
files and remote input-to-pixel latency remain outside this comparison.
Raw [sh](performance-data/memory-2026-10-22/paired-sh.json) and
[csh](performance-data/memory-2026-10-22/paired-csh.json) schedules bind each run
to its executable, build manifest and tool hash.

## Recovery-frame and framework checks

A separate identical UI fixture records all 180 frames after a synthetic peak,
including the frame that frees storage. Across three runs the recovery frame
takes 0.106–0.138 ms. Overall frame p95 medians are 0.123 ms before and 0.116 ms
after. Maximum observed frames are 0.745 ms before and 0.936 ms after; those
outliers are not the trim frames. Every baseline/candidate before/after image
has the same pixel hash. The fixture uses simulated frame time for the cooldown;
the window scheduler uses elapsed application time.

The framework's own native offscreen Metal hill-climb also ran both sources at
its default `.fast` optimization, 300 frames after 30 warmups, three repetitions
per scene. Median frame CPU ranges from -12.8% to +0.5% change across its five
scenes; some p95 values rise by up to 32 microseconds. This is a separate renderer
and optimization scope, not a substitute for the portable tab measurements.
See [cache baseline](performance-data/memory-2026-10-22/cache-baseline.json),
[cache optimized](performance-data/memory-2026-10-22/cache-optimized.json), and
[framework records](performance-data/memory-2026-10-22/framework-hillclimb.json).

## Reproduction

Build once before the optimization and preserve its binary, resource directory
and matching build manifest; repeat the same build command for the candidate.
The measuring script refuses an executable that does not match its manifest.

```sh
python3 tools/build.py --native --portable --skip-bootstrap
python3 tools/measure-memory.py --binary=zig-out/native-portable/bin/letty --manifest=.cache/verification/build-native-portable.json --output=.cache/memory-current
python3 tools/measure-memory.py --binary=zig-out/native-portable/bin/letty --manifest=.cache/verification/build-native-portable.json --output=.cache/memory-csh --shell=/bin/csh --interactive-shell
python3 tools/measure-cache.py --output=.cache/cache-current
```

On target Linux use the Linux build and manifest under `xvfb-run -a`, or run in
an existing X11 session. The diagnostic sums self `smaps` PSS, while these macOS
records intentionally contain null PSS. Cross-builds and ABI audits do not prove
target Linux memory use, oldest-supported-system acceptance, IME or VDI latency.

## Regression validation

The final source passed 239 unit tests and all core/native-VT suites on both
native and portable macOS builds, 841 native and 837 portable hidden UI checks,
and 288 real-VT full/damage pixel comparisons. The font/fallback leaf suite passed
20 tests, including shared TTC teardown and failed registration/probe cleanup;
the arena suite passed two cooldown/boundary tests. The C shaper fixture passed
22 checks, including copying-API lifetime, identical borrowed/copy glyph output,
malformed-borrow failure, and zero source charges after teardown.

The Linux delivery target cross-built and all nine ELF files passed the
GLIBC_2.17 ABI audit. Both nanoui Windows examples cross-built; all 185 framework
files remained within 600 lines. Bootstrap replayed the pinned patch chain.
Linux CI now runs the font/fallback and arena leaf tests alongside raster checks.
The [validation record](performance-data/memory-2026-10-22/validation.json) binds
these local checks to source `4f8d7ce2fd9aae9a86abfbcffc165992b37616abcaa5e4cb3f9d437109983a2f`.
