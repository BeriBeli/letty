# Dependency patches

Bootstrap applies only the sorted `nanoui-*.patch` files directly in this
directory, against the immutable fork archive in `deps.lock.json`.
`tools/patch_nanoui.py` validates the complete chain on temporary copies before
changing vendor, and supports a previously applied prefix. Run bootstrap again
to check idempotency. Never edit vendor without updating and replaying its patch.

The active nanoui chain is:

1. `nanoui-01-font-grid-memory.patch`: compatible font I/O, bounded cluster
   fallback, terminal cell shaping, shared font sources and frame arena recovery.
2. `nanoui-02-native-input-atlas.patch`: mouse/modifier/scroll input, explicit
   text-editing ownership, Shift menu accelerators and glyph atlas lifetime.
3. `nanoui-03-gtk3-x11.patch`: the GTK 3 CPU/X11 surface, ordered owned IME
   delivery, font-point conversion and coalesced damage presentation.
4. `nanoui-04-cpu-damage.patch`: bounded backing/damage tracking, volatile-frame
   invalidation and opaque-fill optimization over the upstream threaded raster.
5. `nanoui-05-image-sink-lifetime.patch`: bind Metal image sinks before native
   view callbacks, migrate preexisting CPU atlas pixels on binding, and prevent
   stale CPU rows from overwriting direct GPU uploads.

The original 29 patches for nanoui v0.4.0 are retained byte-for-byte under
`archive/nanoui-v0.4.0/`, with `sha256.json`. They are historical inputs, not an
additional active chain. Do not apply them to v0.6.4 or remove the active chain
assuming the fork already contains it: the pinned fork has documentation changes
only. The [patch review](../docs/nanoui-fork-patch-review-2026-10-23.md) records
each original patch's disposition and the remaining acceptance boundaries.

The Ghostty pin remains independent. `tools/patch_ghostty.py` replays its
separate idempotent chain: `ghostty-01-osc-allocation-lifetime.patch` repairs
OSC capture ownership and failure fallback; `ghostty-02-native-grapheme-stream.patch`
exposes Ghostty's existing Zig grapheme break state, break function and width
effect kernel. The latter adds no segmentation tables or alternate VT backend;
it lets the bounded editor consume long clusters without a fixed lookahead.
