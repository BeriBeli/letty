#!/usr/bin/env python3
"""Measure portable CPU raster kernels; no window, PTY or clipboard."""
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
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--allocator', action='store_true', help='Compare SafeAllocator page and libc backing on real UI frames')
    parser.add_argument('--raster-source', type=Path, help='Build an isolated framework copy with a preserved raster source for comparison')
    args = parser.parse_args()
    zig = os.environ.get('ZIG') or shutil.which('zig')
    if not zig or subprocess.check_output([zig, 'version'], text=True).strip() != '0.17.0':
        raise SystemExit('Requires exactly Zig 0.17.0')
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='letty-raster-', dir=ROOT / '.cache') as directory:
        work = Path(directory)
        (work / 'options.zig').write_text('pub const portable = true;\npub const version = "0.4.0";\n')
        binary = work / 'raster'
        module_source = ROOT / 'vendor/nanoui/src'
        if args.raster_source:
            module_source = work / 'framework'
            shutil.copytree(ROOT / 'vendor/nanoui/src', module_source)
            shutil.copy2(args.raster_source, module_source / 'ui/raster.zig')
        fixture = ROOT / 'tools/fixtures' / ('allocator_perf.zig' if args.allocator else 'raster_perf.zig')
        command = [zig, 'build-exe', '-OReleaseSafe', '-lc', '--dep', 'nanoui',
                   '-Mroot=' + str(fixture), '--dep', 'build_options',
                   '-Mnanoui=' + str(module_source / 'nanoui.zig'),
                   '-Mbuild_options=' + str(work / 'options.zig'), '-femit-bin=' + str(binary)]
        if platform.system() == 'Darwin':
            for framework in ('AppKit', 'QuartzCore', 'CoreGraphics', 'Foundation', 'ImageIO', 'CoreText'):
                command.extend(['-framework', framework])
            command.append('-lobjc')
        elif args.allocator:
            command.extend(['src/platform/compat.c', '-ldl', '-lpthread', '-lutil'])
        env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / '.cache/zig-global'))
        subprocess.run(command, cwd=ROOT, env=env, check=True)
        output = ''
        for mode in (('page-backing', 'libc-backing') if args.allocator else ('',)):
            for _ in range(3):
                result = subprocess.run([str(binary)] + ([mode] if mode else []), cwd=ROOT, env=env, text=True,
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True)
                output += result.stdout
        prefix = 'ALLOCATOR ' if args.allocator else 'RASTER '
        records = [json.loads(line[len(prefix):]) for line in output.splitlines() if line.startswith(prefix)]
        if len(records) != (6 if args.allocator else 12):
            raise RuntimeError('Incomplete performance measurements')
        sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
        report = {'scope': 'UI tree/shaping only' if args.allocator else 'CPU raster only; excludes text, GTK/X11 and remote presentation',
                  'host': platform.platform(), 'optimize': 'ReleaseSafe',
                  'source_sha256': sha(module_source / 'ui/raster.zig'),
                  'fixture_sha256': sha(fixture),
                  'binary_sha256': sha(binary), 'records': records}
        (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        (args.output / 'run.log').write_text(output)
        print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
