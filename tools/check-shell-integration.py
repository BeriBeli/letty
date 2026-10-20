#!/usr/bin/env python3
"""PTY fixtures for Letty-owned integration, never read/write user startup files."""
import os,pty,select,signal,tempfile,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def run(shell,login=True):
    with tempfile.TemporaryDirectory(prefix='letty-shell-') as name:
        home=Path(name)
        env=dict(os.environ,HOME=name,HISTFILE='/dev/null',TERM='xterm-256color')
        for key in ['ENV','BASH_ENV','ZDOTDIR','GHOSTTY_RESOURCES_DIR','GHOSTTY_SHELL_INTEGRATION']:
            env.pop(key,None)
        scripts=ROOT/'assets/shell-integration'
        if shell.endswith('zsh'):
            (home/'.zshrc').write_text("HISTFILE=/dev/null\nPROMPT='FIXTURE> '\nprecmd() { printf 'USER_HOOK_OK\\n'; }\n")
            env.update(LETTY_ORIGINAL_ZDOTDIR=name,LETTY_ZDOTDIR_SET='0',LETTY_SHELL_DIR=str(scripts),ZDOTDIR=str(scripts/'zsh'))
            (home/'.zprofile').write_text("printf 'LOGIN_PROFILE_OK\\n'\n")
            argv=[shell,'-l'] if login else [shell]
        else:
            # Existing DEBUG traps must survive. Test manual source on macOS Bash 3.2.
            (home/'rc').write_text("PS1='FIXTURE> '\nPROMPT_COMMAND=\"printf 'USER_HOOK_OK\\\\n'\"\ntrap ':' DEBUG\nsource '"+str(scripts/'bash')+"'\n")
            argv=[shell,'--noprofile','--rcfile',str(home/'rc'),'-i']
        pid,fd=pty.fork()
        if pid==0:os.execve(shell,argv,env)
        data=b''
        def until(token):
            nonlocal data
            end=time.monotonic()+5
            while token not in data and time.monotonic()<end:
                if select.select([fd],[],[],.1)[0]:
                    try:data+=os.read(fd,65536)
                    except OSError:break
            if token not in data:raise AssertionError((shell,token,data[-2000:]))
        try:
            until(b'FIXTURE> ')
            assert b'USER_HOOK_OK' in data and b'\x1b]133;A' in data
            if shell.endswith('zsh'):
                assert (b'LOGIN_PROFILE_OK' in data) == login, (login, data)
            data=b'';os.write(fd,b"false\n");until(b'FIXTURE> ')
            assert b'\x1b]133;D;1\x07' in data,(shell,data)
            data=b'';os.write(fd,b"printf 'TRAP:%s\\n' \"$(trap -p DEBUG)\"\n" if shell.endswith('bash') else b"printf 'ZDOT:%s\\n' \"${ZDOTDIR-unset}\"\n")
            until(b'FIXTURE> ')
            assert (b"trap -- ':' DEBUG" in data if shell.endswith('bash') else b'ZDOT:unset' in data),(shell,data)
            print('PASS',shell,'login' if login else 'non-login','user hook, exit status, trap/ZDOTDIR preservation')
        finally:
            os.close(fd)
            try:os.kill(pid,signal.SIGKILL)
            except ProcessLookupError:pass
            os.waitpid(pid,0)
for shell in ['/bin/bash','/bin/zsh']:
    if Path(shell).exists():run(shell)

if Path('/bin/zsh').exists():run('/bin/zsh',login=False)
