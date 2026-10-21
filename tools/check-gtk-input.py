#!/usr/bin/env python3
"""Run the production GTK input handlers with an owned deterministic IM backend."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def main():
    zig = os.environ.get("ZIG") or shutil.which("zig")
    if not zig or subprocess.check_output([zig, "version"], text=True).strip() != "0.17.0":
        raise SystemExit("Requires exactly Zig 0.17.0")
    (ROOT / ".cache").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="letty-gtk-input-", dir=ROOT / ".cache") as name:
        options = Path(name) / "options.zig"
        options.write_text('pub const portable = true;\npub const version = "0.4.0";\n')
        env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / ".cache/zig-global"))
        subprocess.run([zig, "test", "-lc", "-OReleaseSafe", "--dep", "build_options",
                        "-Mroot=vendor/nanoui/src/gtk_input_check.zig", "-Mbuild_options=" + str(options)],
                       cwd=ROOT, env=env, check=True)

if __name__ == "__main__":
    main()
