#!/usr/bin/env python3
"""Isolated native graphics evidence; never builds or switches Letty itself."""
import argparse
import datetime
import hashlib
import json
import os
import platform
import re
import shlex
import subprocess
from pathlib import Path

PROJECT = Path(__file__).resolve().parent
ROOT = PROJECT.parents[2]
OUT = ROOT / ".cache/native-graphics"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--zig", default="/opt/homebrew/bin/zig")
    parser.add_argument("--only", choices=["native", "linux"])
    args = parser.parse_args()
    version = subprocess.check_output([args.zig, "version"], text=True).strip()
    if version != "0.17.0":
        raise RuntimeError("Exactly Zig 0.17.0 is required")
    OUT.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / ".cache/zig-global"))
    commands = []
    results = {}

    def run(command, log_path, cwd=PROJECT):
        text = shlex.join(map(str, command))
        print("+", text, flush=True)
        commands.append({"cwd": str(cwd), "command": text, "log": str(log_path.relative_to(ROOT))})
        with log_path.open("w") as log:
            log.write("cwd: " + str(cwd) + "\n+ " + text + "\n")
            log.flush()
            process = subprocess.run(list(map(str, command)), cwd=cwd, env=env, text=True, stdout=log, stderr=subprocess.STDOUT)
        output = log_path.read_text()
        print(output, end="", flush=True)
        process.check_returncode()
        return output

    try:
        for name in ([args.only] if args.only else ["native", "linux"]):
            prefix = OUT / name
            flags = [] if name == "native" else ["-Dtarget=x86_64-linux.3.10-gnu.2.17", "-Dcpu=baseline"]
            run([args.zig, "build", "-Doptimize=ReleaseSafe", *flags, "--cache-dir", OUT / "cache", "--prefix", prefix, "-j2"], OUT / (name + "-build.log"))
            binary = prefix / "bin/native-graphics-check"
            value = {"build": "pass", "artifact": str(binary.relative_to(ROOT)), "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "execution": "not run"}
            if name == "native":
                text = run([binary], OUT / "native-run.log", ROOT)
                match = re.search(r"All (\d+) native graphics checks passed\.", text)
                if not match:
                    raise RuntimeError("Missing actual graphics check result")
                value.update({"execution": "pass", "checks": int(match.group(1))})
            else:
                run(["python3", ROOT / "tools/audit-elf.py", prefix, "--output", OUT / "linux-abi-audit.json"], OUT / "linux-abi.log", ROOT)
                value["abi"] = json.loads((OUT / "linux-abi-audit.json").read_text())
                value["execution"] = "not run: cross-built on macOS; CentOS/VDI acceptance pending"
            results[name] = value
    finally:
        sources = [ROOT / "src/vt_native_graphics.zig", ROOT / "src/vt_native_graphics_check.zig", ROOT / "src/vt_native_graphics/budget.zig", ROOT / "src/graphics_png.zig", ROOT / "src/graphics_model.zig", PROJECT / "build.zig", PROJECT / "build.zig.zon", Path(__file__)]
        digest = hashlib.sha256()
        for source in sorted(sources):
            digest.update(source.relative_to(ROOT).as_posix().encode() + b"\0" + source.read_bytes())
        metadata = {
            "stage": "N2 native graphics isolated adapter fixture; GUI/backend not switched",
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "zig": version, "ghostty": json.loads((ROOT / "deps.lock.json").read_text())["sources"]["ghostty"],
            "source_sha256": digest.hexdigest(), "simd": False, "io": "std.process.Init.io",
            "host": {"system": platform.system(), "machine": platform.machine()},
            "results": results, "commands": commands,
            "limits": ["Snapshots own values/pixels and no Pins", "64MiB allocator is tracked heap requests, not RSS/mmap", "Direct medium only; real Io retained", "No native GUI graphics claim", "Linux execution and CentOS/VDI remain pending"],
        }
        (OUT / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")


if __name__ == "__main__":
    main()
