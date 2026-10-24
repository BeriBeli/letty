#!/usr/bin/env python3
"""Compile the Ghostty-pinned theme package into a deterministic Zig-port catalog."""
import hashlib,json,re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
ZON=(ROOT/'vendor/ghostty/build.zig.zon').read_text()
pin=re.search(r'\.iterm2_themes\s*=\s*\.\{\s*\.url\s*=\s*"([^"]+)",\s*\.hash\s*=\s*"([^"]+)"',ZON)
if not pin:raise SystemExit('Missing pinned Ghostty theme dependency')
source=ROOT/'zig-pkg'/pin[2]
if not source.is_dir():raise SystemExit('Fetch the exact Ghostty iterm2_themes Zig dependency before regenerating')
entries=[];materials={}
for path in sorted(source.iterdir()):
 if not path.is_file() or path.name.startswith('.') or path.suffix=='.md':continue
 raw=path.read_bytes();materials[path.name]=hashlib.sha256(raw).hexdigest();values={};palette=[0]*16
 for line in raw.decode().splitlines():
  if '=' not in line:continue
  key,value=map(str.strip,line.split('=',1))
  if key=='palette':
   index,color=value.split('=',1);index=int(index)
   if index<16:palette[index]=int(color.strip().lstrip('#'),16)
  elif key in ['foreground','background','cursor-color','cursor-text','selection-background','selection-foreground']:values[key]=int(value.lstrip('#'),16)
 if len(values)!=6:raise SystemExit('Incomplete theme: '+path.name)
 entries.append(dict(name=path.name,foreground=values['foreground'],background=values['background'],cursor=values['cursor-color'],cursor_text=values['cursor-text'],selection=values['selection-background'],selection_text=values['selection-foreground'],palette=palette))
result=dict(source=dict(url=pin[1],zig_hash=pin[2],license='themes-LICENSE',files_sha256=materials),entries=entries)
output=ROOT/'assets/terminal/themes.json';output.write_text(json.dumps(result,ensure_ascii=False,separators=(',',':'))+'\n')
print(f'{len(entries)} pinned themes; {output.stat().st_size} bytes')
