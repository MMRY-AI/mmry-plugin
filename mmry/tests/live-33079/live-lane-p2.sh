#!/usr/bin/env bash
# live-lane.sh BASE_COMMIT - #33062 fix round 5 (r5b), tests 5a/5b/5c on real Codex (codex exec).
# One Codex customer timeline in a private HOME, CODEX_HOME and TMPDIR, adapted from
# 33062-r5-hooktrust/update-impact/harness/lane.sh. Integration only (account A key, never printed).
# Never touches the real ~/.codex or ~/.claude except a read-only copy of ~/.codex/auth.json.
# The "remote" (GitHub master for self-update, and the Codex marketplace channel) is a local bare repo:
#   base = BASE_COMMIT (the build under test), next = base + version 2.15.7 + PROBE lines.
set -euo pipefail
BASE_COMMIT="$1"
R=/c/Users/ericbaroneai/scratch/33079-r2/p2
L="$R/lane-live"
EV="R:/Intranet/ClaudeAI/plans/MMRY/v1.32.1/33079-j016-live/copy-proofs/P2-live-lane"
BARE="$R/bare.git"
SRC=/c/Users/ericbaroneai/repos/33079-r2-plugin
CX="$(command -v codex)"
JQ="$(command -v jq)"
FLAG="R:/Intranet/ClaudeAI/plans/MMRY/v1.32.1/INTEGRATION-CLEAR.flag"
[[ -f "$FLAG" ]] || { echo "INTEGRATION-CLEAR.flag is gone; not running"; exit 3; }

# --- the simulated remote -------------------------------------------------------------------------
rm -rf "$BARE" "$R/next-build"
git init -q --bare "$BARE"
git -C "$SRC" push -q "$BARE" "$BASE_COMMIT:refs/heads/base"
git clone -q "$BARE" "$R/next-build" -b base
ORIGIN="$(git -C "$R/next-build" remote get-url origin)"
case "$ORIGIN" in */scratch/33079-r2/*) ;; *) echo "SAFETY: origin is not the scratch bare repo: $ORIGIN"; exit 9;; esac
git -C "$R/next-build" remote -v
(
    cd "$R/next-build"
    git config user.email r5b@local; git config user.name r5b
    sed -i 's/"version": "2.15.6"/"version": "2.15.7"/' .claude-plugin/marketplace.json mmry/.claude-plugin/plugin.json
    sed -i '1s/.*/# mmry release files 2.15.7/' mmry/release-files.txt
    for f in session-init.sh session-start.sh codex-hook.sh; do
        sed -i "1a printf '%s %s %s %s\\\\n' PROBE-2.15.7 $f \"\${1:-}\" \"\$(cd \"\$(dirname \"\${BASH_SOURCE[0]:-\$0}\")\" \&\& pwd)\" >> \"\${TMPDIR:-/tmp}/r5b-probe.log\" 2>/dev/null || true" "mmry/hooks-handlers/$f"
    done
    git commit -qam "r5b live: next 2.15.7 with probes"
    git push -q origin HEAD:refs/heads/next
)
mkdir -p "$EV"
git -C "$BARE" log --oneline -2 next > "$EV/remote-refs.txt"
git -C "$BARE" diff --stat base next >> "$EV/remote-refs.txt"
git -C "$BARE" diff base next -- mmry/hooks-handlers >> "$EV/remote-refs.txt"

# --- the private customer -------------------------------------------------------------------------
rm -rf "$L"; mkdir -p "$L"/{home,codexhome,tmp,work,state,remote}
export HOME="$L/home" CODEX_HOME="$L/codexhome" TMPDIR="$L/tmp" TEMP="$L/tmp" TMP="$L/tmp" MMRY_TMPDIR="$L/tmp"
unset MMRY_HOST CLAUDE_PLUGIN_ROOT CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID MMRY_CONFIG_FILE MMRY_NO_SELF_UPDATE MMRY_API_KEY MMRY_API_URL
export IMPACT_LANE="$(cygpath -m "$L")" BASH_ENV="$(cygpath -m "$R/mock-curl.bash")"
cp "R:/Intranet/ClaudeAI/plans/MMRY/v1.32.1/33062-r5-hooktrust/update-impact/harness/mock-curl.bash" "$R/mock-curl.bash"
S="$L/state"
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$S/timeline.txt"; }
nat() { cygpath -w "$1"; }
MP="$CODEX_HOME/.tmp/marketplaces/mmry-plugin"
ROOT="$CODEX_HOME/plugins/cache/mmry-plugin/mmry/local"
ST="$CODEX_HOME/mmry"

