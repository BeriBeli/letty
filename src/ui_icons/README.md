# UI icons

Current neutral interface controls use retained SVG sources in `interface/`,
with checked-in 48-pixel ink/light PNG variants. `icons.zig` embeds these PNGs
for both the native and portable renderers. Normal builds need no SVG parser,
network request or additional runtime library.

## Sources and licenses

The interface selection was adapted from Kero at
`4f6b7e04fb96b928441ca78d1eb35638b3af58ab`: Framework7 (MIT), Meteor (MIT),
Lucide (ISC/MIT) and Octicons (MIT). Status and window glyphs were adapted from
Kero's MIT-licensed drawing code. Notices are retained in `assets/licenses/`
at the repository root; [third-party notices](../../THIRD_PARTY_NOTICES.md)
identify the source projects. The pinned Lucide 0.468.0 notice is also retained
in `assets/LICENSE` within this directory.

Document lock/ellipsis controls use the retained Lucide sources; the open lock
is a lock-keyhole derivative with an opened shackle. Bell and chevrons-up-down
use the retained interface SVGs. Sources and their notices remain available for
regeneration.

## Language icons

File/workspace icons use [Material Icon Theme](https://github.com/material-extensions/vscode-material-icon-theme)
at commit `13025adc5ad10a5cc649528a2c1edec93069f1b9` (MIT). Original SVGs,
license, color PNGs and the SHA-256 inventory remain in `languages/`.
Filename classification in `src/file_type.zig` performs no I/O. Language icons
indicate filename type, not syntax highlighting.

## Regeneration

With `rsvg-convert` installed, run from the repository root:

```sh
python3 tools/render-ui-icons.py
```

This single entry regenerates interface ink/light variants and colored language
icons from their retained SVGs. Inspect any changed outputs and preserve the
upstream notices. The retired neutral icon set was removed after confirming
that no retained source embeds it; its original bytes are in the
[cleanup recovery record](../../docs/archive/cleanup-2026-10-24.md).
