#!/usr/bin/env python3
"""Run only the owned hidden image-atlas fixture with private user directories."""
import argparse
import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inputs():
    paths = list((ROOT / 'vendor/nanoui/src').rglob('*'))
    paths += list((ROOT / 'tools/image-atlas-check').glob('*.zig*'))
    paths += list((ROOT / 'patches').glob('nanoui-*.patch'))
    paths += [ROOT / 'deps.lock.json', ROOT / 'src/platform/compat.c', Path(__file__).resolve()]
    paths += list((ROOT / 'src/platform').glob('*.h'))
    return {str(p.relative_to(ROOT)): digest(p) for p in sorted(paths) if p.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', required=True, type=Path)
    parser.add_argument('--label', required=True, choices=['before', 'native', 'portable'])
    parser.add_argument('--expect-failure', action='store_true')
    args = parser.parse_args()
    executable = (args.prefix / 'bin/image-atlas-check').resolve()
    before = inputs()
    with tempfile.TemporaryDirectory(prefix='letty-atlas-private-') as private:
        env = os.environ.copy()
        env.update(HOME=private, XDG_CONFIG_HOME=private + '/config', XDG_CACHE_HOME=private + '/cache')
        result = subprocess.run([str(executable), '--nanoui-hidden'], env=env, cwd=ROOT,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=45)
    after = inputs()
    matched = result.returncode != 0 and 'ImageAtlasPixels' in result.stdout if args.expect_failure else result.returncode == 0 and 'failures: 0' in result.stdout
    passed = before == after and matched
    evidence = ROOT / '.cache/verification'
    evidence.mkdir(parents=True, exist_ok=True)
    log = evidence / f'image-atlas-{args.label}.log'
    receipt = evidence / f'image-atlas-{args.label}.json'
    if receipt.exists():
        history = evidence / 'image-atlas-history' / digest(receipt)
        history.mkdir(parents=True, exist_ok=True)
        shutil.copy2(receipt, history / receipt.name)
        if log.exists():
            shutil.copy2(log, history / log.name)
    log.write_text(result.stdout)
    record = dict(scope='Isolated image-atlas pixels: owned hidden Surface and offscreen frames; no whole-application or target-platform acceptance',
                  label=args.label, passed=passed, expected_pixel_failure=args.expect_failure,
                  exit_code=result.returncode, binary_sha256=digest(executable),
                  source_stable=before == after, input_sha256=before, log_sha256=digest(log))
    receipt.write_text(json.dumps(record, indent=2) + '\n')
    print(result.stdout, end='')
    print(f'Evidence: {log.relative_to(ROOT)}; expected outcome matched: {passed}')
    raise SystemExit(0 if passed else 1)


if __name__ == '__main__':
    main()
