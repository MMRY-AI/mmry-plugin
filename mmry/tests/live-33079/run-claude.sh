#!/usr/bin/env bash
# run-claude.sh OUTDIR [prestore] - Claude Code, two prompts in ONE session, scratch HOME/TMPDIR, Integration.
# prestore: this machine takes 60-90 s to run session-init (process spawn 1-2 s each under load) against
# Claude Code's 30 s SessionStart timeout, so the real SessionStart is cancelled. With prestore the SAME
# session-init command from hooks.json is run first, to completion, for the session id the run will use
# (as the 33030 live specs do), and the real per-prompt hooks run inside the real claude session.
set -u
OUT="${1:?outdir}"; PRE="${2:-}"; mkdir -p "$OUT"
HERE="$(dirname "$0")"
source "$HERE/common.sh" || exit 1
source "$J_SCRATCH/cc/env.sh"
export PLUGIN_ROOT="$J_REPO/mmry"
cd "$J_SCRATCH/cc/work" || exit 1
snap() { curl -s -H "X-Api-Key: $J_KEY" "$LIVE_URL/api/memories/startup?workingDirectory=$(pwd -W)" ; }
SID="$(powershell -NoProfile -Command '[guid]::NewGuid().ToString()' | tr -d '\r\n')"
printf '%s' "$SID" > "$OUT/session-id"
date -u +%FT%TZ > "$OUT/started"
snap > "$OUT/service-startup-before-p1.json"
if [[ "$PRE" == prestore ]]; then
  CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash -c "$("$LIVE_JQ" -r '.hooks.SessionStart[0].hooks[0].command' "$PLUGIN_ROOT/hooks/hooks.json")" \
    < <(printf '{"session_id":"%s","transcript_path":"","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$SID" "$(pwd -W)") \
    > "$OUT/prestore-sessionstart.out" 2> "$OUT/prestore-sessionstart.err"; echo "rc=$?" > "$OUT/prestore.rc"
  date -u +%FT%TZ > "$OUT/prestore-done"
fi
ARGS=(-p --output-format stream-json --verbose --include-hook-events --disallowed-tools "Bash Edit Write Read" --model haiku)
timeout 400 claude "${ARGS[@]}" --session-id "$SID" "Reply with the single word OK." > "$OUT/p1.jsonl" 2> "$OUT/p1.err" < /dev/null; echo "rc=$?" > "$OUT/p1.rc"
ls "$TMPDIR" > "$OUT/tmpdir-after-p1.txt"
snap > "$OUT/service-startup-before-p2.json"
timeout 400 claude "${ARGS[@]}" --resume "$SID" "Reply with the single word FINE." > "$OUT/p2.jsonl" 2> "$OUT/p2.err" < /dev/null; echo "rc=$?" > "$OUT/p2.rc"
snap > "$OUT/service-startup-after-p2.json"
ls "$TMPDIR" > "$OUT/tmpdir-after-p2.txt"
cp "$HOME/.claude/projects/"*/"$SID.jsonl" "$OUT/transcript.jsonl" 2>/dev/null
date -u +%FT%TZ > "$OUT/ended"
