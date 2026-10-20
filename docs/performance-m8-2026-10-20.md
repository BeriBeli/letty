# M8 font and CPU rendering measurements

macOS arm64 development measurements with Zig 0.17.0 ReleaseSafe and pinned Ghostty/nanoui/HarfBuzz; target Linux/GTK/X11/presentation remain unverified.

`tools/verify-cpu-damage.py` uses real native VT/TerminalView/portable TrueType atlas/CPU raster. 1/4/16 VT panes share 1000×680 pixels and 20000 history lines. Eight stages × twelve interleaved full/damage frames produce 288 byte-identical comparisons. Timed panes are in-process VT fixtures; only isolated idle PTYs run. Construction/search/raster are separate, not additive input-to-display latency.

Initial historical table: cumulative CPU raster ms over twelve frames/stage, full → damage, excluding tree construction. Raw: `.cache/verification/m8-cpu-damage/`.

| VT panes | Static | Continuous output | Scroll | Visible cursor movement |
|---|---|---|---|---|
| 1 | 70.756 → 0.473 | 71.061 → 37.531 | 71.149 → 35.735 | 71.486 → 0.619 |
| 4 | 90.126 → 0.890 | 89.744 → 91.981 | 92.597 → 93.450 | 91.445 → 26.147 |
| 16 | 84.586 → 0.754 | 84.299 → 67.439 | 91.246 → 90.286 | 88.052 → 54.351 |

Static frames compare instances without clearing/repainting pixels. Four-pane output/scroll trigger full redraw plus damage overhead; sixteen-pane scroll has little gain. No all-workload acceleration claim follows. Cursor stages return to the viewport bottom, disable search/selection, and verify visible moving cursors. The initial offscreen-cursor report remains in m8-cpu-damage-first-cursor-hidden/ and is not final cursor evidence.

Thirty-one additional CPU checks cover transparency/rounded clips/shadows/order/UV/delete/cursor/selection/search/scroll/expose/invalid backing/atlas generation-size/scale/resize/theme. Invalid backing never presents and recovery rebuilds fully.

## Application comparison

M7 f7f9ccef94e9 versus M8: eighteen native runs in `.cache/verification/m8-native-performance/`, covering Tester/macOS process statistics, excluding Metal present. Final frozen review follows.

## Frozen CPU rerun

Source: `534a13035e129811af659cda9e08696f78c7c71aafce54fb4ef1e6f882e63fbc`. All 288 comparisons passed. Current twelve-frame cumulative raster ms, full → damage; first logs remain in m8-cpu-damage-historical-94c54aae/.

| Panes | Static | Continuous output | Scroll | Visible cursor movement |
|---|---|---|---|---|
| 1 | 72.187 → 0.467 | 72.088 → 38.153 | 72.926 → 35.816 | 72.236 → 0.607 |
| 4 | 90.772 → 0.904 | 92.025 → 93.688 | 94.455 → 95.674 | 91.195 → 26.262 |
| 16 | 87.873 → 0.812 | 88.567 → 70.289 | 95.435 → 93.509 | 88.207 → 54.329 |

Static frames repaint nothing; dynamic damage chooses full/partial redraw. X11/GPU/input latency is unmeasured.

## Frozen performance review

The same frozen source completed eighteen interleaved runs, all with 88771 matches. Median tree times:

| Panes | M7 mean/P95 µs | Candidate mean/P95 µs |
|---|---|---|
| 1 | 482 / 500 | 340 / 354 |
| 4 | 889 / 907 | 565 / 580 |
| 16 | 888 / 906 | 647 / 662 |

All per-run maxima were reviewed: candidate search max 6.253 ms, baseline 6.989. Historical sixteen-pane 29.314 ms and three initial warnings remain in original reports/corrected m8-native-performance-review.json. The frozen rerun did not reproduce the sample; old evidence was not rewritten as passed.

Three warnings remain: one-pane idle 263→292 µs/2s, one-pane system CPU 40→50 ms, four-pane system CPU 70→80 ms. The latter are one 10 ms quantum. Total CPU medians: 250→250/370→340/720→690 ms; peak RSS rises ~4 MiB (<3%); startup 39→39/40→38/38→38 ms. These absolute costs were accepted for development, without deleting warnings/changing thresholds.

Raw: `.cache/verification/m8-final-frozen-performance/report.json`; independent review: `.cache/verification/m8-final-performance-review.json`. Scope excludes GPU present, real-window input latency, GTK/X11, target Linux, and PSS.
