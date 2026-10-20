#!/usr/bin/env python3
"""Bounded owned-process stress with RSS/fd samples and child-reaping proof."""
import argparse, datetime, json, os, re, shutil, subprocess, tempfile, time
from pathlib import Path
from verification import ROOT, STORE, code_hash, sha


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--prefix', default='native')
    p.add_argument('--cycles', type=int, default=48)
    args = p.parse_args()
    lsof = shutil.which('lsof')
    if not lsof:
        raise RuntimeError('lsof is required for descriptor sampling')
    before = code_hash()
    binary = ROOT / 'zig-out' / args.prefix / 'bin/letty'
    binary_hash = sha(binary)
    STORE.mkdir(exist_ok=True, parents=True)
    log = STORE / (args.prefix + '-stability.log')
    samples = []
    with tempfile.TemporaryDirectory(prefix='letty-stability-') as directory:
        scratch = Path(directory)
        config = scratch / 'config'
        config.write_text('shell = /bin/sh\nrestore-layout = false\ncopy-on-select = none\nscrollback-lines = 500\nscrollback-limit = 8388608\n')
        env = dict(os.environ, HOME=directory, XDG_CONFIG_HOME=directory,
                   ENV='/dev/null', BASH_ENV='/dev/null', HISTFILE='/dev/null')
        command = [str(binary), '--stability-checks=' + str(args.cycles),
                   '--nanoui-hidden', '--hold', '--no-restore',
                   '--config=' + str(config), '--cwd=' + directory,
                   '--command=exec /bin/sh']
        start = time.monotonic()
        with log.open('wb') as out:
            child = subprocess.Popen(command, cwd=ROOT, env=env, stdout=out, stderr=subprocess.STDOUT)
            while child.poll() is None:
                if time.monotonic() - start > 180:
                    child.terminate()
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        child.kill(); child.wait()
                    raise RuntimeError('Stability timeout; see ' + str(log))
                sample = {'elapsed_seconds': time.monotonic() - start}
                rss = subprocess.run(['ps', '-o', 'rss=', '-p', str(child.pid)], text=True, capture_output=True)
                if rss.returncode == 0 and rss.stdout.strip():
                    sample['rss_kib'] = int(rss.stdout.strip())
                descriptors = subprocess.run([lsof, '-nP', '-p', str(child.pid), '-Ff'], text=True, capture_output=True)
                if descriptors.returncode == 0:
                    sample['file_descriptors'] = sum(bool(re.fullmatch(r'f\d+', x)) for x in descriptors.stdout.splitlines())
                samples.append(sample)
                time.sleep(0.25)
        output = log.read_text()
        if child.returncode or re.search(r'\b(?:FAIL|panic|leaked)\b', output):
            raise RuntimeError('Stability failure; see ' + str(log))
        rows = [json.loads(x[10:]) for x in output.splitlines() if x.startswith('STABILITY ')]
        done = [json.loads(x[15:]) for x in output.splitlines() if x.startswith('STABILITY_DONE ')]
        if len(done) != 1 or done[0]['cycles'] != args.cycles or len(rows) != args.cycles:
            raise RuntimeError('Missing stability completion')
        if [x['cycle'] for x in rows] != list(range(1, args.cycles + 1)) or any(x['active_ptys'] != 1 for x in rows):
            raise RuntimeError('Incomplete lifecycle iterations')
        retired = [x['retired_pid'] for x in rows] + [done[0]['survivor_pid']]
        # Only recorded owned children are checked. No process is signalled.
        remaining = subprocess.run(['ps', '-p', ','.join(map(str, retired)), '-o', 'pid='], text=True, capture_output=True)
        if remaining.stdout.strip():
            raise RuntimeError('Owned PTY children not reaped: ' + remaining.stdout.strip())
    if before != code_hash() or binary_hash != sha(binary):
        raise RuntimeError('Source or binary changed during stress')
    record = {'status': 'passed', 'created_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'code_sha256': before, 'binary_sha256': binary_hash, 'log_sha256': sha(log),
              'command': command, 'summary': done[0], 'samples': samples,
              'retired_children_reaped': len(retired),
              'scope': 'same-process hidden UI, real PTY input during output, pruning/search/copy/resize/focus and repeated close on the build host; no oldest-kernel or VDI/IME acceptance'}
    report = STORE / (args.prefix + '-stability.json')
    report.write_text(json.dumps(record, indent=2) + '\n')
    print('PASS stability:', args.cycles, 'cycles,', len(retired), 'owned children reaped;', report)


if __name__ == '__main__':
    main()
