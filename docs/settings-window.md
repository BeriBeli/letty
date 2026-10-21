# Settings

Open **Settings…** from the application menu or command palette. The default shortcut is **Cmd+,** on macOS and **Ctrl+,** on Linux. Your custom bindings, `clear`, `unbind`, and `ignore` keep their usual precedence.

Settings is a separate window. Opening it again focuses the same window. It does not create a terminal, consume a terminal-window slot, or start a PTY.

## Editing

Search and icon categories stay on the left. Appearance uses grouped fields and a local preview on the right; smaller windows move that preview into the scrolling form. Terminal, Keyboard, Clipboard, and Advanced use the remaining width without an unrelated preview. Overlay scrollbars appear on scrolling, keyboard reveal, dragging, or pointer movement near the edge; after 1.2 seconds of inactivity they fade out over 0.2 seconds without reserving a track. Switches change boolean settings; font and theme selectors expand local choices while retaining custom input. Numeric controls offer direct entry and increment/decrement actions. Cell spacing, dark-theme selection, and sidebar metadata stay behind disclosure controls and remain searchable. The footer keeps Cancel and Save and apply visible.

- **Appearance:** installed font families, font size, local themes and system light/dark themes, ligatures, cell adjustments, padding, cursor, inactive splits, and workspace navigation.
- **Terminal:** shell, command, working directory and inheritance, shell integration, layout restore, and scrollback limits. Startup, working-directory, and history groups explain when their settings apply. The startup command field matches the Shell control's 240-point width; both fill the available width in narrow layouts and search results. Long commands scroll within the field. History memory is entered in MiB; search by the configuration key retains raw-byte entry.
- **Keyboard:** search effective shortcuts in a grouped action list, select a row to edit it, or add a shortcut. The focused editor records keys, checks conflicts, explicitly replaces conflicts, removes bindings, and restores individual defaults. Moving a shortcut to another key atomically disables its old trigger. Advanced sequences and byte actions remain available in a disclosure. There is no bulk reset.
- **Clipboard:** copy-on-selection, paste protection, safe bracketed paste, and OSC 52 write policy. Unsupported platform capabilities are explained.
- **Advanced:** selected physical configuration path, includes and theme files, diagnostics, and the source-editor entry. Command-line overrides and applied values that differ from the file are expandable rows.

The interface is English and uses system UI fonts. It does not require Maple or a CJK font. An unavailable or unverified preview font falls back to system monospace with an explanation. The installed-font list is local and bounded; it does not download fonts. Terminal font defaults remain separate from Settings chrome.

The local preview updates automatically after a short pause in appearance edits, without writing configuration or applying it to terminals. Incomplete or invalid edits retain the last valid sample. A single sun/moon icon switches the preview between the configured light and dark branches; when both branches use the same theme, their colors are the same. There are no manual preview-update or reload buttons.

The local preview illustrates font family, size (the sample is capped at 28 pt), theme colors, and navigation layout using nanoui text. The saved font-size range remains 8–96 pt. Terminal-specific ligatures and cell metrics are applied by the terminal renderer when you save.

**Save and apply** validates the complete candidate configuration and every open profile before saving. Existing processes keep running. Shell/command/directory changes apply to new sessions; layout restore applies at the next application startup. Lower scrollback limits may discard older history immediately.

Changes stay in a draft until saved. **Default** resets one field in the draft. **Cancel** or closing the window asks before discarding changes. To load changes made outside Settings, close and reopen the window; unsaved drafts still require an explicit discard. An unchanged draft never rewrites the file. A rejected save preserves the draft and the previous working configuration. Quit must resolve an unsaved Settings draft before terminal teardown.

## Workspace navigation

Choose **Top tabs** or **Left sidebar** under **Workspace navigation**. The local preview illustrates the draft layout. Saving applies the mode to all terminal windows and persists it for the next launch.

**Top tab bar** (`tab-bar`) only controls the top layout. It is disabled with an explanation when the draft selects the sidebar. `tab-bar=never` does not hide a sidebar. A sidebar still provides navigation with one workspace. Git and listening-port toggles control the connected local providers. They default to off and only collect while sidebar mode is active. Results are bounded, event driven and tied to live session process identities.

## Configuration preservation

