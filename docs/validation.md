# Validation history

These are development-candidate records, not target Linux certification. Runtime requirements are defined by [kernel/library versions](compatibility.md), and target checks follow the [Linux checklist](linux-testing.md). Historical counts belong to the named source/batch; documentation edits do not rerun them.

## Initial checks (2026-10-19)

| Check | Recorded status | Evidence scope |
|---|---|---|
| Locked nanoui/Ghostty/toolchain | Checked | deps.lock.json, Zig 0.17.0 |
| Clean extraction/idempotent patches | Passed | Fresh locked archives, per-file comparison, two identical applications |
| Native/old-Linux VT static libraries | Passed | Actual fixed-commit Zig builds, explicit Linux target/baseline CPU |
| Queue/config/layout units | Passed | Ring queue, bounds/defaults, layout close/malicious cycles |
| VT/PTY core | Passed on macOS arm64 | ANSI/CJK/combining/alternate/query/resize/key-mouse-paste/search-copy/real PTY/reaping |
| Application native/offscreen | Passed | Actual Maple/Paper, CPU text, real PTYs, 2 tabs/4 PTYs, splits/resize; UI command wrote a verified shell marker |
| Linux ELF ABI | Passed | All delivery architectures/interpreters/NEEDED/versions/RPATH, max GLIBC_2.17 |
| Linux execution/Xvfb/statx ENOSYS | Pending CI | Workflow exists; no local amd64 container |
| Hosted GitHub CI | Not run | No configured remote at initial recording; no repository created/pushed |
| Target Linux 3.10 core/GUI | Pending | Same-package probe/core/gui |
| Native IME/X11/clipboard | Pending | Preedit/candidate/async commit/focus require actual display |
| Konsole PSS/CPU/X11 | Unmeasured | Workload/smaps scripts available; no savings percentage |

Source/runtime each have checksums. build-info records host/dependencies/target/optimization/validation classes. Cross-builds are distinct from Actions. Test and release the same artifact rather than rebuilding after acceptance.

## UI, configuration, and palette (2026-10-19)

Ghostty-inspired nanoui changes kept CoreText/Metal on macOS and portable GTK on Linux: physical-pixel grid rounding, removed extra 2 pt leading, solid inverse/hollow cursor. Hidden --ui-checks exercised 2 tabs/4 PTYs, divider dragging with 7 pt hit area, auto-focused/live-output search, Escape→real shell, split-tab close, 480×300 resize. New-output-after-search regression passed without idle polling.

Text configuration added themes/palette/cell adjustments/asymmetric padding/cursor/blink/opacity/tab bar/bindings/reload/--check-config. Tests covered ranges/unknowns/last-wins/clear/unbind/menu synchronization/parameters and isolated themes/configuration retaining PIDs/old state/cache lifetime.

Palette initially passed fourteen unit/sixteen core plus hidden UI: title/action/CJK keyword filtering, wraparound navigation, Enter→real PTY, mouse/wheel, empty results, Escape/native cancel, outside-click isolation, 480×240, Find focus, custom bindings, reload PID. Paper/dark screenshots inspected; target GTK/X11 remains pending.

## M0–M5 (2026-10-19)

| Batch | Recorded checks | Behavior |
|---|---|---|
| M0–M1 | 19 unit/16 core plus hidden UI | Typed parameters/availability/IME, v1→v2/malicious metadata, directional/equalize/resize/zoom preserving PID/topology, focus/title/stable reorder/eight-tab overflow/atomic limits |
| M2 | 19 unit/31 core plus hidden UI | Real-shell history, independent search/selection, counts/highlights/CJK/combining, reverse/page/scrollbar/output-position/resize/alternate/all/clear/reset preserving PID |
| M3 | 20 unit/31 core plus hidden UI | Stable-ID close with sleep cancel/Escape/default Enter, targeted approval; actual hidden rightMouseDown and windowShouldClose veto; O_EXCL races/opener fallback/error line-key/PID |
| M4–M5 final | 23 unit/46 core/124 UI | Async identity/slot reuse/PRIMARY separation/paste confirm/bracketed-safe/IME/soft-wrap URLs/true OSC 8/HTTP(S) policy; shell/CWD/events/focus |

M1 screenshots: `.cache/test-logs/layout-*.png`; M2: search-matches-paper.png. Viewport-only highlights do not mirror/scan full history per frame. The old C prompt-clear limitation is historical; native behavior is described in [configuration](configuration.md).

M3 patches 05/06/07 add veto/native font I/O/button routing, with two idempotent passes. Linux arm64/Windows x64 counter/gallery/tests cross-built, not executed. The harness supplies external lt_* compatibility objects missing from direct vendor test-bin. 106 nanoui files met 600 lines.

