# Follow-up roadmap: M6–M19

Created 2026-10-19; updated 2026-10-20 (Asia/Singapore). Historical main integration chat: local `01a15755-4f50-74e2-a62d-441733ffb585`; [handoff](handoff-m9-m11.md). The earlier chat remains historical after M8.

M6–M8 and M9–M11/Settings/Sidebar S1–S3 passed their local development gates. See [M8](m8-release.md) and [integration release](m9-m11-release.md). Target Linux, native display/IME, and system-service acceptance remain pending. Counts below belong to their own frozen sources, not every later tree.

## Baseline and scope

The original continuation authorized post-M5 work. M0–M5 had 23 unit/46 core/124 UI checks; that record was read, not rerun during planning. Sequence: multiple windows → advanced configuration → text/rendering → Kitty images → desktop interaction → hotkeys/Quick/accessibility. Recheck interfaces after each batch rather than copying old line references.

Keep nanoui/native Ghostty VT, Zig 0.17.0, pinned dependencies, baseline Linux 3.10/glibc 2.17, Maple/Paper/configuration rules, close/async clipboard/OSC 8/shell/focus regressions. Advanced capabilities are opt-in; CPU/X11 remains usable without modern GTK/libadwaita/OpenGL/Vulkan requirements. macOS implementation does not certify Linux.

Separately authorized early features: [Settings](settings-window-plan.md) in local chat `01a15758-3db3-7d51-82a0-45ca95afa678`; [sidebar/top switching](sidebar-navigation-plan.md), ahead of M13; and [file/Markdown previews](file-markdown-preview-plan.md), ahead of M17's broader rich-content/indexing work. Main integration owned shared configuration/geometry/app/build; isolated modules used agreed interfaces. These historical allocations do not request new agent work.

[Native migration](native-zig-vt-adaptation-plan.md) N0–N4 validated the same pinned commit's Zig API and retired active C VT. Earlier public-C-API constraints were historical implementation choices. The original plan's unrelated “M6 Tern-inspired capabilities” is now M15–M19 below.

## Delivered milestones and required behavior

### M6: windows and application ownership

Recorded local checks: 24 unit/46 core/142 UI; Linux app/framework Linux-Windows cross-builds, with actual GUI pending. Evidence: multiwindow_ui_check/workspace_layout/[validation](validation.md).

AppState owns registry/global IDs/shared config/Quit; WindowState owns layout/views/search/overlays/focus. Defer release for callbacks, route by stable Window/Session IDs, never overlapping slot counters. New Window defaults Cmd+N / Ctrl+Shift+N; Linux next pane moved to Ctrl+Shift+]. Menu actions resolve current windows, including New Window with none open.

Close Window affects one; Quit aggregates once/cancels all; final-window behavior remains explicit. Reload validates all profile mappings before atomic publication, preserves PTYs, and defines per-window zoom. Multiwindow layouts migrate v1/v2, retain titles/focus, and lock or separate multi-instance writes. Limits: eight windows, eight tabs/window, sixteen PTYs/application, with pre-spawn checks/rollback.

Acceptance: two multi-pane windows, correct menu/title/focus/paste/link/close targets, A close preserving B, late response safety, reload atomicity/PIDs, migration/new-process restoration, no irrelevant background redraw.

### M7: sequences, byte actions, and composed configuration

Frozen f7f9ccef94e9 passed 76 unit/46 core/246 UI, fifteen CLI/six AppKit appearance checks; 72 new application assertions. Eight Linux ELF static ABI ≤2.17; 256 lifecycle rounds/257 reaped children/twenty layouts/twenty logins passed. Linux UI 238 was an unexecuted branch expectation. GTK appearance/target IME remain pending.

Per-window chord state supports modified first/unmodified later keys, ambiguity/complete-prefix timeout/mismatch rules, Escape/focus/modal/reload/IME cancellation, one-shot timers without idle polling. Consumed prefixes never reach PTYs; unmatched final keys deliver once without replay. text/csi/esc parameters own bounded length-delimited bytes/escapes and use Session queues. performable/unconsumed/all require actual semantics; global belongs to M11.

