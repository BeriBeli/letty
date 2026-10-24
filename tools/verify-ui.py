#!/usr/bin/env python3
"""Verify the replacement local-terminal UI with owned hidden windows/PTYS."""
import argparse, json, os, platform, shutil, tempfile
from pathlib import Path
from verification import ROOT, STORE, run_suite, sha

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--prefix', default='native' if platform.system() == 'Darwin' else 'linux')
    args=parser.parse_args()
    screenshots=ROOT/'.cache/test-logs'/('letty-port-'+args.prefix)
    screenshots.mkdir(parents=True,exist_ok=True)
    temp_root='/private/tmp' if platform.system() == 'Darwin' else None
    with tempfile.TemporaryDirectory(prefix='letty-local-ui-',dir=temp_root) as name:
        config=Path(name)/'config';config.write_text('language = en\n')
        captured=Path(name)/'screenshots';captured.mkdir()
        env=dict(os.environ, HOME=name, XDG_CONFIG_HOME=name, LETTY_CONFIG=str(config), LETTY_UI_SCREENSHOT_DIR=str(captured), ENV="/dev/null", BASH_ENV="/dev/null", INPUTRC="/dev/null", HISTFILE="/dev/null", ZDOTDIR=name)
        record=run_suite([ROOT/'zig-out'/args.prefix/'bin/letty','--ui-checks','--nanoui-hidden','--shell=/bin/sh','--cwd='+name],args.prefix+'-ui',env,timeout=120)
        source=captured/'letty-light.png'
        if not source.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'):raise RuntimeError('Missing replacement UI screenshot')
        image=screenshots/'letty-light.png'
        shutil.copy2(source,image)
        record['screenshots']={str(image):sha(image)}
        for name in ('svn-unified.png', 'svn-split.png', 'document-light.png', 'document-live.png', 'document-dark.png', 'document-narrow.png', 'document-side.png', 'document-ime.png', 'document-inline-clean.png', 'document-inline-edit.png', 'document-inline-dark.png', 'document-inline-narrow.png', 'document-inline-ime.png', 'document-width-narrow.png', 'document-width-quote.png', 'document-width-code.png', 'document-width-diagram.png', 'document-width-table.png', 'document-width-math.png', 'document-width-ime.png', 'document-width-dark.png', 'document-width-split.png'):
            source=captured/name
            if not source.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'):raise RuntimeError('Missing current UI screenshot: '+name)
            image=screenshots/name
            shutil.copy2(source,image)
            record['screenshots'][str(image)]=sha(image)
        record['scope']='Current local terminal and native file/Markdown workspaces, direct rendered text editing, source editing and live draft preview, guarded automatic Markdown saves, close-time flushes and failure recovery; owned private files, windows and clipboards; no daemon/Mirror; real NFS, Linux X11/VDI and system IME acceptance remain pending'
        (STORE/(args.prefix+'-ui.json')).write_text(json.dumps(record,indent=2)+'\n')

if __name__=='__main__':main()
