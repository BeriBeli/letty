#!/usr/bin/env python3
"""Isolated N0 build/run/ABI evidence. Never builds or changes Letty itself."""
import argparse
import datetime
import hashlib
import json
import os
import platform
import shlex
import subprocess
from pathlib import Path

PROJECT = Path(__file__).resolve().parent
ROOT = PROJECT.parents[1]
OUT = ROOT / ".cache/native-vt-probe"
REVISION = "5064b3265e500d55f5f44ff48ca59b8685543bb8"
SOURCE_EXCLUDES = {"zig-pkg", "__pycache__", ".zig-cache", "zig-out"}


def probe_sources():
    return [path for path in PROJECT.rglob("*") if path.is_file()
            and not SOURCE_EXCLUDES.intersection(path.relative_to(PROJECT).parts)
            and path.suffix in (".zig", ".zon", ".py", ".md")]


def digest(paths):
    hasher = hashlib.sha256()
    for path in sorted(paths):
        hasher.update(path.relative_to(ROOT).as_posix().encode() + b"\0")
        hasher.update(path.read_bytes())
    return hasher.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--zig", default=os.environ.get("ZIG", "/opt/homebrew/bin/zig"))
    parser.add_argument("--only", choices=["native", "linux"])
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    version = subprocess.check_output([args.zig, "version"], text=True).strip()
    if version != "0.17.0":
        raise RuntimeError("Requires exactly Zig 0.17.0")
    lock = json.loads((ROOT / "deps.lock.json").read_text())
    if lock["sources"]["ghostty"]["revision"] != REVISION:
        raise RuntimeError("Requires the locked Ghostty commit; no upstream upgrades")
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
            target = [] if name == "native" else ["-Dtarget=x86_64-linux.3.10-gnu.2.17", "-Dcpu=baseline"]
            run([args.zig, "build", "-Doptimize=ReleaseSafe", *target, "--cache-dir", OUT / "cache", "--prefix", prefix, "-j2"], OUT / (name + "-build.log"))
            executable = prefix / "bin/native-vt-probe"
            result = {"artifact": str(executable.relative_to(ROOT)), "artifact_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(), "build": "pass", "execution": "not run"}
            if name == "native":
                output = run([executable], OUT / "native-run.log", ROOT)
                report = next(json.loads(line) for line in reversed(output.splitlines()) if line.startswith('{"suite":'))
                result.update({"execution": "pass", "report": report})
            else:
                run(["python3", ROOT / "tools/audit-elf.py", prefix, "--output", OUT / "linux-abi-audit.json"], OUT / "linux-abi-audit.log", ROOT)
                result["abi"] = json.loads((OUT / "linux-abi-audit.json").read_text())
                if platform.system() == "Linux" and platform.machine() == "x86_64":
                    output = run([executable], OUT / "linux-run.log", ROOT)
                    result.update({"execution": "pass", "report": next(json.loads(line) for line in reversed(output.splitlines()) if line.startswith('{"suite":'))})
                else:
                    result["execution"] = "not run: cross-built x86_64 Linux executable on macOS host"
            results[name] = result
    finally:
        metadata = {
            "stage": "N0", "backend": "isolated native Zig probe; production backend unchanged",
            "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "zig": version, "ghostty": lock["sources"]["ghostty"], "simd": False,
            "module": "official path dependency dep.module(ghostty-vt)",
            "io": "std.process.Init.io; no TinyIo substitution", "optimize": "ReleaseSafe",
            "host": {"system": platform.system(), "machine": platform.machine(), "release": platform.release()},
            "probe_source_sha256": digest(probe_sources()),
            "probe_source_excludes": sorted(SOURCE_EXCLUDES),
            "ghostty_native_source_sha256": digest([ROOT / "vendor/ghostty/build.zig", ROOT / "vendor/ghostty/build.zig.zon", *[p for p in (ROOT / "vendor/ghostty/src").rglob("*.zig")]]),
            "results": results, "commands": commands,
            "limits": ["Not the Letty production backend", "Linux execution and CentOS/VDI acceptance are separate from cross-build/ABI audit", "N0 does not implement clipboard, full render/search/selection or graphics parity"],
        }
        (OUT / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")


if __name__ == "__main__":
    main()
