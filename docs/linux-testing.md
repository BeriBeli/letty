# Linux acceptance checklist

Use a Linux host meeting the [runtime baseline](compatibility.md). Record the
exact source, binaries, logs, display connection and input-method environment.
Cross-builds and ABI audits cover different evidence from real GTK/X11/VDI use.

## Build and automated checks

Use exactly Zig 0.17.0 and Python 3, from the repository root:

```sh
python3 tools/bootstrap.py
python3 tools/build.py --skip-bootstrap
python3 tools/audit-elf.py zig-out/linux/bin --output .cache/verification/linux-abi.json
python3 tools/verify-ui.py --prefix=linux
```

On a headless machine, wrap the UI command with `xvfb-run -a`. On x86_64 Linux,
the build script executes the unit suite and private local-PTY suite, and builds
and runs the document suite. On macOS it cross-compiles the Linux executables
without running them. Main binaries are `letty`, `letty-local-check` and
`letty-unit-tests`; the document suite is built separately.

The target remains `x86_64-linux.3.10-gnu.2.17`, baseline CPU, ReleaseSafe and
Ghostty SIMD disabled. Keep `zig-out/linux/share/letty/terminal/` with the binary;
it includes the bundled JetBrainsMono Nerd Font. The current development CI
records ABI and hidden-window checks, including `statx` ENOSYS injection.

For a GUI launch from the checkout:

```sh
zig-out/linux/bin/letty
```

## Target and display acceptance

Run the same built application on the actual supported kernel/library environment,
then repeat through the intended X11 forwarding or VDI setup. Retain failures
and measured results for each environment.

- Launch, resize, close and reopen windows and dynamic workspaces/split panes.
- Exercise Unicode/CJK/combining text, selection, history, clipboard, TUI input and mouse reporting.
- Exercise the actual system IME: preedit, candidate placement, commit/cancel and focus changes in terminals and document fields.
- Check sustained PTY output, idle CPU, scrolling and repaint latency over the real display connection.
- Check Git/SVN Changes, document/image helpers, file-drop routes and native notifications where supported.
- Verify owned child reaping and descriptor cleanup after normal close and failure paths.

Hidden tests use private clipboards and synthetic text input; they do not certify
system clipboard integration, real IME composition or native drag/drop.
Record oldest-target execution, target services and performance separately.

## Releases and historical tools

The current rewrite is a development build. The Linux workflow deliberately
blocks release packaging until a current release gate is implemented; see
[CI and release status](github-releases.md). Do not infer current acceptance
from a previous `dist/` package or receipt.

The [preceding Linux checklist](archive/linux-testing-pre-runtime.md) describes
older probe binaries and runtime packages. `tools/test-centos.sh` and `el7`
artifact names remain historical identifiers and impose no distribution requirement.
