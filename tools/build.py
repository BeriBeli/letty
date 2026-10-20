#!/usr/bin/env python3
"""Build the native Zig terminal with exactly Zig 0.17; no local x86 containers."""
import argparse, os, platform, subprocess
from pathlib import Path
from verification import run_suite, build_manifest, code_hash
ROOT = Path(__file__).resolve().parents[1]

def run(args, cwd=ROOT, env=None):
    print('+', ' '.join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--native', action='store_true')
    parser.add_argument('--portable', action='store_true', help='Exercise the real CPU/TrueType renderer on macOS')
    parser.add_argument('--zig')
    parser.add_argument('--skip-bootstrap', action='store_true')
    args = parser.parse_args()
    if not args.skip_bootstrap:
        run(['python3', 'tools/bootstrap.py'])
    host = ('aarch64' if platform.machine() in ('arm64', 'aarch64') else 'x86_64') + '-' + ('macos' if platform.system() == 'Darwin' else 'linux')
    zig = Path(args.zig or os.environ.get('ZIG') or ROOT / '.cache/tools' / ('zig-' + host + '-0.17.0') / 'zig').resolve()
    if not zig.exists():
        raise SystemExit('Zig not found; run bootstrap or pass --zig=/path/to/zig')
    if subprocess.check_output([str(zig), 'version'], text=True).strip() != '0.17.0':
        raise SystemExit('Requires exactly Zig 0.17.0')
    from font_assets import verify
    verify()
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / '.cache/zig-global'))
    target = [] if args.native else ['-Dtarget=x86_64-linux.3.10-gnu.2.17', '-Dcpu=baseline']
    if args.portable:
        target.append('-Dportable=true')
    identity = code_hash()
    suffix = 'native-portable' if args.native and args.portable else 'native' if args.native else 'linux'
    out = ROOT / 'zig-out' / suffix
    run([zig, 'build', '-Doptimize=ReleaseSafe', *target, '--prefix', out, '-j4'], env=env)
    run([zig, 'build', 'test-bin', '-Doptimize=ReleaseSafe', *target, '--prefix', out, '-j4'], env=env)
    if args.native or platform.system() == 'Linux' and platform.machine() == 'x86_64':
        for kind, name in [('unit', 'letty-unit-tests'), ('core', 'letty-check'), ('replay', 'letty-vt-replay'), ('n2', 'letty-vt-n2'), ('protocol', 'letty-vt-protocol'), ('boundary', 'letty-vt-boundary'), ('graphics', 'letty-vt-graphics')]:
            run_suite([out / 'bin' / name], suffix + '-' + kind, env)
    if identity != code_hash():
        raise RuntimeError('Source changed while building; rerun build')
    build_manifest(suffix, 'zig', {'target': host if args.native else 'x86_64-linux.3.10-gnu.2.17', 'cpu': 'host' if args.native else 'baseline', 'zig': '0.17.0', 'optimize': 'ReleaseSafe', 'simd': False, 'portable': args.portable or not args.native})
    print('Built:', out / 'bin')

if __name__ == '__main__':
    main()
