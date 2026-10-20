#!/usr/bin/env python3
"""Apply narrowly reviewed patches to the locked Ghostty source, idempotently."""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
patches = sorted((ROOT / 'patches').glob('ghostty-*.patch'))
with tempfile.TemporaryDirectory(prefix='letty-ghostty-patches-') as name:
    copy = Path(name)
    for patch in patches:
        for line in patch.read_text().splitlines():
            if not line.startswith('+++ b/'):
                continue
            relative = line[6:].split('\t', 1)[0]
            source, target = ROOT / 'vendor/ghostty' / relative, copy / relative
            if source.is_file() and not target.exists():
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
    complete = True
    for patch in reversed(patches):
        if subprocess.run(['patch', '--batch', '--force', '--reverse', '-p1', '-i', str(patch)], cwd=copy, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
            complete = False
            break
    if complete:
        raise SystemExit(0)
for patch in patches:
    command = ['patch', '--batch', '-p1', '-i', str(patch)]
    if subprocess.run(command + ['--force', '--reverse', '--dry-run'], cwd=ROOT / 'vendor/ghostty', stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        continue
    if subprocess.run(command + ['--forward', '--dry-run'], cwd=ROOT / 'vendor/ghostty', stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        raise SystemExit('Patch does not match locked Ghostty: ' + patch.name)
    subprocess.run(command + ['--forward'], cwd=ROOT / 'vendor/ghostty', check=True)
