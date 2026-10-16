#!/usr/bin/env bash
d="$(cd "$(dirname "$0")" && pwd)"
n=$(cat "$d/count" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$d/count"
[ "$n" -eq 1 ] || exit 0
trap 'echo "$(date -u +%FT%TZ) TERM" >> "$d/hook.txt"; exit 0' TERM HUP
echo "$(date -u +%FT%TZ) start pid=$$" >> "$d/hook.txt"
t=0; while [ $t -lt 1740 ]; do sleep 10; t=$((t+10)); [ $((t % 300)) -eq 0 ] && echo "$(date -u +%FT%TZ) hb $t" >> "$d/hook.txt"; done
echo "$(date -u +%FT%TZ) exit2 after $t s" >> "$d/hook.txt"
echo "CEILING-PROBE-31850 the hook ran 1740 s. Reply with exactly: ACK" >&2; exit 2
