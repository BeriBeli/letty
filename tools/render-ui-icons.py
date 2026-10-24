#!/usr/bin/env python3
"""Rasterize current interface and language SVGs for both nanoui renderers.

Requires rsvg-convert only for regeneration. Source pins and licenses are
recorded in src/ui_icons/README.md and THIRD_PARTY_NOTICES.md.
"""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    interface = ROOT / "src/ui_icons/interface"
    for source in sorted(interface.glob("*.svg")):
        for variant, color in (("ink", "#1d1d1f"), ("light", "#ececf0")):
            svg = (source.read_text().replace("currentColor", color)
                   .replace("onColor", "#ffffff" if variant == "ink" else "#161618")
                   .replace("attentionColor", "#c27b0f" if variant == "ink" else "#f0a33a")
                   .replace("dangerColor", "#d93a35" if variant == "ink" else "#ff6961"))
            subprocess.run(["rsvg-convert", "-w", "48", "-h", "48", "-o",
                            str(source.with_name(source.stem + "-" + variant + ".png"))],
                           input=svg.encode(), check=True)
    for source in sorted((ROOT / "src/ui_icons/languages").glob("*.svg")):
        subprocess.run(["rsvg-convert", "-w", "48", "-h", "48", "-o",
                        str(source.with_suffix(".png")), str(source)], check=True)
    print("Regenerated current interface and language icons.")


if __name__ == "__main__":
    main()
