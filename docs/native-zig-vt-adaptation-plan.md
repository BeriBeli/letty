# Native Zig VT migration plan and history

Created 2026-10-19; status updated 2026-10-20 (Asia/Singapore). Original execution chat: local `01a152ef-21d6-7151-84c1-89aee2aebb57`. The user authorized preparation, complete migration, default switching after validation, and retirement of unused C VT after stability/recovery checks.

N0–N3 development gates passed; the GUI defaults to native Zig. N4 local stability/archive recovery/active C cleanup and the post-cleanup gate passed. Target Linux/display/IME remain pending. This document combines the historical plan and results; current commands are in [README](../README.md), and old dual-backend commands apply only to archived source.

## 1. Verified source facts

- Pinned Ghostty `5064b3265e500d55f5f44ff48ca59b8685543bb8` exposes Terminal/TerminalStream/RenderState/search/SelectionGesture/formatter/kitty/input through src/lib_vt.zig.
- src/build/GhosttyZig.zig registers ghostty-vt/ghostty-vt-c and injects terminal_options/Unicode/uucode/optional wuffs-SIMD. Import the official dependency module rather than treating lib_vt.zig as an independent file.
- Official example/zig-vt and zig-vt-stream show path dependencies/dep.module. Their minimum_zig_version does not replace Letty's exact Zig 0.17.0 pin.
- Terminal.vtStream defaults readonly. Text parsing alone does not provide replies/BEL/CWD/title/clipboard: explicitly install Handler.effects.
- Native API stability is not guaranteed. Pin the commit and contain types within Letty's facade.
- Before migration, builds linked C VT/bridge. Active builds no longer do; platform_ffi retains real PTY/files/GTK symbols. Independent C recovery preserves the comparison.
- The baseline M6/shortcut record was 24 unit/46 core/146 UI. Unwired modules could not count as delivered features.

## 2. Goal and boundaries

Own a narrow Letty facade directly importing ghostty-vt, retaining nanoui/Session/PTY/queues/interactions. Never maintain two production VT/history copies. N0/N1 prepared interfaces; N2 migrated; N3 switched defaults after complete evidence; N4 retired active C after verified recovery/stability.

Keep Linux 3.10/glibc 2.17/baseline CPU, Maple/Paper/configuration, eight windows/sixteen PTYs. Native reduces glue but makes no assumed CPU/RSS/size advantage. Local or SSH X11 deployment remains supported subject to target acceptance.

## 3. Interface mapping

| Former boundary | Native direction | Required invariant |
|---|---|---|
| C lifecycle/feed | Terminal/TerminalStream/explicit effects | One VT, exactly-once bounded replies, visible OOM/semantic failure |
| Frame/colors/palette | RenderState/page/cell/style/colors | Visible-only iteration, borrow lifetime, wide tail/inverse/search/selection |
| Resize/settings/history | Terminal/Handler.resize/screens | VT before TIOCSWINSZ, size replies, budget pruning/reflow |
| Key/mouse/paste/focus | Native input encoders/options | Current modes/Ctrl-Alt-Kitty/paste capacity/1004 dedup |
| Search | search/visible hit mapping | Incremental counts/current, selection independence, output invalidation |
| Selection/formatter | SelectionGesture/Pin/formatter | Tracked anchors/pruning/soft wraps/CJK/copy bounds |
| Navigation | Terminal/Screen scrolling/reset/erase | Alternate policy, clear≠reset, actual prompt redraw |
| Events | Handler.effects/getters | Copy title/PWD/BEL/semantic/progress without parser reentry |
| Links | Page hyperlinks/existing URL policy | True OSC 8 targets, visible hits, HTTP(S) |
| Graphics | Kitty storage/placement/PNG | Byte/dimension/copy budgets, screen/delete/viewport/release |
| Platform lt_spawn/lt_read etc. | Keep separate platform layer | forkpty/GTK fd/old ABI/async clipboard/reaping |

## 4. N0: isolated executable probe

Use tools/native-vt-probe with pinned path dependency/exact compiler/explicit target-optimize/simd=false and separate cache/prefix/logs. Heap-stable terminal/stream, stream-first teardown, bounded explicit effects, no callback feed. Test ASCII/SGR/CJK/combining/fragmented UTF-8/alternate/resize-reflow/exact-once DSR/title/PWD/BEL/semantic/progress/key/paste/focus. Actually run native and cross-build/audit baseline Linux; never equate them. Keep init.io; do not reduce capabilities through TinyIo without analysis. Record commands/dependencies/results/failures. Leave app defaults unchanged.

## 5. N1: facade and temporary dual builds

