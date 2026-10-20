#!/usr/bin/env python3
"""Check the real owned macOS appearance observer without posting notifications."""
import datetime
import json
import os
from pathlib import Path
import platform
import subprocess
from verification import ROOT, STORE, code_hash, sha

if platform.system() != 'Darwin':
    raise SystemExit('macOS-only selector check; GTK property routing needs target GUI acceptance')
source = ROOT / 'src/appearance_native_check.zig'
directory = ROOT / '.cache/appearance-check'
directory.mkdir(parents=True, exist_ok=True)
options = directory / 'options.zig'
options.write_text('pub const portable: bool = false;\n')
binary = directory / 'appearance-check'
zig = os.environ.get('ZIG', '/opt/homebrew/bin/zig')
if subprocess.check_output([zig, 'version'], text=True).strip() != '0.17.0':
    raise RuntimeError('Requires exact Zig 0.17.0')
identity = code_hash()
env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / '.cache/zig-global'))
command = [zig, 'build-exe', '-OReleaseSafe', '-lc', '-lobjc', '-framework', 'AppKit',
           '-framework', 'Foundation', '--dep', 'nanoui', '-Mroot=' + str(source),
           '--dep', 'build_options', '-Mnanoui=' + str(ROOT / 'vendor/nanoui/src/nanoui.zig'),
           '-Mbuild_options=' + str(options), '-femit-bin=' + str(binary)]
STORE.mkdir(parents=True, exist_ok=True)
build_log = STORE / 'native-appearance-build.log'
with build_log.open('w') as output:
    subprocess.run(command, cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT, check=True, timeout=180)
result = subprocess.run([str(binary)], cwd=ROOT, env=env, capture_output=True, text=True, timeout=15)
output = result.stdout + result.stderr
log = STORE / 'native-appearance.log'
log.write_text(output)
print(output, end='')
if (result.returncode or output.count('PASS APPEARANCE ') != 6 or
        'All 6 native appearance checks passed.' not in output or
        any(token in output for token in ('FAIL ', 'panic:', 'leaked ['))):
    raise RuntimeError('Native appearance observer failed')
if identity != code_hash():
    raise RuntimeError('Source changed during appearance check')
record = {
    'status': 'passed', 'code_sha256': identity, 'count': 6,
    'source_sha256': sha(source), 'verifier_sha256': sha(Path(__file__)),
    'binary': str(binary), 'binary_sha256': sha(binary),
    'log': str(log), 'log_sha256': sha(log),
    'build_log': str(build_log), 'build_log_sha256': sha(build_log), 'command': command,
    'created_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'scope': 'Actual owned ObjC selector registration/delivery/dedup/teardown; no system notification posted or setting changed; GTK target pending',
}
(STORE / 'native-appearance.json').write_text(json.dumps(record, indent=2) + '\n')
