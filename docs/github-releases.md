# GitHub releases

Releases are built and published entirely by GitHub Actions. No locally built binary is uploaded.

## Publishing a version

1. Update `app_version` in `deps.lock.json`, the CLI version in `src/app.zig`, and `docs/releases/X.Y.Z.md`.
2. Commit and push the changes. The ordinary Linux workflow runs the same build and verification steps.
3. After those checks pass, push an annotated `vX.Y.Z` tag pointing at the release commit.

`.github/workflows/release.yml` calls the reusable Linux workflow at that tag. The runner checks out the exact commit, restores pinned sources, builds the explicit Linux delivery target, and generates fresh source/binary/log-bound verification records.

`tools/verify-native-release.py --linux-ci` requires the current runner's build manifest, all eight suite records and complete UI feature batches, VT goldens, configuration CLI checks, GTK smoke evidence, 20 startup/restore launches, 256 stress cycles, engine symbols, dependency notices and ABI audit. It records its commit and workflow run; packaging rejects another run's gate or modified materials.

This Linux gate is distinct from the historical combined macOS development/recovery gate. The latter remains available through the existing verifier modes. Linux publication does not claim macOS appearance, historical C recovery, the oldest supported Linux environment, VDI or IME acceptance.

Packaging requires agreement between the tag, lockfile version and actual executable version. It produces:

- `letty-X.Y.Z-linux-x86_64.tar.gz`
- `letty-X.Y.Z-source.tar.gz`
- `SHA256SUMS`

The build job has read-only repository permissions. Only the dependent publish job receives `contents: write`; it downloads the artifacts from the same workflow run and rechecks their hashes. It creates a draft, uploads all assets, then publishes the release. It refuses to replace an already published release. An interrupted draft upload can be retried with GitHub Actions' rerun controls.

The runtime package retains executable permissions, shell integration, icons, configuration examples, documentation, dependency licenses, build metadata and its own per-file checksum manifest. Users can extract and run `bin/letty` directly or use `tools/install-user.sh` for a versioned user-directory installation.