Letty-owned Cell/Cursor/Scroll/SearchInfo/Events/Link types isolate upstream. Historical compile-time `-Dvt-backend=c|zig` started with C default. Each variant linked only its own engine, not duplicate implementations. Stable Handler→Session pointers survive container movement. Borrow only current snapshots; raw pointers/Pins never survive mutations.

Start lifecycle/feed/replies/frame/resize/input; unconnected features fail explicitly. Normalize typed errors without dropping bytes/backpressure. Both backends replay equal byte/resize/action scripts and compare normalized visible state/replies/events/copy, not internal pointers/layout/revisions. C retains original regression until migration acceptance.

## 6. N2: feature migration

Migrate history/selection/search, then links/events/shell, then graphics/clipboard capability using owned snapshots/budgets. Preserve paste/window/IME/focus ownership; parser callbacks supply state/effects rather than platform operations.

Prompt-clear follows pinned Ghostty Termio/Terminal/Screen and actual shell redraw needs, testing input/cursor/history/modes. Explicit effects preserve device/size/color/Kitty/clipboard-deny behavior formerly installed by C APIs. Facade capabilities guide new work; no growing C-only wrappers. Unmigrated image hosts do not invalidate independent text tests, but remain unclaimed.

Completion requires every delivered C feature mapped or explicitly blocked, actual core/UI execution for each variant, and new native fixtures without deleting/shrinking tests to hide differences.

## 7. N3: switch, rollback, and performance

Run all model/core/hidden UI/real-shell/window/layout/reload/late-callback regressions. Compare text/styles/cursor/selection/scroll/replies/events through all representative byte splits, pruning, deterministic fixtures, and release. Measure identical C/Zig workloads for sizes/startup/idle/RSS-PSS/1-4-16-pane output/search/scroll, disclosing unmeasured target costs and investigating material regressions.

Audit every Linux ELF and required framework builds. Package native macOS/Linux candidates with matching backend/feature/source/binary/log identities and retain C artifacts/source/restore instructions. Switch root build/tools/Run/packagers/metadata together only after the actual gate; verify an unspecified backend produces native GUI without C engine symbols.

## 8. Original ownership

The original authorized parallel allocation separated probe, adapter/effects/fixtures, and graphics/text models. Main integration owned root build/Session/facade/ffi/app/menu/shared vendor/full tests/packages. Agree interfaces/file ownership and serialize compilation/probe windows. Keep ongoing M7 work. This is historical allocation rather than an instruction to spawn agents during documentation maintenance.

## 9. Evidence policy

Update architecture/validation/build instructions per stage with actual scope. Backend/counts come from fresh logs. Lock unstable upstream through adapters/fixtures, never automatic main tracking. Candidate/default/target-accepted are distinct statuses.

## 10. N0 actual results (2026-10-19)

`python3 tools/native-vt-probe/run.py --zig=/opt/homebrew/bin/zig` sequentially built/ran 35 native assertions and cross-built/audited `x86_64-linux.3.10-gnu.2.17` / baseline, max GLIBC_2.17. Linux was not run on macOS. Exact commands/hashes/Io/backend metadata: `.cache/native-vt-probe/metadata.json` and neighboring logs.

Passed explicit effects, exact single replies, split fixtures, SGR/wide/combining/emoji/screens/resize/events/mode-aware input/budgets/leak-free teardown. Readonly negative confirmed the need for effects. init.io/simd=false, no C archive, unchanged app default.

Historical N1 facade entries included vt.zig/vt_types/vt_c/vt_zig/vt_replay; platform_ffi retained platform code and ffi only old-fixture aliases. Probe success was not GUI acceptance.

## 11. N1 actual boundary and candidate results

C passed 25 unit/46 core/146 UI. Each backend passed nine replay checks with eleven identical normalized records (ANSI/CJK/combining/splits/screens/resize/exact DSR/events/input/paste/focus/reply refusal). Native passed twelve boundary checks with no DebugAllocator leaks: stable address/resize/size-2048/metadata/short buffers/mouse/reentry/allocation failure.

allocator_audit reports actual rawAlloc failure, not normal resize/remap fallback, and does not claim every mmap/OS failure. Real Io/stable audited allocator preserve ownership; overlong PWD rejects rather than truncates. An OOM test exposed Capture fallible-init/self-reference publication. `ghostty-01-osc-allocation-lifetime.patch` completes fallible work before publishing optional/internal writer pointers. Fixed commit retained; native/C regressions/upstream targeted parser test passed; two pristine replays matched bytes.

Historical commands (archived source only):

