#!/bin/bash
set -euo pipefail
lines=${1:-100000}
[[ "$lines" =~ ^[0-9]+$ ]] || exit 2
awk -v n="$lines" 'BEGIN {for(i=1;i<=n;i++) printf "\033[3%dm%08d log 中文 é payload abcdefghijklmnopqrstuvwxyz\033[0m\n", i%7+1, i}'
