#!/usr/bin/env python3
"""Exercise real macOS login shells in owned hidden windows and isolated rc files."""
import argparse, datetime, json, os, platform, re, subprocess, tempfile, time
from pathlib import Path
from verification import ROOT, STORE, code_hash, sha


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--prefix', default='native')
    parser.add_argument('--iterations', type=int, default=20)
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        raise RuntimeError('This check exercises the macOS login path')
    binary = ROOT / 'zig-out' / args.prefix / 'bin/letty'
    identity, digest = code_hash(), sha(binary)
    results = []
    STORE.mkdir(parents=True, exist_ok=True)
    for index in range(args.iterations):
        with tempfile.TemporaryDirectory(prefix='letty-login-') as directory:
            scratch = Path(directory)
            cwd = scratch / 'directory with spaces'
            cwd.mkdir()
            marker = scratch / 'prompt.json'
            # The integration wrapper sources only these owned startup files.
            (scratch / '.zshrc').write_text(
                "HISTFILE=/dev/null\nPROMPT='LETTY_LOGIN_TEST> '\n"
                "precmd() { print -r -- \"$$\" > \"$LETTY_STARTUP_PROBE\"; "
                "print -r -- \"$PWD\" >> \"$LETTY_STARTUP_PROBE\"; }\n")
            config = scratch / 'config'
            config.write_text('shell = /bin/zsh\nshell-integration = detect\n'
                              'restore-layout = false\nconfirm-close-surface = false\n'
                              'working-directory = ' + str(cwd) + '\n')
            env = dict(os.environ, ZDOTDIR=directory, XDG_CONFIG_HOME=directory,
                       ENV='/dev/null', BASH_ENV='/dev/null', HISTFILE='/dev/null',
                       LETTY_STARTUP_PROBE=str(marker))
            command = [str(binary), '--nanoui-hidden', '--hold', '--no-restore',
                       '--smoke-ms=1000', '--config=' + str(config)]
            log = STORE / f'{args.prefix}-login-startup-{index:02d}.log'
            observed, shell_pid, foreground, watched = set(), None, None, None
            start = time.monotonic()
            with log.open('wb') as out:
                child = subprocess.Popen(command, cwd=ROOT, env=env, stdout=out, stderr=subprocess.STDOUT)
                try:
                    while child.poll() is None:
                        direct = subprocess.run(['pgrep', '-P', str(child.pid)], capture_output=True, text=True)
                        observed.update(int(x) for x in direct.stdout.split() if x.isdigit())
                        if marker.exists():
                            lines = marker.read_text().splitlines()
                            if len(lines) == 2 and lines[0].isdigit():
                                shell_pid = int(lines[0])
                                if lines[1] != str(cwd):
                                    raise RuntimeError('Login changed the explicit initial directory')
                                observed.add(shell_pid)
                                groups = subprocess.run(['ps', '-p', str(shell_pid), '-o', 'pgid=,tpgid=,ppid='], capture_output=True, text=True)
                                values = groups.stdout.split()
                                if len(values) == 3:
                                    group, tgroup, parent = map(int, values)
                                    if group == tgroup and group > 0:
                                        foreground = group
                                    watched = parent if parent != child.pid else shell_pid
                                    if parent != child.pid:
                                        observed.add(parent)
                        if time.monotonic() - start > 15:
                            raise RuntimeError('Login startup/quit timeout')
                        time.sleep(0.025)
                finally:
                    if child.poll() is None:
                        child.terminate()
                        try:
                            child.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            child.kill(); child.wait()
            if child.returncode or re.search(r'\b(?:FAIL|panic|leaked)\b', log.read_text()):
                raise RuntimeError('Login startup failed; see ' + str(log))
            if shell_pid is None or foreground is None or not observed:
                raise RuntimeError('Did not observe a real foreground login shell prompt')
            remaining = subprocess.run(['ps', '-p', ','.join(map(str, sorted(observed))), '-o', 'pid='], capture_output=True, text=True)
            if remaining.stdout.strip():
                raise RuntimeError('Login/shell children remain after normal app quit: ' + remaining.stdout.strip())
            results.append({'iteration': index + 1, 'shell_pid': shell_pid,
                            'foreground_group': foreground, 'watched_pid': watched,
                            'children_reaped': len(observed), 'initial_directory_verified': True,
                            'wall_seconds': time.monotonic() - start, 'log_sha256': sha(log)})
        print('PASS real login/foreground/cwd/quit', index + 1, flush=True)
    if identity != code_hash() or digest != sha(binary):
        raise RuntimeError('Source or binary changed during login verification')
    report = {'status': 'passed', 'code_sha256': identity, 'binary_sha256': digest,
              'runner_sha256': sha(Path(__file__)), 'runs': results,
              'created_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'scope': 'macOS login shell, foreground group, explicit cwd and normal hidden-window quit; isolated rc files; CentOS/VDI/IME pending'}
    (STORE / (args.prefix + '-login-startup.json')).write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