```sh
python3 tools/build.py --native --skip-bootstrap --vt-backend=c --zig=/opt/homebrew/bin/zig
python3 tools/build.py --native --skip-bootstrap --vt-backend=zig --zig=/opt/homebrew/bin/zig
python3 tools/compare-vt-replay.py
python3 tools/verify-ui.py
python3 tools/build.py --skip-bootstrap --vt-backend=zig --zig=/opt/homebrew/bin/zig
python3 tools/audit-elf.py zig-out/linux-zig --output .cache/verification/n1-linux-zig-abi.json
python3 tools/package-native-vt-checks.py
```

Skip bootstrap only with prepared pinned/patched dependencies; fresh workspaces bootstrap first. Targeted upstream command from vendor/ghostty:

```sh
zig build test-lib-vt -Dtest-filter='Parser allocating OOM fallback owns stable writer' -Demit-exe=false -Demit-lib-vt=true -Dsimd=false -Doptimize=ReleaseSafe
```

Evidence: `.cache/verification/{native-*.json,build-native*.json,build-linux-zig.json,vt-replay-comparison.json,n1-linux-zig-abi.json,n1-engine-symbols.json,ghostty-patches.json}` and `.cache/test-logs/n1-*.log`. C-only engine symbols were absent in native. Two Linux native check ELFs audited ≤2.17, not executed.

N1 package `dist/letty-native-vt-N1-el7-76e70457ffd0.tar.gz` contained two headless ELFs/eleven golden records/test-centos-native.sh/backend/results/digests. Its script was checked with macOS binaries in a spaced temporary path, not presented as Linux execution. C macOS candidate: `dist/Letty-macos-arm64-M6-76e70457ffd0.zip`, with earlier M6 packages retained. N2 components were still independent and C still app default at this snapshot.

## 12. Authorized default switch and cleanup requirements

The user expanded preparation to actual default switching after all N2/GUI/protocol/PTy/config/layout/shell/boundary/resource checks, fair performance investigation, and Linux ABI. Save independent C prefixes/source/artifacts/checksums before switching; default outputs and measured bytes must agree. Continue independent development if target access is missing, with explicit pending acceptance and executable rollback.

At N4 the user explicitly allowed removing the entire active C VT backend rather than permanent dual maintenance. Require combined repeated startup/exit/layout/reload/windows/late-callback/shell-TUI/output/pruning/search/copy/focus checks, bounded-duration loads with elapsed/iterations/memory/FD/PTy/child/reap data, and regression for every discovered failure. Idle survival alone is insufficient.

Preserve a verified executable/source-rebuildable C archive even while target checks remain pending. Never assume uncommitted Git can restore it. Keep historical binaries/source/golden/comparison/failure logs after deleting active code.

| Category | Cleanup boundary |
|---|---|
| vt_c, VT-specific C bridge/search/navigation/links/events/graphics/headers/externs | Remove after native mapping, archived comparison, zero build references |
| C selector/archive/C-only build-package-comparison paths | Retire after recovery; retain shared assertions as native/golden |
| platform_ffi/PTy/fork/process/files/GTK/X11/clipboard | Keep actual usage |
| Pinned Ghostty/nanoui/Wuffs/HarfBuzz and needed C/C++/licenses | Keep; this is not project-wide removal of C |

After cleanup, rebuild locked dependencies/patches, run complete native/ABI/stability/source-bound release gate, check manifests/references, update docs/backend metadata, and package new digests. Only then mark local migration/retirement complete.

## 13. N2–N3 actual migration/default switch (2026-10-20)

Historical dual commands reproduce only from recovery source. N2 integrated tracked search/selection/history/visible links/32-64 highlights/full teardown and post-leave error propagation, retaining one VT/history and official module. Neither old GUI enabled image/OSC 52 hosts at that time; components did not count as GUI support.

Actual C: 25/46/156 UI; native: 25/46/169 UI. Nine base replay/eleven records each; N2 24 assertions/21 identical records. Both passed 56 protocol fixtures/596 byte splits: 51 identical plus five known old-C missing size callbacks where native replies correctly. Native 21 boundary/lifetime/clear primitives and isolated N2 46 checks/Linux ABI passed.

Prompt clear preserves current line/column outside prompts; at prompts it reserves TX before mutation and sends one FF after leaving VT. Real isolated zsh checked mid-edit cursor/unexecuted CJK/combining/reflow. Busy queues preserve text/selection/revision. Real vi PTY edited/saved UTF-8/returned from alternate screen, verifying bytes/unaffected PIDs.

Eighteen performance runs found identical 88771 matches. Initial 32 MiB quota failure retained, bounded 64 MiB passed. Search total rose ~6.4–6.9 ms; longest-tick medians 4.96–5.24 ms versus C 6.17–6.43. Review accepted disclosed development tradeoffs without erasing threshold warnings; see [performance](performance-zig-migration-2026-10-20.md).

