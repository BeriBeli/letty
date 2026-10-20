# Workspace sidebar and navigation-mode plan

Date: 2026-10-20 (Asia/Singapore). S1/S2/S3 local development implementation/acceptance completed: 81 native and 81 portable app assertions, 26 provider, nine real-login components. Target execution and sidebar end-to-end performance remain pending. See [validation](sidebar-validation.md) and [release](m9-m11-release.md).

Original main/Settings chats: local `01a15755-4f50-74e2-a62d-441733ffb585` / `01a15758-3db3-7d51-82a0-45ca95afa678`. This separately authorized feature proceeded before M13 without changing other milestones' acceptance status.

## Recorded cmux source reference

Pinned manaflow-ai/cmux commit `d7169d699bf58cb465aecaf8507db4bc7ca6193c`; Letty remains nanoui/Zig. Reference paths below are in that [fixed tree](https://github.com/manaflow-ai/cmux/tree/d7169d699bf58cb465aecaf8507db4bc7ca6193c).

| Source | Observed behavior | Letty adaptation |
|---|---|---|
| Sources/Sidebar/SidebarState.swift | Distinct visibility/user width/narrow collapse; bounded edge hits/stable selected ID | Per-window display state, clamping/collapse/restore/active-row visibility |
| Sources/Sidebar/SidebarLayoutModel.swift | Width updates avoid rebuilding terminal subtrees | Rectangles/necessary VT resize without Session/View/font/config recreation |
| Sources/SidebarWorkspaceSnapshotBuilder.swift and Factory | Title/pin/CWD/Git/ports/progress snapshots | Existing tab split tree is workspace; actual Session metadata, display separated from collection |
| SidebarRowSnapshotCache.swift and AppKitList/SidebarWorkspaceTableRowConfiguration.swift | ID/change-based cache, unread cleanup, content-versus-height updates | Bounded owned generation snapshots, change-driven redraw, no per-frame history/Git/process scans |
| AppKitList/SidebarWorkspaceTableActions.swift and MutationScheduler | Existing workspace actions; lightweight drag indications/coalescing | Shared actions/close transactions/stable IDs, persist once after drag |
| SidebarInlineRenameCoordinator.swift and SidebarReorderInteractionState.swift | Exactly-once decisions/IME priority/delayed autosort | Existing rename, isolated input, stable manual order |
| SidebarTabItemSettingsSnapshot.swift and Packages/macOS/CmuxSettings/Sources/CmuxSettings/Keys/SidebarCatalogSection.swift | Independent metadata visibility settings | Expose only implemented navigation/provider controls |
| Sources/PortScanner.swift and docs/shell-integration.md | Coalesced bounded background scans, explicit disable | Native Letty platform providers/trusted CWD; cancellation, no draw subprocesses |

This reference does not establish that cmux itself offers top/sidebar switching; that is the user's Letty requirement. Browser/cloud/AI/PR/cross-window tear-out features are outside this scope.

## Configuration/model contract

- `workspace-navigation = top | sidebar`, Config.workspace_navigation, default top. English Settings choices: Top tab bar / Left sidebar. Save/apply switches all windows and persists; diagnostics/source rules remain shared.
- `tab-bar = auto | always | never` affects top mode only. A one-workspace sidebar still has an entry. Settings explains/disables the top-only policy where appropriate.
- Reuse Layout.tabs[].id/split roots/active IDs/order/titles; no second workspace/PTY container or multiplied limits.
- Mode changes preserve PID/Session/Tab/focus/ratios/history/selection/search/matches/async ownership. Necessary resize is allowed. Navigation-only transactions never blindly clearSearch. Cancel stale drag coordinates during switching.
- Initial sidebar width 240 logical pixels, bounded by window space; drag/collapse/compact entry. Saved user width differs from temporary clamping. Versioned layout metadata stores width/collapse without per-pointer config writes; old layouts get defaults.
- `toggle_sidebar` toggles current sidebar collapse; unavailable in top mode, configurable without a new default binding. Collapse does not change configured mode.

## S1: shared geometry and working navigation

`src/navigation/geometry.zig` supplies navigation/content/compact rectangles to painting and every hit test. Replace fixed 29 px/x=0 assumptions and duplicate search heights. Search/notices/splitters/scrollbars/URL/drop/IME/Kitty/AX/neighbor-resize-equalize use final content/pane geometry. Sidebar drag must not also select terminal text or drag a split.

The vertical list includes active title/trusted CWD/split count/real bell-task-progress state and existing new/switch/rename/close/reorder/context actions. Stable IDs and close confirmation preserve targets. Overflow scroll/keyboard reveal, clear insertion marks, Escape/focus-loss/outside/target-close cancellation, and one end-of-drag commit retain active identity. S1 is complete only with actual Settings/app integration.

## S2: state and persistence

Pinned/unpinned sections preserve stable manual order and old layouts. Aggregate the full split tree; prefer active-pane CWD while exposing origins/other panes. Real VT unread/alert/progress data needs bounded text/counts and tested acknowledgement; BEL alone never invents notification text.

Handle UTF-8 truncation/tooltips/long names/narrow layouts/themes/keyboard/AX together. Pin/alert/progress are not color-only. Reuse rename rather than adding competing input machinery.

## S3: actual Git and ports

Independent providers supply local Git branch/dirty and Session-owned listeners, controlled by default-off toggles. Git handles worktree .git files/detached HEAD/nonrepository/failure/timeout with coalesced trusted-CWD/prompt/focus/refresh/file events and bounded background caching. No per-draw git or permanent watcher child per pane.

macOS/Linux port providers attribute by Session process tree/TTY, retain Linux 3.10/glibc 2.17, bound/throttle events, check PID birth/generation, reject stale results, and disclose unknown/permission/remote/partial states. Never attribute unrelated host ports. Disable/workspace destruction/exit cancels/releases. Remote metadata remains unsupported without trusted capability. Initial ports are display-only; any opener uses explicit existing URL policy, without browser/socket/PR/AI/cloud services.

## Original integration ownership

Main integration owned app/AppState/Session/config/transactions/actions/menu/build/layout/release and shared geometry. Settings owned its draft/form/preview/save controls under src/settings. Shared names/types were agreed before edits; one owner per interface. Separate original modules could proceed independently, while full builds/vendor/freezes stayed serialized. This records completed allocation, not a new request for agents.

## Acceptance

1. Real two-window top↔sidebar with tabs/splits/search/selection/output preserves all IDs/PIDs/focus/ratios/async targets. Cancel/no-op writes nothing; saved mode survives restart.
2. Stable create/rename/cancel-close/pin/reorder/overflow; stale provider/notifications reject. CJK/IME/bindings/right-click/outside/focus/narrow cases, without PTY leakage.
3. First-column selection/search/mouse/split/URL/drop/image/IME/AX geometry aligns in both modes. Record native CPU/Metal/portable/GTK separately.
4. Temp repositories/worktrees/owned listeners/permission/timeout/exit/PID-reuse fixtures; no invented unknown results, leaked tasks, or idle periodic shell queries.
5. Compare frozen baseline idle CPU/RSS/PSS/switch/drag/output/X11 costs honestly; Tester tree times do not replace end-to-end measurements. Deliver versioned source/package/screenshots/limits after appropriate feature/regression gates.

Record S1/S2/S3 implementation, executable checks, and target execution separately; none implies complete cmux parity.
