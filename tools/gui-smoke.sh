#!/bin/bash
# Run under xvfb-run on Ubuntu. Real GTK event loop, keyboard and resize.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
exe=${1:-"$root/zig-out/linux/bin/letty"}
work=$(mktemp -d)
trap 'if [[ -n "${pid-}" ]]; then kill "$pid" 2>/dev/null || true; fi; rm -rf "$work"' EXIT
export XDG_CONFIG_HOME="$work/config"
mkdir -p "$root/.cache/test-logs"
"$exe" --no-restore --hold --smoke-ms=12000 '--command=printf "GUI READY 中文 é\n\033[32mANSI\033[0m\n"; exec /bin/sh' >"$root/.cache/test-logs/gui.log" 2>&1 &
pid=$!
window=''
for _ in $(seq 1 40); do
  window=$(xdotool search --pid "$pid" 2>/dev/null | head -1 || true)
  if [[ -n "$window" ]]; then break; fi
  kill -0 "$pid" 2>/dev/null || { cat "$root/.cache/test-logs/gui.log"; exit 1; }
  sleep 0.1
done
[[ -n "$window" ]] || { echo 'No Letty window'; exit 1; }
xdotool windowfocus --sync "$window"
xdotool type --clearmodifiers --delay 3 "printf SMOKE > '$work/input.txt'"
xdotool key --clearmodifiers Return
xdotool key --clearmodifiers ctrl+shift+d
sleep 0.15
xdotool key --clearmodifiers ctrl+shift+e
sleep 0.15
xdotool key --clearmodifiers ctrl+shift+t
sleep 0.15
xdotool key --clearmodifiers ctrl+Tab
xdotool windowsize --sync "$window" 1200 780
sleep 0.1
xdotool key --clearmodifiers ctrl+shift+f
xdotool type --clearmodifiers 'GUI'
xdotool key --clearmodifiers Escape
wait "$pid"
pid=''
[[ -f "$work/input.txt" && "$(cat "$work/input.txt")" == SMOKE ]] || { echo 'Keyboard input did not reach the real shell'; exit 1; }
if grep -E 'panic:|Segmentation fault|error:|Session action failed|warning:.*leak' "$root/.cache/test-logs/gui.log"; then exit 1; fi
# Four PTYs across two tabs were created. Restore must preserve all four.
python3 - "$work/config/letty/layout.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1]))
assert j['tab_count']==2,j
assert len([n for n in j['nodes'] if n['kind']=='pane'])==4,j
print('PASS GTK window, input dispatch, 2 tabs / 4 PTYs, splits, search and resize')
PY
# Exercise the same portable font and rendering path headlessly for a durable PNG.
"$exe" --no-restore --hold '--command=printf "GUI READY 中文 é\n\033[32mANSI\033[0m\n"; sleep 30' \
  --nanoui-snapshot="$root/.cache/test-logs/linux-preview.png" --nanoui-wait=0.2
