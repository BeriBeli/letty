#!/usr/bin/env python3
"""Real isolated PTY title tests. No user startup files or desktop input."""
import os,pty,select,subprocess,tempfile,termios,time,re,shlex
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];BASE=ROOT/'assets/shell-integration'
TITLE=re.compile(rb'\x1b\]2;([^\x07]*)\x07')
class Shell:
 def __init__(self,exe,home):
  self.fd,slave=pty.openpty();attrs=termios.tcgetattr(slave);attrs[3]&=~termios.ECHO;termios.tcsetattr(slave,termios.TCSANOW,attrs)
  env=dict(os.environ,HOME=str(home),ZDOTDIR=str(home),HISTFILE='/dev/null',TERM='xterm-256color',PROMPT='READY> ',PS1='READY> ')
  self.p=subprocess.Popen([exe,*(['--noprofile','--norc','-i'] if exe.endswith('bash') else ['-d','-f','-i'] if exe.endswith('zsh') else ['-f','-i'])],stdin=slave,stdout=slave,stderr=slave,env=env,cwd=home,start_new_session=True);os.close(slave)
 def send(self,text):os.write(self.fd,text.encode()+b'\n')
 def read(self,needle=b'\x1b]133;B\x07',timeout=4):
  data=b'';end=time.monotonic()+timeout
  while time.monotonic()<end:
   if select.select([self.fd],[],[],max(0,end-time.monotonic()))[0]:
    try:chunk=os.read(self.fd,65536)
    except OSError:break
    if not chunk:break
    data+=chunk
    if needle in data:return data
  raise AssertionError(('timeout',needle,data[-2000:]))
 def command(self,text):self.send(text);return self.read()
 def close(self):
  try:self.send('exit');self.p.wait(timeout=2)
  except subprocess.TimeoutExpired:self.p.kill();self.p.wait(timeout=2)
  finally:os.close(self.fd)
for exe in ['/bin/zsh','/bin/bash']:
 if not Path(exe).exists():
  print('SKIP unavailable shell',exe);continue
 with tempfile.TemporaryDirectory(prefix='letty-title-') as name:
  home=Path(name).resolve();(home/'项目 space').mkdir();s=Shell(exe,home)
  try:
   s.read(b'READY> ');hook=BASE/('zsh/hooks.zsh' if exe.endswith('zsh') else 'bash')
   s.send("PS1='READY> '; source "+shlex.quote(str(hook))+"; printf '__LOADED__\\n'")
   out=s.read();assert TITLE.findall(out)[-1]==b'~',out
   out=s.command("cd '项目 space'");assert TITLE.findall(out)[-1]=='~/项目 space'.encode(),out
   s.send('/bin/sleep 0.4');out=s.read(b'\x1b]133;C');assert TITLE.findall(out)[-1]==b'/bin/sleep 0.4',out
   out=s.read();assert TITLE.findall(out)[-1]=='~/项目 space'.encode(),out
   s.send("printf '\\033]2;APP_TITLE\\007'; /bin/sleep 0.4");out=s.read(b'\x1b]2;APP_TITLE\x07');assert b'\x1b]2;APP_TITLE\x07' in out
   out=s.read();assert TITLE.findall(out)[-1]=='~/项目 space'.encode(),out
   out=s.command('false');assert b'\x1b]133;D;1\x07' in out,out
   out=s.command('source '+shlex.quote(str(hook)));assert len(re.findall(rb'\x1b\]133;D;',out))==1,out
   print('PASS',exe,'directory, Unicode/space, running command, application OSC2, prompt restore, exit status, idempotent source')
  finally:s.close()

import urllib.parse
for exe in ['/bin/csh','/bin/tcsh']:
 if not Path(exe).exists():
  print('SKIP unavailable shell',exe);continue
 with tempfile.TemporaryDirectory(prefix='letty-tcsh-title-') as name:
  home=Path(name).resolve();(home/'项目 space').mkdir();s=Shell(exe,home)
  try:
   s.send('unset edit; set prompt="STATUS%?READY> "; set history=100; setenv LETTY_SHELL_DIR '+shlex.quote(str(BASE)))
   s.read(b'READY> ')
   s.send("alias precmd 'echo -n __USER_PRE__'; alias postcmd 'echo -n __USER_POST__'")
   s.read(b'READY> ')
   s.send('source '+shlex.quote(str(BASE/'tcsh/hooks.tcsh')))
   out=s.read(b'READY> ');assert TITLE.findall(out)[-1]==b'~',out;assert b'__USER_PRE__' in out
   s.send("cd '项目 space'");out=s.read(b'READY> ')
   assert TITLE.findall(out)[-1]=='~/项目 space'.encode(),out
   uri=re.findall(rb'\x1b\]7;([^\x07]*)\x07',out)[-1].decode()
   assert urllib.parse.unquote(urllib.parse.urlsplit(uri).path)==str(home/'项目 space'),uri
   s.send('/bin/sleep 0.4');out=s.read(b'\x1b]2;/bin/sleep 0.4\x07');assert b'__USER_POST__' in out or b'/bin/sleep' in out
   out=s.read(b'READY> ');assert TITLE.findall(out)[-1]=='~/项目 space'.encode(),out
   s.send("/bin/sh -c 'printf \"\\033]2;APP_TITLE\\007\"; sleep 0.4'")
   out=s.read(b'\x1b]2;APP_TITLE\x07');out=s.read(b'READY> ');assert TITLE.findall(out)[-1]=='~/项目 space'.encode(),out
   s.send('false');out=s.read(b'READY> ');assert b'STATUS1READY> ' in out,out
   s.send('source '+shlex.quote(str(BASE/'tcsh/hooks.tcsh')));out=s.read(b'READY> ');assert out.count(b'__USER_PRE__')==1,out
   print('PASS',exe,'directory + command + app OSC2 + Unicode/space + OSC7 + exit status + existing aliases + idempotence')
  finally:s.close()
helper=BASE/'tcsh/title.sh'
out=subprocess.check_output(['/bin/sh',str(helper),'command','abc\n\x1b]52;bad\x07'])
assert len(TITLE.findall(out))==1 and b'\x1b]52;' not in out,out
print('PASS tcsh title control sanitization')
