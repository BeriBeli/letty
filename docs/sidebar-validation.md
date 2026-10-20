# Workspace sidebar validation

Date: 2026-10-20 (Asia/Singapore). Frozen `8e6a2f5691b5` passed 81 native feature assertions (62 navigation/interaction, nineteen real Session-provider); see [release](m9-m11-release.md). M8 counts/performance are not reused.

Scope: [sidebar plan](sidebar-navigation-plan.md). It reuses existing tabs/split trees/PTYs. QA uses isolated Hosts/private Tester input/clipboard/owned children, never the real desktop/hotkeys/system clipboard.

## Entry points and assertions

Main: `src/sidebar_ui_check.zig.run(s)` → `src/sidebar_geometry_ui_check.zig.run(w,t)`. Existing navigation_ui_check retains original M2 search/scroll scenarios.

`src/sidebar_provider_ui_check.zig.run(s)` passed nineteen frozen-native assertions using owned `/tmp/letty-sidebar-provider-*` empty directories, Git enabled/ports disabled, real Session/OSC 7/OSC 133/workers/fd events. It checks non-repository state, no draw scans, CWD coalescing/stale generations, disabled-owner release, close without late notifications, surrounding PID retention, held natural exit, and production renderFailed cleanup. Real repository/port correctness uses separate provider fixtures.

| Scope | Actual assertion | Recorded result |
|---|---|---|
| Two-window mode | Real config_transaction prepare/commit top→sidebar→top; compare every PID/Session ID/Layout/Tab ID/pane/ratio | Native passed |
| Search/selection/async | Distinct real VT match counts; query/total/current/lt_vt_has_selection/private paste ID | Native passed |
| IME/navigation-only | set_marked on real search input; preserve focused/marked state | Native passed |
| Content geometry | Actual navigation_rects/drop_panes/postframe AX, containment/nonoverlap | Native passed |
| First-column selection | Render FIRST_COLUMN_SAMPLE, drag real Tester cells, ordinary Copy must equal FIR | Native passed |
| Drop boundary | Real cell rectangles to private destination, production Bridge.receive(.probe); terminal accepts/sidebar rejects | Native passed; not OS drag/drop |
| Sidebar focus/input | Row click/text/marked/unmark/Escape; exactly one focused AX tab, no terminal claim | Native passed |
| No PTY leakage | Owned raw PTY `od -N5` gets only final Tab+CJK+Z after sidebar/modal/IME work, byte comparison | Native passed |
| Reorder/cancel | Real pointer drag, stable/active identity; out-of-bounds/mode switch/Escape rejects stale coordinates | Native passed |
| Width/collapse/compact | Resize changes real VT cols; Escape restores; AX Press uses action; narrow clamp preserves saved metadata | Native passed |
| Pin/close AX | Queue semantic stable Tab IDs, change active tab, verify captured targets/confirmation cancel | Native passed |
| Rename/CJK/menu | Double-click existing rename, marked/Tab/select-all/insert/Enter, captured context menu | Native passed |
| All-split metadata | Feed nonfocused pane BEL/OSC 9, Session.refresh; aggregate two panes/bell/37%; selecting acknowledges tab | Native passed |
| Overflow/budgets | New to eight tabs; ninth allocates no PTY; Home/End reveals active row; cross-group drag preserves pin | Native passed |
| Persistence | Actual Document→JSON encode/decode preserves width/collapse/pin/full Layout | Native passed; not app restart |

## Audit fixes

Navigation-only transactions retain owner/search/selection/IME and cancel temporary drag/resize rather than activating a tab to switch styles. Only the selected navigation-focused row declares AX focus; terminal does not, preventing multiple-focus rejection. Labels/CWD values truncate at UTF-8 boundaries while snapshots/tooltips keep complete owned text.

Compact/Collapse uses sidebar_toggle→toggle_sidebar. Pin/Close uses tab_pin/tab_close stable IDs resolved at execution; icon semantics belong to the actual tab. Explicit AX terminal focus releases sidebar focus and ends search through the existing action when necessary.

## Frozen results and limits

- Source: `8e6a2f5691b5b59a0a87afe735b986d0db0050b79ce1f762cd1678b95ff4e107`; all batches share the frozen integrated binary.
- Native/portable feature suites each 81; full UI 675/671; nine Linux ELF cross-build/static audits passed, governed by the source-bound release gate.
- Inspected hidden-window [light](images/sidebar/sidebar-light.png)/[dark](images/sidebar/sidebar-dark.png) screenshots include long CJK names, pinned sections, search, and terminal offsets.
- Provider 26 and real-login PTY nine component checks cover temp repositories, known descendant listeners, identity reuse, timeout, cancellation. Unreadable set-id login root FDs yield partial verified-descendant results, never a complete-scan claim.
- Idle collection creates no jobs across 32 frames. Sidebar drag end-to-end latency/PSS was not independently measured; generic performance covers only its listed Tester workloads.
- Real multiple monitors/VoiceOver/GTK3/X11/target Linux/IME/native drag/drop/restart acceptance remains pending.
