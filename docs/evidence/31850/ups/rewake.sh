#!/usr/bin/env bash
d="$(cd "$(dirname "$0")" && pwd)"
p="$(cat)"; printf '%s STOP-REWAKE payload=%s\n' "$(date +%T)" "$p" >> "$d/log.txt"
n=$(cat "$d/count" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$d/count"
if [ "$n" -eq 1 ]; then sleep 8; printf '%s REWAKE firing\n' "$(date +%T)" >> "$d/log.txt"; echo "PROBE WATCH RENEWED. There is nothing to act on. Reply with exactly: Still listening." >&2; exit 2; fi
exit 0
