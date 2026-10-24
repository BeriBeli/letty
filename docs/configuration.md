# Configuration and shortcuts

This guide describes `src/runtime/main.zig`. The
[preceding configuration guide](archive/configuration-pre-runtime.md) records the
older application and its different keys, command line and JSON format.

## File selection and validation

Letty selects configuration in this order:

1. `LETTY_CONFIG`, when set.
2. `$XDG_CONFIG_HOME/letty/config`, when `XDG_CONFIG_HOME` is set; otherwise `~/.config/letty/config`.
3. An existing sibling `kero-config` only when the canonical `config` file is absent, for compatibility with earlier development builds.

A missing selected file uses defaults. Letty Settings saves to the selected
path. The current CLI does not accept `--config` or load `config.json`.
Use `LETTY_CONFIG` to select a separate file without changing the default.

```sh
zig-out/native/bin/letty config path
zig-out/native/bin/letty config show --defaults
LETTY_CONFIG=/absolute/path/to/config zig-out/native/bin/letty --check-config
```

`config show` displays parsed settings; `config check` validates the selected
file; `config edit` opens it with the system default application. These commands
do not create a terminal window. `--cwd=DIR` and `--shell=PATH` select the initial
working directory and shell; `-- COMMAND [ARG…]` or `-e COMMAND [ARG…]` launches a
command in the initial terminal. See `letty --help` for launch options.

## Format and example

Use UTF-8 `key = value` lines, optional surrounding double quotes and whole-line
`#` comments. Boolean values are `true` or `false`. Unknown keys, malformed
values and invalid bindings are errors. The file limit is 1 MiB.
The [current example](../config/config.example) can be copied to the selected
`config` path:

```ini
theme = letty
font-size = 13
language = system
scrollback-limit = 4
git-status = true
diff-layout = auto
```

The empty default `font-family` selects the bundled JetBrainsMono Nerd Font.
Any installed monospaced family can be selected explicitly. The font files live
under `share/letty/terminal/fonts/` beside an installed executable, or
`Contents/Resources/terminal/fonts/` in the macOS preview.

## Settings

Defaults and validation are defined by `Settings` and `Config.parse` in
`src/runtime/settings.zig`. The native Settings window offers finite choices and
editable fields. The following table groups the current keys; platform and
remaining behavior limits are listed in the [implementation scope](implementation-scope.md).

| Area | Keys and accepted values |
| --- | --- |
| Sessions | `new-session-directory`: `current`, `project`, `home`; `session-name`: `focused`, `lead`, `folder`; `focus-follows-mouse` and `confirm-close`: booleans |
| Appearance | `window-theme`: `system`, `light`, `dark`; `language`: `system`, `en`, `zh-Hans`; `background`: `rex`, `mist`, `meadow`, `dusk`, `petal`, `plain`; `window-translucent`: boolean |
| Font | `font-family`: family name; `font-size`: 6–72; `font-weight`: 100–900; `line-height`: 1–3; `font-ligatures` and `font-thicken`: booleans |
| Terminal colors | `theme`: name/path or light/dark pair; `minimum-contrast`: 1–21; `dim-unfocused-terminals`: boolean |
| Cursor | `cursor-style`: `block`, `bar`, `underline`; `cursor-style-blink`: boolean |
| Input | `macos-option-as-alt` and `copy-on-select`: booleans; `clipboard-read`: `ask`, `allow`, `deny`; `right-click-action`: `context-menu`, `paste`, `copy-or-paste` |
| Shell/history | `command`: shell executable, with an empty value using the default shell; `scrollback-limit`: 0–128 MiB per terminal, default 4 |
| Notifications | `notify-on-waiting`, `notify-on-done`, `notify-on-error`, `notify-sound`, `dock-badge`, `dock-bounce`: booleans |
| Changes | `git-status`: boolean controlling automatic Git and SVN status; `diff-layout`: `auto`, `unified`, `split` |
| Repeated entries | `env = NAME=value` and `keybind = CHORD=action.id` |

Settings validates and atomically saves accepted edits before publishing them.
External changes or failed writes retain the last saved configuration. Use
Advanced → Reload to read external edits. Startup settings apply to newly
created terminals. See [Settings](settings-window.md) for persistence details.

Sidebar geometry, project aliases and file-workspace preferences are stored
separately in `<config>.ui.json`; this does not restore running shell processes.

## Themes

`theme = letty` selects the built-in light/dark palette. The old `kero` selector
remains a compatibility alias. The bundled Ghostty catalog contains 771 themes:

```ini
theme = light:letty,dark:Gruvbox Dark
```

For custom themes, use an absolute path or a name under `LETTY_THEME_DIR`,
`$XDG_CONFIG_HOME/ghostty/themes` or `~/.config/ghostty/themes`. Custom theme
files contain terminal colors and repeated `palette = N=#RRGGBB` lines; these
color keys belong in a theme file, not the main configuration.
The theme picker previews colors before selection.

## Environment and bindings

Repeated `env` entries apply to newly launched PTYs. Each binding uses an action
ID from `src/runtime/actions.zig`. Explicit assignments replace default
collisions; `none` removes a binding for an action:

```ini
env = EDITOR=vi
keybind = Ctrl+F5=session.new
keybind = none=session.newHome
```

Use Settings → Keyboard to record, reset or unbind shortcuts. The current
binding format uses one chord and an action ID; older action strings and
multi-chord sequences belong to the preceding implementation.

| Action | macOS | Linux |
| --- | --- | --- |
| New workspace / window | Cmd+T / Cmd+N | Ctrl+Shift+T / Ctrl+Shift+N |
| Split right / down | Cmd+D / Cmd+Shift+D | Alt+Shift+= / Alt+Shift+- |
| Close pane | Cmd+W | Ctrl+Shift+W |
| Copy / paste | Cmd+C / Cmd+V | Ctrl+Shift+C / Ctrl+Shift+V |
| Find / command palette | Cmd+F / Cmd+P | Ctrl+Shift+F / Ctrl+Shift+P |
| Settings | Cmd+, | Ctrl+, |
| Changes | Cmd+Alt+G | Ctrl+Shift+G |
| Toggle sidebar | Cmd+B | Ctrl+Shift+B |

The action catalog is authoritative when adding or rebinding an action.
