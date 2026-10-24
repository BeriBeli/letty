# Third-party notices

Letty uses the following upstream projects. Dependency revisions, source hashes and download locations are pinned in [deps.lock.json](deps.lock.json) and [tools/shaper-dependency.json](tools/shaper-dependency.json).

| Component | Source and license |
| --- | --- |
| nanoui | [BeriBeli/nanoui fork](https://github.com/BeriBeli/nanoui), based on [justrach/nanoui](https://github.com/justrach/nanoui) v0.6.4, MIT; Letty-owned compatibility patches remain under `patches/` |
| Kero UI adaptation | [egoist/kero at 4f6b7e0](https://github.com/egoist/kero/tree/4f6b7e04fb96b928441ca78d1eb35638b3af58ab), [included MIT license](assets/licenses/kero-MIT.txt); palette, Rex wash, sidebar and pane-card presentation ported from mygo to nanoui |
| Framework7 Icons | Kero’s pinned SVGs from [Framework7 Icons](https://github.com/framework7io/framework7-icons), [MIT license](assets/licenses/framework7-MIT.txt) |
| Meteor Icons | Kero’s pinned terminal SVG from [Meteor](https://github.com/zkreations/meteor), [MIT license](assets/licenses/meteor-MIT.txt) |
| Octicons | Kero’s file-diff SVG from [Primer Octicons](https://github.com/primer/octicons), [MIT license](assets/licenses/octicons-MIT.txt) |
| Ghostty native VT | [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty), MIT |
| HarfBuzz | [harfbuzz/harfbuzz](https://github.com/harfbuzz/harfbuzz); see its `COPYING` notice in the pinned source |
| Maple Mono Normal NL NF CN | [Maple Mono 7.9](https://github.com/subframe7536/maple-font/releases/tag/v7.9), [included SIL Open Font License](assets/fonts/LICENSE.txt) |
| Lucide UI icons | [Lucide 0.468.0](https://github.com/lucide-icons/lucide/tree/0.468.0), [included license](src/ui_icons/assets/LICENSE) |
| Material Icon Theme language icons | [pinned source](https://github.com/material-extensions/vscode-material-icon-theme/tree/13025adc5ad10a5cc649528a2c1edec93069f1b9), [included MIT license](src/ui_icons/languages/LICENSE) |

Bootstrap downloads upstream source with its license notices. Packaging includes the notices from the actual dependency sources used by the build. The SVG originals, rendered icons and language-icon inventory are retained under `src/ui_icons/`; see the [regeneration instructions](src/ui_icons/README.md).

The application icon has separate [asset provenance](assets/icons/README.md). Third-party licenses apply to their respective components.
## Kero reference code and resources

The replacement local terminal under `src/runtime/` is adapted from egoist/kero
at `e95cbcc85be5c55dbc47630940257c9982a2a98b`, under the MIT license retained
in `assets/terminal/LICENSE`. Kero icons and locale catalogs retain that attribution.
JetBrains Mono Nerd Font resources are unmodified and retain their SIL Open Font
License in `assets/terminal/fonts/OFL.txt`. Agent-detection manifests originate from
Herdr and retain the separate Apache-2.0 license in
`assets/terminal/manifests/LICENSE`; this source data is not relicensed as MIT.

The historical notices below also cover the retired Letty source retained for
recovery. Their presence does not mean those features ship in the rewrite.

The bundled terminal theme catalog is generated from Ghostty's pinned
`ghostty-themes-release-20261012-151317-d3e95e4.tgz`, containing 771 themes
from [iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes/tree/d3e95e4).
The MIT notice is retained in `assets/terminal/themes-LICENSE`; source filenames and
SHA-256 digests are embedded in `assets/terminal/themes.json`. Regenerate it with
`tools/compile-themes.py`.
