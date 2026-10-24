# nanoui fork pin and patch review — 2026-10-23

## Scope and source identity

The supported delivery remains `x86_64-linux.3.10-gnu.2.17`, baseline CPU,
ReleaseSafe, Zig 0.17.0 and native Ghostty VT with SIMD disabled. The remote
transport is X11 to an X server/VDI. There is no terminal-state Mirror or daemon.
GTK 3.22.30+, GLib 2.56.1+ and Cairo 1.15.12+ remain separate runtime requirements;
kernel and glibc versions alone do not establish GUI compatibility.

The fork's release baseline is upstream **v0.6.4**, commit
`f34d980944843a7c3054698d304ba22a5041fc42`. Letty pins fork commit
`e68e577db963cf003dacd9aa8da3b00b4cf8f71c`, which adds only the fork policy
documentation above that release. The previously requested `28379c4` was on
post-release upstream main; it is deliberately not the delivery pin after the
user selected a stable release baseline. The fork maintenance branch is
`codex/x11-v0.6.4`; its existing main history was not rewritten.

Downloaded archive SHA-256:
`1c5678c80fcc3ea693212b6ee52cb30ee9d2da4200b6690b36d5b724412e51f2`.
Both the full fork SHA and archive hash are recorded in `deps.lock.json`.
The downloaded archive was compared with the local Git commit's file contents.
The fork pin does **not** include Letty's compatibility changes. Per the user's
decision, those remain in Letty's active [four-patch chain](../patches/README.md).

The old 29-patch chain was replayed from its original v0.4.0 commit
`ad6f8659e29fa9a5a1f2ac90a4316a4e7f551cbf`. Its resulting `src/` matched the
pre-migration vendor tree exactly. Every original patch is preserved under
`patches/archive/nanoui-v0.4.0/`, with a SHA-256 inventory. The two patch-23
filenames are distinct inputs, so there are 29 files despite numbering to 28.

## Assessment method

Necessity is judged against the reachable `src/runtime/main.zig` application,
its actual framework calls and the supported Linux/X11 path, rather than
historical Letty features. A patch's existence or successful application is
not evidence that the current app uses its API. General rendering/lifetime
guards can still be necessary without a direct application-level call.

Upstream v0.6.4 adds its own retained CPU canvas/damage, threaded rasterization,
GTK 4 selection, OpenGL presentation and revised macOS resize scheduling.
Overlapping implementations need semantic review, not merely adjusted offsets.
The current migration retains upstream's threaded raster and macOS scheduling;
Letty's Linux overlay deliberately uses the GTK 3 CPU surface. It does not
implicitly select GTK 4 or a forwarded OpenGL context. The upstream GTK 4/GL
source remains present, but those are not supported Letty rendering paths here.

## Disposition of all 29 original patches

Active group numbers refer to `patches/README.md`. "Retire" means removed from
the active build, with the original patch archived unchanged. It does not mean
that the historical feature is permanently excluded from the product.

