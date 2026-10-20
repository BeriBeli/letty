# Configuration and customization

macOS and Linux use the same resolution rules:

1. Explicit `--config=/absolute/path/to/file` wins; a missing explicit file is an error.
2. Otherwise use `~/.config/letty/config`, or `$XDG_CONFIG_HOME/letty/config` when XDG_CONFIG_HOME is absolute.
3. If `config` is absent, try sibling `config.json`. If both are absent, use defaults while retaining `config` as the intended path.

Letty neither overwrites configuration nor reads Ghostty's directory. `letty --check-config` reports the selected path and checks syntax without a PTY/window.

Text configuration uses `key = value`, optional double-quoted values, and whole-line `#` comments. Unknown keys, invalid values, and unsupported actions are errors. Copy packaged `config/config.example`:

```ini
font-family = Maple Mono Normal NL NF CN
theme = paper
font-size = 14
window-padding-x = 8
window-padding-y = 8
cursor-style = block
cursor-style-blink = false
keybind = ctrl+shift+r=reload_config
```

Maple Mono Normal NL NF CN and Otty Paper are replaceable defaults.

## Reload

Save, then use Edit → Reload Configuration / Cmd+Shift+, on macOS, or the command palette / Ctrl+Shift+, on Linux. `reload_config` can be rebound.

Fonts, colors, palettes, spacing, padding, cursors, inactive-pane opacity, tab bars, and bindings apply without restarting PTYs. Invalid configuration retains the last working snapshot and reports the cause in the window/stderr. Shell/command/CWD changes affect new sessions; restoration options apply at next launch. Lower history budgets may immediately prune old history.

## Common options

| Option | Meaning and range |
|---|---|
| `font-family` / `font-size` | Terminal family; 8–96 pt |
| `font-feature` | Repeatable, up to 32 OpenType tags, e.g. `-liga`, `ss01=1`; empty clears |
| `font-ligatures` | Letty extension: false finally forces liga/calt/dlig to 0; true preserves explicit features |
| `font-family-fallback` | Letty extension: up to 16 additional families; empty clears |
| `theme` | Built-in `paper`, `custom`, or external name/path |
| `background` / `foreground` | `#RRGGBB` or `RRGGBB` |
| `palette = N=#RRGGBB` | Repeatable, ANSI indexes 0–15 |
| `cursor-color` | Defaults to foreground |
| `selection-background` / `selection-foreground` | Defaults to inverted foreground/background |
| `window-padding-x` / `window-padding-y` | 0–128 pt; single value or `left,right` / `top,bottom` |
| `adjust-cell-width` / `adjust-cell-height` | Grid adjustment in pt or percent, e.g. `2`, `10%` |
| `cursor-style` | `block`, `bar`, `underline`, `block_hollow` |
| `cursor-style-blink` | Boolean; subsequent application cursor control can override |
| `unfocused-split-opacity` | 0.15–1 |
| `tab-bar` | Letty extension: `auto`, `always`, `never`; auto keeps workspace controls visible, including a single tab |
| `split-divider-color` | Divider color |
| `ui-panel` / `ui-border` / `ui-accent` | Letty UI overrides; otherwise derived from light/dark terminal colors |
| `shell` / `command` / `working-directory` | New-session launch settings; CWD accepts `home`, `inherit`, absolute paths, and `~`; see launch rules below |
| `scrollback-lines` | Up to 100000 lines |
| `scrollback-bytes` / `scrollback-limit` | Up to 128 MiB, also constrained by the line budget |
| `restore-layout` | Restore topology into new processes at next launch |
| `keybind` | Repeatable; see below |

Cell adjustments range from -50 to 200, with a final minimum of 1 pt. Large negative values can overlap glyphs. Explicit colors always override theme colors, regardless of line order.

## Font features and fallback

```ini
font-feature = ss01=1
font-feature = -liga
font-family-fallback = Noto Sans CJK SC
font-family-fallback = Symbols Nerd Font
```

The last `font-family` wins; add fallback through its separate option. A grapheme's combining characters shape together in one font. Ligatures do not change VT column widths. Cursor, selection, search, and style boundaries split shaping runs.

macOS uses CoreText and converts color glyphs to monochrome ink masks retaining internal contrast; color emoji output is unavailable. The portable path uses pinned HarfBuzz 14.6.0 and monochrome TrueType rasterization, without CFF/color-emoji rasterization. Missing glyphs and shaping failures produce diagnostics; degraded drawing does not establish successful feature application.

