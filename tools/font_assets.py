"""Pinned, unmodified application font resources; never install system fonts."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIRECTORY = ROOT / "assets/terminal/fonts"


def lock():
    return json.loads((ROOT / "deps.lock.json").read_text())["bundled_font"]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify():
    spec = lock()
    files = []
    for name, expected in spec["files"].items():
        if Path(name).name != name:
            raise RuntimeError("Invalid font resource name")
        path = DIRECTORY / name
        if not path.is_file() or digest(path) != expected:
            raise RuntimeError("Missing or changed bundled font: " + name + "; run bootstrap")
        files.append(path)
    return files


def prepare(fetch):
    # The pinned Kero font files are versioned with this source tree.
    # Bootstrap verifies them without downloading a different font family.
    del fetch
    verify()
    spec = lock()
    print("Verified bundled font:", spec["family"], spec["version"])
