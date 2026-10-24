#!/usr/bin/env python3
"""Exercise production SVN jobs against private file:// repositories, offline.

Requires SVN 1.9+ and svnadmin in PATH (or explicit --svn/--svnadmin paths).
Never reads the user's working copy/configuration or contacts a server.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from verification import ROOT, STORE, code_hash


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', default=os.environ.get('ZIG') or shutil.which('zig'))
    parser.add_argument('--svn', default=shutil.which('svn'))
    parser.add_argument('--svnadmin', default=shutil.which('svnadmin'))
    parser.add_argument('--ui', metavar='LETTY', help='Also verify the built native Changes panel with this private working copy')
    args = parser.parse_args()
    if not all((args.zig, args.svn, args.svnadmin)):
        parser.error('Provide Zig 0.17.0, svn and svnadmin using PATH or explicit options')
    zig, svn, admin = (str(Path(p).resolve()) for p in (args.zig, args.svn, args.svnadmin))
    if subprocess.check_output([zig, 'version'], text=True).strip() != '0.17.0':
        parser.error('Requires exactly Zig 0.17.0')
    identity = code_hash()
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / '.cache/zig-global'))
    prefix = ROOT / '.cache/svn-check'
    subprocess.run([zig, 'build', 'svn-check-bin', '--prefix', str(prefix), '-j4'], cwd=ROOT, env=env, check=True)
    binary = prefix / 'bin/letty-svn-check'
    checks = []

    def passed(name):
        checks.append(name)
        print('PASS SVN ' + name, flush=True)

    with tempfile.TemporaryDirectory(prefix='letty-svn-check-') as raw:
        base = Path(raw).resolve()
        home = base / 'home'
        home.mkdir()
        config = home / '.subversion'
        config.mkdir()
        poison = base / 'external-diff-ran'
        # A user's external diff helper must never be executed for previews.
        helper = base / 'external-diff'
        helper.write_text('#!/bin/sh\ntouch "' + str(poison) + '"\nexit 42\n')
        helper.chmod(0o700)
        (config / 'config').write_text('[helpers]\ndiff-cmd = ' + str(helper) + '\n')
        # Give production jobs a controlled PATH without requiring a global install.
        tools = base / 'bin'
        tools.mkdir()
        (tools / 'svn').symlink_to(svn)
        env.update(HOME=str(home), XDG_CONFIG_HOME=str(home), SVN_CONFIG_DIR=str(config),
                   PATH=str(tools) + os.pathsep + os.environ.get('PATH', '/usr/bin:/bin'))
        repo, wc, other, seed = (base / name for name in ('repo', 'wc', 'other', 'seed'))
        seed.mkdir()
        (seed / 'trunk').mkdir()
        (seed / 'ext').mkdir()
        (seed / 'ext' / 'external.sv').write_text('module external; endmodule\n')
        names = ['modified.sv', 'delete.sv', 'missing.sv', 'copy-source.sv', 'move-source.sv',
                 'props.sv', 'conflict.sv', 'tree.sv', 'property-conflict.sv', 'binary.bin',
                 'space & 文件.sv', 'peg@42.sv', '-option.sv']
        for name in names:
            (seed / 'trunk' / name).write_text('old\n')
        (seed / 'trunk' / 'subdirectory').mkdir()

        def run(*command, cwd=None):
            result = subprocess.run(command, cwd=cwd, env=env, check=True, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
            return result.stdout

        def s(*command, cwd=wc):
            return run(svn, '--non-interactive', '--no-auth-cache', *command, cwd=cwd)

        def inspect(directory=wc, path=None, custom_env=None):
            command = [str(binary), str(directory)] + ([] if path is None else [path])
            result = subprocess.run(command, env=custom_env or env, text=True, check=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
            return json.loads(result.stdout)

        run(admin, 'create', str(repo))
        s('import', str(seed), repo.as_uri(), '-m', 'private baseline', cwd=base)
        s('checkout', repo.as_uri() + '/trunk', str(wc), cwd=base)
        s('checkout', repo.as_uri() + '/trunk', str(other), cwd=base)
        clean = inspect(wc / 'subdirectory')
        assert clean['backend'] == 'svn' and clean['root'] == str(wc) and not clean['files']
        passed('nested working-copy detection and clean status')

        for name in ('modified.sv', 'space & 文件.sv', 'peg@42.sv', '-option.sv'):
            (wc / name).write_text('new\n')
        (wc / 'added.sv').write_text('added\n')
        s('add', '--', 'added.sv')
        s('delete', '--', 'delete.sv')
        (wc / 'missing.sv').unlink()
        s('copy', 'copy-source.sv', 'copied.sv')
        s('move', 'move-source.sv', 'moved.sv')
        s('propset', 'test:property', 'local value', 'props.sv')
        s('propset', 'test:root', 'root value', '.')
        (wc / 'untracked.sv').write_text('untracked\n')
        s('propset', 'svn:mime-type', 'application/octet-stream', 'binary.bin')
        (wc / 'binary.bin').write_bytes(b'\x00\xffbinary\n')
        s('propset', 'svn:externals', '^/ext external', '.')
        s('update')
        # update restores an unscheduled missing node; remove it afterwards.
        (wc / 'missing.sv').unlink(missing_ok=True)
        (wc / 'external' / 'external.sv').write_text('external changed\n')
        s('changelist', 'review', 'modified.sv')
        snapshot = inspect(wc / 'subdirectory')
        files = {f['path']: f for f in snapshot['files']}
        for name, expected in {'modified.sv': 'modified', 'added.sv': 'added', 'delete.sv': 'deleted',
                               'missing.sv': 'missing', 'copied.sv': 'added', 'moved.sv': 'added',
                               'move-source.sv': 'deleted', 'untracked.sv': 'untracked'}.items():
            assert files[name]['status'] == expected, (name, files)
        assert files['copied.sv']['copied'] and files['moved.sv']['moved_from'] == 'move-source.sv'
        assert files['props.sv']['property_status'] == 'modified'
        assert files['.']['property_status'] == 'modified'
        assert 'external/external.sv' not in files
        passed('added/deleted/missing/untracked/copy/move/property/changelist status')
        passed('external working copies are not recursively scanned')

        for name in ('modified.sv', 'space & 文件.sv', 'peg@42.sv', '-option.sv'):
            preview = inspect(path=name)
            assert '-old' in preview['patch'] and '+new' in preview['patch'], preview
            assert not preview['message'], preview
        assert not poison.exists()
        passed('literal filenames and internal diff override')
        if args.ui:
            ui_binary = Path(args.ui).resolve()
            ui_digest = hashlib.sha256(ui_binary.read_bytes()).hexdigest()
            ui_home = base / 'ui-home'
            ui_home.mkdir()
            ui_config = ui_home / 'config'
            ui_config.write_text('')
            ui_env = dict(env, HOME=str(ui_home), XDG_CONFIG_HOME=str(ui_home), LETTY_CONFIG=str(ui_config),
                          LETTY_SVN_UI_CWD=str(wc), ENV='/dev/null', BASH_ENV='/dev/null', INPUTRC='/dev/null',
                          HISTFILE='/dev/null', ZDOTDIR=str(ui_home))
            ui = subprocess.run([str(ui_binary), '--ui-checks', '--nanoui-hidden', '--shell=/bin/sh', '--cwd='+str(ui_home)],
                                env=ui_env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
            STORE.mkdir(parents=True, exist_ok=True)
            (STORE / 'native-svn-ui.log').write_text(ui.stdout)
            print(ui.stdout, end='', flush=True)
            ui.check_returncode()
            if hashlib.sha256(ui_binary.read_bytes()).hexdigest() != ui_digest:
                raise RuntimeError('Application binary changed during SVN UI checks; rerun')
            assert 'All UI checks passed.' in ui.stdout and 'real SVN split diff renders' in ui.stdout
            passed('real SVN working copy drives the native Changes panel and both diff layouts')
        assert '+added' in inspect(path='added.sv')['patch']
        assert '-old' in inspect(path='delete.sv')['patch']
        prop_patch = inspect(path='props.sv')['patch']
        assert 'test:property' in prop_patch and 'local value' in prop_patch
        root_patch = inspect(path='.')['patch']
        assert 'test:root' in root_patch and 'modified.sv' not in root_patch
        assert 'svn:mime-type' in inspect(path='binary.bin')['patch']
        passed('addition/deletion/property/directory/binary previews')
        for name in ('untracked.sv', 'missing.sv'):
            preview = inspect(path=name)
            assert preview['message'] and not preview['patch'], preview
        passed('explicit unavailable preview reasons')

        # Create real text, property and tree conflicts using only this file repo.
        (other / 'conflict.sv').write_text('incoming\n')
        s('propset', 'test:conflict', 'incoming', 'property-conflict.sv', cwd=other)
        s('delete', 'tree.sv', cwd=other)
        s('commit', '-m', 'private conflict baseline', cwd=other)
        (wc / 'conflict.sv').write_text('local\n')
        (wc / 'tree.sv').write_text('local tree change\n')
        s('propset', 'test:conflict', 'local', 'property-conflict.sv')
        s('update', '--accept', 'postpone')
        conflicts = {f['path']: f for f in inspect()['files']}
        assert conflicts['conflict.sv']['status'] == 'conflicted'
        assert conflicts['property-conflict.sv']['property_status'] == 'conflicted'
        assert conflicts['tree.sv']['tree_conflicted']
        assert '<<<<<<<' in inspect(path='conflict.sv')['patch']
        passed('real text/property/tree conflicts and conflict patch')

        # The working copy must remain reviewable when its repository is offline.
        repo.rename(base / 'offline-repository')
        assert '+new' in inspect(path='peg@42.sv')['patch']
        passed('status and diff remain local with repository unavailable')
        nested = wc / 'subdirectory'
        (nested / '.git').write_text('gitdir: private-test-marker\n')
        assert inspect(nested)['backend'] == 'git'
        (nested / '.git').unlink()
        linked = base / 'symlinked-project'
        linked.symlink_to(nested, target_is_directory=True)
        assert inspect(linked)['backend'] == 'svn'
        assert inspect(base)['backend'] == 'none'
        passed('nearest Git marker, symlinked projects and no-VCS detection')
        missing_env = dict(env, PATH=str(base / 'no-executables'))
        failure = subprocess.run([str(binary), str(wc)], env=missing_env, text=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        assert failure.returncode != 0 and 'ExecutableNotFound' in failure.stderr
        passed('missing SVN executable fails explicitly')

    if code_hash() != identity:
        raise RuntimeError('Source changed while verifying SVN; rerun')
    STORE.mkdir(parents=True, exist_ok=True)
    record = {'suite': 'native-svn', 'status': 'passed', 'count': len(checks), 'checks': checks,
              'code_sha256': identity, 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
              'verifier_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'svn_version': subprocess.check_output([svn, '--version', '--quiet'], text=True).strip()}
    if args.ui:
        record['ui_binary_sha256'] = ui_digest
        record['ui_log_sha256'] = hashlib.sha256((STORE / 'native-svn-ui.log').read_bytes()).hexdigest()
    (STORE / 'native-svn.json').write_text(json.dumps(record, indent=2) + '\n')
    print(f'All SVN checks passed ({len(checks)} checks).')


if __name__ == '__main__':
    main()
