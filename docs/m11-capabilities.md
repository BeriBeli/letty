# M11 capabilities and acceptance boundaries

Date: 2026-10-20 (Asia/Singapore). The [integration release](m9-m11-release.md) binds source/packages/63 feature assertions/local gate. Historical M8 526/522 counts are not reused.

## Hotkeys and configuration transactions

| Capability | Implementation | Executable evidence | Pending platform acceptance |
|---|---|---|---|
| macOS globals | Dynamically loaded public Carbon RegisterEventHotKey, current-layout physical-key lookup | Injected registration/conflict/unregister/owned Request/reentry/stale-token tests | Real conflicts/layouts/press-release/background activation |
| GTK3/X11 globals | Dynamic Xlib, separate connection, roots on all screens, lock-modifier combinations, GLib fd | Shared manager/host queue; Linux build/ABI | Real X11/disconnect/WM conflicts/forwarded input |
| Wayland/no DISPLAY | Explicit unsupported, no required portal | Passive capability/build | No Wayland support claim |
| Atomic replacement | Prepare reserves added chords while old table remains; commitPrepared publishes without registration; rollback removes additions | Prepared-token silence, old action stability, save rollback, stale/pending/disable tests | Actual OS unregister failure frequency |
| Event targets | Callback copies Request/stable Window/Session/Tab IDs; UI loop revalidates | Real Host/Window switching/tab/session/closed-target checks | Desktop timing |

No `global:` default means no hotkey backend at startup. Explicit bindings request chords; `global-hotkeys = false` disables. Hidden checks do not connect X11/register Carbon/request permissions. Registration failure retains old configuration. If old unregister fails after successful registration, commit the new table, silence the old token, and report cleanup_pending rather than complete cleanup.

Prepare/save/commit stays within one non-yielding UI call chain. Failed rollback unregister retains a silent orphan; next prepare retries cleanup and rejects if unresolved. Exit closes the owned backend.

## Quick Terminal

| Capability | Implementation/checks | Boundary |
|---|---|---|
| Dedicated window/PTY | Host.createQuick uses normal registries; create hidden, then position; omitted from restoration | Shares eight-window/sixteen-PTY limits |
| Toggle/hide/show | Hide retains PID/VT; show reuses; close releases and next toggle recreates | Hidden window excluded from ordinary active/cycling routes |
| Geometry | top/bottom/left/right/center, fractions, work area, negative origins, decorations, minimum size/clamping | GTK async resize uses planned rectangle |
| Screen changes | Event-driven reconfigure even when hidden, no polling | Simulated areas/hidden windows do not prove monitor hotplug |
| Blur | Optional autohide; synchronous callbacks deferred until transition ends | No ordinary-window activation/focus stealing |
| Topmost/desktops | Existing platform APIs | No all-desktop guarantee; WM/Wayland restrictions apply |

Models cover anchors/invalid geometry/create-position failures/reentry/GTK async size/synchronous blur/PID retention. Real Host fixtures use hidden owned native windows; they never show/activate/manipulate the user desktop.

## Accessibility

| Capability | Implementation/checks | Boundary |
|---|---|---|
| Semantic tree | Post-arrange/paint owned bounded nodes/logical geometry/stable IDs | 128 nodes, 64 KiB text, 256-byte label, 16 KiB/value |
| Initial controls | Tabs/panels/search/confirm/rename/palette/menus/themes/Inspector/scrollbars | Only constructed visible virtual rows |
| macOS | NSAccessibilityElement roles/hierarchy/labels/values/state/focus/hit-test/UTF-16/actions | Unattached NSView is not VoiceOver/external AXUIElement/permission acceptance |
| Linux | Dynamic ATK Object/Action/Text/Component; bytes→Unicode scalars; retired nodes defunct | GTK3/ATK/Orca runtime pending |
| Actions/lifecycle | Callbacks queue stable IDs; next frame checks live/modal-generation/pending-operation stamp | Reject closed/moved/stale/noninteractive targets |
| IME | Traversal checks marked text; queued AX actions reject during preedit | Retry after commit/cancel; real IME pending |
| Keyboard | Modal/search Tab/Shift-Tab/Enter; terminal Tab still goes to PTY | Traversal alone is not screen-reader support |
| Terminal text | Fresh synchronized frame, ≤4096 visible UTF-8 bytes/pane; CJK/combining/selection/caret; conceal omitted | Current viewport only, shared 60 KiB scratch with truncation state |
| Copy visible content | Reacquire at execution; visible selection or bounded viewport | Separate from normal Copy including scrollback |

Native C update also validates focused-node enabled/visible ancestors and modal ownership; rejected candidates retain the old snapshot. Snapshots own text without VT/frame/config pointers. Detach precedes close, so retained old elements cannot call a freed host.

## Validation entry points

- global_hotkey_check, application_hotkeys_check, quick_terminal_check are wired into leaf test/main model targets; file existence alone is not execution evidence.
- services_ui_check exercises real WindowState postframe trees/geometry/actions/modal/IME/text/private clipboard, including three queued-AX/composition/fresh-copy regressions.
- services_hotkeys_ui_check adds 23 real Host transaction/queue/injected-hotkey/hidden-Quick checks, counted only after unified UI execution.
- accessibility_native_test + platform/accessibility_test_adapter: ten local checks, including hidden-ancestor/modal rollback, without system UI.
- platform/accessibility_macos_native_check: 35 checks on unattached NSView, without windows/AXUIElement/activation/trust requests.

Only frozen release records govern final packages. Real VoiceOver/Orca, OS hotkeys/permissions/desktops/hotplug, target Linux, and IME remain pending.

Settings focus blocks terminal actions at enqueue/wake/execution. Chord capture also rejects application-wide globals, including earlier queued New Window. Five real Host regressions prove no PTY input, clipboard reads, or extra windows/processes.