publish_remote() {
    git -C "$BARE" branch -f chan "$1" >/dev/null
    git -C "$BARE" show "$1:.claude-plugin/marketplace.json" > "$L/remote/marketplace.json"
    git -C "$BARE" archive --format=tar.gz --prefix=mmry-plugin-master/ -o "$L/remote/master.tar.gz" "$1"
    log "REMOTE now $1 ($(git -C "$BARE" rev-parse --short "$1"), version $($JQ -r '.plugins[0].version' "$L/remote/marketplace.json"))"
}
rpc() {
    local out="$1" wait_id="$2"; shift 2
    : > "$out"
    { printf '%s\n' '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"mmry-33062-r5b","version":"1"}}}' '{"method":"initialized"}'
      printf '%s\n' "$@"
      local i=0; while (( i < 90 )); do grep -q "\"id\":${wait_id}[,}]" "$out" 2>/dev/null && break; sleep 1; i=$((i+1)); done
    } | ( cd "$L/work" && "$CX" app-server ) > "$out" 2> "${out}.err" || true
}
trust_state() {
    rpc "$S/hooks-$1.jsonl" 2 "$($JQ -cn --arg w "$(nat "$L/work")" '{id:2,method:"hooks/list",params:{cwds:[$w]}}')"
    $JQ -r 'select(.id==2) | .result.data[]?.hooks[]? | select(.pluginId=="mmry@mmry-plugin") | "\(.key) \(.trustStatus) \(.currentHash)"' "$S/hooks-$1.jsonl" | tr -d '\r' | LC_ALL=C sort > "$S/trust-$1.txt"
    log "TRUST $1: $(awk '{print $2}' "$S/trust-$1.txt" | sort | uniq -c | tr '\n' ' ')"
}
trust_all() {
    rpc "$S/hooks-pre-$1.jsonl" 2 "$($JQ -cn --arg w "$(nat "$L/work")" '{id:2,method:"hooks/list",params:{cwds:[$w]}}')"
    local v; v="$($JQ -c 'select(.id==2) | [.result.data[]?.hooks[]? | select(.pluginId=="mmry@mmry-plugin") | {key:.key, value:{trusted_hash:.currentHash}}] | from_entries' "$S/hooks-pre-$1.jsonl")"
    rpc "$S/hooks-write-$1.jsonl" 3 "$($JQ -cn --argjson v "$v" '{id:3,method:"config/value/write",params:{keyPath:"hooks.state",mergeStrategy:"upsert",value:$v}}')"
    log "TRUST-ALL $1 written ($($JQ -r 'keys|length' <<< "$v") hooks) - the customer's one hook review"
    trust_state "$1"
}
snap() {
    local f="$S/snap-$1.txt"
    {
        echo "plugin folder version: $($JQ -r .version "$ROOT/.claude-plugin/plugin.json" 2>/dev/null)"
        echo "plugin folder probe lines: $(grep -l PROBE "$ROOT"/hooks-handlers/*.sh 2>/dev/null | wc -l)"
        echo "plugin folder dotfiles: $(cd "$ROOT" 2>/dev/null && ls -A | grep '^\.' | tr '\n' ' ')"
        echo "plugin folder checksum: $(cd "$ROOT" 2>/dev/null && find . -type f -exec cksum {} + | LC_ALL=C sort -k3 | cksum)"
        echo "state dir version (plugin.json): $($JQ -r .version "$ST/.claude-plugin/plugin.json" 2>/dev/null)"
        echo "state dir .last-self-update: $(cat "$ST/.last-self-update" 2>/dev/null)"
        echo "state dir .last-release-cleanup: $(cat "$ST/.last-release-cleanup" 2>/dev/null)"
        echo "state dir probe lines: $(grep -l PROBE "$ST"/hooks-handlers/*.sh 2>/dev/null | wc -l)"
    } > "$f"
    ( cd "$ROOT" 2>/dev/null && find . -print | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort -k3 ) > "$S/root-$1.txt"
    sed "s/^/  /" "$f" | tee -a "$S/timeline.txt"
}
quiet() { local i=0 still=0 prev="" cur=""; while (( i < 240 )); do cur="$(ls -lRa "$ROOT" "$ST" 2>/dev/null)"; if [[ "$cur" == "$prev" ]]; then still=$((still+1)); (( still >= 10 )) && return 0; else still=0; fi; prev="$cur"; sleep 0.5; i=$((i+1)); done; }
conversation() {
    local n="$1" rc=0 before after rp
    rm -f "$TMPDIR/.mmry-update-checked"
    : > "$TMPDIR/r5b-probe.log"
    before="$(find "$CODEX_HOME/sessions" -name 'rollout-*.jsonl' -type f 2>/dev/null | LC_ALL=C sort)"
    log "SESSION $n: codex exec"
    ( cd "$L/work" && timeout 300 "$CX" exec --skip-git-repo-check --sandbox read-only --json \
        -o "$S/run-$n.last.txt" "Reply with the single word OK. Do not run any commands." \
        < /dev/null > "$S/run-$n.jsonl" 2> "$S/run-$n.err" ) || rc=$?
    after="$(find "$CODEX_HOME/sessions" -name 'rollout-*.jsonl' -type f 2>/dev/null | LC_ALL=C sort)"
    rp="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep . | head -1)"
    [[ -n "$rp" ]] && cp "$rp" "$S/run-$n.rollout.jsonl" || : > "$S/run-$n.rollout.jsonl"
    $JQ -r 'select(.type=="response_item" and .payload.type=="message" and .payload.role=="developer") | .payload.content[]? | .text? // empty' "$S/run-$n.rollout.jsonl" | tr -d '\r' | grep 'MMRY AI' > "$S/run-$n.delivered.txt" || true
    quiet
    cp "$TMPDIR/r5b-probe.log" "$S/probe-$n.log" 2>/dev/null
    log "  exit $rc; memories handed: $(grep -c -E '^MMRY AI loaded [0-9]+ memories' "$S/run-$n.delivered.txt")"
    log "  hook refusals: $(grep -h -i -o -e 'hook approval required' -e 'plugin contents changed' "$S/run-$n.err" "$S/run-$n.jsonl" "$S/run-$n.rollout.jsonl" 2>/dev/null | sort | uniq -c | tr '\n' ' ')"
    log "  probes this session: $(sed "s#$(cygpath -m "$L")#<L>#g; s#$L#<L>#g" "$S/probe-$n.log" 2>/dev/null | awk '{print $1, $2, $3, $4}' | sort | uniq -c | tr '\n' ';')"
    log "  mock self-update fetches so far: $(cut -d' ' -f2 "$L/mock-curl.log" 2>/dev/null | sort | uniq -c | tr '\n' ' ')"
    snap "after-$n"
}

