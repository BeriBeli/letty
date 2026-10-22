#!/usr/bin/env python3
"""Measure exceptional arena recovery, including the frame that frees storage."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--framework', type=Path, default=ROOT / 'vendor/nanoui/src')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    zig = os.environ.get('ZIG') or shutil.which('zig')
    if not zig or subprocess.check_output([zig, 'version'], text=True).strip() != '0.17.0':
        raise SystemExit('Requires exactly Zig 0.17.0')
    args.output.mkdir(parents=True, exist_ok=True)
    framework = args.framework.resolve()
    fixture = ROOT / 'tools/fixtures/cache_perf.zig'
    with tempfile.TemporaryDirectory(prefix='letty-cache-', dir=ROOT / '.cache') as name:
        work = Path(name)
        options = work / 'options.zig'
        options.write_text('pub const portable = true;\npub const version = "0.4.0";\n')
        binary = work / 'cache'
        command = [zig, 'build-exe', '-OReleaseSafe', '-lc', '--dep', 'nanoui',
                   '-Mroot=' + str(fixture), '--dep', 'build_options',
                   '-Mnanoui=' + str(framework / 'nanoui.zig'), '-Mbuild_options=' + str(options),
                   '-femit-bin=' + str(binary)]
        if platform.system() == 'Darwin':
            for library in ('AppKit', 'QuartzCore', 'CoreGraphics', 'Foundation', 'ImageIO', 'CoreText'):
                command.extend(['-framework', library])
            command.append('-lobjc')
        else:
            command.extend(['src/platform/compat.c', '-ldl', '-lpthread', '-lutil'])
        env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / '.cache/zig-global'))
        subprocess.run(command, cwd=ROOT, env=env, check=True)
        records, logs = [], []
        for _ in range(3):
            result = subprocess.run([str(binary)], cwd=ROOT, env=env, check=True, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
            logs.append(result.stdout)
            records.extend(json.loads(line[6:]) for line in result.stdout.splitlines() if line.startswith('CACHE '))
        if len(records) != 3:
            raise RuntimeError('Incomplete cache measurements')
        sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
        report = {'host': platform.platform(), 'optimize': 'ReleaseSafe', 'fixture_sha256': sha(fixture),
                  'binary_sha256': sha(binary), 'records': records,
                  'source_sha256': {str(p.relative_to(framework)): sha(p) for p in framework.rglob('*.zig')},
                  'scope': 'Offscreen UI layout/shaping, including peak-trim frame; synthetic 32 MiB transient. No PTY or display latency.'}
        (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        (args.output / 'run.log').write_text(''.join(logs))
        print(json.dumps(records, indent=2))


if __name__ == '__main__':
    main()
