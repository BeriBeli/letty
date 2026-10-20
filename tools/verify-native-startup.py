#!/usr/bin/env python3
"""Repeat the real hidden-window event loop using owned config and PTYs."""
import argparse, datetime, json, os, re, subprocess, tempfile, time
from pathlib import Path
from verification import ROOT, STORE, code_hash, sha


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--prefix', default='native')
    p.add_argument('--iterations', type=int, default=10)
    args = p.parse_args()
    binary = ROOT / 'zig-out' / args.prefix / 'bin/letty'
    identity, digest = code_hash(), sha(binary)
    results = []
    STORE.mkdir(parents=True, exist_ok=True)
    version = subprocess.check_output([str(binary), '--version'], stderr=subprocess.STDOUT, text=True)
    if 'vt-backend=zig' not in version:
        raise RuntimeError('Expected actual native Zig application')
    for index in range(args.iterations):
        with tempfile.TemporaryDirectory(prefix='letty-startup-') as directory:
            config = Path(directory) / 'config'
            config.write_text('shell = /bin/sh\nrestore-layout = true\nconfirm-close-surface = false\n')
            env = dict(os.environ, HOME=directory, XDG_CONFIG_HOME=directory,
                       ENV='/dev/null', BASH_ENV='/dev/null', HISTFILE='/dev/null')
            # Both launches share an isolated workspace, so the second checks
            # actual persisted layout parsing and fresh PTY restoration.
            for restored in (False, True):
                command = [str(binary), '--nanoui-hidden', '--hold', '--smoke-ms=350',
                           '--config=' + str(config)]
                # command config allows restoration (CLI --command disables it).
                config.write_text(config.read_text().split('command =')[0] + 'command = exec /bin/sleep 30\n')
                log = STORE / f'{args.prefix}-startup-{index:02d}-{int(restored)}.log'
                known_children = set()
                start = time.monotonic()
                with log.open('wb') as out:
                    child = subprocess.Popen(command, cwd=ROOT, env=env, stdout=out, stderr=subprocess.STDOUT)
                    while child.poll() is None:
                        listing = subprocess.run(['pgrep', '-P', str(child.pid)], capture_output=True, text=True)
                        known_children.update(int(x) for x in listing.stdout.split() if x.isdigit())
                        if time.monotonic() - start > 15:
                            child.terminate()
                            try:
                                child.wait(timeout=5)
                            except subprocess.TimeoutExpired:
                                child.kill(); child.wait()
                            raise RuntimeError('Hidden window startup/quit timeout')
                        time.sleep(0.025)
                if child.returncode or re.search(r'\b(?:FAIL|panic|leaked)\b', log.read_text()):
                    raise RuntimeError('Startup regression; see ' + str(log))
                if not known_children:
                    raise RuntimeError('No owned real PTY child was observed')
                remaining = subprocess.run(['ps', '-p', ','.join(map(str, sorted(known_children))), '-o', 'pid='], capture_output=True, text=True)
                if remaining.stdout.strip():
                    raise RuntimeError('Startup left owned child processes alive')
                state = Path(directory) / 'letty/layout.json'
                if not state.is_file():
                    raise RuntimeError('Missing real saved workspace')
                workspace = json.loads(state.read_text())
                if workspace.get('version') != 6 or len(workspace.get('windows', [])) != 1:
                    raise RuntimeError('Wrong workspace format')
                results.append({'iteration': index + 1, 'restored': restored,
                                'wall_seconds': time.monotonic() - start,
                                'children_reaped': len(known_children), 'log_sha256': sha(log),
                                'workspace_sha256': sha(state)})
        print('PASS startup/quit and workspace restore pair', index + 1, flush=True)
    if identity != code_hash() or digest != sha(binary):
        raise RuntimeError('Sources or application changed during validation')
    record = {'status': 'passed', 'code_sha256': identity, 'binary_sha256': digest,
              'created_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'version': version.strip(), 'runs': results,
              'scope': 'actual host window/event-loop startup and timed quit, isolated layout save/restore, owned PTY cleanup; no oldest-kernel or VDI/IME acceptance'}
    output = STORE / (args.prefix + '-startup.json')
    output.write_text(json.dumps(record, indent=2) + '\n')
    print('PASS', len(results), 'actual startup/quit cycles;', output)


if __name__ == '__main__':
    main()
