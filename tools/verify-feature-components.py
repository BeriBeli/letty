#!/usr/bin/env python3
"""Run current M10/M11 native component fixtures without external OS services.

The AppKit fixture owns an unattached NSView. No global shortcut is registered,
no accessibility permission is requested, and only private temporary files and
in-process adapters are used. Run serially with other Zig builds.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

from verification import ROOT, STORE, code_hash, sha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', default='/opt/homebrew/bin/zig')
    args = parser.parse_args()
    if subprocess.check_output([args.zig, 'version'], text=True).strip() != '0.17.0':
        raise RuntimeError('Requires exactly Zig 0.17.0')
    identity = code_hash()
    directory = STORE / 'feature-components'
    directory.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / '.cache/zig-global'))
    report = {'status': 'failed', 'code_sha256': identity, 'runner_sha256': sha(Path(__file__)),
              'commands': [], 'checks': {}, 'sources': {}, 'binaries': {}, 'screenshots': {},
              'created_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'scope': 'owned files, unattached NSView and adapters; no OS hotkeys/VoiceOver/Orca acceptance'}
    sources = ['src/config_edit_native_check.zig', 'src/accessibility_native_test.zig',
               'src/accessibility_macos_adapter_test.zig', 'src/platform/accessibility_test_adapter.c',
               'src/platform/accessibility_macos_native_check.c', 'src/platform/accessibility_macos_test_host.c',
               'tools/fixtures/config_edit_native.c', 'tests/navigation/provider_native.c', 'tests/navigation/provider_login_native.c',
               'src/settings/check.zig', 'src/settings_check.zig', 'tools/settings-check/build.zig',
               'src/preview_check.zig', 'src/preview/ui_check.zig', 'tools/preview-check/build.zig',
               'tools/preview-check/build.zig.zon', 'tests/preview/loader_native.c',
               'vendor/nanoui/src/images_check.zig', 'vendor/nanoui/src/ui/images_check.zig']
    sources += [p.relative_to(ROOT).as_posix() for p in sorted((ROOT / 'src/preview').glob('*.zig'))]
    report['sources'] = {name: sha(ROOT / name) for name in sources}

    def run(label, command, completion=None, prefix=None):
        path = directory / (label + '.log')
        result = subprocess.run(list(map(str, command)), cwd=ROOT, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
        path.write_bytes(result.stdout)
        output = result.stdout.decode()
        record = {'label': label, 'command': list(map(str, command)), 'returncode': result.returncode,
                  'log': str(path), 'log_sha256': sha(path)}
        report['commands'].append(record)
        if result.returncode or re.search(r'^FAIL(?:\s|:)|panic:|leaked \[|error\(gpa\):', output, re.M):
            print(output)
            raise RuntimeError('Component failed: ' + label)
        if completion:
            match = re.search(completion, output)
            if not match:
                raise RuntimeError('Missing component completion: ' + label)
            count = int(match[1])
            if prefix and sum(line.startswith(prefix) for line in output.splitlines()) != count:
                raise RuntimeError('Component assertion count mismatch: ' + label)
            report['checks'][label] = count
        print('PASS COMPONENT', label, report['checks'].get(label, 'compiled'), flush=True)

    try:
        options = directory / 'image-options.zig'
        options.write_text('pub const portable: bool = true;\n')
        binary = directory / 'image-sampler'
        run('image-sampler-build', [args.zig, 'test', '-OReleaseSafe', '-lc', '--dep', 'build_options',
            '-Mroot=' + str(ROOT / 'vendor/nanoui/src/images_check.zig'),
            '-Mbuild_options=' + str(options), '--test-no-exec', '-femit-bin=' + str(binary)])
        report['binaries'][str(binary)] = sha(binary)
        run('image-sampler', [binary], r'All (\d+) tests passed\.')
        binary = directory / 'config-edit'
        run('config-build', [args.zig, 'build-exe', '-OReleaseSafe', '-lc',
            'src/config_edit_native_check.zig', 'src/platform/config_edit.c',
            'tools/fixtures/config_edit_native.c', '-femit-bin=' + str(binary)])
        report['binaries'][str(binary)] = sha(binary)
        run('config-edit', [binary], r'All (\d+) native config edit checks passed\.', 'PASS CONFIG EDIT NATIVE ')
        binary = directory / 'ax-appkit'
        run('ax-appkit-build', [args.zig, 'cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
            'src/platform/accessibility.c', 'src/platform/accessibility_macos.c',
            'src/platform/accessibility_macos_native_check.c', '-framework', 'AppKit',
            '-framework', 'CoreGraphics', '-lobjc', '-o', binary])
        report['binaries'][str(binary)] = sha(binary)
        run('ax-appkit', [binary], r'PASS AX APPKIT NATIVE (\d+) checks;', 'PASS AX AppKit: ')
        for label, root, files in [
            ('ax-transaction', 'src/accessibility_native_test.zig', ['src/platform/accessibility.c', 'src/platform/accessibility_test_adapter.c']),
            ('ax-adapter', 'src/accessibility_macos_adapter_test.zig', ['src/platform/accessibility.c', 'src/platform/accessibility_macos.c', 'src/platform/accessibility_macos_test_host.c']),
        ]:
            command = [args.zig, 'test', '-OReleaseSafe', '-lc', root, *files]
            if label == 'ax-adapter':
                command += ['-framework', 'AppKit', '-framework', 'CoreGraphics', '-lobjc']
            run(label, command, r'All (\d+) tests passed\.')
        binary = directory / 'navigation-provider'
        run('navigation-provider-build', [args.zig, 'cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
            '-pthread', 'tests/navigation/provider_native.c', '-o', binary])
        report['binaries'][str(binary)] = sha(binary)
        run('navigation-provider', [binary], r'NAV_PROVIDER_NATIVE \{"checks":(\d+),', 'PASS NAV_PROVIDER ')
        binary = directory / 'navigation-login'
        run('navigation-login-build', [args.zig, 'cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
            '-pthread', 'tests/navigation/provider_login_native.c', 'src/platform/compat.c', '-o', binary])
        report['binaries'][str(binary)] = sha(binary)
        run('navigation-login', [binary], r'NAV_PROVIDER_LOGIN_NATIVE \{"checks":(\d+),', 'PASS NAV_PROVIDER_LOGIN ')
        binary = directory / 'preview-loader'
        run('preview-loader-build', [args.zig, 'cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
            '-pthread', 'tests/preview/loader_native.c', '-o', binary])
        report['binaries'][str(binary)] = sha(binary)
        run('preview-loader', [binary], r'PREVIEW_LOADER_NATIVE \{"checks":(\d+),', 'PASS PREVIEW_LOADER ')
        for portable in (False, True):
            label = 'preview-portable' if portable else 'preview-native'
            prefix = directory / label
            run(label + '-build', [args.zig, 'build', '--build-file', 'tools/preview-check/build.zig',
                '-Doptimize=ReleaseSafe', '-Dportable=' + str(portable).lower(),
                '--cache-dir', ROOT / '.cache/preview-zig', '--prefix', prefix, '-j4'])
            binary = prefix / 'bin/letty-preview-check'
            report['binaries'][str(binary)] = sha(binary)
            run(label, [binary], r'PREVIEW checks=(\d+)', 'PASS preview ')
            for scene in ('rendered', 'dark-narrow', 'local-image', 'stale-error'):
                screenshot = Path('/private/tmp/letty-preview-' + scene + '.png')
                if not screenshot.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'):
                    raise RuntimeError('Missing actual preview screenshot: ' + scene)
                target = directory / (label + '-' + scene + '.png')
                shutil.copy2(screenshot, target)
                report['screenshots'][str(target)] = sha(target)
        for portable in (False, True):
            label = 'settings-portable' if portable else 'settings-native'
            prefix = directory / label
            run(label + '-build', [args.zig, 'build', '--build-file', 'tools/settings-check/build.zig',
                '-Doptimize=ReleaseSafe', '-Dportable=' + str(portable).lower(),
                '--cache-dir', ROOT / '.cache/settings-zig', '--prefix', prefix, '-j4'])
            binary = prefix / 'bin/letty-settings-check'
            report['binaries'][str(binary)] = sha(binary)
            run(label, [binary], r'Settings acceptance: (\d+) checks passed', 'PASS settings ')
        if code_hash() != identity or any(sha(ROOT / name) != value for name, value in report['sources'].items()):
            raise RuntimeError('Source changed during component verification')
        report['status'] = 'passed'
    except BaseException as error:
        report['error'] = str(error)
        raise
    finally:
        (directory / 'report.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
