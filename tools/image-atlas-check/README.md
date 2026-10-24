# Image-atlas initialization regression

Use Zig 0.17.0 from the Letty repository root. Build serially:

```sh
ZIG_GLOBAL_CACHE_DIR=.cache/zig-global zig build --build-file tools/image-atlas-check/build.zig --prefix "$PWD/.cache/image-atlas-check/native" -j4
python3 tools/verify-image-atlas.py --prefix .cache/image-atlas-check/native --label native
ZIG_GLOBAL_CACHE_DIR=.cache/zig-global zig build --build-file tools/image-atlas-check/build.zig -Dportable=true --prefix "$PWD/.cache/image-atlas-check/portable" -j4
python3 tools/verify-image-atlas.py --prefix .cache/image-atlas-check/portable --label portable
```

The runner uses a private temporary HOME and an owned hidden window. It does not
post system events, use the system clipboard, show windows or capture the user's
screen. Metal device access is required even for the macOS portable Surface;
the portable Tester itself uses CPU rasterization. Logs and input/binary hashes
are under `.cache/verification/image-atlas-*.{log,json}`. These are isolated
framework receipts, not whole-application or target X11/VDI acceptance.

The check starts with one PNG and adds two different PNGs on later frames. It
samples actual rendered pixels after each change and after subsequent frames.
It covers the real native Surface's reentrant creation frames, the legacy late
sink binding with retained CPU pixels, an unsynced CPU atlas migrated to a sink,
and the portable CPU renderer. It never resets the Images object to hide the
transition. The migration case is native-only.

Before `nanoui-05-image-sink-lifetime.patch`, the real hidden Surface rendered
three creation frames before the sink was bound, retained a 16 MiB CPU atlas,
and lost every later PNG when stale CPU rows overwrote direct GPU uploads.
The captured pre-fix run had 9 failures in 14 assertions. The fixed native run
has 15 passing assertions, including explicit migration-storage release; the
portable run has 11. Original pre-fix receipt hashes remain unchanged.

The same fixture cross-builds for `x86_64-linux.3.10-gnu.2.17` (baseline CPU,
ReleaseSafe) and Windows. The Linux ELF audit reports GLIBC 2.17 as the maximum
required version. The framework Counter/Gallery examples also compile for the
iOS simulator after the bundled Zig stdlib workaround; they are not launched.
No Docker executable is available on this host, so Linux runtime checks were
not run. See `.cache/verification/image-atlas-cross-build.json` and
`image-atlas-linux-abi.json` for the isolated build scope.
