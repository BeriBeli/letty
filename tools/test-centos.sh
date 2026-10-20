#!/bin/bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mode=${1:-help}
case "$mode" in
  probe) "$root/bin/letty-probe" ;;
  core)
    "$root/bin/letty-unit-tests"
    "$root/bin/letty-check"
    "$root/bin/letty-vt-replay"
    "$root/bin/letty-vt-n2"
    "$root/bin/letty-vt-protocol"
    if [[ -x "$root/bin/letty-vt-boundary" ]]; then "$root/bin/letty-vt-boundary"; fi
    if [[ -x "$root/bin/letty-vt-graphics" ]]; then "$root/bin/letty-vt-graphics"; fi
    ;;
  gui) : "${DISPLAY:?Run inside your SSH X11 session first}"; "$root/bin/letty" --no-restore "${@:2}" ;;
  collect)
    out=${2:-letty-diagnostics-$(date +%Y%m%d-%H%M%S)}
    mkdir -p -- "$out"
    {
      uname -a
      getconf GNU_LIBC_VERSION
      printf 'DISPLAY=%s\nLANG=%s\nLC_CTYPE=%s\nGTK_IM_MODULE=%s\nXMODIFIERS=%s\n' "${DISPLAY-}" "${LANG-}" "${LC_CTYPE-}" "${GTK_IM_MODULE-}" "${XMODIFIERS-}"
      rpm -q glibc gtk3 glib2 cairo fontconfig 2>/dev/null || true
      locale
      command -v fc-match >/dev/null && fc-match monospace || true
      command -v fc-match >/dev/null && fc-match ':lang=zh' || true
      command -v infocmp >/dev/null && infocmp xterm-256color >/dev/null && echo 'xterm-256color terminfo: present' || true
    } >"$out/environment.txt" 2>&1
    cp -- "$root/build-info.json" "$out/"
    if "$root/bin/letty-probe" >"$out/probe.txt" 2>&1; then echo 'Probe passed'; else echo 'Probe failed; see log'; fi
    if "$root/bin/letty-check" >"$out/core.txt" 2>&1; then echo 'Core passed'; else echo 'Core failed; see log'; fi
    printf 'Saved diagnostics in %s (review before sharing)\n' "$out"
    ;;
  *) printf '%s\n' 'Usage: tools/test-centos.sh probe|core|gui|collect [output-directory]' 'GUI options after gui are forwarded to Letty.'; exit 0 ;;
esac
