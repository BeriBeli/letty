# nanoui Settings window plan

Date: 2026-10-20 (Asia/Singapore). Original implementation chat: local / `01a15758-3db3-7d51-82a0-45ca95afa678`. This historical plan records the requested scope; [Settings](settings-window.md) and [validation](settings-validation-2026-10-20.md) describe delivery.

The user requested a separate implementation chat to make configuration easier. Work shared the local tree with M9–M11, retained native Zig VT, uncommitted changes, and accepted M8 packages.

The additional [sidebar request](sidebar-navigation-plan.md) introduced `workspace-navigation = top | sidebar`, `Config.workspace_navigation`, default top. Main integration owned the shared schema; Settings owned draft/preview/save/apply and tab-bar interaction. In sidebar mode, tab-bar controls only the top bar. Switching preserves PTYs/focus/search/layout; detail toggles must reflect real capabilities.

## Deliverable

A working cross-platform nanoui window with categories, search, forms, local preview, editing, Save and Apply, and Cancel/Discard. Current documentation/UI is English; technical keys can assist advanced users without requiring syntax knowledge.

- Appearance: supported fonts/size/themes/conditional themes/ligatures/spacing/padding/cursor/tab bar/inactive opacity.
- Terminal/startup: shell/CWD/inheritance/restoration/history budgets, labeled immediate/new-session/next-launch effects.
- Keyboard: existing bindings, action search, chord capture/conflicts/reset, retaining advanced sequence text.
- Clipboard: copy-on-select, PRIMARY availability, paste protection; OSC 52/images/hotkeys only when actually integrated.
- Advanced: selected configuration path, source/include chain, diagnostics, Open Configuration, retaining file-based workflows.

Prioritize common tasks and readable layout; avoid forcing every advanced field into one long form.

## Behavior and configuration consistency

- Menu/palette/open_settings, Cmd+, / Ctrl+,, respecting override/clear/unbind/ignore; repeated open focuses one instance.
- Independent UI outside PTY/window/tab budgets. Closing Settings leaves the app/layout intact. Input/IME never leaks to terminal.
- Independent draft/local preview, dirty state, field errors, reset as pending change; no-op saves do not rewrite files.
- Reuse config_edit, loading/validation, and atomic all-window reload. Preserve comments, untouched/repeated keys, ACL/xattrs, symlink policy, and concurrent-edit protection.
- Keep --config/XDG/config/config.json resolution and explain effective values/includes/CLI overrides. Never modify included files to simulate root changes. Respect duplicate-key and explicit-color precedence.
- Preserve JSON parsing; if lossless editing is unavailable, disclose it and offer explicit migration preview. Never write INI into JSON or silently create a higher-priority file.
- Validate ranges/actions/conflicts/all-window profiles before save. Failure preserves file/configuration/PIDs/draft and identifies fields; success publishes without PTY restart. External changes require reload/conflict resolution.
- Derive UI from existing schema/ranges/capabilities; do not edit the user's Ghostty configuration.

## Original ownership

The Settings task owned `src/settings/`, isolated tests, and its documentation. Main integration (`01a15755-4f50-74e2-a62d-441733ffb585`) owned App/AppState/Session/build/config/actions/menu/vendor/release. Coordinate exact interfaces rather than concurrently editing shared files. The host supplies effective values/sources, save/apply, theme/font/action catalogs, Open Configuration, focus, and close; UI must not retain reload-invalid arena slices/WindowState pointers.

Serialize full builds/release freezes; lightweight isolated checks can run independently. Do not reset/clean or overwrite others' changes. Tests use private files/clipboard/hidden windows, never real user configuration or desktop state.

## Acceptance

1. Tester: categories/search/focus/IME/light-dark/narrow scrolling/reachable controls; inspect actual screenshots.
2. Temporary configuration: defaults/existing/invalid/includes/explicit paths/conflicts/cancel-without-write/save failure/repeated-key semantics.
3. Real application: menu/palette/bindings, singleton, all-window apply preserving PIDs, close/reopen with new values.
4. Native/portable and Linux cross-build/ABI; unexecuted GTK/native-service checks remain pending.
5. Update configuration/use/validation records and deliver host integration plus a testable package. An isolated form or screenshot alone is incomplete.

Routine layout/field order/implementation decisions were authorized for the original task.
