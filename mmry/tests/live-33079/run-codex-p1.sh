#!/usr/bin/env bash
# run-codex-p1.sh OUTDIR - P1 (copy proof): Codex "load my memories" in the NOT-LOADED case. Reuses the scratch CODEX_HOME that
# run-codex.sh installed and trusted (plugin d472548). DECLARED MOCK: for this one session start the scratch mmry-config.json
# points at an unreachable API (127.0.0.1:9), so SessionStart cannot load; a watcher restores the real config the moment the
# first-prompt hook has run, i.e. before the assistant can call memory_load. The key is only ever copied, never read or printed.
set -u
OUT="${1:?outdir}"; mkdir -p "$OUT"
HERE="$(dirname "$0")"
source "$HERE/common.sh" || exit 1
CX=/c/Users/ericbaroneai/AppData/Local/Programs/OpenAI/Codex/bin/codex
S="$J_SCRATCH/cx"
_native() { cygpath -w "$1"; }
for v in $(env | grep -E '^(CLAUDE|ANTHROPIC|MMRY|CODEX)' | cut -d= -f1); do unset "$v"; done
export HOME="$S/home" USERPROFILE="$(_native "$S/home")" CODEX_HOME="$S/codexhome" TMPDIR="$S/tmp" TEMP="$(_native "$S/tmp")" TMP="$(_native "$S/tmp")" MMRY_TMPDIR="$S/tmp"
export MMRY_NO_SELF_UPDATE=1
rm -rf "$S/tmp"; mkdir -p "$S/tmp"
cp /c/Users/ericbaroneai/.codex/auth.json "$CODEX_HOME/auth.json"
cp "$CODEX_HOME/mmry-config.json" "$S/mmry-config.good"
"$LIVE_JQ" -cn '{apiUrl:"http://127.0.0.1:9",apiKey:"unreachable-mock",authMethod:"apikey"}' > "$CODEX_HOME/mmry-config.json"
echo "MOCK: scratch mmry-config.json points at http://127.0.0.1:9 until the first-prompt hook has run" > "$OUT/MOCK.txt"; date -u +%FT%TZ > "$OUT/started"
( i=0; while (( i < 600 )); do [[ -f "$S/tmp/mmry-codex-first-prompt.log" ]] && break; sleep 0.1; i=$((i+1)); done
  cp "$S/mmry-config.good" "$CODEX_HOME/mmry-config.json"; date -u +%T.%N > "$OUT/config-restored-at" ) &
W=$!
cd "$S/work" || exit 1
timeout 400 "$CX" exec --skip-git-repo-check --sandbox read-only --json -o "$OUT/p1-last.txt" "${PROMPT:-Load my MMRY memories now.}" < /dev/null > "$OUT/p1.jsonl" 2> "$OUT/p1.err"; echo "rc=$?" > "$OUT/p1.rc"
wait $W
cp "$S/mmry-config.good" "$CODEX_HOME/mmry-config.json"
cp "$S/tmp/mmry-codex-session-start.log" "$S/tmp/mmry-codex-first-prompt.log" "$OUT/" 2>/dev/null
ls -la --time-style=full-iso "$S/tmp" > "$OUT/tmp-after.txt"
find "$CODEX_HOME/sessions" -name 'rollout-*.jsonl' -newer "$OUT/started" -type f | head -1 | while read -r r; do cp "$r" "$OUT/rollout.jsonl"; done
rm -f "$CODEX_HOME/auth.json" "$S/mmry-config.good"
date -u +%FT%TZ > "$OUT/ended"
