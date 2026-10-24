# macOS native development preview (preceding implementation)

> Historical guide. Commands, configuration and release gates below describe
> the preceding application. Use the [current documentation](../README.md).

Open `Letty.app` directly. Defaults are Maple Mono Normal NL NF CN and Otty Paper, with local shells, tabs, horizontal/vertical splits, selection/copy/paste, and history search. Both platforms share nanoui UI; macOS uses CoreText/Metal, Linux portable text/GTK.

Packaging installs the [original Letty icon](../../assets/icons/README.md) from `assets/icons/Letty.icns` and sets CFBundleIconFile. Run `python3 tools/prepare-icon.py` after updating the master.

This is an Apple Silicon development preview. The minimum macOS version follows the actual Mach-O deployment target recorded in `Contents/Resources/build-info.json`. Signing is local ad-hoc, without Developer ID notarization.

Use Run in Codex or:

```bash
./script/build_and_run.sh
```

The script closes an existing Letty preview, builds with Zig 0.17.0, runs core/hidden UI checks, creates a local-preview app/ZIP, and opens it. This entry requires current native checks; distribution separately requires Linux ABI, archive recovery, stability, and performance review. Options: `--verify` checks launch, `--logs` shows logs, `--debug` uses LLDB.

Configuration follows [shared path and reload rules](../configuration.md): `~/.config/letty/config` or `$XDG_CONFIG_HOME/letty/config`, no overwrite, `letty --check-config`, Edit → Reload Configuration / Cmd+Shift+,. Reload preserves PTYs; restoration creates new processes. Sessions follow Ghostty's `/usr/bin/login` convention and display login information unless account `.hushlogin` suppresses it. Explicit/inherited CWD remains effective.

UI references pinned Ghostty TransparentTitlebarTerminalWindow.swift, TerminalWindow.swift, SurfaceView.swift, and SplitView.swift: matching transparent titlebar, persistent workspace controls in top navigation, floating top-right search, draggable 1 pt divider, and inactive-pane opacity 0.7. AppKit owns titlebar/menus; nanoui owns rename/reorder/focus-aware tabs. Native tab tear-out/merge is unavailable.

Default macOS shortcuts:

- Cmd+T new tab; Cmd+1…8 select; Cmd+Shift+[ / ] switch.
- Cmd+D split right; Cmd+Shift+D split down; Cmd+] next pane. Drag dividers, double-click for equal division.
- Cmd+W close pane; Cmd+Alt+W close tab; Cmd+Shift+W close window.
- Cmd+C/V copy/paste; Cmd+F search; Escape closes search.
- Cmd+Shift+P palette; type/arrows/Enter/Escape, configurable via toggle_command_palette.
- Cmd+= / - adjusts font; Cmd+0 resets startup size.

File/Edit/View expose the same actions. Next Launch Profile selects later sessions. Linux retains Ctrl+Shift bindings. macOS previews do not replace target Linux GTK/X11/IME acceptance.

The historical frozen M8 package retained M0–M7, latency/title fixes, and actually checked later-feature routes. See [M8 scope](../m8-release.md) for 526/522 UI counts and [subsequent integration](../m9-m11-release.md) for its own frozen evidence.

## Native Zig default backend

Since 2026-10-20, builds import official ghostty-vt and report `vt-backend=zig`. nanoui/Maple/Paper remain. Cmd+K uses prompt redraw preserving unexecuted input/cursor. Active C VT was removed; the validated [recovery archive](../c-vt-recovery.md) remains independent. Target Linux/display/IME is pending; see [migration performance](../performance-zig-migration-2026-10-20.md).

To keep an existing preview bundle intact, pass `--output-dir=dist/<preview-name>` to `tools/package-macos.py --local-preview`. The app, archives, and checksums are written together in that directory.
