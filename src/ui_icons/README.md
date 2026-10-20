# UI icons

SVG sources are from [Lucide 0.468.0](https://github.com/lucide-icons/lucide/tree/0.468.0/icons).
The upstream ISC/MIT license is preserved in `assets/LICENSE`.

Run `python3 tools/render-ui-icons.py` with `rsvg-convert` installed to regenerate
the checked-in 48-pixel PNGs. These are rasterizations of the SVG sources, not
hand-drawn approximations. Native and portable renderers use the same embedded
assets; normal builds require no SVG parser, network access, or new runtime
library. The two neutral ink variants remain legible in light and dark themes.

## Language icons

File/workspace icons use [Material Icon Theme](https://github.com/material-extensions/vscode-material-icon-theme)
at commit `13025adc5ad10a5cc649528a2c1edec93069f1b9` (MIT). Original SVGs,
the license, color PNG rasterizations, and SHA-256 inventory are in `languages/`.
The same regeneration command covers these assets. Distribution packages include
the upstream license. Filename classification lives in `src/file_type.zig`; it
performs no IO. Shell variants share the console icon, SystemVerilog/Verilog share
the HDL icon, and C/C++ headers have distinct icons. Unknown files keep the neutral
document icon. Language icons indicate filename type, not syntax highlighting.