## External and conditional themes

`theme = midnight` resolves to `themes/midnight` beside the selected configuration. Absolute paths, `~/...`, and relative paths such as `./my-theme` are accepted.

Themes accept supported Ghostty color fields: background/foreground, cursor and selection colors, and repeated palette entries. They can also supply font-feature/font-ligatures; explicit main configuration wins. Both light/dark branches are validated and cached. The package includes `config/themes/midnight`; themes are not downloaded. Dark themes also update nanoui tabs/search/menus.

```ini
config-file = common
config-file = ?machine-local
theme = light:paper,dark:midnight
```

Includes expand recursively in place; later values override earlier ones. Relative paths resolve beside the file defining the directive. `?` ignores only absence; permission errors, directories, and FIFOs fail. Canonical paths including symlinks detect loops. Limits: depth 16, 64 KiB per file, 1 MiB across configuration and both themes, 256 sources/missing optional entries. Themes can include text files. The root can be legacy JSON; included files must be text configuration.

Reload reads and validates both themes, including the inactive branch. System appearance changes select cached colors without file reads or PTY restarts and preserve per-window font zoom. Repeated notifications do not reconfigure terminals. macOS uses appearance notifications; Linux uses GTK Settings properties. Real GTK/desktop signals require target acceptance.

`--check-config` lists canonical configuration/include/theme sources; failures include source, line, and include chain. Any include/theme failure retains all windows' old configuration and PTYs.

## Command palette

Open with Cmd+Shift+P on macOS or Ctrl+Shift+P on Linux, View → Command Palette… on macOS, or the Linux tab bar's ⋯. The nanoui palette follows theme colors. Search titles, action names, or supported Chinese keywords; arrows select, Enter executes, Escape/outside click closes. Mouse/wheel navigation and binding hints are supported.

Actions cover implemented tab/split/search/clipboard/configuration/font/navigation/close behavior. Filter text never reaches the shell. Rebind with `keybind = super+shift+p=toggle_command_palette`; Linux also accepts explicit `ctrl+shift+p`. `keybind = clear`, `ignore`, or `unbind` can remove defaults; add the binding last to restore it.

## Key bindings

```ini
keybind = super+k=new_split:right
keybind = ctrl+shift+r=reload_config
keybind = super+equal=increase_font_size:2
keybind = super+q=ignore
```

`super` / `cmd` / `command` means Command on macOS and Control on Linux. Modifiers include ctrl/shift/alt; the first chord needs ctrl/super/alt. Keys include characters, comma, period, minus, equal, plus, left_bracket, right_bracket, arrows, tab, enter, escape, and space.

Last definition wins. `keybind = clear` removes defaults/prior bindings; empty `keybind =` restores defaults. `unbind` removes an app binding; `ignore` consumes it. macOS menu equivalents follow configuration. System window shortcuts are outside this interface.

Supported base actions: `new_tab`, `new_split:right/down`, `close_surface`, `close_tab` / `close_tab:this`, `close_window`, `quit`, `copy_to_clipboard`, `paste_from_clipboard`, `start_search`, `toggle_command_palette`, `reload_config`, `next_tab`, `previous_tab`, `goto_tab:1…16`, `goto_split:next`, `increase_font_size:N`, `decrease_font_size:N`, `reset_font_size`, `unbind`, `ignore`. Font step N must be greater than 0 and at most 32. Additional actions are described in their sections.

### Sequences and byte actions

```ini
keybind = ctrl+b>t=new_tab
keybind = ctrl+b>right=new_split:right
keybind-sequence-timeout = 1000
keybind = ctrl+alt+x=text:hello\\\x1b\x00
keybind = ctrl+alt+c=csi:31m
keybind = ctrl+alt+e=esc:c
keybind = performable:super+c=copy_to_clipboard
keybind = unconsumed:ctrl+alt+q=text:example
keybind = all:ctrl+alt+a=text:shared input
```

Sequences have at most eight chords; later chords may be unmodified. Prefixes are consumed. If a prefix is also a complete action, it waits for continuation and executes on timeout. The deadline starts at the first chord and never extends. A mismatching final chord executes any pending complete action and is delivered normally once; prefixes are not replayed. Escape, focus loss, overlays/search, IME composition, and reload cancel sequences. Each window has independent state and a cancellable one-shot timer, without idle polling. Timeout: 50–5000 ms.

