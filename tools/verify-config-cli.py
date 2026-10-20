#!/usr/bin/env python3
"""Verify --check-config against real isolated files, without opening a window.

No build or GUI launch. All HOME/XDG paths belong to one TemporaryDirectory.
Each command has a five-second deadline, including FIFO refusal; raw output and
source/binary identity are retained in .cache/verification/<prefix>-config-cli.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import time

from verification import ROOT, STORE, code_hash, sha


def require(ok: bool, message: str) -> None:
    if not ok:
        raise RuntimeError(message)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", default="native" if platform.system() == "Darwin" else "linux")
    parser.add_argument("--binary", type=Path, help="Explicit already-built Letty executable")
    args = parser.parse_args()
    require(bool(args.prefix) and all(c.isalnum() or c in "-_" for c in args.prefix), "Unsafe evidence prefix")
    binary = (args.binary or ROOT / "zig-out" / args.prefix / "bin" / "letty").resolve(strict=True)
    before = code_hash()
    binary_sha = sha(binary)
    suite = args.prefix + "-config-cli"
    directory = STORE / suite
    directory.mkdir(parents=True, exist_ok=True)
    checks: list[dict] = []

    with tempfile.TemporaryDirectory(prefix="letty config cli ") as temporary:
        root = Path(temporary).resolve()
        child = root / "child"
        child.mkdir()
        themes = child / "themes"
        themes.mkdir()
        home = root / "home"
        home.mkdir()
        xdg = root / "xdg"
        xdg.mkdir()
        config = root / "config"
        options = child / "options"
        nested = child / "nested"
        day = themes / "day"
        night = themes / "night"
        env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(xdg))
        env.pop("XDG_CONFIG_DIRS", None)
        env.pop("ZDOTDIR", None)

        def write(path: Path, data: str) -> None:
            path.write_text(data, encoding="utf-8")

        def inputs() -> list[dict]:
            result = []
            for p in sorted(root.rglob("*")):
                if p.is_symlink():
                    result.append({"path": str(p.relative_to(root)), "kind": "symlink", "target": os.readlink(p)})
                elif p.is_file():
                    result.append({"path": str(p.relative_to(root)), "kind": "file", "sha256": sha(p)})
                elif p.exists() and not p.is_dir():
                    result.append({"path": str(p.relative_to(root)), "kind": "special"})
            return result

        def run(name: str, path: Path | None, valid: bool, tokens: list[str], absent: list[str] = ()) -> str:
            argv = [str(binary), "--check-config"]
            if path is not None:
                argv.append("--config=" + str(path))
            source_inputs = inputs()
            start = time.monotonic()
            try:
                result = subprocess.run(argv, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, timeout=5, text=True, errors="replace")
                output = result.stdout
            except subprocess.TimeoutExpired as error:
                output = (error.stdout or b"").decode(errors="replace") if isinstance(error.stdout, bytes) else (error.stdout or "")
                (directory / (name + ".log")).write_text(output, encoding="utf-8")
                raise RuntimeError(name + " blocked beyond five seconds") from error
            elapsed = time.monotonic() - start
            log = directory / (name + ".log")
            log.write_text(output, encoding="utf-8")
            require((result.returncode == 0) == valid, f"{name}: unexpected exit {result.returncode}; see {log}")
            require(all(token in output for token in tokens), f"{name}: missing expected output {tokens!r}; see {log}")
            require(all(token not in output for token in absent), f"{name}: unexpected successful/fallback output; see {log}")
            require("panic:" not in output and "leaked [" not in output, f"{name}: runtime failure; see {log}")
            checks.append({"name": name, "status": "passed", "command": argv, "returncode": result.returncode,
                           "elapsed_seconds": elapsed, "timeout_seconds": 5, "log": str(log), "log_sha256": sha(log),
                           "inputs": source_inputs})
            print("PASS CONFIG CLI " + name, flush=True)
            return output

        root_text = "config-file=child/options\nconfig-file=?optional-not-here\nforeground=#123456\nkeybind=ctrl+k>x=text:\\x00\\u{4e2d}\n"
        options_text = "config-file=nested\ntheme=light:themes/day,dark:themes/night\nkeybind-sequence-timeout=175\n"
        write(config, root_text)
        write(options, options_text)
        write(nested, "font-size=17\n")
        write(day, "background=#f0eee0\n")
        write(night, "background=#102030\n")
        expected_sources = [config, options, nested, root / "optional-not-here", day, night]
        output = run("01-nested-optional-and-conditional", config, True,
                     ["Configuration valid:", "config-file", "cached light/dark", "chord sequences", "text/csi/esc"] +
                     ["source: " + str(p) for p in expected_sources])
        require(output.count("source: ") == len(expected_sources), "Source inventory silently omitted or duplicated a resource")

        alias = root / "config alias"
        alias.symlink_to(config)
        run("02-canonical-root-alias", alias, True,
            ["source: " + str(config), "source: " + str(night)], ["source: " + str(alias) + "\n"])

        write(nested, "# invalid included value\nkeybind-sequence-timeout=49\n")
        run("03-semantic-source-and-chain", config, False,
            [str(nested) + ":2", "InvalidSequenceTimeout", str(config) + ":1", str(options) + ":1"], ["Configuration valid:"])
        write(nested, "font-size=17\n")

        write(options, "config-file=required-missing\n")
        run("04-required-include-missing", config, False,
            ["ConfigNotFound", str(options) + ":1", str(config) + ":1"], ["Configuration valid:"])

        loop = child / "loop"
        loop.symlink_to(config)
        write(options, "config-file=loop\n")
        run("05-physical-symlink-cycle", config, False,
            ["IncludeCycle", str(options) + ":1", str(config) + ":1"], ["Configuration valid:"])

        write(options, "theme=light:themes/day,dark:themes/not-present\n")
        run("06-inactive-theme-missing", config, False,
            ["ConfigNotFound", str(themes / "not-present"), str(options) + ":1", str(config) + ":1"], ["Configuration valid:"])

        write(options, options_text)
        write(night, "# invalid inactive theme\nbackground=broken\n")
        run("07-inactive-theme-invalid", config, False,
            ["InvalidColor", str(night) + ":2", str(options) + ":2", str(config) + ":1"], ["Configuration valid:"])

        write(config, "keybind=global:performable:ctrl+k=ignore\n")
        run("08-unsupported-global-combination", config, False,
            ["UnsupportedGlobalBinding", str(config) + ":1"], ["Configuration valid:"])

        write(config, json.dumps({"shell": "/bin/sh", "font-family": "Maple Mono Normal NL NF CN",
                                  "profiles": [{"name": "Local", "cwd": "~/isolated"}],
                                  "keybind_sequence_timeout": 5000}) + "\n")
        run("09-legacy-json", config, True, ["Configuration valid:", "source: " + str(config)])

        fifo = root / "configuration fifo"
        os.mkfifo(fifo, 0o600)
        run("10-fifo-root-nonblocking", fifo, False, [str(fifo)], ["Configuration valid:"])
        write(config, "config-file=?configuration fifo\n")
        run("11-optional-fifo-is-not-missing", config, False, ["ConfigIo", str(config) + ":1"], ["Configuration valid:"])
        write(config, "config-file=?child\n")
        run("12-optional-directory-is-not-missing", config, False, ["ConfigIo", str(config) + ":1"], ["Configuration valid:"])

        default_dir = xdg / "letty"
        default_dir.mkdir(exist_ok=True)
        preferred = default_dir / "config"
        fallback = default_dir / "config.json"
        write(fallback, '{"shell":"/bin/sh","restore_layout":false}\n')
        os.mkfifo(preferred, 0o600)
        run("13-default-xdg-fifo-refuses-fallback", None, False,
            ["ConfigIo", str(preferred)], ["Configuration valid:", "Using defaults", "source: " + str(fallback)])
        preferred.unlink()
        preferred.mkdir()
        run("14-default-xdg-directory-refuses-fallback", None, False,
            ["ConfigIo", str(preferred)], ["Configuration valid:", "Using defaults", "source: " + str(fallback)])
        preferred.rmdir()
        run("15-default-missing-text-allows-json", None, True,
            ["Configuration valid: " + str(fallback), "source: " + str(fallback)], ["Using defaults"])

    require(before == code_hash(), "Source changed during configuration CLI verification")
    require(binary_sha == sha(binary), "Executable changed during configuration CLI verification")
    record = {"suite": suite, "status": "passed", "count": len(checks), "code_sha256": before,
              "binary": str(binary), "binary_sha256": binary_sha,
              "verifier_sha256": sha(Path(__file__).resolve()), "checks": checks,
              "created_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
              "scope": "CLI only; no UI, build, user configuration or shell startup execution"}
    (STORE / (suite + ".json")).write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(f"All {len(checks)} configuration CLI checks passed.", flush=True)


if __name__ == "__main__":
    main()