M5 real zsh checks preserved hooks/spaced CWD/explicit priority/background failure/fallback/always-idle close; pane/modal/window focus is deduplicated lost-before-gained. Events cover BEL/PWD/semantic/progress, prompt navigation/resize, remote authority refusal, mode-off zero focus bytes. Temporary startup files/private adapters avoid user state. `python3 tools/check-shell-integration.py` passed real Bash 3.2 manual source and zsh wrapper hook/exit/trap/ZDOTDIR preservation. Bash 3.2 auto-injection is disabled; Linux Bash 4.2 auto-launch remains pending.

Patch 08 adds focus/GTK IME reset. Eight patches replayed from pristine to twelve byte-identical files, second pass unchanged; 106-file limit and framework cross-builds passed, without target execution. Paper paste/link and light/dark screenshots inspected. [Performance](performance-native-2026-10-19.md) excludes GPU/X11. Four Linux delivery ELFs max GLIBC_2.17; macOS plist/strict codesign/resources/archive/SHA256 checks passed.

## M6 and native palette shortcuts (2026-10-19)

M6: 24 unit/46 core/142 UI, no SafeAllocator leaks. Real hidden windows verified unique Window/Session IDs/PIDs, active-window menu queue, aggregate Quit/cancel, all-window reload atomicity, eight-window/sixteen-PTY bounds, isolated close, late clipboard disposal. v3 restored two new-PTY windows, migrated v1/v2, and tested write locks. Patch 09 adds application Quit veto; framework cross-builds passed, target GUI/readers unexecuted. Package counts came from actual logs/source/binaries rather than old constants.

Four actual hidden NSEvent/menu checks raised UI to 146: Cmd+Shift+P toggles without inserting P/replacing PTY; NSMenu performs equivalently; ignore removes accelerator. AppKit needs uppercase Shift-letter equivalents. Patch 10 fixes native registration without changing common Linux/Windows parsing. Ten patches/two replays/fifteen byte-identical files and 106-file limit passed.

## Native migration and launch behavior (2026-10-19–20)

See the [migration plan and evidence](native-zig-vt-adaptation-plan.md) and [performance comparison](performance-zig-migration-2026-10-20.md).

| Stage/source | Actual recorded checks |
|---|---|
| N0 | 35 native probe, Linux cross/ABI |
| N1 | C 25 unit/46 core/146 UI; each backend nine replay/eleven equal records; native twelve boundary, no DebugAllocator leaks; two Linux ELF ≤2.17 |
| N2/N3 | C 25/46/156 UI; native 25/46/169 UI; 24 N2 assertions/21 equal records; 56 protocol/596 splits each; 51 equal plus five known old-C missing size replies; native 21 boundaries |
| Login/CWD alignment | Native 26/46/174 UI; C 26/46/161; real zsh prompt-clear thirteen and vi UTF-8 edit/save/alternate nine |
| N4 final 76d6fabb5620 | Native 26/46/174 UI/21 boundaries; fixed 11/21/56 golden records/596 splits; eight Linux ELF ≤2.17; graphics component 26 and geometry/budget two each |

OSC Capture allocation testing exposed/fixed fallible-init/self-reference publication in a local pinned-source patch, replayed idempotently. N1 packages were headless checks, not native GUI acceptance. N2 graphics were component evidence before GUI integration.

Default switched only after pre/post gates. Search quota initially failed at 32 MiB, became bounded 64 MiB with failure evidence retained; eighteen performance runs were reviewed, without claiming every metric faster. Native prompt-clear follows pinned Termio with TX reservation/one post-VT FF. Actual zsh preserves pending input/cursor/CJK/combining/reflow; vi fixtures verify saved bytes and other PIDs.

Launch follows pinned Ghostty Exec/WorkingDirectory/desktop behavior: macOS login with .hushlogin quiet, Linux interactive non-login; desktop/CLI CWD and three inheritance switches, revalidated directories, PWD preserving symlinks. Watched login PID differs from shell foreground group. Real argv/Bash forwarding/zsh login-nonlogin passed.

N4 final lifecycle: 256 rounds/~69.4 s, 257 children reaped; twenty layout-startup restores and twenty real login/foreground/spaced-CWD/reaping checks. Complete [C recovery](c-vt-recovery.md) was verified and rebuilt offline in a fresh spaced path: 26/46/161 UI/nine replay/24 N2/56 protocol. Twenty-one retired VT-C/tool files were removed; platform C/dependencies remain. Eighteen native before/after runs retained one four-pane system-CPU +10 ms warning. The source-bound gate passed. Initial sandbox PTY refusal remains; authorized-host rerun passed without removing tests/weakening checks. Linux UI 166 was a future static-branch expectation, not executed CI.

## M7 application acceptance (2026-10-20)

Source f7f9ccef94e9: 76 unit/46 core/246 UI, fifteen configuration CLI, fixed golden/596 splits/21 boundaries. Seventy-two new application assertions cover sequence completion/ambiguity/absolute timeout/cancel/IME/window identity; a cancelled 1000 ms prefix cannot delay a new 50 ms prefix (verified within 80 ms). Raw PTY/od checks exact Unicode/backslash/ESC/NUL/csi/esc and unmatched final-key delivery. Queued Requests own bytes after binding arenas free.

