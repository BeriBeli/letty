# Isolated native Zig VT probe (N0)

This project uses the official `ghostty-vt` module from the repository's fixed
`vendor/ghostty` path dependency. It does not link the C VT archive or change
Letty's backend. Zig must be exactly 0.17.0; the dependency receives explicit
target/optimization and `simd=false`.

Run from any working directory:

```sh
python3 /absolute/path/to/letty/tools/native-vt-probe/run.py --zig=/opt/homebrew/bin/zig
```

The runner sequentially builds and executes the native probe, then cross-builds
`x86_64-linux.3.10-gnu.2.17` with baseline CPU and audits its ELF. Use `--only
native` or `--only linux` to narrow a rerun. Independent caches, prefixes, build
logs, execution logs, ABI audit, exact commands and backend/source metadata are
written to `.cache/native-vt-probe/`. Cross-build success does not assert Linux
execution; the runner executes Linux only on an x86_64 Linux host.

The heap-owned terminal and stream never move. Effects are explicitly installed
over `.readonly`; callback payloads are copied into bounded owner buffers, and
reply overflow reports failure without partial bytes. Callbacks never feed the
stream. Stream teardown precedes terminal teardown. `std.process.Init.io` is
retained; no TinyIo capability reduction is used. A debug allocator checks that
probe-owned objects are released.

Checks cover ASCII, cell SGR, wide CJK and tail cells, combining characters,
UTF-8 byte-at-a-time input, all split positions through a mixed UTF-8/ANSI/DSR
fixture, alternate screen isolation/restoration, resize/reflow and rejection,
exactly-once DSR and size replies, title/PWD/BEL, semantic prompt/command/exit,
progress, terminal-derived normal/application/Kitty keyboard options, paste
framing/newline policy and focus mode gating. A readonly negative case documents
why importing the module alone does not provide host effects.

This is preparation evidence, not N1/N2 feature parity. It deliberately does not
provide OS clipboard callbacks, search/selection rendering, image integration,
focus deduplication, shell sessions or GUI behavior. Those remain facade/adapter
and full-application acceptance work. Target Linux kernel/runtime and display checks remain
required separately.

`zig-pkg/`, `.zig-cache/`, `zig-out/` and `__pycache__/` inside this isolated
project are generated caches, excluded from the probe source digest and source
delivery. Zig recreates dependency-cache contents from the fixed path dependency
and its locked transitive dependencies; retain the normal global package cache
for offline rebuilds. The runner's authored source manifest excludes these
directories even when they contain `.zig` or `.zon` files.

The separate N2 leaf fixture is run with `python3 tools/native-vt-probe/run-n2.py`
from the repository root. It passes `-Dn2=true`, executes the native fixture,
then cross-builds and audits the old Linux baseline sequentially. Its `n2-*`
logs, prefixes and metadata stay separate from N0. The build copies the three
actual `src/vt_zig/{navigation,selection,search}.zig` leaves into one generated
module so sibling imports have one Zig module identity; these are generated
copies, not separate maintained implementations. Its metadata hashes those
adapter sources as well as the authored probe sources and patched Ghostty tree.
The fixture owns a stable mock host and checks real native search/selection,
allocation refusal, tracked anchor pruning and resource release. Production
facade/core/UI and real shell prompt redraw require their own acceptance.
