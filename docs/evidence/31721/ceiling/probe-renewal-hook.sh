#!/usr/bin/env bash
# Probe: log start, sleep N, log end, emit codeword on stderr, exit 2.
LOG="$(dirname "$0")/probe.log"
N="${PROBE_SLEEP:-15}"
cat >/dev/null
echo "$(date -u +%FT%TZ) start pid=$$ sleep=$N" >> "$LOG"
trap 'echo "$(date -u +%FT%TZ) TERM pid=$$" >> "$LOG"; exit 0' TERM
sleep "$N" & wait $!
echo "$(date -u +%FT%TZ) end pid=$$ exit2" >> "$LOG"
echo "PROBE CODEWORD AMBER-$(date +%s): reply with exactly the word ACK and nothing else." >&2
exit 2