Two real raw PTYs test all-or-none enqueue under busy targets, identical delivery after recovery, and skipping exits. Actual dispatch tests performable/unconsumed/private clipboard. Two-window includes/optional/symlink cycles/semantic errors/inactive-theme failure retain old config/PIDs. Deleted/corrupt theme files do not break cached appearance changes; zoom/revision remain stable. Six actual AppKit selector checks cover registration/delivery/dedup/teardown/late callbacks without changing system appearance. GTK native signals remain pending.

Initial InvalidCharacter became InvalidColor; broadcast checks now parse actual od bytes rather than terminal-formatted strings. Initial P95 warning remains; removing unnecessary idle/text availability queries resolved it on rerun without changing 1.10 thresholds. Lifecycle: 256 rounds/~68.6 s/257 reaped children; twenty layouts/twenty logins; eight Linux ELF ≤2.17. Linux UI 238 remained an unexecuted expectation. M8–M11 were not yet fully integrated at this snapshot.

## M8 intermediate snapshot (2026-10-20)

Unreleased 94c54aae363e passed native/portable 87 unit/46 core/355 UI, golden/protocol/boundaries/fifteen CLI. Each font suite had 76 assertions including actual Maple calt glyph replacement without column changes, default/explicit 2027 grapheme modes, five underlines/colors/overline/conceal, old-arena cache lifetime. CoreText color glyphs became contrast-preserving masks; portable ZWJ unsupported/tofu was disclosed. Fourteen screenshots generated and native glyph/gray-emoji inspected.

288 CPU comparisons and 31 correctness checks passed; offscreen-cursor measurements were retained separately. Failed font candidates no longer exhaust portable load budgets; seventeen database checks passed without evicting published sources. Sandbox PTY failure and authorized rerun were retained.

Linux f32/maxInt(u32) compilation failed, then used an exact exclusive 2^32 bound. f61d9f493d39 eight ELF audits passed; patch 11 replayed 27 files from its ten-patch base. Later window/graphics changes required fresh patch-12/13 evidence. Concurrent window instrumentation caused build9/stability source guards to reject changed binaries; those rejections were preserved. Initial M8 eighteen-run report retained three warnings and a 29.314 ms search tick pending frozen rerun. This snapshot did not certify M8–M11.

## M8 frozen acceptance (2026-10-20)

Source `534a13035e129811af659cda9e08696f78c7c71aafce54fb4ef1e6f882e63fbc`; passed gate SHA256 `68d783a52438d4cd1f3d9906698f0517d5be1ecb3f93894d39b0c962c13e2bc2`. Checks: 110 model/46 core/526 native UI/522 portable UI, golden/596 splits, thirteen graphics Context, fifteen CLI, six appearance, seventeen save, 256 lifecycle/257 reaped, twenty layout/twenty login, 288 CPU pixels. Fifteen patches/46 replay-identical files, framework Linux/Windows/123-file limit, nine ELF ≤GLIBC_2.17 passed.

Eighteen frozen performance runs reviewed all maxima: candidate search max 6.253 ms. Historical 29.314 ms/warnings remain; three small absolute costs have recorded acceptance reasons in [performance](performance-m8-2026-10-20.md). Receipt: m8-native-release-acceptance.json. Only local M8 scope was complete at this point; target/native services remained pending.

## M9–M11, Settings, Sidebar frozen acceptance (2026-10-20)

Source `8e6a2f5691b5b59a0a87afe735b986d0db0050b79ce1f762cd1678b95ff4e107`; gate SHA256 `84750e7b0b172465d849f53a2061b773c76719c7e59cdc3d5c59137baea59a5e`. Checks: 190 model/46 core/675 native UI/671 portable UI, golden/596 splits/thirteen graphics Context/fifteen CLI/six appearance. Native feature counts: 45/102/63/81/18; portable: 41/102/63/81/18. Settings forms 61 each, provider 26, real-login provider nine. Lifecycle 256/257, twenty layouts/twenty logins, 288 CPU pixels, matching CPU/Metal Kitty hashes. Sixteen patches/48 files, framework cross-builds, nine Linux ELF ≤2.17 passed.

Eighteen M8 comparisons had no >1.10 median warning. RSS rose <0.5%, unstripped binary +15.53%; see [performance](performance-m9-m11-2026-10-20.md). Fixed/retested issues include conditional-ligature branch/draft preservation, repeated font invalidation, crop bleed, ThemeCancel reverting navigation, and set-id login metadata permissions. Old guards/failures retain their identities.

[Release/artifacts](m9-m11-release.md) govern this batch; M8 archives/receipts remain intact. Real Carbon/X11 hotkeys, VoiceOver/Orca, IME/native drop, target Linux/GTK/X11, hosted CI, and sidebar end-to-end performance still have no passed execution claim.
