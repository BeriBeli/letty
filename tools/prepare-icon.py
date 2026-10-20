#!/usr/bin/env python3
"""Export the checked-in Letty artwork using macOS system image tools."""
import platform
import struct
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ICONS = ROOT / "assets/icons"


def resize(source, target, size):
    target.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["sips", "-z", str(size), str(size), str(source), "--out", str(target)],
        check=True, stdout=subprocess.DEVNULL,
    )


def main():
    if platform.system() != "Darwin":
        raise SystemExit("Run on macOS; pre-exported PNG and ICNS files are included for other hosts.")
    source = ICONS / "letty-master.png"
    for size in (16, 24, 32, 48, 64, 128, 256, 512, 1024):
        resize(source, ICONS / f"hicolor/{size}x{size}/apps/letty.png", size)
    # PNG-backed ICNS representations, including Retina slots. Writing the
    # container directly also works where iconutil's encoder is unavailable.
    representations = (
        (b"icp4", 16), (b"icp5", 32), (b"icp6", 64),
        (b"ic07", 128), (b"ic08", 256), (b"ic09", 512), (b"ic10", 1024),
        (b"ic11", 32), (b"ic12", 64), (b"ic13", 256), (b"ic14", 512),
    )
    chunks = []
    for tag, size in representations:
        png = (ICONS / f"hicolor/{size}x{size}/apps/letty.png").read_bytes()
        chunks.append(tag + struct.pack(">I", len(png) + 8) + png)
    payload = b"".join(chunks)
    (ICONS / "Letty.icns").write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)
    print("Exported Letty.icns and Linux hicolor PNGs (16–1024 px).")


if __name__ == "__main__":
    main()