config-file provides relative/optional/ordered bounded includes, canonical-cycle detection/source chains, all-or-none load. Cached light/dark themes follow system events with explicit color/feature precedence and no repeated reads. CLI shows actual sources/capabilities; never touches Ghostty configuration.

Acceptance: sequence/IME/TUI/window boundaries, Unicode/backslash/ESC/NUL, rejected bad escapes, all-target atomic enqueue, include/theme failures retaining config/PIDs, queued payloads surviving arena release. M8 later integrated conditional font features.

### M8: text correctness, fonts, and CPU damage

Frozen 534a13035e12 passed 110 model/46 core/526 native UI/522 portable UI, 288 CPU pixel comparisons, eighteen performance runs, 256 lifecycle rounds, nine ELF ABI checks, fifteen patch replays. [Release scope](m8-release.md) and [retained warnings](performance-m8-2026-10-20.md) remain authoritative; target presentation is pending.

Required fixtures cover mixed scripts/accents/punctuation/Nerd Font/ZWJ/variation selectors/styles/box drawing/ligatures/DPI, recording actual fallback/missing glyphs. Fixed SGR data drives underline styles/colors/inverse/faint/conceal without silent support claims. Visible run shaping maps clusters to VT cells, retaining grapheme width/order and selection/search/link/cursor/IME geometry without arbitrary paragraph reordering.

Bound font-feature/fallback settings; CoreText on macOS, pinned licensed statically linked HarfBuzz for portable with old ABI. Ligature toggles/boundaries retain positioning; unsupported color/emoji behavior is explicit. CPU damage/caching must cover resize/selection/search/cursor/scroll/overlay/transparency/expose and match full pixels before keeping optimization. Measure raster and app 1/4/16-pane output/scroll/search/static workloads separately from end-to-end presentation.

### M9: bounded Kitty static images

Local gate passed, native 45 feature checks; see [capabilities](m9-capabilities.md) and [release](m9-m11-release.md).

VT alone parses APC. Deliver direct RGB/RGBA/PNG static transfer/basic placements/delete/query; matrix separately lists file/shared-memory/animation/placeholders/virtual/complex extensions. Bounded ID+revision image resources update/evict rather than leak atlas copies. Explicit byte/dimension/count/storage/snapshot/renderer quotas, default off, visible refusal. Main/alternate/reset/hide/scroll/resize/clipping/layer/selection/cursor ordering follows actual upstream data. No borrowed pixels/handles survive feed/resize. PNG failures leave no partial fake image.

Acceptance: real protocol→Context→CPU/Metal pixels, reply/delete/screen/scroll/scale/overlay, multiple stores, corrupt/oversize/repeated updates/releases, Linux ABI. Ordinary UI images alone do not establish terminal-protocol support.

### M10: themes, Inspector, drops, and OSC 52

Local gate passed, 102 feature checks; see [capabilities](m10-capabilities.md).

Themes search packaged/user directories, preview only the captured window, Cancel restores cached theme/zoom, Apply scope is explicit, Save preserves comments/unknown content/metadata/concurrent-edit protection. No network download dependency.

Read-only Inspector exposes bounded identities/grid/modes/CWD/queues/history/fonts/render/events, text off by default and no idle timer when closed. Drops quote known shell paths without Enter/execution; unknown/locality failures offer raw preview/copy, never assume remote files exist.

OSC 52 writes copy bounded owned UTF-8 and defer policy/confirmation until after parsing. Synchronous reads cannot block GTK/reenter VT/use nested loops. Final implementation accepts read deny only; do not pretend async ask. Manual clipboard/PRIMARY stays independent, source identity visible and expired targets reject.

Acceptance: cancel/save/window ownership, private diagnostics, quote-only drops, OSC 52 encoding/budgets/cancel/policy/exit and real negative read tests.

### M11: global hotkeys, Quick Terminal, accessibility

Local gate passed, 63 feature checks; see [capabilities](m11-capabilities.md).

