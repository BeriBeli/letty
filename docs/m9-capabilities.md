# M9 Kitty image capabilities and acceptance boundaries

Date: 2026-10-20 (Asia/Singapore). This source audit is tied to the [integration release](m9-m11-release.md); existing M8 checks are not counted as newly added.

Images default off. With `kitty-graphics = true`, pinned native Ghostty VT remains the sole Kitty/APC parser. `vt_zig/graphics` produces owned RGBA snapshots; terminal_graphics_state captures before borrowed text, terminal_graphics_view emits clipped/layered commands, and nanoui_graphics_resources.Store supplies bounded BGRA to the window TextSystem. Nodes retain keys/scalar geometry, never borrowed pixels/Pin/placement/UVs.

| Capability | Behavior and evidence |
|---|---|
| Direct RGB/RGBA/PNG static images | Protocol→Context→pane→Tester.render actual pixels, including alpha/PNG |
| Chunked direct transfer | Upstream assembles; upload only after completion; actual-pixel checks |
| Malformed PNG | Bounded CRC/chunks/IEND/dimensions/decompression; fixes absent PLTE, out-of-range indexes, invalid/duplicate/oversize tRNS; no fake black output |
| Same-ID replacement | Upstream removes old image/placements when replacement starts, even if replacement fails; monotonic revision keys free old bitmap/atlas; 24 replacements verify constant usage |
| Query/delete | Real write-PTY effects; deletion clears resources; fixture replies stay in memory without a PTY |
| Main/alternate/reset/hide/show | Separate storage; screen/epoch changes clear cache; show recaptures; hiding releases renderer immediately |
| Scroll/resize/source crop/pixel offset | Upstream placement/grid/source APIs, negative positions, source/destination clipping; 2× crop-pixel checks |
| Layers | Pane background → below-background → SGR backgrounds → below-text → glyph → above-text → selection/search/cursor/preedit; actual overlay checks |
| Relative placement | Bounded basic chains/negative columns; no complete complex-client compatibility claim |
| Multiple panes/windows | Shared budget/key issuer per TextSystem; independent stores; two hidden Testers check pixels/delete/release |
| File/tempfile/shared-memory transfer | Disabled; protocol cannot open host files/shared memory |
| Unicode placeholders/virtual placement | Skipped and reported via virtual_placements diagnostics |
| Animation | Some upstream frame parsing exists, but no host playback clock; static images only |
| Compression/complex extensions | Pinned upstream behavior, without complete feature acceptance |

## Budgets and failure

| Layer | Limit/ownership |
|---|---|
| VT storage | 8 MiB per main/alternate screen, direct medium; disabling clears both |
| APC/decode pool | 48 MiB tagged graphics/Context; core pool history +32 MiB with 16 MiB APC headroom; requested heap bytes, not RSS/mmap |
| Image/PNG | Side ≤2048, RGBA ≤4 MiB; PNG ≤4 MiB/1 MP/4096 chunks; 16 MiB scratch charged to engine quota |
| Snapshot | 32 images, 128 placements, 8 MiB owned RGBA; release previous snapshot first; bounded placement scan |
| View renderer | 32 images/8 MiB, downsample side ≤1024 using premultiplied BGRA averaging; proportionally transform crops |
| Shared TextSystem | 128 managed keys/8 MiB decoded bitmaps plus fixed atlas/backing/GPU textures; not a total application-memory ceiling |

Soft quota refusal can skip images while text/DSR continues; actual allocator OOM explicitly fails the affected VT. Renderer aggregate refusal affects only that pane, retaining other panes and permitting later readmission. Full atlases skip visibly rather than growing indefinitely. Delete/hide/reset/disable/teardown release decoded ownership; fixed atlas/textures follow TextSystem lifetime.

## Recorded checks

Three new PNG unit tests and ten new M9 UI assertions were added. Frozen native/portable feature suites passed 45/41, sharing forty protocol-image assertions. Source-crop sampling now clamps CPU/Metal to original pixel-center bounds; viewport clipping does not change those bounds, and GPU instance ABI is unchanged. Nineteen sampler checks include three new boundary regressions.

M9_UI reports actual raster_wyhash for `two-pane-red-green-384x120-bgra`: CPU and Metal readback both `656cb39c595193ee`. Texture handles/generations alone do not establish pixel correctness. This text-free scene does not establish full-screen/font parity.

Real AppKit/GTK presentation, target Linux execution, SSH X11, complex clients, and long-load RSS/latency remain pending. Cross-builds, hidden Tester, and ELF audits are separate evidence.
