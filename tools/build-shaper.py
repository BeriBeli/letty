#!/usr/bin/env python3
"""Build pinned memory-font HarfBuzz; export a source-bound static integration kit.

--prepare-only never invokes a compiler or accesses the network. It verifies an
existing source tree or extracts the already cached, checksum-locked tarball.
Normal builds may fetch only the locked archive. --prefix exports lib/, include/,
share/licenses/ and build-info.json; intermediates/probes remain under .cache.
"""
import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / 'tools/shaper-dependency.json'
FLAGS = ['-std=c++17', '-O2', '-fno-exceptions', '-fno-rtti', '-DHAVE_PTHREAD=1', '-DHB_CUSTOM_MALLOC',
         '-DHB_NO_MMAP', '-DHB_NO_OPEN', '-DHB_NO_GETENV', '-DHB_NO_SETLOCALE',
         '-DHB_NO_BUFFER_SERIALIZE', '-DHB_NO_BUFFER_VERIFY', '-DHB_NO_DRAW',
         '-DHB_NO_COLOR', '-DHB_NO_MATH', '-DHB_NO_META', '-DHB_NO_STYLE', '-DNDEBUG',
         '-DHB_BUFFER_MAX_LEN_FACTOR=1', '-DHB_BUFFER_MAX_LEN_MIN=4096',
         '-DHB_BUFFER_MAX_LEN_DEFAULT=4096', '-DHB_BUFFER_MAX_OPS_FACTOR=512',
         '-DHB_BUFFER_MAX_OPS_MIN=65536', '-DHB_BUFFER_MAX_OPS_DEFAULT=2097152']
C_FLAGS = ['-std=c11', '-O2']
TARGETS = ('aarch64-macos', 'x86_64-linux.3.10-gnu.2.17')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    pending = path.with_suffix(path.suffix + '.tmp')
    pending.write_text(json.dumps(value, indent=2) + '\n')
    pending.replace(path)


def tree_sha(root):
    digest = hashlib.sha256()
    for path in sorted(p for p in root.rglob('*') if p.is_file()):
        if not path.resolve().is_relative_to(root.resolve()):
            raise RuntimeError('Source link escapes locked HarfBuzz tree')
        digest.update(path.relative_to(root).as_posix().encode() + b'\0')
        digest.update(bytes.fromhex(sha(path)))
    return digest.hexdigest()


def run(args, env):
    print('+', ' '.join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=ROOT, env=env, check=True)


def prepare(lock, offline):
    source = ROOT / 'vendor/harfbuzz'
    if not source.exists():
        archive = ROOT / '.cache' / lock['archive']
        archive.parent.mkdir(parents=True, exist_ok=True)
        if not archive.exists():
            if offline:
                raise RuntimeError('--prepare-only needs verified vendor/harfbuzz or cached ' + str(archive))
            pending = archive.with_suffix('.download')
            with urllib.request.urlopen(lock['url'], timeout=120) as response, pending.open('wb') as dest:
                shutil.copyfileobj(response, dest)
            if sha(pending) != lock['sha256']:
                pending.unlink()
                raise RuntimeError('HarfBuzz download SHA-256 mismatch')
            pending.replace(archive)
        if sha(archive) != lock['sha256']:
            raise RuntimeError('HarfBuzz archive SHA-256 mismatch')
        with tempfile.TemporaryDirectory(dir=ROOT / '.cache') as temp:
            with tarfile.open(archive) as tar:
                for member in tar.getmembers():
                    parts = PurePosixPath(member.name).parts
                    if not parts or parts[0] != lock['archive_root'] or '..' in parts or member.name.startswith('/'):
                        raise RuntimeError('Unexpected HarfBuzz archive path')
                tar.extractall(temp, filter='data')
            source.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(Path(temp) / lock['archive_root']), source)
    if tree_sha(source) != lock['source_tree_sha256']:
        raise RuntimeError('Pinned HarfBuzz source tree mismatch')
    if sha(ROOT / lock['license_file']) != lock['license_sha256']:
        raise RuntimeError('Pinned HarfBuzz COPYING mismatch')
    return source


