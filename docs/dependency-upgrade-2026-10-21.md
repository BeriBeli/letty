# Ghostty and nanoui upgrade — 2026-10-21

The dependencies remain pinned to immutable commits and verified archive hashes
in `deps.lock.json`. Ghostty was upgraded and checked first, then nanoui.

| Dependency | Previous pin | New pin |
| --- | --- | --- |
| Ghostty native VT | `5064b3265e500d55f5f44ff48ca59b8685543bb8` | `df246d0105e13dfd4a6a54754a9c6555325644ec` (`1.3.2-dev`, Zig 0.17 migration merged) |
| nanoui | `e4d53be8b216efa66a800bf3093d6c1cb83bbd8d` (`v0.1.0`) | `ad6f8659e29fa9a5a1f2ac90a4316a4e7f551cbf` (`v0.4.0`) |

The compiler remains exactly Zig 0.17.0. The delivery target remains
`x86_64-linux.3.10-gnu.2.17`, baseline CPU, ReleaseSafe, with VT SIMD disabled.
The native Zig VT boundary and the intentional platform C interfaces remain.
The manual nanoui module definitions now supply its version option and link
CoreVideo on macOS, as required by the new framework.

## Patch review

Ghostty's OSC allocation lifetime fix still applies unchanged. Upstream still
needs the stable writer allocation and transactional publication used by the
patch. Its targeted allocation-failure regression passed on the new revision.

All 19 existing nanoui patches still have required behavior. Their diffs were
rebased against 0.4.0; no complete patch became redundant. The upstream Alt/Ctrl
mouse modifier handling absorbed part of patch 07, so those duplicate hunks were
removed. Four patches (01, 06, 10, 17) apply byte-for-byte unchanged.

| Patch | Disposition and compatibility boundary |
| --- | --- |
| Ghostty 01 OSC allocation lifetime | Retained unchanged; targeted OOM test passes. |
| nanoui 01 font I/O | Retained unchanged; bounded font loading. |
| 02 legacy I/O | Rebased; Linux compatibility interfaces remain application-owned. |
| 03 IME | Rebased; composition and commit routing preserved. |
| 04 mouse | Rebased; terminal input state preserved. |
| 05 close request | Rebased; vetoable close ownership preserved. |
| 06 native font I/O | Retained unchanged. |
| 07 pointer buttons | Rebased; removed upstream-equivalent Alt/Ctrl changes; retained additional button handling. |
| 08 focus events | Rebased; focus callback ownership preserved. |
| 09 application quit request | Rebased; application-owned quit handling preserved. |
| 10 Shift menu accelerator | Retained unchanged. |
| 11 grid font shaping | Rebased; preserved upstream textures and wrap cache alongside grid glyph runs and bounded CPU damage tracking. |
| 12 window timing | Rebased; preserved upstream frame texture upload and lifetime handling. |
| 13 managed terminal images | Rebased; retained bounded images alongside upstream layers, motion and image tint. |
| 14 atlas ownership | Rebased; atlas lifetime and transactional image synchronization preserved. |
| 15 post-frame semantics | Rebased; deferred semantic ownership preserved. |
| 16 image sample bounds | Rebased; managed crop bounds are distinguished from image tint and frame texture slots in CPU and Metal paths. |
| 17 rich layout | Retained unchanged. |
| 18 control modifier refresh | Rebased; GTK modifier refresh preserved. |
| 19 GTK commit lifetime | Rebased; copied commit text retains its original lifetime protection. |
| 20 v0.4 render compatibility | Added; persistent CPU surfaces redraw mutable frame textures and glass backdrops, including their removal. Adapts upstream image test fixtures to the retained fallible sync/reset API. |

Patch 20 adds four regressions covering tinted images, nonzero texture slots,
in-place texture updates/removal, and glass backdrop pixel equivalence.
Full redraw is deliberately used for frames containing glass or frame textures;
ordinary terminal frames retain bounded damage tracking and idle behavior.

The concurrent Markdown table, kit component and scrolling tasks are separate
changes in the shared checkout. Their nanoui additions are patch 21 (scroll input)
and patch 22 (kit appearance), followed by document editing and minimum wheel
steps in the two independently authored patch-23 files. The final 24-patch
nanoui chain and single Ghostty patch were replayed twice from clean pinned
sources; the result matched all 137 nanoui and 1,014 Ghostty source files.
Final application evidence includes these changes in its recorded source hash.
The performance comparison therefore measures the combined checkout, rather
than isolating the cost of the dependency updates.

The upgrade also enlarged nanoui text buffers from 1 KiB to 16 KiB. The Settings
model previously stored all field buffers inline; stack-resident draft temporaries
then overflowed the macOS stack. Field storage now belongs to the existing draft
arena, with transactional allocation cleanup. The oversized-value regression
uses the actual buffer capacity, and all 80 standalone Settings checks pass.

## Verification

Completed dependency checks: exact Zig 0.17.0 bootstrap; the Ghostty OSC OOM
regression; and the final replayed 24-patch nanoui chain, with 115 native tests
passed and 98 portable tests passed (5 skipped). All 177 checked files satisfy
the 600-line limit. Linux aarch64 and Windows x86_64 examples and test binaries
also cross-compiled successfully. Earlier 22-patch results remain in the logs.

