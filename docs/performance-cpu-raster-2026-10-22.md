# Portable raster improvements, 2026-10-22

The remote 0.2.2 comparison found higher Letty memory use and more `writev`
calls during tab switching, but did not measure input-to-pixel latency or
identify the caller stacks. Source inspection found a separate, measurable
main-thread cost: the portable CPU renderer blended every pixel of large opaque
backgrounds, and traversed fully transparent pane overlays. These operations
occur on the Linux rendering path during content changes, including tab switches.

## Changes

`nanoui-27-cpu-solid-fill.patch` adds two allocation-free paths to the production
quad rasterizer:

- Fill the opaque interior with packed BGRA pixels. Conservative inward bounds
  and an endpoint check use the scalar kernel's geometry. Rounded edges, borders,
  fractional coverage and rounded clips retain scalar rendering; four disjoint
  edge strips preserve one blend per edge pixel and damage scissoring.
- Skip a completely transparent quad when it has no visible border. The default
  unfocused-pane overlay can have zero opacity and previously still traversed
  its area. A transparent fill with a visible border remains on the drawing path.

Pixel conversion uses the scalar blend's exact f32 rounding. No extra framebuffer,
presentation cache, worker, timer or unbounded storage is introduced. ReleaseSafe,
the current allocator, history limits and shell initialization remain unchanged.

## Measurements

The same ReleaseSafe fixture calls the actual portable CPU raster at 3000 by
1600 pixels, scale 1, with 257 instances. Each scene has three warmup frames and
15 measured frames; the whole executable runs three times per implementation.
The preserved pre-change raster is compiled in an isolated copy of the framework,
without editing the working source. Measurements are on Apple Silicon/macOS
27.0.1, using Zig 0.17.0. They exclude tree/layout, text shaping, GTK/X11, PTYs,
remote delivery and GPU presentation.

| Scene | Baseline median, ms (range of run medians) | Optimized median, ms (range) |
| --- | ---: | ---: |
| Opaque rectangles | 23.82 (23.60–23.98) | 3.44 (3.43–4.27) |
| Opaque rounded rectangles | 26.34 (26.25–26.44) | 8.25 (8.24–8.26) |
| Translucent rounded/clipped rectangles | 29.27 (29.23–29.27) | 15.93 (15.90–16.00) |
| Transparent overlays over an opaque root | 18.65 (18.54–18.79) | 1.37 (1.37–1.37) |

The first scene's CPU raster time falls about 86%; this is not an end-to-end tab
latency claim. Every scene's final pixel hash matches across all baseline and
optimized runs. The translucent and transparent scenes also include the opaque
root, so they measure the combined changes, not an isolated blending operation.
The final scalar-equivalence regression compares complete byte buffers across
240 combinations of scale, radius, border, clipping, opacity and color rounding.
Persistent damage rendering is also compared with full CPU rendering.

Raw [baseline](performance-data/cpu-raster-2026-10-22/baseline.json) and
[optimized](performance-data/cpu-raster-2026-10-22/optimized.json) reports include
host, source, fixture and executable hashes, per-run medians and p95 samples.
Adjacent `.log` files retain the fixture output. These reports describe these
sources and this local CPU only; Linux display acceptance remains pending.

```sh
python3 tools/measure-cpu-raster.py --output=.cache/raster-candidate
# Supply a preserved original raster to compare without changing vendor files.
python3 tools/measure-cpu-raster.py --raster-source=/path/to/original-raster.zig --output=.cache/raster-baseline
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig-global" zig test vendor/nanoui/src/ui/damage_check.zig -lc -OReleaseSafe
```

The framework hillclimb was attempted but could not fetch its pinned Clay
dependency because of network/DNS failure. Its offscreen Metal measurements are
not substituted by these CPU results.

## Regression verification

The final source passed 238 unit tests and the core/native-VT suites on macOS,
830 native hidden UI checks and 826 portable hidden UI checks. The standalone
damage/raster suite passed all eight tests, including scalar-equivalent fast
paths and full-versus-incremental pixel equality. Linux CI now runs this suite
alongside the existing GTK input and X11 presentation regressions. Build and
UI receipts remain in `.cache/verification`, bound to their recorded source and
binary hashes; historical receipts do not certify later changes.

The real VT/portable-atlas fixture also passed 288 full-versus-incremental frame
comparisons across one, four and sixteen panes, covering output, scrolling,
search, selection, cursor changes, overlays and idle frames. The Linux delivery
target cross-built, and all nine ELF files passed the GLIBC_2.17 static ABI
audit. These checks do not execute the Linux GUI or measure the remote display.

## Allocation and startup findings

Zig 0.17.0's `std.process.Init.gpa` uses SafeAllocator with page backing in
ReleaseSafe. An experiment retained SafeAllocator but substituted libc backing
for real alternating UI tree/shaping frames. Across three independent runs,
the median of frame medians changed from 0.199 to 0.188 ms, while process peak RSS
increased from 71.8 to 275.4 MiB. The latter includes cold system-font discovery;
it is not Letty's two-terminal PSS. This tradeoff was rejected and no application
allocator policy changed. See the [experiment report](performance-data/cpu-raster-2026-10-22/allocator-comparison.json).

There is no newly measured PSS reduction. A single 3000 by 1600 BGRA backing uses
18.3 MiB; fonts, shaping resources, UI caches and VT storage also consume memory.
A complete retained-memory breakdown still needs a target process profile.

The earlier remote check found `csh -i -c exit` took 0.66 s while `csh -f -i -c
exit` rounded to 0.00 s. Shell startup files therefore contribute to new-tab
prompt delay. Measured `fsync` calls were short; persistence was not moved to a
worker without evidence. Neither observation rules out other application or
transport costs. The installed remote 0.2.2 has not been replaced by this change.
