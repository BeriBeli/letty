#!/usr/bin/env python3
"""Measure real, isolated AppKit windows. Does not touch an existing Letty app.

Uses system menu actions when available, labels geometry-only fallbacks, and
records CAMetalDrawable presentation callbacks. Minimize/restore notification
latency includes the system animation; no macOS animation preferences change.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import statistics
import subprocess

from verification import ROOT, code_hash, sha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT/'zig-out/native/bin/letty')
    parser.add_argument('--label', required=True)
    parser.add_argument('--allow-failed-checks', action='store_true', help='Record known baseline failures; never use for a candidate')
    parser.add_argument('--history', type=int, nargs='+', default=[0, 10000])
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    binary = args.binary.resolve()
    bundle = output/'Letty Window Timing.app'
    macos = bundle/'Contents/MacOS'
    macos.mkdir(parents=True)
    executable = macos/'LettyWindowTiming'
    shutil.copy2(binary, executable)
    executable.chmod(0o755)
    with (bundle/'Contents/Info.plist').open('wb') as file:
        plistlib.dump({'CFBundleName':'Letty Window Timing', 'CFBundleExecutable':executable.name,
                      'CFBundleIdentifier':'dev.letty.window-timing', 'CFBundlePackageType':'APPL',
                      'NSPrincipalClass':'NSApplication', 'NSHighResolutionCapable':True}, file)
    subprocess.run(['codesign','--force','--sign','-',str(bundle)], check=True, capture_output=True)
    vendor_sources = lambda: {str(p.relative_to(ROOT)):sha(p) for p in sorted((ROOT/'vendor/nanoui/src').rglob('*.zig'))}
    report = {'driver_sha256':sha(Path(__file__)), 'executed_binary':str(executable), 'executed_binary_sha256':sha(executable),
              'all_nanoui_sources':vendor_sources(), 'label':args.label, 'status':'running', 'created_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'binary':str(binary), 'binary_sha256':sha(binary), 'code_sha256':code_hash(),
              'vendor_sha256':{name:sha(ROOT/'vendor/nanoui/src/ui'/name) for name in
                               ('surface.zig','metal.zig','ui.zig','window_metrics.zig')},
              'scope':'real AppKit/Metal window; system menu if available; geometry fallback explicitly labeled; no preference changes',
              'runs':[], 'medians':{}}
    home = output/'home'
    home.mkdir()
    for history in args.history:
        config = output/f'config-{history}'
        config.write_text('shell = /bin/sh\nshell-integration = none\nrestore-layout = false\n'
                          'cursor-style = bar\ncursor-style-blink = false\nscrollback-lines = 100000\n')
        log = output/f'window-{history}.log'
        stdout = output/f'window-{history}.stdout'
        command = ['/usr/bin/open','-n','-W',str(bundle),'--env',f'HOME={home}','--env',f'XDG_CONFIG_HOME={output}/config-root','--env','HISTFILE=/dev/null','--stdout',str(stdout),'--stderr',str(log),
                   '--args',f'--window-perf={history}',f'--config={config}',f'--cwd={output}',
                   '--hold','--no-restore','--command=exec /bin/sleep 120']
        print('MEASURE', args.label, 'history', history, flush=True)
        subprocess.run(command,check=True,timeout=90)
        text = log.read_text()
        if f'WINDOW_DONE history={history}' not in text or 'error(gpa)' in text or 'panic:' in text:
            raise RuntimeError('Incomplete or failed window run: '+str(log)+'\n'+text[-3000:])
        rows = [json.loads(line[len('WINDOW_RESULT '):]) for line in text.splitlines() if line.startswith('WINDOW_RESULT ')]
        if len(rows)!=27 or len({(r['repeat'],r['operation']) for r in rows})!=27:
            raise RuntimeError('Missing/duplicate window operations')
        if any(v['count']>512 for r in rows for v in r['stages'].values()):
            raise RuntimeError('Timing sample cap exceeded')
        failures = [line for line in text.splitlines() if line.startswith('WINDOW_CHECK_FAILED')]
        if failures and not args.allow_failed_checks:
            raise RuntimeError('Window correctness checks failed: '+str(log)+'\n'+'\n'.join(failures))
        report['runs'].append({'history':history,'check_failures':failures,'command':command,'log':str(log),'log_sha256':sha(log),
                               'routes':[line for line in text.splitlines() if line.startswith('WINDOW_ROUTE')], 'rows':rows})
        medians={}
        for operation in dict.fromkeys(r['operation'] for r in rows):
            group=[r for r in rows if r['operation']==operation]
            medians[operation]={key:statistics.median(r[key] for r in group) for key in
                                ('call_us','settle_us','first_present_us','first_callback_us','presentations','callbacks')}
            medians[operation]['stages']={stage:{key:statistics.median(r['stages'][stage][key] for r in group)
                                               for key in ('count','total_us','max_us','p95_us')}
                                         for stage in group[0]['stages']}
        report['medians'][str(history)] = medians
        (output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    if code_hash()!=report['code_sha256']:
        raise RuntimeError('Source changed while measuring')
    if vendor_sources()!=report['all_nanoui_sources']:
        raise RuntimeError('Framework source changed while measuring')
    if sha(executable)!=report['executed_binary_sha256']:
        raise RuntimeError('Executed signed application changed')
    if sha(binary)!=report['binary_sha256']:
        raise RuntimeError('Measured executable changed')
    report['status']='measured-with-check-failures' if any(r['check_failures'] for r in report['runs']) else 'measured'
    (output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print('WINDOW MEASURED', output/'report.json',flush=True)

if __name__=='__main__':
    main()
