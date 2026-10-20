# UI review fixes: 2026-10-20

The six remaining audit findings (F2, F3, F4, F5, F6, F9) are implemented and locally verified. The earlier navigation changes (F1, F7, F8) remain integrated. This is local development-preview evidence, not target Linux acceptance or a distribution release gate.

## Frozen identity

- Source SHA-256: `f36cc1029a5ea8286d7d82876c0f05f6c6bf35a801f972eef0119e2a0784b815`.
- Native executable SHA-256: `a5f689948507d69193a7aa1a268585c3f3c5d5822db75463dfdb7cb3f61c39f2`.
- Compiler: Zig 0.17.0; ReleaseSafe; native Zig VT; VT SIMD disabled.
- Linux delivery target remains `x86_64-linux.3.10-gnu.2.17`, baseline CPU.
- Limits remain eight windows, sixteen tabs per window, sixteen application-wide PTYs, four preview documents per tab, and sixteen application-wide preview documents.
- [Evidence inventory](assets/ui-fixes-2026-10-20/evidence.json) records receipt, log, screenshot, and executable hashes. The original audit remains in `.cache/ui-audit-2026-10-20/report.html`; previous candidate evidence and versioned packages retain their original identities.

## Findings and fixes

| Finding | Resulting behavior | Verification |
|---|---|---|
| F1: collapsed sidebar loses navigation | Compact rail retains numbered workspaces, selected state, count, new-workspace and command controls. | Same-source hidden navigation checks; real two-workspace selection returned to the terminal containing `QA-FIRST`. |
| F2: rendered Markdown prose clips | Headings, paragraphs, and list prose wrap into visual rows at the available width. Code blocks and tables retain horizontal scrolling. Drawing, hit testing, links, selection, keyboard movement, and search share the same row geometry. | Native/portable preview components test narrow widths, grapheme boundaries, wrapped links, copy fidelity, width and zoom invalidation. Desktop screenshots show both the full preview and the 440-point dock. |
| F3: edited path becomes stale document identity | Opening the draft path restores the old document's path field to its actual loaded path before activating the destination. Copy Path, Refresh, and External use loaded-document identity. | Application checks cover path restoration and identity; desktop opened README, entered a PNG path, opened it, and switched back to README with its original path and content intact. |
| F4: source search match remains offscreen | Search reveals the selected byte range on both axes, including matches far along unwrapped source lines. | Long-line, cross-line and oversize-query component checks; desktop reverse search reached result 10/10 with the highlighted `Linux` visible near the right and bottom edges. |
| F5: stale feedback | Known success messages expire after four seconds. Capacity and prerequisite messages are reevaluated when the condition changes. Errors remain until replaced, resolved, or dismissed. Timers are cancelled with their owning window. | Timer and replacement-error checks; modal prerequisite regression; desktop rejected tab 17, closed to two tabs, and split successfully with no stale capacity message. Settings save feedback disappeared without another save. |
| F6: incomplete accessibility | Settings publishes visible categories, semantic fields and values, actions, errors and notices. Unsaved-change confirmation exposes only its modal content and two actions. Preview exposes mode, path, navigation, search, copy, refresh, external-open, image and collapse controls. | AppKit bridge, adapter and transaction components; hidden stale-action/generation tests; real macOS AX trees show `text field` roles, values, validation text, modal focus, and keyboard Tab/Return activation. |
| F7: preview entry unclear | Stable Open/Show/Hide File Preview entry points remain available; restoring a hidden document retains its reading/search position. | Hidden navigation checks and desktop restore retained Source mode, `Linux`, result 10/10 and document position. |
| F8: tab visual hierarchy | Existing integrated top-tab and document-tab styling is retained. Selected tabs connect visually to their content; overflow navigation remains available. | Hidden tab layout/reorder/focus tests; real two-tab and sixteen-tab screenshots show selected state and overflow arrows. |
| F9: preview Find updates only on Enter | Query edits schedule bounded incremental scanning, up to 64 KiB candidate starts per update and 512 retained matches. Search stops scheduling frames when complete. Composition clears stale results and postpones committed-query search. | Component checks cover delayed scanning, empty/no-match queries, composition, forward/reverse cycling; desktop typing `Linux` immediately produced 1/10 before Enter. |

The Settings numeric validation message now tells the user to enter a valid number within the field's stated range rather than exposing an internal parser error name.

