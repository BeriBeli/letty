# M9–M11 historical handoff

Date: 2026-10-20 (Asia/Singapore). The user requested a new chat because the original development context was long. This handoff is grounded in repository/evidence rather than requiring the full history.

Original chat: Terminal development plan, local / `01a152ef-21d6-7151-84c1-89aee2aebb57`. Receiving chat: M9–M11 integration, local / `01a15755-4f50-74e2-a62d-441733ffb585`, in the same checkout. Chat IDs retain the historical identities.

## Baseline at handoff

- nanoui/Zig 0.17.0/native ghostty-vt, pinned in deps.lock.json. Active C VT removed; platform PTY/GTK/X11 C retained. Independent C recovery remains; do not restore active dual backends.
- M0–M7 delivered locally; M8 frozen development gate/package completed. See [M8](m8-release.md), [validation](validation.md), and m8-native-release-acceptance.json.
- M8 source: `534a13035e129811af659cda9e08696f78c7c71aafce54fb4ef1e6f882e63fbc`. Recorded checks: 110 model/46 core/526 native UI/522 portable UI, 288 CPU pixels, thirteen graphics Context, fifteen configuration CLI, six appearance, seventeen file-save, 256 lifecycle rounds/257 reaped children, twenty layout restores/twenty real-login checks.
- Eighteen performance runs reviewed; maximum search slice 6.253 ms. Historical 29.314 ms sample and small absolute CPU warnings retained in [performance](performance-m8-2026-10-20.md). Tree construction is not Metal/X11 latency.
- Fifteen nanoui patches/46 replay-identical files; nine Linux ELF files maximum GLIBC_2.17. Target Linux/display/IME/native services remain pending.
- Retained packages: `dist/Letty-macos-arm64-native-zig-534a13035e12.zip`, `dist/letty-linux-x86_64-el7-zig-c122324ef1e0.tar.gz`, matching source/digests. Keep rollback identity; do not relabel them as new-feature delivery.

## Receiving scope

Read M9–M11 in the [follow-up plan](ghostty-nanoui-next-plan.md), M8, configuration, and architecture; identify implemented versus unaccepted behavior, then complete M9→M10→M11. Reuse existing integration rather than rewriting modules or treating old counts as new evidence.

- M9: actual protocol→Context→CPU/Metal, budgets/screens/scroll/resize/layers/generations/delete/release in vt_native_graphics*, terminal_graphics_*, nanoui_graphics_resources. Default off; matrix for complex transfer/animation.
- M10: theme_browser/application_theme_browser, Inspector, application_drop/drop_paths, application_osc52. Verify cancel/ACL/xattr/concurrency/window/stale-target semantics. OSC 52 default write deny/read unsupported; synchronous callbacks must not block.
- M11: application_hotkeys/global_hotkey/quick_terminal/accessibility adapters, conflicts/transaction reload/unregister/hidden PID retention/semantic focus/actions/IME. Owned NSView/adapter checks are distinct from actual system acceptance.
- Each batch needs feature evidence, complete/partial/pending scope, and reviewable artifacts. M12–M19 remain a roadmap, not automatic daemon/plugin/AI work.

## Original collaboration/build contract

The receiving chat retained the existing uncommitted checkout, without reset/clean. Its original user authorization allowed up to three bounded subtasks; main integration owned shared build/Session/app/config/vendor/release. This is a historical allocation, not a request to start agents during documentation maintenance.

Read other active work before shared edits. Serialize full rebuilds/freezes; source-guard changes require fresh evidence, never altered hashes. Follow vendor/nanoui/AGENTS.md, reproducible patches, and line limits. Tests use private files/clipboard/hidden windows without user hotkeys/permissions.

Keep baseline Linux 3.10/glibc 2.17, Maple/Paper, XDG/--config rules, sixteen PTYs, and no modern GTK/GPU requirement or dependency upgrades. Verify `/opt/homebrew/bin/zig` is 0.17.0, inspect current --help, and reuse build.py/verify-ui.py/verify-native-release.py/feature verifiers/packagers. Source/binary/log/performance/gate identities must match. Update plans/validation/configuration/capability matrices/metadata per batch.