`text:` sends UTF-8; `csi:` prepends ESC `[`, and `esc:` prepends ESC. Escapes: `\\`, `\n`, `\r`, `\t`, `\xNN`, `\u{hex-codepoint}`, including length-delimited NUL. Invalid escapes reject loading. Each action owns up to 4096 bytes across reload and sends through the session queue. The actual bytes determine whether a shell executes a command.

`performable:` consumes only when currently available. `unconsumed:` executes and then delivers the chord normally once. `all:` supports only byte actions across live sessions in every window: snapshot stable IDs, preflight all queues, enqueue all, then flush. A busy target rejects the entire enqueue; later OS writes cannot be rolled back. `global:` requires explicit registration as described below.

## Splits and tabs

The palette/macOS menu provides four-way splitting, directional/previous/next focus, zoom, equalization, and resizing. Default pane navigation is Cmd+Alt+arrows / Ctrl+Alt+arrows; zoom is Cmd+Shift+Enter / Ctrl+Shift+Enter. Equalization allocates area by subtree leaf count within minimum ratios and available cells. `resize_split:direction,pixels` uses 1–1000 pixels.

```ini
keybind = super+alt+left=goto_split:left
keybind = super+shift+enter=toggle_split_zoom
keybind = super+alt+e=equalize_splits
keybind = super+alt+r=resize_split:right,20
keybind = super+alt+t=prompt_tab_title
keybind = super+alt+comma=move_tab:-1
```

Additional actions: `new_split:left/up`, `goto_split:left/right/up/down/previous`, `toggle_split_zoom`, `equalize_splits`, `resize_split:direction,pixels`, `prompt_tab_title` (alias `rename_tab`), and `move_tab:±1…7`. Tab movement wraps. Double-click renames; an empty name restores the terminal title. Drag reorders; overflow controls support narrow windows. Each tab remembers its pane. v2 introduced stable tab metadata and v1 migration; the current workspace format is v4.

Zoom changes presentation only. Directional focus can select another zoomed pane; tab change, new split, or pane close exits zoom without rebuilding other PTYs.

## Search and scrolling

Search shows current/total counts and no-results/progress states. All visible hits are highlighted; the current hit uses the accent color. Terminal selection remains independent. Enter/Shift+Enter navigate, Escape closes; actions are `navigate_search:next/previous` and `end_search`. macOS defaults: Cmd+G / Cmd+Shift+G; Linux next: Ctrl+Shift+G. Search is literal with ASCII case folding, incremental over bounded history. Query limit: 4096 bytes; temporary quota: 64 MiB. Failures show Search failed rather than zero results.

A narrow scrollbar supports dragging and page-track clicks. Alternate screens hide main history. Palette/menu actions include `scroll_to_top/bottom`, `scroll_page_up/down`, `select_all`, `clear_screen`, and `reset`. macOS Cmd+Home/End and Linux Ctrl+Shift+Home/End go to bounds; Linux Ctrl+Shift+PageUp/PageDown pages. Edge-selection autoscroll runs only while dragging.

Native `clear_screen` clears history while preserving VT modes. At a trusted prompt, shell redraw preserves the edit buffer/cursor; during ordinary output it removes lines above the cursor and retains the current line. Alternate screen rejects it. Insufficient TX capacity rejects before mutation. macOS zsh unexecuted input/CJK/combining/reflow checks passed; target Linux shells need acceptance. The archived C baseline keeps its own CSI strategy. `reset` fully resets VT modes/history/content while retaining dimensions and PTY/PID; it sends no shell command. Cmd+K clears; Cmd+A / Ctrl+Shift+A selects all. Overlay/search editing takes clipboard/select-all priority.

## Menus, configuration entry, and close confirmation

Terminal context menus provide copy/paste/select-all/search-selection/split/zoom/clear/close; tab menus provide rename/move/close/close-others. TUI mouse tracking receives ordinary right-click; Shift+right-click opens Letty's menu. Arrows/Enter, Escape, and outside dismissal work.

`open_config` opens the selected file. Missing files require Create & Open confirmation; O_EXCL prevents overwriting existing/concurrently created files. The system editor uses a native file URL on macOS or separate xdg-open argv on Linux, without shell concatenation. Failure offers a copyable path. `show_config_diagnostics` shows path/line/key/cause; failed reload keeps old configuration and PTYs.