log "LIVE LANE base $BASE_COMMIT ($(git -C "$SRC" rev-parse --short "$BASE_COMMIT")); codex $("$CX" --version)"
cp "/c/Users/ericbaroneai/.codex/auth.json" "$CODEX_HOME/auth.json"
printf 'model_reasoning_effort = "low"\n\n[windows]\nsandbox = "elevated"\n' > "$CODEX_HOME/config.toml"
KEY="$(cat /c/Users/ericbaroneai/.mmry-test-secrets/integration-33030-a-apikey)"
$JQ -cn --arg u "https://integration.mmryai.com" --arg k "$KEY" '{apiUrl:$u,apiKey:$k,authMethod:"apikey"}' > "$CODEX_HOME/mmry-config.json"
unset KEY
publish_remote base
( cd "$L/work" && timeout 180 "$CX" plugin marketplace add MMRY-AI/mmry-plugin ) >> "$S/install.out" 2>&1
sed -i "s#^source = .*#source = \"file:///$(cygpath -m "$BARE")\"\nref = \"chan\"#" "$CODEX_HOME/config.toml"
( cd "$L/work" && timeout 180 "$CX" plugin marketplace upgrade && timeout 180 "$CX" plugin add mmry@mmry-plugin ) >> "$S/install.out" 2>&1
log "installed: $(tail -2 "$S/install.out" | tr '\n' ' ')"
snap installed
trust_all initial
set +e   # setup done under set -e; sessions keep the original lenient mode
conversation 1
trust_state after-1
conversation 2
trust_state after-2
log "=== RELEASE: next (2.15.7) published to GitHub master and the Codex marketplace channel ==="
publish_remote next
conversation 3
trust_state after-3
log "=== the customer's one review for this release ==="
trust_all review-2.15.7
conversation 4
trust_state after-4
conversation 5
trust_state after-5
conversation 6
trust_state after-6
log "LIVE LANE DONE"
cp "$S"/timeline.txt "$S"/snap-*.txt "$S"/trust-*.txt "$S"/run-*.delivered.txt "$S"/run-*.err "$S"/probe-*.log "$S"/install.out "$S"/root-*.txt "$EV"/ 2>/dev/null
cp "$L/mock-curl.log" "$EV/mock-curl.log" 2>/dev/null
cp "$TMPDIR/mmry-codex-session-start.log" "$EV/mmry-codex-session-start.log" 2>/dev/null
echo "EXIT=0"
