#!/usr/bin/env bash
# Runs one variant: starts the stub, then one headless Claude Code session (driver.js from #31721)
# that answers one prompt and then sits idle for HOLD seconds with nobody typing. The watch window is
# shortened to WINDOW seconds (MMRY_IDLE_POLL_SECONDS) so renewals come every half minute.
#
# The save prompt is debounced for 15 minutes, which a 28-minute window always outlasts. With a short
# window it would not, so the harness ages the save prompt's marker past the debounce once per watch,
# 10 s before that watch renews - exactly the state a real renewal turn starts from.
#   bash run.sh <run dir> <plugin mmry dir> <port> <hold seconds> <window seconds>
set -euo pipefail
RUN="$1"; PLUGIN="$2"; PORT="$3"; HOLD="$4"; WINDOW="$5"
HERE="$(cd "$(dirname "$0")" && pwd)"
DRIVER="$HERE/../../31721/ceiling/driver.js"
node "$HERE/stub.js" "$PORT" "$RUN/requests.txt" & STUB=$!
trap 'kill $STUB 2>/dev/null || true; kill $AGER 2>/dev/null || true' EXIT
(
  seen=""
  while :; do
    for d in "$RUN"/tmp/.mmry-formation-poll-*; do
      [[ -f "$d/pid" ]] || continue
      pid="$(cat "$d/pid" 2>/dev/null || true)"
      age=$(( $(date +%s) - $(stat -c %Y "$d/pid" 2>/dev/null || echo 0) ))
      if [[ "$pid" != "$seen" ]] && (( age >= WINDOW - 10 )); then
        touch -t 202001010000.00 "$RUN/tmp/.mmry-stop-checked" 2>/dev/null || true
        echo "$(date -u +%FT%TZ) aged save marker for watch $pid" >> "$RUN/harness.txt"
        seen="$pid"
      fi
    done
    sleep 1
  done
) & AGER=$!
cd "$RUN/project"
HOME="$(cd "$RUN/home" && pwd)" TMPDIR="$(cd "$RUN/tmp" && pwd)" CLAUDE_PLUGIN_ROOT="$PLUGIN" \
MMRY_CONFIG_FILE="$(cd "$RUN/home" && pwd)/.claude/mmry-config.json" MMRY_IDLE_POLL_SECONDS="$WINDOW" \
  node "$DRIVER" "$(pwd -W)" "$HOLD" "$RUN/session.txt" "Reply with exactly: READY"
