# Contributing

Letty uses exactly Zig 0.17.0 and Python 3. Read [AGENTS.md](AGENTS.md), the [architecture](docs/architecture.md), and the [documentation index](docs/README.md) before changing application ownership or platform integration.

## Build and check

Run from the repository root:

```sh
python3 tools/bootstrap.py
python3 tools/build.py --native --skip-bootstrap
python3 tools/verify-ui.py --prefix=native
```

On headless Linux, run UI checks under `xvfb-run -a`. On macOS, `--native --portable` exercises the portable renderer; use `--prefix=native-portable` for its UI checks.

Build the Linux delivery target and inspect its ABI separately:

```sh
python3 tools/build.py --skip-bootstrap
python3 tools/audit-elf.py zig-out/linux/bin
```

Run builds serially and leave sources unchanged during verification. Test records bind source, executable and log hashes. A cross-build or static ABI audit does not establish target Linux, X11/VDI or IME acceptance.

## Changes

- Preserve the Linux baseline, native Zig VT boundary and pinned dependencies.
- Keep asynchronous operations tied to stable identities and revalidate ownership before applying results.
- Keep session queues, history and active background work bounded. Window and workspace counts grow with system resources.
- Add focused regression coverage for behavioral changes and update the relevant English documentation.
- Reproduce dependency changes through `patches/` and the patch scripts.
- Use isolated fixtures and owned test windows. Preserve original validation receipts and recovery artifacts.

## Repository contents

Source, tests, dependency locks, patches, icon assets and documented validation evidence are versioned. Bootstrap restores upstream source into `vendor/`. `.cache/`, `.zig-cache/`, `zig-pkg/`, `zig-out/` and `dist/` remain local.

Normal GitHub Actions runs build, regression and lifecycle checks and verify a fresh Linux release gate. Version tags invoke the same checks before packaging and publishing GitHub Release assets; see [GitHub releases](docs/github-releases.md). Development previews and historical records are not release approval.
