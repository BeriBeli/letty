# Development tools

Run commands from the repository root with exactly Zig 0.17.0 and Python 3.
The [contribution guide](../CONTRIBUTING.md) describes the standard verification
sequence; the [documentation index](../docs/README.md) identifies current guides.

## Current build and verification

| Tool | Purpose |
| --- | --- |
| `bootstrap.py` | Verify/fetch locked source and toolchain archives, replay active patches and verify fonts |
| `build.py` | Build native or baseline Linux binaries; run applicable unit, local-PTY and document suites |
| `verify-ui.py` | Verify the current application using private files/clipboards and owned hidden windows |
| `audit-elf.py` | Audit Linux architecture, loader, dependency versions and RPATH |
| `verification.py` | Internal source/binary/log hashing and evidence records |
| `build-shaper.py` | Build the pinned HarfBuzz CPU-shaping adapter |
| `verify-svn.py` | Test production SVN jobs against private offline repositories; optional current-app UI route |
| `verify-image-atlas.py` | Verify the isolated nanoui image-atlas fixture |
| `package-port-preview.py` | Package a currently verified macOS development preview |

`document-check/` is the separate native document-test root used by `build.py`.
`image-atlas-check/` is an isolated renderer fixture. `native-vt-probe/` retains
its own documented standalone VT build. Keep builds serial and leave sources
stable throughout verification.

Examples, after bootstrap:

```sh
python3 tools/build.py --native --skip-bootstrap --zig=/absolute/path/to/zig
python3 tools/verify-ui.py --prefix=native
python3 tools/verify-svn.py --zig=/absolute/path/to/zig
```

Use `xvfb-run -a` around Linux UI checks on headless hosts. Native macOS UI checks
require a GUI session and Metal access. Fixtures spawn/reap their own children.

## Asset and dependency maintenance

| Tool | Purpose |
| --- | --- |
| `compile-themes.py` | Compile the Ghostty-pinned theme catalog |
| `compile-detection.py` | Compile pinned detection rules into bounded Zig NFA data |
| `render-ui-icons.py` | Regenerate current interface and language icons from retained SVG sources |
| `generate-rex-backdrop.py` | Regenerate the retained UI background washes |
| `prepare-icon.py` | Prepare the application icon from its master |
| `font_assets.py` | Verify the locked bundled font files |
| `patch_nanoui.py`, `patch_ghostty.py` | Replay pinned dependency patches |

Read [asset provenance](../src/ui_icons/README.md), [third-party notices](../THIRD_PARTY_NOTICES.md)
and [the active patch chains](../patches/README.md) before regenerating resources.

## Preceding implementation tooling

Other release, feature, startup, shell-integration and measurement helpers retain
their historical contracts. In particular, `verify-native-release.py`,
`package.py`, `package-macos.py`, `verify-features.py`, the `settings-check/`,
`preview-check/` and `m9-native-check/` roots are not the current default pipeline.
Their expected binaries/build steps may belong to an older source snapshot.
Use the [historical index](../docs/archive/README.md) and the matching recorded
source for reproducing that work. The current Linux release workflow explicitly
blocks packaging; see [release status](../docs/github-releases.md).

Build caches are local. Historical receipts, failure logs, performance data,
release packages and `.cache/recovery/` are evidence/recovery materials and must
retain their recorded identities during cleanup.