Pre/post gates: `.cache/verification/n3-pre-switch-gate.json` and native-migration-gate.json. Root/tools/Run/macOS/Linux defaulted zig; unspecified builds reported vt-backend=zig and matched measured native bytes. C temporarily became explicit native-c/linux-c. nm found ghostty_terminal_new only in C. Linux GUI/checks cross-built/audited ≤GLIBC_2.17, unexecuted.

Pre-switch `dist/letty-c-baseline-5c9da7d514a5.tar.gz` plus wholearchive.sha256 retained authored source/five C binaries/logs/file checksums/RESTORE independent of Git/cache. Old N1/M6 remained. Historical validation:

```sh
python3 tools/build.py --native --skip-bootstrap --zig=/opt/homebrew/bin/zig
python3 tools/build.py --native --skip-bootstrap --vt-backend=c --zig=/opt/homebrew/bin/zig
python3 tools/verify-ui.py --prefix=native
python3 tools/verify-ui.py --prefix=native-c
python3 tools/compare-vt-replay.py
python3 tools/compare-vt-n2.py
python3 tools/verify-vt-protocol.py
python3 tools/build.py --skip-bootstrap --zig=/opt/homebrew/bin/zig
python3 tools/audit-elf.py zig-out/linux --output .cache/verification/n3-linux-abi.json
python3 tools/verify-native-migration.py --performance .cache/verification/n3-performance-final/report.json --review .cache/verification/n3-performance-review.json --c-archive dist/letty-c-baseline-5c9da7d514a5.tar.gz
```

Performance acceptance binds measured binaries/raw logs; changing a default alone was not called a new measurement. Future CI may reference matching code-hash acceptance but must run its own Linux checks/ABI, never another source's receipt.

## 14. N4 stability and target boundary

The initial candidate completed 256 real-PTY rounds/~62 s, each 4000 lines with concurrent input/ACK then search/copy/resize/focus/close. All 257 children reaped; post-warm RSS quartile medians 46,624→46,896 KiB, range 46,608–50,160, FDs 8–10. Twenty hidden startup/exit runs (ten save/restart pairs) checked v3 layouts/PTy reaping. Post-switch reruns retained their own latest native-stability/startup.json and earlier logs.

These minute-scale local checks are not prolonged target Linux/SSH X11/IME acceptance. Bash/TUI/clipboard/IME/steady memory/echo latency remain pending. Verified C source/runtime recovery permits retiring dual maintenance without losing the executable fallback or relabeling macOS as target success.

## 15. N4 active C retirement (2026-10-20)

Login/CWD-corrected 9b2f19589436 repeated 256 lifecycle rounds/257 reaped children, twenty layouts/startups, twenty real macOS login/foreground/spaced-CWD/reaping checks. Earlier b9b33b07 evidence retained its identity.

Final `dist/letty-vt-c-recovery-9b2f19589436.tar.gz` contains all authored source/tools/fixtures/golden, macOS/Linux C programs/shell resources/raw comparison/failure logs. Whole archive and 757 regular members verified. Fresh spaced-directory offline restore from locked archives plus seven dependency source trees, without caches, actually rebuilt/passed C 26 unit/46 core/161 UI/nine replay/24 N2/56 protocol. Inventory/code hash matched. Report: `.cache/verification/n4-c-recovery-restore.json`; [recovery guide](c-vt-recovery.md).

Twenty-one old VT-C/header/specialized-tool files were then removed. Platform C/upstream dependencies remain. Root imports official Zig directly, without backend selection. Shared assertions compare eleven/21/56 native golden records, 596 splits, and five historical C size exceptions. Independent graphics remained component-only at retirement; later M9 integrated the GUI.

Final cleanup source: `76d6fabb5620496ad4ab30e483d4b64c9fe2901bacd26c205d9e55d76b68f700`. Actual results: 26 unit/46 core/174 UI/21 boundary/nine replay/24 N2/56 protocol, fixed golden/596 splits, eight Linux ELF ≤2.17, graphics 26 and geometry/budget two each plus cross/ABI. Lifecycle 256/~69.4 s/257 reaped; RSS quartile medians 46784→46944 KiB, FDs 3–9 including exit; twenty layouts/twenty logins fully reaped.

Eighteen before/after-native runs independently reviewed the one +10 ms system-CPU warning. native-release-gate.json passed with strict source/binary/log/golden/recovery binding. docs/native-release-acceptance.json is a versioned historical receipt for future CI to compare alongside its own checks; hosted CI was not run.

Run produces explicitly local-preview packages after current local checks; distribution still enforces the full native release gate. Packagers collect dependency licenses from actual root zig-pkg; nine notices matched bytes, without relying on old C/vendor caches. No active C VT does not mean no C in the project.