| Original patch | Decision | Requirement and evidence |
| --- | --- | --- |
| 01 font I/O | Keep in 1 | Portable font discovery/loading must use the Linux 3.10-compatible, bounded I/O adapter. Current `src/runtime/font_io.zig` exports the hooks in Zig; no new C shim is added to nanoui. |
| 02 legacy I/O | Merge into 1 | Required adapter for 01, not an independently useful feature. Avoid assuming Zig's newer filesystem path works on the old kernel. |
| 03 IME | Merge into 3 | Keep preedit, release filtering and caret placement. Its original borrowed commit delivery is replaced by 25/26's owned queue. |
| 04 mouse | Merge into 2 | `desktop.zig` consumes the shared mouse-button identity for terminal selection/protocol input. |
| 05 close request | Retire | The final current application uses its own `window_guard.zig` for native close interception and live-process confirmation. Its brief `on_close_request` integration during concurrent development was replaced; no final consumer requires the framework extension. |
| 06 native font I/O | Merge into 1 | Required non-Linux branch of 02 for macOS portable validation; Linux exports must not become mandatory macOS symbols. |
| 07 pointer buttons | Keep in 2/3 | Normalize GTK right/middle numbering and preserve modifiers/additional native mouse handlers. Terminal mouse encoding consumes these values. |
| 08 focus events | Retire callbacks; keep IM reset in 3 | There is no current `on_focus_changed` registration. Keep GTK IM focus/reset lifetime handling; do not claim that this implements VT focus reporting. |
| 09 app quit request | Retire | No current `on_quit_request` assignment. The Linux/Windows patch only adds a field; it does not itself route OS quit requests through it. |
| 10 Shift menu accelerator | Keep in 2 | Current menu/palette actions include Shift shortcuts; AppKit key equivalents need the shifted character. This is a macOS preview requirement, not a Linux ABI fix. |
| 11 grid font shaping | Split into 1/4 and GTK surface in 3 | `render.zig` calls `gridLayout`, uses cell spans/features and custom font families. Retain bounded cluster/font and damage state. Do not replace v0.6.4's threaded raster with the old scalar implementation or retain unused raster-work telemetry. See the portable-shaper integration gap below. |
| 12 window timing | Retire | No current `window_metrics` consumer. Its resize/presentation overrides were based on older upstream scheduling; preserve v0.6.4's newer scheduling instead of blindly applying them. |
| 13 managed terminal images | Retire | Current VT sets `kitty_image_storage_limit = 0`; no active managed-image API calls. The additional resource maps, limits and atlas protocol do not serve the current renderer. |
| 14 atlas ownership | Keep glyph subset in 2 | Glyph-atlas coordinate reuse must not mutate storage sampled by submitted Metal frames; preserve transactional portable glyph-texture replacement too. Managed-image sink/repack changes depend on retired 13 and are omitted. |
| 15 post-frame semantics | Retire | Current UI has neither an `after_frame` callback nor a `marked_text_id` consumer. Do not carry an unused deferred callback surface from the retired semantic/accessibility layer. |
| 16 image sample bounds | Retire with 13 | Applies to managed crop metadata, which the current app does not generate. Keep upstream's ordinary image/texture renderer rather than a second inactive crop contract. |
| 17 rich layout | Retire | A public export for old read-only rich selection; no current `ui.rich` consumer. |
| 18 control modifier refresh | Merge into 3 | Modifier release must reflect GDK's pre-event state. The later owned handler already incorporates this behavior; do not retain a second key handler. |
| 19 GTK commit lifetime | Merge into 3 | Owning commit bytes remains essential. Patch 25 supersedes the old one-off copy by owning every queued event. |
| 20 v0.4 render compatibility | Keep volatile-frame subset in 4 | Retain in-place texture and glass invalidation, including transition/removal. Managed-crop/tint workarounds are unnecessary after dropping 13/16. Tests cover the retained surface independently of those retired APIs. |
| 21 scroll input | Keep in 2/3 | Current terminal input consumes `scroll_lines` and `scroll_started`. Distinguish wheel line counts from precise pixel motion and retain horizontal motion. |
| 22 Kit appearance | Retire | Current `src/runtime/` uses native `ui` widgets and no customized `kit` button API. Application-specific visual styling is not an X11 compatibility requirement. |
| 23 document editor | Retire | Current fields use ordinary `TextBuffer`; no external buffer, `newline_on_enter` or document-editor consumer. |
| 23 scroll minimum step | Keep in 2 | Preserve small discrete AppKit detents without amplifying precise trackpad input. Separate from the preceding patch-23 file. |
| 24 X11 damage presentation | Keep and rebase in 3 | Upstream has partial invalidation, but this path also coalesces raster/presentation, handles exposure before idle and reuses bounded backing. Keep outward DPI rounding and avoid dirty-less X11 invalidation. |
| 25 GTK input and font points | Keep and rebase in 3 | Owned ordered events, reentrancy/teardown safety, queue budgets, idle coalescing and GTK font-DPI conversion directly serve terminal input and VDI. Replace its historical ID-bit shortcut heuristic. |
| 26 GTK modified commits | Keep in 3 | Preserve IME ownership of transformed/AltGr/composing input while recovering exact synchronous ASCII Ctrl echoes. Keep delayed commits as text. |
| 27 CPU solid fill | Keep over upstream raster in 4 | Opaque rectangle interiors can use row fills, while clipped/rounded/bordered edges retain scalar semantics. Upstream's fast scalar interior still blends per pixel; it does not replace this optimization. Pixel equivalence is required; no new performance gain is claimed without target measurements. |
| 28 font sources and arena retention | Keep in 1 | Shared immutable font snapshots reduce duplicate per-window source bytes; leases preserve teardown ownership. Exceptional frame peaks shrink at a safe boundary through a one-shot timer, without idle polling. |

## Corrections and remaining gaps

The old GTK handler distinguished terminal input from editable text using the
highest bit of `FocusedText.id`. The current terminal uses ordinary increasing
pane IDs, so Ctrl+C/A/V/X could be intercepted as text-field edits. IDs now
remain identities: `FocusedText.editable` defaults to true for native fields,
and the terminal sets it to false. Regression coverage uses both low and high
ID values and checks that all four shortcuts reach the terminal path.

GTK's [preedit API](https://docs.gtk.org/gtk3/method.IMContext.get_preedit_string.html)
reports its cursor in characters, while nanoui `TextOp.set_marked` selections
use UTF-8 bytes. Patch 25 formerly forwarded that character index unchanged,
putting Chinese composition carets inside multibyte characters. The rebased
handler converts to a bounded byte boundary. Callback-level regressions cover
Chinese text, a combining character, negative and beyond-end cursor positions.

