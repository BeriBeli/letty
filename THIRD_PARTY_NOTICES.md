# Third-party notices

Letty uses the following upstream projects. Dependency revisions, source hashes and download locations are pinned in [deps.lock.json](deps.lock.json) and [tools/shaper-dependency.json](tools/shaper-dependency.json).

| Component | Source and license |
| --- | --- |
| nanoui | [justrach/nanoui](https://github.com/justrach/nanoui), MIT |
| Ghostty native VT | [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty), MIT |
| HarfBuzz | [harfbuzz/harfbuzz](https://github.com/harfbuzz/harfbuzz); see its `COPYING` notice in the pinned source |
| Maple Mono Normal NL NF CN | [Maple Mono 7.9](https://github.com/subframe7536/maple-font/releases/tag/v7.9), [included SIL Open Font License](assets/fonts/LICENSE.txt) |
| Lucide UI icons | [Lucide 0.468.0](https://github.com/lucide-icons/lucide/tree/0.468.0), [included license](src/ui_icons/assets/LICENSE) |
| Material Icon Theme language icons | [pinned source](https://github.com/material-extensions/vscode-material-icon-theme/tree/13025adc5ad10a5cc649528a2c1edec93069f1b9), [included MIT license](src/ui_icons/languages/LICENSE) |

Bootstrap downloads upstream source with its license notices. Packaging includes the notices from the actual dependency sources used by the build. The SVG originals, rendered icons and language-icon inventory are retained under `src/ui_icons/`; see the [regeneration instructions](src/ui_icons/README.md).

The application icon has separate [asset provenance](assets/icons/README.md). Third-party licenses apply to their respective components.
