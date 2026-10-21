#!/bin/bash
# Run under xvfb-run on Ubuntu. Real GTK event loop, keyboard and resize.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
exe=${1:-"$root/zig-out/linux/bin/letty"}
work=$(mktemp -d)
trap 'if [[ -n "${pid-}" ]]; then kill "$pid" 2>/dev/null || true; fi; if [[ -f "$work/config/letty/layout.json" ]]; then cp "$work/config/letty/layout.json" "$root/.cache/test-logs/gui-layout.json"; fi; rm -rf "$work"' EXIT
export XDG_CONFIG_HOME="$work/config"
mkdir -p "$root/.cache/test-logs"
"$exe" --no-restore --hold --smoke-ms=30000 '--command=printf "GUI READY 中文 é\n\033[32mANSI\033[0m\n"; exec /bin/sh' >"$root/.cache/test-logs/gui.log" 2>&1 &
pid=$!
window=''
for _ in $(seq 1 150); do
  window=$(xdotool search --onlyvisible --pid "$pid" 2>/dev/null | head -1 || true)
  if [[ -n "$window" ]]; then break; fi
  kill -0 "$pid" 2>/dev/null || { cat "$root/.cache/test-logs/gui.log"; exit 1; }
  sleep 0.1
done
[[ -n "$window" ]] || { echo 'No Letty window'; exit 1; }
# Inspect only the window owned by this fixture on its private Xvfb display.
xprop -id "$window" WM_CLASS > "$work/window-class"
grep -q '"Letty"' "$work/window-class"
# xprop defaults to 250000 bytes, less than this icon's 262152 bytes.
# Leave room beyond the expected property so the length assertion detects extras.
xprop -id "$window" -len 1048576 -notype -f _NET_WM_ICON 32c _NET_WM_ICON > "$work/window-icon"
python3 - "$work/window-icon" <<'PY'
from pathlib import Path
import sys
values = [int(value.strip()) for value in Path(sys.argv[1]).read_text().split('=', 1)[1].split(',')]
assert values[:2] == [256, 256], values[:2]
assert len(values) == 2 + 256 * 256, len(values)
assert any(value >> 24 for value in values[2:]), 'Window icon is fully transparent'
print('PASS GTK application WM_CLASS and nonempty 256x256 X11 window icon')
PY
xdotool windowfocus --sync "$window"
xdotool mousemove --sync --window "$window" 500 300 click 1
sleep 0.2
xdotool type --clearmodifiers --delay 3 "printf SMOKE > '$work/input.txt'"
xdotool key --clearmodifiers Return
for _ in $(seq 1 100); do
  [[ -f "$work/input.txt" ]] && break
  sleep 0.1
done
if [[ ! -f "$work/input.txt" || "$(cat "$work/input.txt")" != SMOKE ]]; then
  echo 'Keyboard input did not reach the real shell'
  xdotool getwindowfocus getwindowname
  xdotool getwindowgeometry "$window"
  import -window root "$root/.cache/test-logs/gui-failure.png"
  exit 1
fi
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
assert j['version']==6 and len(j['windows'])==1,j
layout=j['windows'][0]['layout']
assert layout['tab_count']==2,layout
assert len([n for n in layout['nodes'] if n['kind']=='pane'])==4,layout
print('PASS GTK window, input dispatch, 2 tabs / 4 PTYs, splits, search and resize')
PY
# Exercise the same portable font and rendering path headlessly for a durable PNG.
"$exe" --no-restore --hold '--command=printf "GUI READY 中文 é\n\033[32mANSI\033[0m\n"; sleep 30' \
  --nanoui-snapshot="$root/.cache/test-logs/linux-preview.png" --nanoui-wait=0.2
