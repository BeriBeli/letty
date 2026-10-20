# Ghostty feature gap plan: M0–M5

Date: 2026-10-19 (Asia/Singapore). Historical execution chat: local `01a152ef-21d6-7151-84c1-89aee2aebb57`. M0–M5 completed local implementation/regression: 23 unit, 46 core, 124 offscreen UI checks; Linux/Windows framework cross-builds passed. Target Linux/display/IME remains pending. The original C prompt-preserving clear limitation was later addressed by native migration; see [configuration](configuration.md) and [migration](native-zig-vt-adaptation-plan.md).

## Purpose and baseline

Close daily-use Ghostty gaps while keeping nanoui UI and libghostty-vt state; do not substitute Ghostty's own SwiftUI/AppKit/GTK/libadwaita frontend. The original audit read app/layout/terminal_view/session/keybindings/command_catalogue, former vt_bridge, configuration/validation, fixed upstream source/public headers. Online documentation defines semantics rather than proving every pinned C API capability.

Keep deps.lock.json: Zig 0.17.0, nanoui e4d53be8, Ghostty 5064b326, `x86_64-linux.3.10-gnu.2.17`, baseline CPU, configurable Maple/Paper, existing XDG/--config precedence. Current native architecture supersedes the historical C interface implementation details in this plan.

Existing foundations were local shells/independent PTYs/bounded TX/VT/CJK/combining, eight tabs/sixteen PTYs, right/down splits/divider dragging, selection/clipboard/bracketed paste/wheel, incremental search, configuration/reload, and topology restoration into new processes. The palette was already being completed, not a separate new engine.

## Original gap matrix

| Gap | Layer/batch | Recorded result |
|---|---|---|
| Shared parameterized palette/menu/bindings and availability | UI/actions, P0 M0 | Local complete |
| Four-way splits/directional-previous focus/zoom/equalize/resize | UI/layout, P0 M1 | Local complete |
| Stable tab titles/reorder/focus memory/overflow | UI/layout, P0 M1 | Local complete |
| All visible search hits/current index/reverse shortcuts | UI/VT, P0 M2 | Local complete |
| Scrollbar/page/top/bottom/history position | UI/VT, P0 M2 | Local complete |
| Select-all/clear/reset distinct semantics | VT/UI, P0 M2 | Old C prompt-clear detail partial; other behavior complete |
| Terminal/tab context menus | UI/input, P0 M3 | Local complete |
| Open Configuration/expanded error location | UI/platform, P0 M3 | Local complete |
| Cancellable pane/tab/window/quit | UI/platform/process, P0 M3 | Local complete |
| PRIMARY/copy-on-select/middle-paste | Platform/UI, P1 M4 | Local complete |
| Multiline/control paste preview | UI/transaction, P1 M4 | Local complete |
| Visible HTTP(S)/true OSC 8 targets | VT/UI/platform, P1 M4 | Local complete |
| CWD inheritance/prompt navigation | VT/shell, P1 M5 | Local complete |
| BEL/completion/progress | VT/UI, P1 M5 | Local complete |
| Mode-1004 focus | Platform/VT, P1 M5 | Local complete |
| Multiple windows; shaping/images; sequences/hotkeys/Quick Terminal; OSC 52/themes/Inspector/accessibility | Original P2 | Promoted to [M6–M11](ghostty-nanoui-next-plan.md), later locally delivered |

Every local result still requires applicable target acceptance; [validation](validation.md) records actual execution.

## Invariants

1. nanoui owns controls/overlays/search/menus/tabs/scrollbars; OS supplies windows/IME/clipboard/openers.
2. VT is the sole parser/history owner. No second ANSI/OSC parser, full-history mirror, or per-frame history URL/highlight scan.
3. Historical work used verified pinned public APIs (scrollbar/search/PWD/BEL/progress/semantic/focus). Check missing API signatures rather than inventing capabilities/upgrading dependencies. Native migration now has its own facade.
4. Stable IDs route keys/callbacks, never reusable slots/indexes/first panes.
5. Shared focus/modal routing isolates text/confirm/Escape/right-click from PTYs; focus changes clear drag/preedit.
6. No idle Linux polling; hidden tabs parse without continuous drawing; state changes trigger redraw.
7. Vendor changes follow nanoui AGENTS.md, ≤600 lines/changed file, managed idempotent patches, without unrelated rewrites.
8. Distinguish Ghostty-compatible names from Letty extensions; invalid config rejects while preserving config/PTys.

