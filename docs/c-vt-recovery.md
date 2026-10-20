# C VT baseline recovery

Active builds use native Zig only. The separate `letty-vt-c-recovery-9b2f19589436.tar.gz`, matching `.wholearchive.sha256`, and `.README.txt` retain the C baseline.

These are local development recovery artifacts in `dist/`, excluded from the public source repository. The instructions below apply when that archive is available; ordinary builds use the pinned native Zig dependencies and do not require it.

Whole-archive SHA256: `58a9b6af2a6dcc0513236a8c05f2b62df79c584719d921c2171fdf63c8fc4ceb`.

The archive contains complete authored source, macOS C binaries, seven baseline Linux 3.10/glibc 2.17 C binaries, shell resources, raw validation logs, and per-file checksums. Linux was cross-built/statically audited; target execution/display/IME remain pending.

Verify before extracting into a new directory:

```sh
sha256sum -c letty-vt-c-recovery-9b2f19589436.tar.gz.wholearchive.sha256
# On macOS, use shasum -a 256 -c with the same manifest.
tar -xzf letty-vt-c-recovery-9b2f19589436.tar.gz
cd letty-vt-c-recovery-9b2f19589436
sha256sum -c SHA256SUMS
```

On a compatible Linux host, run without Zig/Python:

```sh
sh linux/run-c.sh verify
sh linux/run-c.sh probe
sh linux/run-c.sh fullfixture
# Within the target DISPLAY session:
sh linux/run-c.sh ui
sh linux/run-c.sh gui
```

The script verifies payloads and actual C-backend reporting. GUI uses temporary configuration. `source/` retains the complete C build; see archived RESTORE.txt. `--vt-backend=c` exists only in that independent source.

An actual offline restore in a new spaced path reconstructed vendor from locked archives and copied seven dependency source directories. Zig 0.17.0 with fresh caches passed C build, 26 unit/46 core/161 hidden UI/9 replay/24 N2/56 protocol checks. The authored manifest matched the archive. This proves local source recovery, not target Linux execution. Original report: `.cache/verification/n4-c-recovery-restore.json`.