Settings follows the same `--config`, XDG, `config`, and `config.json` selection as the application. Text saves append local overrides at the end of the root file so that a later include cannot override a field you just changed. Existing comments, repeated settings, and unrelated options remain intact. Included files are not modified. Explicit color overrides still take priority over theme colors.

Existing text files use the checked `config_edit.Native.save` path, including metadata and external-change checks. Symlinks remain symlinks; replacement targets the captured physical file. Changed included/theme files also reject a save. A missing root is created exclusively, with private parent directories as needed; a concurrently created file is never overwritten.

The file and its inputs are checked again after host preflight. POSIX cannot eliminate a final race against an uncooperative external writer between the last comparison and rename; Settings retains the existing writer's documented limitation. A directory-fsync warning means the save was committed but durability could not be confirmed.

Filesystems such as NFS that return `ENOTSUP`/`EOPNOTSUPP` when listing extended attributes support normal editing, saving, and subsequent saves in the same Settings window. This capability is captured separately from a supported empty attribute list and must match on the original and replacement files. Linux POSIX and NFSv4 ACLs are queried separately when enumeration is unsupported; available ACLs are preserved. Darwin ACL handling remains unchanged. Mode, owner, group, content, and external-change checks still apply, including to included files.

If a readable root or included file instead has an ACL/attribute access error, I/O failure, or excessive metadata, Settings displays the actual parsed values with the affected path and diagnostic, and disables saving. **Open Config** remains available. Errors while reading an individual attribute are never treated as absence. Reopen after resolving the error to restore editing. Display-only snapshots cannot authorize a replacement, even through the native writer.

JSON remains read-only in this first version. **Show migration preview** explains the editable subset without changing files or configuration precedence. JSON profiles have no complete text equivalent, so automatic migration is unavailable. To migrate manually, preserve the JSON, review the preview, save a separate text file, and explicitly select that path.

Each editable text field has a 16 KiB UTF-8 buffer. Existing longer values remain intact and read-only until explicitly reset. Draft field buffers are allocated in the draft’s memory arena, so opening Settings does not place the complete field set on the thread stack.

Command-line overrides remain in effect after saving. Profiles can also override startup command/directory values. Advanced shows these inputs so a file edit is not mistaken for removal of a launch override.

When available, Advanced also lists applied values captured when Settings opened that differ from the file. These strings are owned by the Settings draft. After reloading the draft, reopen the window to capture a fresh runtime comparison.

## Accessibility and feedback

The Settings window publishes its visible categories, fields, values, actions and validation messages through the native accessibility bridge. Text fields have editable-text roles; choices and toggles expose their current value. Tab/Shift+Tab and Enter share the visible controls. Clicking a category gives that row keyboard focus: the focus outline stays on the clicked row, and Tab/Shift+Tab continue from there. The filled category indicates the current page, while the outline indicates keyboard focus. The unsaved-draft confirmation has an isolated dialog tree and focus sequence. Queued actions are rejected after category/filter, draft generation, modal or window changes, and during composition. Native callbacks do not write configuration directly.

Successful save feedback expires after four seconds. Validation and durability errors remain discoverable until addressed or replaced. Terminal-window success notices also expire; action-limit feedback is rechecked against current tab, PTY and window capacity and disappears or updates when the condition changes. Closing a window cancels its timers.

## Validation scope

The standalone harness is in `tools/settings-check/build.zig`; it creates only temporary configurations and offscreen nanoui screenshots. It covers file preservation, save rejection, external conflicts, draft cancellation, range errors, includes, JSON protection, keyboard/IME composition events, system-font fallback, and narrow layouts. It does not use the user's clipboard, running windows, or real configuration.

The same build also produces `letty-settings-metadata-check`. Run it with `--nanoui-hidden` (under a private `xvfb-run -a` on Linux). It injects unsupported attribute enumeration only for its own private temporary directory and drives the actual Settings Save button through first creation, repeated saves, and reopening. It also checks ACL preservation, included-file conflicts, metadata capability changes, and refusal of genuine access/I/O failures. The injection code is linked only into this test executable.

The application integration and release checks are separate. A passing standalone harness is not evidence that real GTK/X11, native IME, accessibility, or multi-window PTY acceptance has completed. See `settings-validation-2026-10-20.md` for the actual results and remaining checks.
