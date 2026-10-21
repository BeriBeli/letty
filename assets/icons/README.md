# Letty application icon

An original short-haired character portrait uses black/white outlines, warm paper-white, and dark-green hair clips to match Letty's Paper theme. The visual direction references the user's preferred Hermes Agent character icon.

`letty-master.png` is the selected production master: an anime-style portrait without glasses, with transparent outer padding and a rounded backing. Superseded alternate masters have been removed from the active asset directory.

- `Letty.icns`: macOS icon used by `tools/package-macos.py`.
- `hicolor/{size}x{size}/apps/letty.png`: Linux PNGs at 16, 24, 32, 48, 64, 128, 256, 512, and 1024 pixels; packaged under `share/icons/hicolor/`.
- `prompt.txt`, `prompt-v2.txt`, `prompt-v3.txt`: retained generation/edit provenance, using built-in imagegen without API/CLI fallback. Historical prompt variants do not imply alternate production assets are shipped.

Linux builds also install the PNGs under their output prefix. Before creating
windows, Letty loads the 256-pixel icon relative to `/proc/self/exe` as GTK's
default window icon, covering terminal and Settings windows even when launched
from an extracted archive. The X11 program class is `Letty`.

`tools/install-user.sh` registers `letty.desktop` in the user's XDG applications
directory. Its executable and icon paths follow the installation's `current`
link, and `StartupWMClass=Letty` matches running windows. Uninstall removes this
entry only when it still points to that installation.

After editing the master on macOS, run `python3 tools/prepare-icon.py`, then `python3 tools/package-macos.py`. Linux packaging uses exported PNGs without macOS tools.