`confirm-close-surface = true` is the default: confirm foreground work or uncertain idle state. `false` disables confirmation; `always` confirms all user closes. Pane/tab/other-tabs/window/quit/WM requests share the transaction. Escape, Cancel, and default Enter cancel without destroying processes. Natural exit is separate. Additional actions: `close_other_tabs`, `open_config`, `show_config_diagnostics`, `search_selection`.

## Launch profiles

Sibling `config.json` retains legacy profiles; see `config/config.example.json`. Text `config` wins if both exist, or select JSON explicitly with `--config=/path/to/config.json`.

Profiles contain name/command/cwd. Local follows platform shell conventions below; an SSH example is `exec ssh my-server-alias`. Existing SSH configuration/agent handles authentication. File → Next Launch Profile or the Linux palette chooses later sessions; `--profile=NAME` selects explicitly. Reload maps profiles by name; removing one used by an open pane rejects reload.

`--command=COMMAND` and `--cwd=DIR` override that launch and survive reload. Layouts store topology/profile references, not running processes or CLI overrides. This is a supported configuration subset, not full Ghostty compatibility. Transparency/blur/custom shaders are unsupported; unknown keys fail. See [Linux testing](linux-testing.md) for fonts and runtime limits.

## Clipboard and links (M4)

`copy-on-select`: `none/false`, `primary`, `clipboard`, `both`; true means PRIMARY on Linux and CLIPBOARD on macOS. Defaults: Linux PRIMARY, macOS none. Linux middle-click reads PRIMARY; in TUI mouse mode use Shift+middle-click. Async reads capture Session ID; tab switching never retargets and closed targets discard results.

`clipboard-paste-protection = true` previews non-bracketed multiline/control content; cancel sends nothing. `clipboard-paste-bracketed-safe = true` allows bracketed paste without dangerous controls directly. All entries share the 1 MiB bound and CRLF/CR→LF normalization. IME commit bypasses clipboard confirmation.