## M0: shared typed actions and palette

Local result: fifteen unit/sixteen core plus UI passed on 2026-10-19; parameters match menu queues/palette/bindings, availability and IME isolation checked.

Define owning typed requests with common title/keywords/parameters/availability/binding hints. Every entry uses one dispatcher and preserves existing binding names/override rules. Palette must carry arguments rather than just enums. Show consistent unavailable reasons for empty selection/single-pane zoom/budgets. Keep Cmd+Shift+P/Ctrl+Shift+P, typing/arrows/Enter/Escape/outside/mouse/wheel/focus restoration with IME priority. Suggested modules: actions and command_catalogue, leaving app orchestration narrow.

Acceptance includes custom/clear/unbind/menu-hint parity, cross-entry arguments, no filter-text PTY delivery, and narrow-window fit.

## M1: usable tabs and splits

Local result: nineteen unit/sixteen core plus UI, layout_ui_check and `.cache/test-logs/layout-nested-dark.png` / layout-overflow-paper.png. v1→v2 migration stores stable tab IDs/titles/focus. M3 later added context rename; menu/palette/double-click already worked.

Add directional/previous/next focus, zoom, equalize, pixel resize, left/up creation. Choose actual-rectangle neighbors by overlapping edges/distance; no neighbor never jumps tabs. Zoom retains tree/ratios/PTys; close/tab/new-split exits predictably. Equalization uses leaf counts/minimum grids rather than blindly setting every ratio to 0.5. Tabs own IDs/title override/focus, move_tab/drag/rename, and reachable overflow. Validate migrations before spawning and never persist process handles.

Acceptance: asymmetric four-pane navigation; exact zoom restoration; rename/reorder/first-pane close preserve IDs/PIDs; old layouts; atomic capacity refusal.

## M2: search, scrolling, selection, clear/reset

Local result: nineteen unit/31 core plus UI, navigation_check/navigation_ui_check and search-matches-paper.png. Search has independent current/visible matches, reverse navigation, scrollbar, select-all/reset. Historical C API lacked eraseActive/prompt-preserving primitives: main-screen CSI clear removed content/history, retained modes, rejected alternate screen; it was not identical to Ghostty prompt redraw.

Expose current index/viewport hits and draw normal/current highlights without rewriting selection. Show counts/no-results/progress; Enter/Shift+Enter/Escape and bounded incremental updates. Literal search only. VT scrollbar metadata drives drag/page/top/bottom and hides main history in alternate screen. Distinguish clear/history/reset without typing shell commands. New output preserves a scrolled viewport; edge selection uses bounded autoscroll.

Acceptance: CJK/combining/soft-wrap geometry, independent selection, normal post-search input, pruning/resize bounds, 100000-line incremental behavior without history copies. Original C bridge suggestions are historical; active implementation is native.

## M3: menus, configuration, and close lifecycle

Local result: twenty unit/31 core plus UI, real hidden rightMouseDown/windowShouldClose, sleep cancel/approval, config races/line errors. Evidence: lifecycle_ui_check, close-confirmation-paper.png, config-diagnostics-paper.png. Framework Linux arm64/Windows x64 examples/tests cross-built with harness compatibility objects; target execution pending. Patches replayed, 106 files met 600 lines. M5 later added trusted-idle detection.

Shared terminal/tab menus reuse actions; normal TUI right-click is encoded, Shift+right opens Letty. Clamp menus and isolate dismissal. Open Configuration/diagnostics show actual paths/line/key/cause; missing-file creation is explicit/O_EXCL, never overwrite. Openers use argv and offer copyable fallback.

