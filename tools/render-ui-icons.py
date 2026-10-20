#!/usr/bin/env python3
"""Regenerate checked-in portable icon PNGs from the pinned Lucide SVG sources.

Requires rsvg-convert (librsvg) only when regenerating assets, not when building
or running Letty. Both renderers consume the same 3x source images.
"""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "src/ui_icons/assets"
for source in sorted(ASSETS.glob("*.svg")):
    for variant, color in (("ink", "#282b25"), ("light", "#efeee8")):
        svg = source.read_text().replace('stroke="currentColor"', f'stroke="{color}"')
        subprocess.run(
            ["rsvg-convert", "-w", "48", "-h", "48", "-o",
             str(source.with_name(source.stem + "-" + variant + ".png"))],
            input=svg.encode(), check=True,
        )
print("Regenerated portable icon assets.")

# Language icons keep their upstream colors.
for source in sorted((ROOT / "src/ui_icons/languages").glob("*.svg")):
    subprocess.run(["rsvg-convert", "-w", "48", "-h", "48", "-o", str(source.with_suffix(".png")), str(source)], check=True)