The complete upstream Ghostty VT suite passed **6,757 tests, with 56 skipped**
across both API harnesses; all 42 build steps succeeded. It ran from
`vendor/ghostty` in Debug with SIMD disabled, because tracked-pin tests require
slow runtime safety. The earlier invocation from Letty's root had 32 missing
snapshot-fixture failures; the corrected complete run required no source change
or golden update. Both the earlier failure log and final passing log are retained.
See the [dependency checks](assets/dependency-upgrade-2026-10-21/dependency-checks.json)
and [evidence inventory](assets/dependency-upgrade-2026-10-21/evidence-index.json).

The final application builds and execution checks use source hash
`bd90ac162f6c45224a5684cf3421c8ade557519a88da8407b79751096e383c24`.

| Check | Result |
| --- | --- |
| Native and portable ReleaseSafe builds | Passed; 228 unit, 49 core, 9 replay, 24 N2, 56 protocol, 21 boundary and 13 graphics checks in each mode |
| Complete hidden application UI | 806 native / 802 portable checks passed |
| Linux delivery build and static ABI | All 9 binaries passed; target, baseline CPU and glibc ceiling preserved |
| Feature components | Native/portable preview 94 each; Settings 80 each; image sampler, configuration writer, accessibility, navigation provider/login and preview loader passed |
| Configuration CLI | 15 passed |
| Strict VT golden records | 11 replay, 21 N2 and 56 protocol records matched |
| Native appearance observer | 6 passed |
| CPU damage rendering | 288 pixel comparisons passed |
| Preview performance | 3 native and 3 portable runs passed, including idle scheduling checks |
| PTY lifecycle | 256 cycles; all 257 owned children reaped |
| Startup and workspace restoration | 20 actual startup/quit runs passed |
| Login shell, foreground group and working directory | 20 actual runs passed |

The release verifier’s exact assertion counts were refreshed from these raw logs.
Its Linux UI expectation is 756, derived by excluding the 50 macOS/Metal-only
assertions from the native total; this is not a Linux execution result.
The final binaries report the actual Ghostty pin in both application and replay
version labels. The [local developer release gate](assets/dependency-upgrade-2026-10-21/acceptance.json)
passed after validating the source, binary and raw-log hashes. Historical receipts
were not relabeled as current acceptance.
Fresh reports and raw logs are stored under
`.cache/dependency-upgrade-2026-10-21/` and `.cache/verification/`.
The pre-upgrade binaries, manifests, patch chain and vendor sources were retained
under `.cache/dependency-upgrade-2026-10-21/` for comparison and recovery.

The standalone Linux nanoui examples need Letty's existing `compat.c` linked because patches 01/02 intentionally call those interfaces.
The isolated cross-build fixture supplies them; this does not add C code to
nanoui. Windows uses its own native I/O path. Cross-builds do not execute target
binaries. Docker is unavailable on this host, so nanoui's Linux container tests
cannot run here.

## Performance review

The [final comparison](assets/dependency-upgrade-2026-10-21/performance.json)
completed all 18 interleaved baseline/candidate runs (1, 4 and 16 panes, three
repetitions), with the same 88,771 matches and 151 search slices. The unchanged
1.10 regression threshold raised four warnings:

| Workload / metric | Baseline median | Candidate median | Change |
| --- | --- | --- | --- |
| 1 pane, idle CPU over about 2 seconds | 261 µs | 314 µs | +53 µs / +20.3% |
| 4 panes, longest search slice | 5.615 ms | 6.361 ms | +0.746 ms / +13.3% |
| 16 panes, idle CPU over about 2 seconds | 323 µs | 380 µs | +57 µs / +17.6% |
| 16 panes, bulk history feed | 80.250 ms | 89.285 ms | +9.035 ms / +11.3% |

The [manual review](assets/dependency-upgrade-2026-10-21/performance-review.json)
accepts these disclosed costs for local developer use. The largest candidate
search slice across all runs was 7.348 ms; frame P95 medians were 0.474–0.700 ms,
and the largest run P95 was 0.747 ms. Median peak RSS increased 3.67–3.97 MiB
(about 1.84–2.14%); executable size increased 4.24%. These measurements include
concurrent application changes and do not isolate the dependency upgrade.

The earlier run, before correcting the version labels, had three threshold
warnings (single-pane mean/P95 frame time and idle CPU). Its unchanged report
and raw logs remain in
`.cache/dependency-upgrade-2026-10-21/performance-before-version-label-fix/`.
The final rebuild was required by the version-label correction, not to remove
performance warnings. Neither run establishes a universal speed improvement.

## Remaining platform scope

Target Linux execution, X11/VDI, system IME and target performance acceptance
remain separate from macOS execution and Linux static ABI validation.

The original C recovery archive was absent from `dist/`. Its retained extracted
payload and deterministic historical packager allowed byte-for-byte recovery:
all 757 payloads were checked and the reconstructed compressed archive matched
the original SHA256 `58a9b6af2a6dcc0513236a8c05f2b62df79c584719d921c2171fdf63c8fc4ceb`.
Its historical source and validation identities were preserved.
