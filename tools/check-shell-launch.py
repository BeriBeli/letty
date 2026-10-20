#!/usr/bin/env python3
"""Validate the production launch plan without changing system login records."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='letty-launch-') as name:
    home = Path(name)
    binary = home / 'check'
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra',
                    '-Werror', '-I', str(ROOT / 'src'),
                    str(ROOT / 'tests/shell_launch_check.c'), '-o', str(binary)],
                   check=True)
    subprocess.run([str(binary)], check=True)
    # A shell path and command containing shell syntax stay distinct argv values.
    shell = home / "shell ' $literal"
    shell.symlink_to('/bin/bash')
    env = dict(os.environ, HOME=name, HISTFILE='/dev/null')
    for key in ('BASH_ENV', 'ENV'):
        env.pop(key, None)
    command = "printf '%s\\n' 'payload $(literal)'; shopt -q login_shell"
    for platform, status in [('darwin', 0), ('linux', 1)]:
        result = subprocess.run([str(binary), 'exec', platform, str(shell), command],
                                env=env, text=True, capture_output=True)
        assert result.returncode == status, (platform, result)
        assert 'payload $(literal)' in result.stdout, result
    print('PASS shell launch real Bash forwarding preserves quoted paths/commands and platform login mode')
