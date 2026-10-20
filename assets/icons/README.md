# Letty application icon

An original short-haired character portrait uses black/white outlines, warm paper-white, and dark-green hair clips to match Letty's Paper theme. The visual direction references the user's preferred Hermes Agent character icon.

`letty-master.png` is the selected production master: an anime-style portrait without glasses, with transparent outer padding and a rounded backing. Superseded alternate masters have been removed from the active asset directory.

- `Letty.icns`: macOS icon used by `tools/package-macos.py`.
- `hicolor/{size}x{size}/apps/letty.png`: Linux PNGs at 16, 24, 32, 48, 64, 128, 256, 512, and 1024 pixels; packaged under `share/icons/hicolor/`.
- `prompt.txt`, `prompt-v2.txt`, `prompt-v3.txt`: retained generation/edit provenance, using built-in imagegen without API/CLI fallback. Historical prompt variants do not imply alternate production assets are shipped.

After editing the master on macOS, run `python3 tools/prepare-icon.py`, then `python3 tools/package-macos.py`. Linux packaging uses exported PNGs without macOS tools.
