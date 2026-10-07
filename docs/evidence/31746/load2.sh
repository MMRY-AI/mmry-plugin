#!/usr/bin/env bash
# load2.sh - hold a Windows Git Bash machine at roughly the load recorded on #31746
# (about 62 bash processes, CPU about 34%) for as long as STOPFILE is absent.
#
#   SPIN busy-loop bash workers, each pinning one logical CPU (no forking: pure CPU)
#   IDLE bash workers that wake every NAP seconds (default 2) and fork once (date)
#
# Usage: load2.sh SPIN IDLE STOPFILE [NAP]
SPIN="${1:-8}"; IDLE="${2:-50}"; STOP="$3"; NAP="${4:-2}"
rm -f "$STOP"
for i in $(seq 1 "$SPIN"); do
    bash -c 'n=0; while [ ! -f "'"$STOP"'" ]; do n=$((n+1)); if [ $((n % 200000)) -eq 0 ]; then :; fi; done' >/dev/null 2>&1 &
done
for i in $(seq 1 "$IDLE"); do
    bash -c 'while [ ! -f "'"$STOP"'" ]; do sleep '"$NAP"'; date >/dev/null; done' >/dev/null 2>&1 &
done
echo "started ${SPIN} spinners and ${IDLE} idle workers"
