# GitHub releases

Releases are built and published entirely by GitHub Actions. No locally built binary is uploaded.

## Publishing a version

1. Update `app_version` in `deps.lock.json`, the package version in `build.zig.zon`, the CLI version in `src/app.zig`, and `docs/releases/X.Y.Z.md`. macOS bundle metadata follows the lockfile version.
2. Commit and push the changes. The ordinary Linux workflow runs the same build and verification steps.
3. After those checks pass, push an annotated `vX.Y.Z` tag pointing at the release commit.

`.github/workflows/release.yml` calls the reusable Linux workflow at that tag. The runner checks out the exact commit, restores pinned sources, builds the explicit Linux delivery target, and generates fresh source/binary/log-bound verification records.

`tools/verify-native-release.py --linux-ci` requires the current runner's build manifest, all eight suite records and complete UI feature batches, VT goldens, configuration CLI checks, GTK smoke evidence, 20 startup/restore launches, 256 stress cycles, engine symbols, dependency notices and ABI audit. It records its commit and workflow run; packaging rejects another run's gate or modified materials.

This Linux gate is distinct from the historical combined macOS development/recovery gate. The latter remains available through the existing verifier modes. Linux publication does not claim macOS appearance, historical C recovery, the oldest supported Linux environment, VDI or IME acceptance.

Packaging requires agreement between the tag, lockfile version and actual executable version. It produces:

- `letty-X.Y.Z-linux-x86_64.tar.gz`
- `SHA256SUMS`

Source downloads use GitHub's automatic ZIP and tar.gz archives of the tag. They
include authored code, dependency locks and patches; bootstrap restores pinned
dependencies. No duplicate custom source archive is uploaded. Local diagnostic
packaging without `--version` retains its source snapshot and test tools.

The build job has read-only repository permissions. Only the dependent publish job receives `contents: write`; it downloads the artifacts from the same workflow run and rechecks their hashes. It creates a draft, uploads all assets, then publishes the release. It refuses to replace an already published release. An interrupted draft upload can be retried with GitHub Actions' rerun controls.

The runtime package contains only `bin/letty`, fonts, shell integration, icons,
configuration examples, install/rollback/uninstall scripts, a runtime README, dependency
licenses, compact `build-info.json`, `abi-audit.json` and per-file `SHA256SUMS`.
It excludes test/probe executables, historical screenshots, full development docs
and duplicated verification JSON. The unchanged full CI release gate runs before
packaging; its complete records and logs are uploaded as the workflow's evidence
artifact. Build metadata links to that workflow. Upload and publication use the
exact versioned archive name so unrelated local archives cannot become assets.

Users can extract and run `bin/letty` directly or use `tools/install-user.sh` for a
versioned installation under `~/.local/share/letty`, with the command symlink at
`~/.local/bin/letty`. Upgrades and rollbacks switch the version behind that link.
`tools/uninstall-user.sh` removes installed versions and their launcher while
preserving configuration and saved layouts.