Pane/tab/window/quit transactions list stable affected sessions, allow cancellation without kill/persistence/destruction, and veto before OS teardown (not merely notify afterward). Unknown foreground status confirms; M5 permits trusted local idle prompts. true/false/always semantics stay explicit.

Acceptance covers every close entry, preserved sleep/vim on cancel, exact approved batches, natural exit during dialogs, invalid config retaining PID, and TUI mouse behavior.

## M4: clipboard and links

Local checks cover independent PRIMARY/CLIPBOARD, async stable targets, preview cancel/approve, IME, soft-wrap HTTP(S), and true public OSC 8 URI. Private clipboard/opener adapters leave system state intact. Screenshots: paste-confirmation-paper.png/link-hover-paper.png. Real GTK/X11 remains pending.

All paste paths share capacity/CRLF/bracketed preprocessing and stable Session transactions. IME commit is separate; cancel sends no bytes and exited targets discard. Visible URL/OSC 8 hits support modifier hover/preview/click/context-copy. HTTP(S)-only opener uses separate argv, rejects controls/unknown schemes, runs on the GUI host, and exposes failure/copy/retry rather than assuming another machine's browser.

Acceptance: no selection-channel crossover, no target retargeting, no bytes after cancel, correct CJK/soft-wrap boundaries, intact ordinary selection/TUI mouse.

## M5: CWD, shell semantics, feedback, and focus

Real zsh tested spaced directories/inheritance/explicit priority/hooks/background failure/disabled integration/close policy. Bash/zsh PTY fixtures checked exit/traps/ZDOTDIR. Pane/modal/window focus and mode gating passed. Linux Bash 4.2 auto-launch/native GTK focus/IME remain pending; macOS Bash 3.2 auto-injection is disabled. Use tab markers rather than a mandatory notification daemon.

Copy PWD/BEL/semantic/progress effects promptly, without parser reentry. Inherit trusted local CWD only; remote OSC 7 cannot chdir locally. Minimal bash/zsh scripts affect new local shells without editing startup files/remote SSH settings or replacing traps/hooks. VT prompt metadata drives jump_to_prompt with explicit unavailability otherwise. BEL/completion/failure/progress changes set restrained background markers without idle animation/libnotify requirements. OS/pane focus sends deduplicated 1004 reports only when enabled.

Acceptance: CWD precedence/authority, prompt pruning/resize, trusted versus unknown close state, completion feedback without repeated notifications, correct mode-on/off bytes and target ordering. See [performance](performance-native-2026-10-19.md) for measured scope.

## Delivery requirements and references

Implement/check/update each batch before advancing; continue independent work when target access is unavailable, leaving target checks pending. Use meaningful state/identity/lifecycle tests and real Tester interactions with temporary files/private clipboard/hidden windows. Run native unit/core/UI and inspect light/dark/narrow/nested/CJK screenshots; serialize full builds, keep Linux target/ELF audits and required vendor cross-builds, no local amd64 container. Run actual GTK/Xvfb only where available, and label hosted CI passed only after execution.

Maintain [Linux manual checks](linux-testing.md), performance/environment/raw data, README/configuration/architecture/validation/plans, and versioned macOS ZIP/Linux tar.gz/checksums/build-info with rollback. Never report unmeasured memory/latency savings. Local completion, API-blocked items, and target execution remain distinct.

Later P2 work is in [M6–M19](ghostty-nanoui-next-plan.md): application/window ownership, advanced rendering, sequences/includes/themes/Inspector, system hotkeys/Quick/accessibility/drops, and carefully scoped synchronous OSC 52 policies.

Primary source references: pinned Ghostty input/Binding.zig and public vt terminal/search/focus/formatter headers; nanoui README/AGENTS. Semantic references: [actions](https://ghostty.org/docs/config/keybind/reference), [configuration](https://ghostty.org/docs/config/reference), [shell integration](https://ghostty.org/docs/features/shell-integration). These are retained historical references, not a new upstream compatibility audit.
