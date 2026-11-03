#!/usr/bin/env bash
# run-codex.sh OUTDIR - Codex CLI, two prompts in ONE conversation (exec, then exec resume), scratch HOME,
# CODEX_HOME, TMPDIR, Integration. Plugin installed from the checkout into the scratch Codex home only,
# every MMRY hook trusted as a customer who accepted the plugin would (same method as codex-session-live.bats).
# Auth: a read-only copy of the signed-in auth.json goes into the scratch CODEX_HOME and is deleted after.
set -u
OUT="${1:?outdir}"; mkdir -p "$OUT"
HERE="$(dirname "$0")"
source "$HERE/common.sh" || exit 1
CX=/c/Users/ericbaroneai/AppData/Local/Programs/OpenAI/Codex/bin/codex
S="$J_SCRATCH/cx"
_native() { cygpath -w "$1"; }
_cx_rpc() {
    local out="$1" wait_id="$2"; shift 2; : > "$out"
    { printf '%s\n' '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"mmry-33079-live","version":"1"}}}' '{"method":"initialized"}'
      printf '%s\n' "$@"; local i=0
      while (( i < 150 )); do grep -q "\"id\":${wait_id}[,}]" "$out" 2>/dev/null && break; sleep 1; i=$((i+1)); done
    } | "$CX" app-server > "$out" 2> "${out}.err" || true
}
for v in $(env | grep -E '^(CLAUDE|ANTHROPIC|MMRY|CODEX)' | cut -d= -f1); do unset "$v"; done
export HOME="$S/home" USERPROFILE="$(_native "$S/home")" CODEX_HOME="$S/codexhome" TMPDIR="$S/tmp" TEMP="$(_native "$S/tmp")" TMP="$(_native "$S/tmp")" MMRY_TMPDIR="$S/tmp"
export MMRY_NO_SELF_UPDATE=1
rm -rf "$S/codexhome" "$S/tmp" "$S/home"; mkdir -p "$S/codexhome" "$S/tmp" "$S/home/.claude" "$S/work"
cp /c/Users/ericbaroneai/.codex/auth.json "$CODEX_HOME/auth.json"
printf 'model_reasoning_effort = "low"\n\n[windows]\nsandbox = "elevated"\n' > "$CODEX_HOME/config.toml"
live_write_config "$CODEX_HOME/mmry-config.json" "$J_KEY"
date -u +%FT%TZ > "$OUT/started"
"$CX" plugin marketplace add "$(_native "$J_REPO")" > "$OUT/install.out" 2>&1 || { echo "marketplace add failed" > "$OUT/FAILED"; exit 1; }
"$CX" plugin add mmry@mmry-plugin >> "$OUT/install.out" 2>&1 || { echo "plugin add failed" > "$OUT/FAILED"; exit 1; }
if [[ -n "${HOOK_TIMEOUT:-}" ]]; then  # MEASUREMENT VARIANT: the scratch plugin copy only, never the repo
  M="$CODEX_HOME/plugins/cache/mmry-plugin/mmry/local/hooks/codex-hooks.json"; cp "$M" "$OUT/codex-hooks.as-installed.json"
  "$LIVE_JQ" --argjson t "$HOOK_TIMEOUT" '(.hooks[][].hooks[].timeout) |= (if . < $t then $t else . end)' "$OUT/codex-hooks.as-installed.json" > "$M"
  echo "variant: every hook timeout raised to at least ${HOOK_TIMEOUT} s in the scratch plugin copy" > "$OUT/VARIANT.txt"
fi
wcwd="$(_native "$S/work")"
_cx_rpc "$OUT/hooks1.jsonl" 2 "$("$LIVE_JQ" -cn --arg w "$wcwd" '{id:2,method:"hooks/list",params:{cwds:[$w]}}')"
allv="$("$LIVE_JQ" -c 'select(.id==2) | [.result.data[]?.hooks[]? | select(.pluginId=="mmry@mmry-plugin") | {key:.key, value:{trusted_hash:.currentHash}}] | from_entries' "$OUT/hooks1.jsonl")"
want="$("$LIVE_JQ" -r '[.hooks[][].hooks[]] | length' "$PLUGIN_ROOT/hooks/codex-hooks.json")"; have="$("$LIVE_JQ" -r 'keys|length' <<< "$allv")"
echo "hooks listed=$have manifest=$want" > "$OUT/trust.txt"
write="$("$LIVE_JQ" -cn --argjson v "$allv" '{id:3,method:"config/value/write",params:{keyPath:"hooks.state",mergeStrategy:"upsert",value:$v}}')"
_cx_rpc "$OUT/hooks2.jsonl" 4 "$write" "$("$LIVE_JQ" -cn --arg w "$wcwd" '{id:4,method:"hooks/list",params:{cwds:[$w]}}')"
"$LIVE_JQ" -r 'select(.id==4)|.result.data[]?.hooks[]?|select(.pluginId=="mmry@mmry-plugin")|[.eventName,.trustStatus]|@tsv' "$OUT/hooks2.jsonl" >> "$OUT/trust.txt"
cd "$S/work" || exit 1
snap() { curl -s -H "X-Api-Key: $J_KEY" "$LIVE_URL/api/memories/startup?workingDirectory=$(pwd -W)"; }
snap > "$OUT/service-startup-before-p1.json"
timeout 500 "$CX" exec --skip-git-repo-check --sandbox read-only --json -o "$OUT/p1-last.txt" "Reply with the single word OK. Do not run any commands." < /dev/null > "$OUT/p1.jsonl" 2> "$OUT/p1.err"; echo "rc=$?" > "$OUT/p1.rc"
TID="$("$LIVE_JQ" -r 'select(.type=="thread.started")|.thread_id' "$OUT/p1.jsonl" | head -1)"; printf '%s' "$TID" > "$OUT/thread-id"
for n in 2 3 4; do
  sleep "${SETTLE:-30}"; snap > "$OUT/service-startup-before-p$n.json"; ls -la --time-style=full-iso "$TMPDIR" > "$OUT/tmp-before-p$n.txt"
  timeout 500 "$CX" exec resume --skip-git-repo-check --json -o "$OUT/p$n-last.txt" "$TID" "Reply with the single word FINE. Do not run any commands." < /dev/null > "$OUT/p$n.jsonl" 2> "$OUT/p$n.err"; echo "rc=$?" > "$OUT/p$n.rc"; date -u +%FT%TZ > "$OUT/p$n.done"
done
snap > "$OUT/service-startup-after-p2.json"
find "$CODEX_HOME/sessions" -name 'rollout-*.jsonl' -type f > "$OUT/rollouts.txt"
while read -r r; do cp "$r" "$OUT/rollout.jsonl"; done < "$OUT/rollouts.txt"
ls "$TMPDIR" > "$OUT/tmpdir-after.txt"
rm -f "$CODEX_HOME/auth.json"
date -u +%FT%TZ > "$OUT/ended"