The old GTK/Windows scroll patch converted one wheel detent into three
`scroll_lines`, while the current terminal multiplies that value by three
again. That gives nine history rows per detent and overstates mouse-wheel
events. The native backends now publish one signed detent; the application
owns the three-row history policy. Precise pixel deltas are unchanged.

The old damage patch and upstream canvas overlap, but are not equivalent:
the retained damage implementation bounds its instance cache and CPU backing,
tracks atlas changes, validates geometry and invalidates on failed rendering.
Those guards are useful for long-lived multi-window terminals. It still uses
one union damage rectangle and does not implement an X11 scroll-copy protocol;
smooth remote scrolling is a measurement target, not an established result.

The portable `gridLayout` contract requires `setRunShaper`; the initial Kero
snapshot did not install that callback. The shared application's subsequent
integration now installs the app-owned `terminal-shaper` module in
`src/runtime/fonts.zig`, using its pinned HarfBuzz bridge. This reinforces the
necessity of patch 11's callback/source contract, but does not by itself
establish Linux ligature or complex-script acceptance. That application
integration remains outside nanoui and must be covered by the final portable
build and target rendering checks.
The retired focus callback does not establish VT focus-in/out behavior. Close
confirmation uses the application's own native guard, which remains in Letty.
The shared checkout changed that integration during this review; patch 05's
final disposition was rechecked against the final consumer rather than an
intermediate snapshot. These are application integration boundaries, separate
from the four active framework patches.

## Verification

The [final evidence inventory](assets/nanoui-fork-2026-10-23/final-verification.json) records
source/log hashes, raw results and copied build manifests. All five framework
checks used stable final nanoui source identity
`54030f7fc48d3501d604fd9a6493965cf9b377b100365aec59b3b5f4a946417f`.

| Check | Result |
| --- | --- |
| Original patch provenance | All 29 archived files match the originals byte-for-byte. |
| Final active chain | Two clean, zero-fuzz replays; all 156 source files match vendor. Bootstrap is idempotent. |
| Framework line limit | `zig build lines`: 211 files, all within 600 lines. |
| Framework native Metal tests | 140 passed, 1 skipped. |
| Framework portable tests | 127 passed, 5 skipped. |
| Standalone GTK input/presentation tests | 25 passed, including terminal ID-independent shortcuts, Unicode preedit cursor boundaries and damage rounding. |
| Framework Windows x86_64 cross-build | All 9 steps passed. |
| Framework iOS Simulator arm64 cross-build | All 8 steps passed. |
| Letty native and native-portable ReleaseSafe | Both built; 14 unit and 5 owned PTY checks passed in each mode. |
| Letty Linux delivery build | Passed with baseline CPU, ReleaseSafe and VT SIMD disabled. |
| Current Linux ELF ABI | The three manifest-listed binaries passed; highest required glibc is 2.17. Older binaries already present in `zig-out/linux/bin` were excluded from current evidence and preserved. |
| Complete application hidden UI | 19 checks passed in each native and native-portable mode; deterministic screenshots were saved and visually inspected. |

Application results certify source snapshot
`59d357b01eea9d952ecec673c16d674ea77cd89c5885dfef35bb0fa64e8bf893`.
Native, native-portable, Linux, UI and ABI checks used this same stable source,
which matched the checkout when the final evidence was saved. Compare
`tools/verification.py`'s `code_hash()` before reusing the receipts after any
later edits. The final nanoui source and patch identities are independently
recorded above.

The initial hidden-UI run stopped earlier at `MissingSelectionFixture`. A
diagnostic build of a frozen application snapshot against the original v0.4.0
vendor and all 29 old patches reproduced the same failure. Its only framework
addition was an unused `FocusedText.editable` field to compile the new caller;
no renderer behavior was changed. Subsequent application fixture work reaped
the owned shells before deterministic rendering and progressed past selection
and private clipboard checks. A later palette failure was also retained as a
failure, not waived or asserted to be an upstream regression. Further
application changes fixed its action handling; the complete suite then passed
in both modes. The [earlier evidence](assets/nanoui-fork-2026-10-23/verification.json)
for source `46cf8ef91b6dea8bed42d05eef11677ba92d8402da25ec103f8dbcb842f81a57`
and its failed-check logs remain unchanged. Final application logs, screenshots
and receipts are separate under `assets/nanoui-fork-2026-10-23/final-application/`.
The portable renderer's uncompressed PNG is archived losslessly as `.png.gz`;
the inventory records both archive and original PNG hashes.

Historical release receipts retain their original identities and are not
relabeled as current evidence. Cross-compilation and static ABI checks never
establish real Linux 3.10/glibc 2.17 execution, X11/VDI latency, clipboard,
system-IME or performance acceptance. No Linux container runtime is installed
on this host, so target Linux execution was not performed.