def inputs(lock, target):
    return {'target': target, 'cpu': 'baseline', 'zig': '0.17.0', 'cxx_flags': FLAGS, 'c_flags': C_FLAGS,
            'source_tree_sha256': lock['source_tree_sha256'], 'archive_sha256': lock['sha256'],
            'lock_sha256': sha(LOCK), 'builder_sha256': sha(Path(__file__)),
            'wrapper_sha256': sha(ROOT / 'src/portable_shaper.c'), 'header_sha256': sha(ROOT / 'src/portable_shaper.h')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', default=os.environ.get('ZIG', 'zig'))
    parser.add_argument('--native', action='store_true')
    parser.add_argument('--target', choices=TARGETS)
    parser.add_argument('--prefix', type=Path)
    parser.add_argument('--check', action='store_true', help='Execute genuine upstream fixture fonts on a matching host')
    parser.add_argument('--prepare-only', action='store_true', help='Locked source verification; no network or compiler')
    parser.add_argument('--force', action='store_true')
    args = parser.parse_args()
    if args.prepare_only and (args.check or args.force):
        parser.error('--prepare-only cannot be combined with --check or --force')
    lock = json.loads(LOCK.read_text())
    source = prepare(lock, offline=args.prepare_only)
    if args.prepare_only:
        print(json.dumps({'status': 'prepared', 'version': lock['version'], 'source': str(source),
                          'source_tree_sha256': lock['source_tree_sha256'], 'lock_sha256': sha(LOCK),
                          'license_sha256': lock['license_sha256'], 'network': 'not_used', 'compiler': 'not_invoked'}))
        return
    zig = shutil.which(args.zig) or args.zig
    if subprocess.check_output([zig, 'version'], text=True).strip() != '0.17.0':
        raise RuntimeError('Requires exactly Zig 0.17.0')
    target = args.target or ('aarch64-macos' if args.native and platform.system() == 'Darwin' else TARGETS[1])
    suffix = 'native' if target == TARGETS[0] else 'linux'
    compatible = ((target == TARGETS[0] and platform.system() == 'Darwin' and platform.machine() in ('arm64', 'aarch64'))
                  or (target == TARGETS[1] and platform.system() == 'Linux' and platform.machine() == 'x86_64'))
    if args.check and not compatible:
        parser.error('--check cannot execute this cross target; omit --check')
    dest = (args.prefix or ROOT / '.cache/shaper' / suffix).resolve()
    library, header, notice = dest / 'lib/libportable_shaper.a', dest / 'include/portable_shaper.h', dest / 'share/licenses/harfbuzz/COPYING'
    for path in (library, header, notice):
        path.parent.mkdir(parents=True, exist_ok=True)
    work = ROOT / '.cache/shaper-build' / suffix
    work.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / '.cache/zig-global'))
    identity = inputs(lock, target)
    fingerprint = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    info_path = dest / 'build-info.json'
    previous = json.loads(info_path.read_text()) if info_path.exists() else {}
    rebuild = (args.force or previous.get('fingerprint') != fingerprint or not library.exists()
               or previous.get('library_sha256') != sha(library))
    info = {'schema': 1, 'status': 'incomplete', 'dependency': 'HarfBuzz', 'version': lock['version'],
            **identity, 'fingerprint': fingerprint, 'license': lock['license'],
            'bounds': lock['bounds'], 'disabled': lock['disabled'], 'license_file': 'share/licenses/harfbuzz/COPYING',
            'scope': 'owned memory-font glyph shaping; font fallback/rasterization/cell mapping are host responsibilities',
            'cxx_runtime': 'C-only link probe, no libc++ or libstdc++ linked',
            'allocation_diagnostics': 'HB_CUSTOM_MALLOC per-thread failed-allocation epoch; not a cumulative heap quota',
            'execution': 'not_run'}
    write_json(info_path, info)
    common = ['-target', target, '-mcpu=baseline']
    if rebuild:
        run([zig, 'c++', *common, *FLAGS, '-c', source / 'src/harfbuzz.cc', '-o', work / 'harfbuzz.o'], env)
        run([zig, 'cc', *common, *C_FLAGS, '-I', source / 'src', '-c', ROOT / 'src/portable_shaper.c', '-o', work / 'portable_shaper.o'], env)
        run([zig, 'ar', 'rcs', library, work / 'harfbuzz.o', work / 'portable_shaper.o'], env)
    shutil.copyfile(ROOT / 'src/portable_shaper.h', header)
    shutil.copyfile(ROOT / lock['license_file'], notice)
    # Always link a C-only probe against precisely the exported library.
    probe = work / 'portable-shaper-check'
    run([zig, 'cc', *common, '-O2', ROOT / 'src/portable_shaper_check.c', library, '-lc', '-lpthread', '-o', probe], env)
    info['link_probe'] = {'path': str(probe), 'sha256': sha(probe), 'status': 'linked'}
    if args.check:
        result = subprocess.run([str(probe)], cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
        log = dest / 'check.log'
        log.write_text(result.stdout)
        print(result.stdout, end='')
        result.check_returncode()
        if 'FAIL' in result.stdout or 'panic' in result.stdout or 'leaked [' in result.stdout:
            raise RuntimeError('Portable shaper fixture failed')
        validation = json.loads(result.stdout.splitlines()[-1])
        if validation.get('status') != 'pass' or validation.get('version') != lock['version'] or validation.get('checks', 0) < 16:
            raise RuntimeError('Incomplete real-font fixture record')
        write_json(dest / 'validation.json', validation)
        info.update(execution='passed', check_log_sha256=sha(log), validation_sha256=sha(dest / 'validation.json'))
    if target == TARGETS[1]:
        audit = dest / 'abi-audit.json'
        run(['python3', ROOT / 'tools/audit-elf.py', work, '--output', audit], env)
        info['abi_audit_sha256'] = sha(audit)
    if inputs(lock, target) != identity or tree_sha(source) != lock['source_tree_sha256']:
        raise RuntimeError('Shaper source or build policy changed during build')
    info.update(status='ready', library_sha256=sha(library), artifacts={
        str(path.relative_to(dest)): {'sha256': sha(path), 'bytes': path.stat().st_size}
        for path in (library, header, notice)},
        zig_leaf_sources={name: sha(ROOT / 'src' / name) for name in
                          ('portable_shaper.zig', 'font_features.zig', 'run_clusters.zig')})
    write_json(info_path, info)
    print('Built:', library, '; integration metadata:', info_path)


if __name__ == '__main__':
    main()