Cmd-hover on macOS / Ctrl-hover on Linux previews and underlines visible HTTP(S) URLs or true OSC 8 targets. Click opens; context-copy copies the true target. The same modifier on a local file path opens the in-app [file preview](file-markdown-preview.md#opening-paths-from-terminal-output); remote/explicit-command terminals refuse it. Plain URL detection joins visible soft wraps, never hard breaks or full history. Other schemes are refused. xdg-open runs on the GUI host with separate arguments; failure offers copying/retry.

## Local shell, directories, and feedback (M5)

`shell-integration = detect` injects packaged scripts into new interactive zsh/Linux Bash; `none` disables it. Explicit commands, including SSH profiles, receive no injection. Remote settings and user startup files are unchanged. macOS Bash 3.2 is not automatically injected; use zsh or manually source packaged `shell-integration/bash` after Bash configuration. Bash 4.2 is the Linux integration baseline; real target startup remains to be accepted.

Bash preserves/composes PROMPT_COMMAND string/arrays and does not replace existing DEBUG traps/extdebug; the host marks submitted commands busy conservatively. zsh uses an isolated ZDOTDIR wrapper, preserves startup files/hooks, then restores ZDOTDIR. Complex prompt plugins can conflict; choose none if needed. Changes affect only new sessions.

New tabs/splits inherit the source pane's latest valid local directory. Explicit profile CWD wins, then inherited CWD, then CLI initial CWD/global working-directory. OSC 7 file URIs decode percent escapes; bare directories remain literal. Only existing absolute local-host paths qualify. Remote hostnames clear inheritance candidates.

Previous/Next Shell Prompt (`jump_to_prompt:-1/1`) uses VT prompt markers and reports unavailable without semantics. Background BEL/completion/failure set tab markers. OSC 9;4 shows percentages/static ellipsis and removes on request. No libnotify dependency or idle animation is added.

Only an injected local shell at a trusted prompt, without pending submission and with its foreground process group still the shell, bypasses default confirmation. Unknown states confirm. Mode 1004 emits deduplicated focus reports only when enabled; window/pane/tab/search/overlay transitions update the target without user-input side effects.

## Multiple windows (M6)

`new_window`: Cmd+N / Ctrl+Shift+N. Linux next/previous pane uses Ctrl+Shift+] / [. `goto_window:next/previous` is in the palette. Window, tab, split and PTY collections grow on demand; memory, file descriptors and OS resources determine capacity.

`close_window` affects one window; `quit` aggregates all sessions into one confirmation. Cancel preserves PIDs; newly added unapproved sessions invalidate an accepted Quit. The final terminal window keeps the app alive if Settings is open. Explicit Quit handles dirty Settings first. macOS routes through the key window; Linux entries bind their own window.

Reload validates profile mappings for every window before publishing one shared snapshot. Any mismatch preserves all old configuration; success keeps PTYs and resets temporary font sizes to configured values.

Layout v4 saves window collections, positions/content dimensions, titles, pinned groups, focus, and sidebar width/collapse. v1/v2/v3 migrate; restoration creates new processes. The primary holds `layout.json.lock`; other instances write `layout-instance-PID.json`. Closing a window removes only it; the final useful layout remains for next launch.

macOS uses `/usr/bin/login -flp` for login shells, preserves CWD/integration environment, and adds `-q` for account `.hushlogin`. Linux directly starts an interactive non-login shell; commands use shell `-c`. Bash reads `.bashrc`; zsh installs hooks after `.zshrc`. macOS commands run in a login shell.

CWD follows pinned Ghostty `Config.probableCliEnvironment` / `WorkingDirectory`: macOS launchd/Finder/open chooses account HOME; otherwise a nonempty TERM_PROGRAM or CLI arguments inherit process CWD, falling back to HOME. `working-directory = home/inherit` overrides this. `window-inherit-working-directory`, `tab-inherit-working-directory`, and `split-inherit-working-directory` default true. Explicit profile CWD wins over inheritance, which wins over CLI/global initial CWD. Revalidate inherited directories before spawn; deleted directories fall back. Explicit chdir also sets PWD and preserves symlink spelling.

## Theme browser, file drops, and Inspector

Browse Themes searches Paper, configuration `themes/`, and packaged themes. Preview affects only the initiating window; Cancel restores, Apply changes its runtime theme, Save edits only root text `theme`. Concurrent content/metadata changes reject overwrite. Comments/newlines/permissions/ACL/xattrs are preserved. JSON roots are not automatically rewritten. PTYs continue throughout.

Local file drops quote for the actual POSIX shell/fish, append a space, and never Enter. Unknown shells, command overrides, and remote URIs get read-only raw previews/Copy Details without PTY delivery. Limits: 16 paths, 4095 bytes/path, 64 KiB total. Invalid input rejects. Bracketed paste is respected; stale targets never redirect to the active pane.

Terminal Inspector (Cmd+Alt+I / Ctrl+Shift+I) shows grid/session/budgets, actual fonts/glyph IDs, input modes, graphics budgets, and service diagnostics. Text capture is off until Show Cell Text; close/source destruction erases it. Freeze affects diagnostics only. Copy Diagnostics omits cell text, keystrokes, pasted content, and full history.

## OSC 52 and Kitty images

```ini
# Terminal clipboard writes require confirmation.
clipboard-write = ask
clipboard-read = deny
# Enable direct RGB/RGBA/PNG Kitty transfer when needed; default is off.
kitty-graphics = true
```

`clipboard-write`: deny/ask/allow, UTF-8 only, at most 64 KiB decoded. Ask occurs after parsing; default Enter cancels. Policy changes/source close/revoked prompts invalidate pending writes. `clipboard-read` accepts only deny; no async permission protocol is offered.

Kitty engine storage is 8 MiB per main/alternate screen; the application's current snapshot is at most 8 MiB. All panes in one window share 8 MiB raw rendering resources plus a fixed atlas. Oversize/count/atlas exhaustion skips images with diagnostics while text/queries continue. GPU texture generations and raw resources are accounted separately; 8 MiB is not total application memory. Close/hide/disable releases rendering resources. Terminal transfer requests do not open system files.

## Global hotkeys and Quick Terminal

No system key is registered by default. Declare explicitly:

```ini
keybind = global:ctrl+alt+g=toggle_quick_terminal
quick-terminal-position = top
quick-terminal-width = 1
quick-terminal-height = 0.4
quick-terminal-autohide = true
quick-terminal-always-on-top = true
```

`global:` accepts one modified chord, without sequences/performable/unconsumed/all. Registration conflict rejects reload and preserves old configuration. `global-hotkeys = false` disables registration. Quick Terminal is a separate transient window retaining PTYs while hidden, excluded from layout restoration but counted in normal window/PTY budgets. Positions: top/bottom/left/right/center; width/height must be greater than 0 and at most 1.

macOS uses AppKit/Carbon; Linux uses GTK/X11. Wayland global keys, forced placement, and all-desktop visibility are outside scope. `accessibility = false` disables the native bridge. VoiceOver/Orca, native drag/drop, multiple monitors, and target Linux behavior require actual platform acceptance.

## Settings and workspace sidebar

[Settings](settings-window.md) is a separate English window, opened from menu/palette or Cmd+, / Ctrl+,. It uses system UI fonts and creates no PTY. Drafts pass complete configuration, all-window/profile, and service-reservation validation before saving/publishing. Failure/conflict preserves the draft and running configuration.

```ini
workspace-navigation = top
sidebar-show-git = false
sidebar-show-ports = false
```

`workspace-navigation`: top (default) or sidebar. `tab-bar` controls only top mode; sidebar works with one workspace. Switching preserves Session/PID, split tree/ratios, search, selection, and queued input. Sidebar supports pinned groups, within-group dragging, keyboard selection, collapse/width/scroll. Temporary narrow-window compression does not overwrite saved width. Sidebar-owned keyboard/IME events never reach PTYs.

Git/ports are off by default and collected only in sidebar mode with explicit enablement. Git queries trusted local CWD through bounded async processes; ports inspect Session-root/same-TTY descendants' TCP listeners. Results validate Session/generation/process identity. CWD/prompt/focus events coalesce requests; static drawing never polls. Close/exit/fatal/disable revokes watches/results. Permission, non-repository, timeout, unsupported, and partial states are explicit; data is never fabricated.

Navigation-only publication preserves terminal interaction/configuration ownership and rebases open theme-preview originals, so Cancel cannot restore an old mode. Other changes use full application. Workspace persistence is v6 (v3/v4/v5 collections migrate). See [sidebar validation](sidebar-validation.md) and [M9](m9-capabilities.md)/[M10](m10-capabilities.md)/[M11](m11-capabilities.md).

Independent file workspaces open with Cmd+O / Ctrl+Shift+O. Bind `open_file_workspace`, `move_preview_to_workspace`, `open_file_preview`, `preview_selected_path`, `close_file_preview`, `toggle_file_preview`, and `refresh_file_preview` using existing override/unbind/ignore/palette rules. Document focus routes copy/select/find/page/font actions to the reader. IME preedit blocks document switching/close. No remote reading/network configuration is added. See [file/Markdown previews](file-markdown-preview.md) for path and resource limits.

## Workspace navigation capacity and compact controls

Each OS window supports dynamically allocated terminal and file workspaces. There is no fixed count limit for windows, workspaces, split panes or application PTYs. Creation can fail when memory or operating-system resources are exhausted; existing sessions and topology remain intact. History, input queues, preview content and concurrent file transforms retain their resource budgets. Side previews retain four document tabs per dock. `goto_tab:N` accepts any positive platform-sized integer; `move_tab:N` accepts a nonzero signed platform-sized offset and wraps within the current tab order. Default direct number shortcuts remain Cmd+1…8, and the palette includes the first sixteen direct positions. Previous/next tab and sidebar navigation reach every workspace. Layout restore validates up to 64 MiB of JSON before spawning fresh sessions.

The compact sidebar uses a 44-point icon rail with folder rows, active selection and attention dots. Accessible row names retain workspace numbers and titles. Scroll the rail to reach overflow rows; hovering a row shows its full title and metadata. Clicking a folder selects the workspace and returns keyboard input to its terminal. The header expands the sidebar, and the stacked bottom plus and search icons create a workspace and open Commands. Expanded sidebar navigation retains keyboard Up/Down/Home/End/Enter and Escape to return input. Narrow windows temporarily use the compact rail without changing preferred sidebar width.

Top navigation keeps its controls visible with one tab in `auto` mode (`never` remains an explicit opt-out). It keeps New Tab immediately beside the tabs, with overflow arrows when needed. The native macOS title bar retains its system dragging behavior. Layout restoration accepts older eight-slot tab arrays and saves the expanded bounded arrays; restoring recreates processes, while file-workspace paths are restored and preview reading state remains memory-only.

Show / Hide File Preview uses Cmd+Shift+O / Linux Ctrl+Alt+O. The right-edge File/Show entry is available in both navigation modes. Open File Preview (Cmd+O / Ctrl+Shift+O) remains a separate action.
