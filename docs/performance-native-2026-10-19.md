# Bounded native performance measurements (2026-10-19)

Environment: macOS 27.0.1 arm64, Zig 0.17.0 ReleaseSafe, nanoui CoreText, 1000×680 ui.Tester. One post-build sample; raw data is in the matching JSON. The original single-sample `tools/measure-native.py` entry has been retired. Use `tools/compare-native-versions.py` for fresh repeated, isolated, source-checked comparisons; inspect its current `--help`. New runs are new evidence and do not reproduce or replace this historical report automatically. Normal application idle polling was not added.

Each real PTY emits 1000 CJK-containing lines; completion includes shell startup and a 200 ms delay. Frame/scroll timings cover tree construction/layout/instance generation, excluding Metal draw/present, displays, and X11. Sixteen panes use a different nested grid total, so scaling cannot be inferred.

| PTYs | Output complete ms | Build mean ms | Build p95 ms | CPU over ~2s idle ms | Search ms | Scroll 60 frames ms |
|---|---|---|---|---|---|---|
| 1 | 227.55 | 0.552 | 0.648 | 0.457 | 55.65 | 23.64 |
| 4 | 229.21 | 0.842 | 1.080 | 0.331 | 55.59 | 40.45 |
| 16 | 259.73 | 0.719 | 0.797 | 0.593 | 55.12 | 40.82 |

An independent 80×24 VT receives 100000 lines with a 64 MiB history budget. Pruning leaves 88771 matches, processed across 151 bounded ticks (~55–56 ms). No complete history copy exists. This does not mean every input line was retained, or establish GTK/X11/low-end performance.

Target Linux, SSH X11, IME, and Konsole PSS/CPU comparisons remain unmeasured. Use tools/workload.sh and memory-sample.sh on target; no memory-saving percentage or cross-platform latency claim follows.
