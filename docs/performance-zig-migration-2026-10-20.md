# Native Zig migration performance comparison (2026-10-20)

macOS 27.0.1 arm64, Zig 0.17.0 ReleaseSafe, pinned Ghostty/nanoui. C/native builds each ran three times at 1/4/16 PTYs: eighteen interleaved isolated runs. Raw records: `.cache/verification/n3-performance-final/`; review: n3-performance-review.json. Historical reproduction uses archived `source/tools/compare-vt-performance.py`; current native-version comparisons use `tools/compare-native-versions.py`.

Each PTY emits 1000 CJK log lines. 1000×680 Tester timings cover construction/layout, excluding GPU present/composition/X11. An 80×24 VT receives 100000 lines with 64 MiB history; both backends find **88771** retained matches each run. macOS time -l peak RSS is neither PSS nor steady-state memory. Tables show three-run medians, C → native Zig.

| PTYs | Startup ms | Frame mean ms | Search total ms | Longest tick ms | Peak RSS MiB |
|---|---|---|---|---|---|
| 1 | 40 → 39 | 0.710 → 0.651 | 54.145 → 60.861 | 6.432 → 5.228 | 150.48 → 147.33 |
| 4 | 40 → 40 | 1.056 → 1.059 | 54.065 → 60.446 | 6.174 → 4.961 | 159.56 → 156.55 |
| 16 | 39 → 40 | 0.951 → 0.937 | 54.097 → 61.008 | 6.227 → 5.236 | 191.67 → 188.84 |

Native executable: 3,174,952 bytes versus C 3,490,488 (~9% smaller). This applies only to these host artifacts.

## Findings and acceptance

The first run failed: 32 MiB search quota could not hold the same result set. Pinned upstream clones page highlights per match; Zig 0.17/aarch64 minimum container capacities for 88771 single-page results exceed 32 MiB before growth scratch. The bounded quota became **64 MiB**, retaining refusal/OOM/result/release checks without a history mirror. Initial failures remain in n3-performance-initial/.

Six ratio >1.10 warnings remain. Search total rose ~6.4–6.9 ms (~12%). Additional quota/allocation auditing may contribute, but no CPU profile establishes a sole cause. Longest-tick medians fell; every one of nine native maxima stayed ≤5.61 ms. Frame/startup showed no material regression. The local candidate was accepted with the search-total difference disclosed. Idle warnings differ by tens of microseconds; system CPU has 10 ms granularity. These data do not establish target Linux/X11/IME/GPU/Konsole acceptance; the C recovery comparison remains available.

## N4 native comparison before/after C cleanup

Both binaries use native Zig: 9b2f19589436 → 76d6fabb5620. Eighteen interleaved runs used compare-native-versions.py. Raw: `.cache/verification/n4-native-performance/report.json`; review: n4-native-performance-review.json. Same scope/workload, 88771 matches/run, both unsigned binaries 3192968 bytes.

| PTYs | Startup ms | Frame mean ms | Search total ms | Longest tick ms | Peak RSS MiB |
|---|---|---|---|---|---|
| 1 | 38→38 | 0.465→0.479 | 62.187→62.396 | 5.311→5.349 | 147.563→147.641 |
| 4 | 39→39 | 0.883→0.866 | 63.212→62.467 | 5.308→5.136 | 156.563→156.828 |
| 16 | 38→39 | 0.861→0.887 | 64.084→63.089 | 5.690→5.509 | 188.922→188.984 |

One >1.10 warning: four-pane system CPU 0.07→0.08 s (one 10 ms quantum), total CPU 0.36→0.37 s. Frame differences -17…+26 µs, RSS increases <0.2%, idle -3…+9 µs/2s, search totals within 1 ms. Review accepted cleanup while retaining warnings/raw data, without claiming every metric improved or inferring Linux performance.

## M7 native application integration

Candidate f7f9ccef94e9 versus frozen N4 76d6fabb5620: eighteen interleaved runs, three/backend/pane count, 88771 matches each. Raw: `.cache/verification/m7-native-performance-final/report.json`; review: m7-native-performance-review.json. Initial 9531badc report remains in m7-native-performance/report.json.

| PTYs | Frame mean/P95 µs before→after | Peak RSS MiB before→after |
|---|---|---|
| 1 | 477/505 → 475/498 | 147.469 → 148.344 |
| 4 | 898/1061 → 887/922 | 156.547 → 157.547 |
| 16 | 876/902 → 880/919 | 188.969 → 189.750 |

Initial one-pane P95 529→819 µs prompted skipping action-availability checks without bindings/pending sequences; actual reruns removed that regression. Final four-pane idle warning 183→268 µs over two seconds remains: +85 µs, ~0.00425 percentage points of one CPU, accepted as immaterial locally. Thresholds/old results remain unchanged.

Scope stays Tester construction/macOS process statistics, excluding GPU present/GTK/X11/PSS/target Linux execution.