## Final checks

All commands ran serially with source-hash guards. PTY suites ran with permission to spawn and reap their own children. The initial sandbox-only PTY execution denial was an environment restriction; the authorized rerun passed.

| Gate | Result |
|---|---|
| Native build and host suites | 213 unit tests, 49 core checks; VT replay, protocol, N2, boundary and graphics suites passed |
| Native hidden UI | 760 checks passed |
| Portable build and hidden UI | Host suites passed; 756 UI checks passed |
| Feature components | Preview: 66 each for native and portable; Settings: 61 each; AppKit bridge: 37; remaining loader/config/navigation/AX components passed |
| Linux cross-build and ELF audit | Nine executables passed static audit; maximum required GLIBC version 2.17 |
| Preview performance | Three runs per renderer passed; native and portable idle frame/draw counts remained zero in the offscreen cases |

Commands and complete output are under `.cache/ui-fixes-2026-10-20/`. Current receipts are under `.cache/verification/`; the evidence inventory includes only receipts matching the frozen source, not older feature receipts left in that directory.

Performance measurements exercise production loading and offscreen readers with 10,000-line text and 1,000-block Markdown fixtures. They do not measure real-window PTY, GPU, X11/VDI, or target-machine performance.

## Desktop evidence

Desktop testing used a separate `dev.letty.ui-fix-qa` app with the exact native executable above, an isolated configuration directory, no session restoration, and owned `/bin/sh` terminals. No user configuration was saved by this run. The QA app was closed after testing.

| Capture | Evidence |
|---|---|
| Markdown at full-preview width | [Screenshot](assets/ui-fixes-2026-10-20/01-final-markdown-narrow.png) |
| Markdown in a 440-point dock | [Screenshot and terminal alongside](assets/ui-fixes-2026-10-20/04-final-docked-markdown.png) |
| Immediate source search | [1/10 before Enter](assets/ui-fixes-2026-10-20/02-final-live-source-search.png) |
| Reverse search with two-axis reveal | [10/10 visible](assets/ui-fixes-2026-10-20/03-final-search-wrap-last.png) |
| Original path restored | [README after opening PNG](assets/ui-fixes-2026-10-20/12-final-original-path-restored.png) |
| Settings validation | [Screenshot](assets/ui-fixes-2026-10-20/05-final-settings-validation.png), [AX tree](assets/ui-fixes-2026-10-20/05-final-settings-validation.txt) |
| Modal isolation | [Screenshot](assets/ui-fixes-2026-10-20/06-final-settings-modal.png), [AX tree](assets/ui-fixes-2026-10-20/06-final-settings-modal.txt) |
| Compact sidebar | [Selected first workspace and retained terminal](assets/ui-fixes-2026-10-20/08-final-compact-navigation.png) |
| Capacity feedback | [Limit reached](assets/ui-fixes-2026-10-20/09-final-capacity-limit.png), [cleared after closing; split input](assets/ui-fixes-2026-10-20/10-final-capacity-cleared-split-focus.png) |
| Top navigation | [Two tabs](assets/ui-fixes-2026-10-20/11-final-top-two-tabs.png), [sixteen tabs with overflow](assets/ui-fixes-2026-10-20/15-final-top-sixteen.png) |
| Hidden preview restored | [Screenshot](assets/ui-fixes-2026-10-20/14-final-preview-restored.png), [AX tree with 10/10](assets/ui-fixes-2026-10-20/14-final-preview-restored.txt) |

Actual VoiceOver speech/navigation and live system IME composition have not been accepted. AX inspection and synthetic composition regressions are narrower evidence. Pointer drag mapping in the desktop automation was inconclusive; the drag attempt is retained separately and is not counted as an interactive resize pass. Width-change layout and hit testing are covered by automated regressions, and native window resizing produced the recorded full/docked layouts.

Target Linux execution, X11 forwarding/VDI, Linux ATK behavior, hosted CI, and the complete native release gate remain separate acceptance work. Automated fixtures validate loaded-path restoration; source inspection confirms Copy Path and External read the loaded model path. Clipboard output and external-viewer dispatch were not repeated in the desktop run.

## Local package

`dist/Letty.app` and `dist/Letty-macos-arm64-local-preview-f36cc1029a5e.zip` are the local preview outputs. Package metadata identifies its own source and executable hashes. This package is not a notarized distribution release.
