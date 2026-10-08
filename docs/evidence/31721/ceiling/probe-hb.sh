#!/usr/bin/env bash
# Probe with heartbeat: log every 10 s while sleeping N; on completion emit codeword and exit 2.
LOG="$1/probe.log"; N="$2"
cat >/dev/null
echo "$(date -u +%FT%TZ) start pid=$$ sleep=$N" >> "$LOG"
trap 'echo "$(date -u +%FT%TZ) TERM pid=$$" >> "$LOG"; exit 0' TERM
trap 'echo "$(date -u +%FT%TZ) HUP pid=$$" >> "$LOG"; exit 0' HUP
t=0
while (( t < N )); do sleep 10; t=$((t+10)); echo "$(date -u +%FT%TZ) hb pid=$$ t=$t" >> "$LOG"; done
echo "$(date -u +%FT%TZ) end pid=$$ exit2" >> "$LOG"
echo "PROBE CODEWORD AMBER: reply with exactly the word ACK and nothing else." >&2
exit 2
