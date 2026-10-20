"""Pinned, unmodified application font resources; never install system fonts."""
import hashlib
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DIRECTORY = ROOT / ".cache/fonts/maple-mono"


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
    if digest(ROOT / "assets/fonts/LICENSE.txt") != spec["files"]["LICENSE.txt"]:
        raise RuntimeError("Bundled font license differs from the pinned archive")
    return files


def prepare(fetch):
    spec = lock()
    archive = ROOT / ".cache/fonts/MapleMonoNormalNL-NF-CN.zip"
    fetch(spec["url"], spec["sha256"], archive)
    DIRECTORY.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as source:
        for name, expected in spec["files"].items():
            if Path(name).name != name:
                raise RuntimeError("Invalid font archive member")
            path = DIRECTORY / name
            if path.is_file() and digest(path) == expected:
                continue
            data = source.read(name)
            if hashlib.sha256(data).hexdigest() != expected:
                raise RuntimeError("Bundled font checksum mismatch: " + name)
            temporary = path.with_suffix(".tmp")
            temporary.write_bytes(data)
            temporary.replace(path)
    verify()
    print("Verified bundled font:", spec["family"], spec["version"])
