#!/bin/bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mode=${1:-run}
case "$mode" in
run | --verify | --debug | --logs) ;;
*)
  echo "Usage: $0 [run|--verify|--debug|--logs]" >&2
  exit 2
  ;;
esac
cd "$root"
if [[ ! -f vendor/nanoui/.letty-revision || ! -f vendor/ghostty/.letty-revision ]]; then
  python3 tools/bootstrap.py --sources-only
fi
zig_path=${ZIG:-}
if [[ -z "$zig_path" && -x .cache/tools/zig-aarch64-macos-0.17.0/zig ]]; then
  zig_path="$root/.cache/tools/zig-aarch64-macos-0.17.0/zig"
fi
if [[ -z "$zig_path" ]]; then zig_path=$(command -v zig || true); fi
if [[ -z "$zig_path" ]]; then
  python3 tools/bootstrap.py
  zig_path="$root/.cache/tools/zig-aarch64-macos-0.17.0/zig"
fi
python3 tools/build.py --native --skip-bootstrap --zig="$zig_path"
python3 tools/verify-ui.py --prefix=native
python3 tools/package-port-preview.py
bundle="$root/dist/Letty.app"
mkdir -p "$root/.cache/test-logs"
case "$mode" in
--debug) exec lldb -- "$bundle/Contents/MacOS/Letty" ;;
*) /usr/bin/open -n "$bundle" --stdout "$root/.cache/test-logs/macos-app.stdout.log" --stderr "$root/.cache/test-logs/macos-app.stderr.log" ;;
esac
case "$mode" in
--verify)
  for ((i = 0; i < 30; i++)); do
    if pgrep -x Letty >/dev/null; then
      echo 'Letty launched'
      exit 0
    fi
    sleep 0.2
  done
  cat "$root/.cache/test-logs/macos-app.stderr.log" >&2
  echo 'Letty did not remain running' >&2
  exit 1
  ;;
--logs) exec /usr/bin/log stream --info --style compact --predicate 'process == "Letty"' ;;
esac
