# Bundled terminal font

Letty ships unmodified Maple Mono Normal NL NF CN 7.9 fonts in Regular, Bold,
Italic and BoldItalic styles, including CJK and Nerd Font glyphs.

The official release archive and each selected member are SHA-256 pinned in
`deps.lock.json`. `tools/bootstrap.py` downloads and verifies the archive, then
extracts only the selected faces and license into `.cache/fonts/maple-mono/`.
Font binaries are build resources and are not duplicated in Git.

The build installs them in `share/letty/fonts/`. Linux archives retain that
directory; macOS packages use `Letty.app/Contents/Resources/fonts/`. The portable
renderer loads these resources directly and macOS registers them only for the
application process. There is no system-font installation or runtime download.

Custom configured system font families remain supported. Other fonts can still
supply glyphs outside the bundled family's coverage.

Source: [Maple Mono v7.9](https://github.com/subframe7536/maple-font/releases/tag/v7.9).
The original [SIL Open Font License](LICENSE.txt) accompanies every package.