Use per-platform capability tables/test adapters. Explicit global chords register transactionally; conflict/permission/unsupported preserves configuration, no unsolicited bindings. Linux GTK3/X11 uses available dynamically loaded libraries; Wayland/no DISPLAY is unsupported without a required portal. Test backends do not register user hotkeys/request permissions.

Quick Terminal is a managed dedicated window with position/fractions/screen-change/toggle/autohide/hidden PID retention and normal limits; topmost/desktops follow real OS support. Native permission requests belong to explicit application actions.

nanoui semantics expose bounded roles/labels/state/actions/focus/hierarchy through macOS accessibility/Linux ATK: tabs/panels/search/dialogs/menus/scrollbars initially, plus visible terminal text/selection/caret. No expensive node-per-cell or history-wide claim. Stable queued actions/IME/focus/lifetime checks are required.

Acceptance: conflict/reload/unregister/stale-target adapters, hidden Quick/two-window geometry/PIDs, actual semantic-tree/action tests; real VoiceOver/Orca/X11/permissions/desktops/hotplug require separate platform execution.

## Future roadmap

These milestones remain planned unless a separate feature record says otherwise.

| Milestone | Purpose | Priority/dependencies |
|---|---|---|
| M12 | Target Linux acceptance, performance, maintainable releases | P0; native candidate and deliverable M7–M11 |
| M13 | Workspace templates/switching/cross-window organization | P1; stable IDs/layout/config/M12 |
| M14 | Shell/TUI/SSH daily compatibility/profiles | P1; shell semantics/M12 |
| M15 | Background session service/detach/reattach | Optional P2; demonstrated need beyond tmux/M12 |
| M16 | Multiple views and controlled local IPC | Optional P2; M15/Session-View separation |
| M17 | Command index/output retrieval/rich views | Optional P2; shell metadata/bounded resources; cross-process depends M15/M16 |
| M18 | Restricted extensions/automation API | Optional P3; versioned permissions/interfaces |
| M19 | Optional AI workflows | Optional P3; structured context/controlled actions/explicit need |

### M12: target acceptance and release loop

Reuse migration evidence and fill missing runtime/release gaps. Test one unchanged native candidate on baseline Linux with local or SSH X11: startup/PTys/resize/IME/CLIPBOARD/PRIMARY/focus/hotkeys/Quick/accessibility. Attribute failures to backend/syscall/display path.

Compare Konsole with equal fonts/pixels/history/workloads for PSS/RSS/CPU/echo/scroll/X11, 1/4/16 PTYs, output/search/images on-off/releases, repeated variability and additional processes. Publish actual capabilities/limits/font-terminfo/diagnostics; versioned install/upgrade/rollback preserves config. Source/licenses/checksums/build-info match.

Run hosted clean locked-toolchain/dependency/patch/native/Linux-ABI/GTK-Xvfb CI when a remote is available. Local evidence is not renamed CI. Acceptance links same-package digests to target steps, fixes/reruns performance issues, and reproduces upgrade/rollback. N4 cleanup remains bound to its own gate.

### M13: templates and session organization

Named layouts reference profile/CWD/title/ratio and create new processes, distinct from future attach. A bounded searchable switcher exposes trusted names/CWD/task/recent state without history scans. Move complete tab trees across windows preserving Session/PID/VT/async ownership with atomic limit failure. Exit/reopen/undo must disclose whether it starts new processes or delays termination.

Acceptance: template round trips/migration/invalid-atomicity, ongoing output/paste/focus/close during moves, keyboard-accessible switcher.

### M14: shell/TUI/SSH compatibility

Expand real Bash 4.2/zsh/vi-vim/tmux/TUI key/mouse/focus/paste/Unicode/resize/prompt fixtures and turn target failures into regressions. Connection profiles retain system OpenSSH/config/agent/known_hosts, explicit reconnect without replaying input, and clear launch/exit diagnostics. Explain TERM/terminfo remediation; remote writes/installations require explicit application actions. Preserve CWD authority. Add fish/other integration only for actual need while preserving hooks/startup/status.

