# macOS development preview

macOS is a development host for Letty. The current preview uses CoreText/Metal;
Linux delivery uses the nanoui CPU/GTK/X11 renderer. The bundled terminal font
is JetBrainsMono Nerd Font, and the built-in terminal theme is `letty`.

Use exactly Zig 0.17.0 and Python 3. From the repository root:

```sh
./script/build_and_run.sh
```

The script builds the current source, runs unit/PTY/document/hidden-window UI
checks, creates `dist/LettyPort.app` with `tools/package-port-preview.py`, and
opens a new preview process. It retains a timestamped backup when replacing a
previous preview bundle. It does not close an already running preview.

| Mode | Result |
| --- | --- |
| `./script/build_and_run.sh --verify` | Launch and check that the preview remains running |
| `./script/build_and_run.sh --debug` | Open LLDB on the packaged preview executable |
| `./script/build_and_run.sh --logs` | Launch and stream preview process logs |

Set `ZIG=/absolute/path/to/zig` to select an existing 0.17.0 compiler. Standard
output and errors are written under `.cache/test-logs/macos-app.*.log`.
The preview is locally ad-hoc signed and is a development package.

To verify without launching an interactive app:

```sh
python3 tools/build.py --native --skip-bootstrap --zig=/absolute/path/to/zig
python3 tools/verify-ui.py --prefix=native
```

After bootstrap, `--native --portable` builds the macOS CPU-renderer variant;
verify it with `--prefix=native-portable`. Run builds serially and keep the
source stable throughout verification. UI checks need a GUI session and Metal
access for the native renderer, plus permission to spawn/reap their own PTYs.

Configuration is `~/.config/letty/config` or `$XDG_CONFIG_HOME/letty/config`,
with `LETTY_CONFIG` as an explicit override. See [configuration and shortcuts](configuration.md),
[documents](file-markdown-documents.md) and [Settings](settings-window.md).

The [preceding preview guide](archive/macos-preview-pre-runtime.md) records
older `Letty.app` packages and their different features and gates. Real Linux
X11/VDI/IME acceptance remains separate from the macOS preview.
