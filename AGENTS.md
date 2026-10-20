# Letty agent guide

Letty is a Zig terminal application using nanoui and Ghostty's native `ghostty-vt` module. Start with [README.md](README.md), [architecture](docs/architecture.md), and the [documentation index](docs/README.md).

## Project map

- `src/app.zig`, `app_state.zig`, `application_*.zig`: application/window ownership and actions.
- `src/session.zig`, `vt.zig`, `vt_zig/`: PTY lifecycle and native VT integration.
- `src/terminal_*.zig`, `workspace_view.zig`: rendering and workspace UI.
- `src/config*.zig`, `settings/`, `navigation/`, `preview/`: configuration and feature modules.
- `src/platform/`: C interfaces for PTYs, files, GTK/X11, and macOS services.
- `tools/`, `tests/`: build, regression, packaging, and acceptance tooling.
- `patches/`, `deps.lock.json`: reproducible changes to pinned dependencies.

## Build and verify

Use **exactly Zig 0.17.0** and Python 3. Run commands from the repository root:

```sh
python3 tools/bootstrap.py
python3 tools/build.py --native --skip-bootstrap
python3 tools/verify-ui.py --prefix=native
```

`build.py` runs host unit/core/VT suites; `verify-ui.py` runs hidden UI checks. Pass `--zig=/path/to/zig` to the build script when using an existing compiler. On headless Linux, run UI checks under `xvfb-run -a`.

```sh
python3 tools/build.py --skip-bootstrap
python3 tools/audit-elf.py zig-out/linux/bin
```

The second sequence builds the Linux delivery target. On macOS, it cross-compiles without executing Linux binaries. `--native --portable` exercises the portable renderer on macOS. Run builds serially and keep source stable during verification: manifests and logs are bound to source hashes.

For an interactive macOS preview, use `./script/build_and_run.sh`; it builds, checks, packages, and launches the app. Build outputs live in `zig-out/`, evidence in `.cache/verification/`, and packages in `dist/`. Distribution additionally requires `tools/verify-native-release.py`; consult its `--help` and the release docs.

## Constraints

- Preserve `x86_64-linux.3.10-gnu.2.17`, baseline CPU, ReleaseSafe, and VT SIMD disabled. Runtime requirements are in [compatibility](docs/compatibility.md); support is defined by interfaces/library versions, not a distribution name.
- Keep the native Zig VT boundary. Platform C remains intentional; the former C VT backend is retained only as a recovery archive.
- Use stable IDs for deferred actions; revalidate ownership/generation before execution. Keep PTY queues, history, and background work bounded. Copy borrowed VT text before retaining it.
- Windows, workspaces, split panes and PTYs use dynamic storage with no fixed count ceiling. Preserve stable ownership, transactional failure handling, and bounded per-session history/input and active background work.
- Keep dependency versions pinned. Make vendor changes reproducible through `patches/` and the patch scripts; follow nested `AGENTS.md` instructions when editing vendor code.
- Keep maintained documentation in English. Update relevant feature/configuration docs when behavior changes.
- Use isolated temporary files, private clipboard fixtures, and owned hidden windows for tests. PTY tests need permission to spawn/reap their own children.
- Historical receipts, logs, and recovery packages certify their recorded source only. Generate fresh evidence after code changes; preserve original hashes. Cross-build/ABI success does not establish target Linux, X11/VDI, or IME acceptance.
- Inspect the working tree before editing: other chats may share this checkout. Preserve unrelated changes and recovery artifacts; avoid broad cleanup commands.