Acceptance: local/remote target scenarios, no credential logs/plaintext profiles/PTY leaks, disabled integration works, user shell behavior retained.

### M15: optional background service

Record benefit/cost relative to tmux first. One local service owns Session/PTY/unique VT/history while GUI owns Views; keep lightweight in-process mode. Detach removes a View; explicit termination ends processes. Differentiate GUI close/service exit/SSH loss/reboot; never promise process survival across reboot.

Current-user IPC has versions/bounded messages/backpressure/consistent snapshot+ordered deltas; slow clients cannot grow memory or block all sessions. Define socket/lock cleanup/crash/orphans/version mismatch and query/attach/detach/stop entry points. Acceptance preserves actual PIDs/modes/cursor/output and accounts for service PSS/images/history, disconnect/slow/crash/restart/permissions; restarting commands is not attach.

### M16: optional multiple views and local control

One explicit input owner/read-only observers/permission transfer; broadcast opt-in with targets shown. Viewport/selection/search/cache is per-view while one arbiter sets PTY size and Session retains one history. A restricted local request-ID/version/error/cancel/query API distinguishes read from input/termination and is never an unauthenticated network service. Machine-readable output/capability negotiation/version tests are required.

Acceptance: independent views, deterministic size/input ownership, ordered reconnect, isolated slow views, authorization boundaries, measured IPC/cache costs.

### M17: optional command navigation/rich views

Bounded shell-semantic command index supports command/exit search/jump/copy/export, pruning with history without duplicating body text. Optional fold/table/image views preserve raw VT and ordinary fallback when metadata is absent. Resource budgets and teardown are explicit; output cannot execute host actions. Any Tern/TSP-like protocol needs a fixed spec, negotiation/flow-control/degradation/tmux-SSH matrix rather than visual similarity claims.

Acceptance: long/failing/interrupted/no-integration/resize/pruning boundaries, faithful export, unaffected PTY modes, accurate protocol matrix. The separately delivered file preview does not imply the rest of M17.

### M18: optional extensions/automation

Versioned discoverable action interfaces support palette items/events/workspaces without upstream internals. Explicit file/process/network/text/input permissions, no arbitrary-directory loading, bounded time/memory/messages, isolation/disable. Track source/version/digest/update/rollback/uninstall; distinguish configuration from executable extensions while retaining Linux baseline.

Acceptance: runaway/crash isolation, revoke/uninstall cleanup, clear mismatch errors, fully functional no-extension GUI without extra idle polling.

### M19: optional AI assistance

Start only after explicit product/context/service decisions. Explain selected output/summarize failed commands/draft reviewable commands using authorized inspectable context. Define models/services/secure credentials/cancel/timeout/cost/disable while preserving offline terminal use. Suggestions enter editable preview and execute only through controlled actions with clear source/Session; neither model nor remote output grants itself control.

Acceptance: no unauthorized text transfer, cancelled requests stop, no credentials in logs, suggestions editable/rejectable, disabled/unavailable service leaves core terminal working. No premature vendor/model/protocol/free-tier commitments.

## Shared delivery rules

Implement → targeted checks → prior regressions → updated evidence per batch, with one full compilation at a time. Test actual ownership/queued callbacks/config arenas/clipboard/focus/images/releases using private tempfiles/clipboard/hidden windows. Follow vendor AGENTS.md/≤600-line changed files/no nanoui C shim/cross-backend/event-driven requirements and pristine patch replay.

Lock/package/license/reproduce new dependencies/resources without unrequested upgrades or raising Linux ABI. Preserve versioned prior packages. Feature counts/backend/build-info come from actual current logs, never old hardcoded 23/46/124. Match source/binary/log/screenshot/gate hashes. Update README/configuration/architecture/validation/[Linux testing](linux-testing.md)/capability matrices/roadmap.

M6–M11 completion requires implemented feasible scope and evidence plus explicit platform/API limitations and testable packages; development success cannot replace target acceptance. M12 is required productization, M13/M14 follow daily feedback, and M15–M19 require independently justified needs and budgets.
