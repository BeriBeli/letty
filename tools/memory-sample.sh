#!/bin/bash
# Explicit PIDs only. /proc/PID/smaps works on EL7; RSS is not summed as PSS.
set -euo pipefail
pid=${1:?Usage: memory-sample.sh PID [count=10] [interval=1]}
count=${2:-10}
interval=${3:-1}
[[ "$pid" =~ ^[0-9]+$ && "$count" =~ ^[0-9]+$ ]] || { echo 'PID/count must be integers' >&2; exit 2; }
printf 'timestamp,pid,pss_kib,rss_kib,private_kib\n'
for ((i=0;i<count;i++)); do
  [[ -r /proc/$pid/smaps ]] || { echo "Cannot read /proc/$pid/smaps" >&2; exit 1; }
  awk -v now="$(date -u +%Y-%m-%dT%H:%M:%SZ)" -v pid="$pid" '
    /^Pss:/ {pss+=$2} /^Rss:/ {rss+=$2} /^Private_(Clean|Dirty):/ {private+=$2}
    END {printf "%s,%s,%d,%d,%d\n",now,pid,pss,rss,private}' "/proc/$pid/smaps"
  sleep "$interval"
done
