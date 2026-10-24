# CI and release status

The current local-terminal rewrite is a development build. Release packaging
is deliberately blocked in `.github/workflows/linux.yml`: when called with
`package: true`, the workflow stops at **Require a completed port release gate**.
A tag is not approval to publish the current implementation.

## Current Linux workflow

`.github/workflows/linux.yml` runs on main-branch pushes, pull requests and manual
runs, and is reusable by the release workflow. It:

1. Restores locked dependencies and exactly Zig 0.17.0.
2. Builds the baseline Linux application and runs applicable local VT/PTY/document tests.
3. Audits the delivery ELF baseline.
4. Runs hidden UI checks under Xvfb, including a `statx` ENOSYS-injected run.
5. Uploads source-bound verification records and test logs, including failed runs.

These checks do not replace real oldest-target Linux, X11/VDI, system IME or
performance acceptance. See [Linux acceptance](linux-testing.md).

## Publishing boundary

`.github/workflows/release.yml` still defines the tag-triggered publish pipeline,
but its dependent Linux job currently fails at the explicit packaging gate.
Before enabling publication, implement and validate a release gate and packaging
contract for the current runtime, including consistent CLI/lockfile/package
versions, notices, runtime assets and source/binary/log-bound evidence.

`tools/package-port-preview.py` packages a locally verified macOS developer
preview. It does not satisfy a distribution release gate. Historical
`tools/verify-native-release.py`, `tools/package.py` and `tools/package-macos.py`
retain their preceding executable/suite contract and must not be used as a
current release claim.

The [preceding release guide](archive/github-releases-pre-runtime.md),
[release records](archive/README.md#releases-and-validation) and
[runtime-package template](runtime-package.md) remain available for historical
packages. Preserve their hashes, logs and source identity when comparing them.
