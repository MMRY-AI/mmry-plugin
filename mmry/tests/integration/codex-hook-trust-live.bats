#!/usr/bin/env bats
# codex-hook-trust-live.bats - MMRY's hooks stay trusted from one Codex conversation to the next (#33062).
#
# THE DEFECT. A customer trusts MMRY's hooks once, as Codex asks them to. Codex records, for each hook,
# a hash of the hook and a hash of the plugin folder it installed (trusted_hash, trusted_content_hash).
# On 2.15.5 and 2.15.6 MMRY's first session wrote run-time files into that folder (.mmry-host from
# session-init.sh, .last-release-cleanup from self-update.sh), so from the second conversation on Codex
# found "plugin contents changed": the app showed "Hooks need review" again, and `codex exec` failed
# every MMRY hook with "plugin contents changed; hook approval required", so no memories loaded.
#
# WHAT THIS FILE PROVES, with the real Codex CLI against the real service (Integration, never
# production):
#   1. A private Codex home; MMRY installed with `codex plugin marketplace add` and `codex plugin add`;
#      every MMRY hook trusted ONCE, the way codex-session-live.bats does it (hooks/list for each hook's
#      key and current hash, config/value/write to record it; Codex's --dangerously-bypass-hook-trust is
#      NOT used).
#   2. Three conversations, one after the other, with `codex exec`. Each is handed MMRY's memories, and
#      none reports a hook needing approval.
#   3. After the second and third, Codex's own trust state (hooks/list) still reads every MMRY hook as
#      trusted, with the same hash it had when it was trusted. That is the state the interactive app
#      reads to decide whether to show "Hooks need review"; the screen itself is only seen by a person.
#   4. The plugin folder Codex fingerprints is byte-identical after the three conversations.
#
# The update check runs as it does for a customer (MMRY_NO_SELF_UPDATE is not set), inside its hourly
# debounce, so it does its once-per-version tidy-up but asks the network for nothing.
#
# NEEDS A REAL CODEX HOST and the accounts described in helpers/live-journey.bash; without them it FAILS
# and says so, it is never skipped. Like codex-session-live.bats it is in run-tests.sh's `journeys`,
# not `integration`. The machine's real ~/.codex, ~/.claude and temporary folder are never written.

load '../libs/bats-support/load'
load '../libs/bats-assert/load'
load '../helpers/live-journey'

_cx_rpc() {
    local out="$1" wait_id="$2"; shift 2
    : > "$out"
    {
        printf '%s\n' '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"mmry-33062-trust","version":"1"}}}' '{"method":"initialized"}'
        printf '%s\n' "$@"
        local i=0
        while (( i < 90 )); do
            grep -q "\"id\":${wait_id}[,}]" "$out" 2>/dev/null && break
            sleep 1; i=$((i + 1))
        done
    } | "$CX_BIN" app-server > "$out" 2> "${out}.err" || true
}

_native_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# _trust_state OUT - Codex's view of every MMRY hook, one "key trustStatus currentHash" line each, sorted.
_trust_state() {
    local S="$BATS_FILE_TMPDIR" n="$1"
    _cx_rpc "$S/state/hooks-$n.jsonl" 2 "$("$LIVE_JQ" -cn --arg w "$(_native_path "$S/work")" '{id:2,method:"hooks/list",params:{cwds:[$w]}}')"
    "$LIVE_JQ" -r 'select(.id==2) | .result.data[]?.hooks[]? | select(.pluginId=="mmry@mmry-plugin") | "\(.key) \(.trustStatus) \(.currentHash)"' \
        "$S/state/hooks-$n.jsonl" | tr -d '\r' | LC_ALL=C sort > "$S/state/trust-$n.txt"
}

# The plugin folder Codex installed, as names plus a checksum of every file.
_root_snapshot() {
    ( cd "$CX_ROOT" && find . -print | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort -k3 ) > "$1"
}

# Wait for MMRY's housekeeping, which runs on after a hook returns, to stop writing (at most 120 s).
_quiet() {
    local i=0 still=0 prev="" cur=""
    while (( i < 240 )); do
        cur="$(ls -lRa "$CX_ROOT" "$CODEX_HOME/mmry" 2>/dev/null)"
        if [[ "$cur" == "$prev" ]]; then still=$((still + 1)); (( still >= 10 )) && return 0; else still=0; fi
        prev="$cur"; sleep 0.5; i=$((i + 1))
    done
}

# _conversation N - one real `codex exec` conversation, its record kept as state/run-N.*.
_conversation() {
    local S="$BATS_FILE_TMPDIR" n="$1" rc=0 before after
    touch "$S/tmp/.mmry-update-checked"
    before="$(find "$CODEX_HOME/sessions" -name 'rollout-*.jsonl' -type f 2>/dev/null | LC_ALL=C sort)"
    ( cd "$S/work" && live_timeout 300 "$CX_BIN" exec --skip-git-repo-check --sandbox read-only --json \
        -o "$S/state/run-$n.last.txt" "Reply with the single word OK. Do not run any commands." \
        < /dev/null > "$S/state/run-$n.jsonl" 2> "$S/state/run-$n.err" ) || rc=$?
    printf '%s' "$rc" > "$S/state/run-$n.rc"
    after="$(find "$CODEX_HOME/sessions" -name 'rollout-*.jsonl' -type f 2>/dev/null | LC_ALL=C sort)"
    comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep . | head -1 > "$S/state/run-$n.rollout-path" || true
    if [[ -s "$S/state/run-$n.rollout-path" ]]; then
        cp "$(cat "$S/state/run-$n.rollout-path")" "$S/state/run-$n.rollout.jsonl"
    else
        : > "$S/state/run-$n.rollout.jsonl"
    fi
    "$LIVE_JQ" -r 'select(.type=="response_item" and .payload.type=="message" and .payload.role=="developer") | .payload.content[]? | .text? // empty' \
        "$S/state/run-$n.rollout.jsonl" | tr -d '\r' | grep 'MMRY AI' > "$S/state/run-$n.delivered.txt" || true
    _quiet
    _trust_state "after-$n"
}

setup_file() {
    export PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$BATS_TEST_DIRNAME/../.." && pwd)}"
    export LIVE_SPEC_NAME="codex-hook-trust-live.bats"
    live_require_accounts || return 1
    export LIVE_JQ LIVE_URL

    CX_BIN="${MMRY_LIVE_CODEX_BIN:-$(command -v codex 2>/dev/null || true)}"
    if [[ -z "$CX_BIN" || ! -x "$CX_BIN" ]]; then
        echo "no Codex CLI: this spec needs a real Codex host (set MMRY_LIVE_CODEX_BIN or put codex on PATH)" >&2
        return 1
    fi
    if [[ -z "${MMRY_LIVE_CODEX_AUTH:-}" || ! -f "${MMRY_LIVE_CODEX_AUTH}" ]]; then
        echo "MMRY_LIVE_CODEX_AUTH does not name a signed-in Codex auth.json; a real Codex conversation cannot start without one" >&2
        return 1
    fi
    local market
    market="$(cd "$PLUGIN_ROOT/.." && pwd)"
    [[ -f "$market/.claude-plugin/marketplace.json" ]] || { echo "no marketplace.json above $PLUGIN_ROOT" >&2; return 1; }
    export CX_BIN

    local S="$BATS_FILE_TMPDIR"
    mkdir -p "$S/state" "$S/home" "$S/tmp" "$S/work" "$S/codexhome"
    export HOME="$S/home" CODEX_HOME="$S/codexhome" TMPDIR="$S/tmp" TEMP="$S/tmp" TMP="$S/tmp" MMRY_TMPDIR="$S/tmp"
    unset MMRY_HOST CLAUDE_PLUGIN_ROOT CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID MMRY_CONFIG_FILE MMRY_NO_SELF_UPDATE
    export MMRY_API_URL="" MMRY_API_KEY="" MMRY_AUTH_METHOD=""

    cp "$MMRY_LIVE_CODEX_AUTH" "$CODEX_HOME/auth.json"
    printf 'model_reasoning_effort = "low"\n\n[windows]\nsandbox = "elevated"\n' > "$CODEX_HOME/config.toml"

    # One Foundation memory in account A, so every conversation has something to be handed.
    local id
    id="$(live_plant "$MMRY_INTEGRATION_API_KEY" "J-011 hook trust $(live_nonce)" "Planted by ${LIVE_SPEC_NAME} (#33062).")" || return 1
    printf '%s' "$id" > "$S/state/id-a"
    live_write_config "$CODEX_HOME/mmry-config.json" "$MMRY_INTEGRATION_API_KEY"

    live_timeout 120 "$CX_BIN" plugin marketplace add "$(_native_path "$market")" > "$S/state/install.out" 2>&1 \
        || { echo "codex plugin marketplace add failed: $(tail -3 "$S/state/install.out")" >&2; return 1; }
    live_timeout 120 "$CX_BIN" plugin add mmry@mmry-plugin >> "$S/state/install.out" 2>&1 \
        || { echo "codex plugin add failed: $(tail -3 "$S/state/install.out")" >&2; return 1; }
    CX_ROOT="$(find "$CODEX_HOME/plugins/cache/mmry-plugin/mmry" -mindepth 1 -maxdepth 1 -type d | head -1)"
    [[ -n "$CX_ROOT" && -f "$CX_ROOT/hooks/codex-hooks.json" ]] || { echo "no installed MMRY plugin folder under $CODEX_HOME/plugins/cache" >&2; return 1; }
    export CX_ROOT

    # Trust every MMRY hook once, as codex-session-live.bats does.
    local wcwd allv write want have
    wcwd="$(_native_path "$S/work")"
    _cx_rpc "$S/state/hooks0.jsonl" 2 "$("$LIVE_JQ" -cn --arg w "$wcwd" '{id:2,method:"hooks/list",params:{cwds:[$w]}}')"
    allv="$("$LIVE_JQ" -c 'select(.id==2) | [.result.data[]?.hooks[]? | select(.pluginId=="mmry@mmry-plugin") | {key:.key, value:{trusted_hash:.currentHash}}] | from_entries' "$S/state/hooks0.jsonl")"
    want="$("$LIVE_JQ" -r '[.hooks[][].hooks[]] | length' "$PLUGIN_ROOT/hooks/codex-hooks.json")"
    have="$("$LIVE_JQ" -r 'keys | length' <<< "$allv")"
    (( want > 0 && have == want )) || { echo "Codex listed $have MMRY hooks, hooks/codex-hooks.json registers $want" >&2; return 1; }
    write="$("$LIVE_JQ" -cn --argjson v "$allv" '{id:3,method:"config/value/write",params:{keyPath:"hooks.state",mergeStrategy:"upsert",value:$v}}')"
    _cx_rpc "$S/state/hooks-write.jsonl" 3 "$write"
    _trust_state trusted
    if grep -qv ' trusted ' "$S/state/trust-trusted.txt" || [[ "$(grep -c . "$S/state/trust-trusted.txt")" != "$want" ]]; then
        echo "Codex did not record every MMRY hook as trusted: $(cat "$S/state/trust-trusted.txt")" >&2
        return 1
    fi
    _root_snapshot "$S/state/root-installed.txt"

    _conversation 1
    _conversation 2
    _conversation 3
    _root_snapshot "$S/state/root-after.txt"
}

teardown_file() {
    live_resolve_jq >/dev/null 2>&1 || true
    live_service_url >/dev/null 2>&1 || return 0
    [[ -f "$BATS_FILE_TMPDIR/state/id-a" ]] && live_retire "$MMRY_INTEGRATION_API_KEY" "$(cat "$BATS_FILE_TMPDIR/state/id-a")"
    return 0
}

_s() { printf '%s' "$BATS_FILE_TMPDIR/state"; }

# _assert_session N - conversation N ran MMRY's hooks: it was handed the memories, and no hook was
# refused for want of approval.
_assert_session() {
    local n="$1"
    run grep -l -i -e 'hook approval required' -e 'plugin contents changed' -e 'hooks need review' \
        "$(_s)/run-$n.err" "$(_s)/run-$n.jsonl" "$(_s)/run-$n.rollout.jsonl"
    [[ "$status" -eq 1 ]] || {
        echo "conversation $n: Codex refused MMRY's hooks:"
        grep -h -i -o -e '.\{0,120\}hook approval required.\{0,40\}' -e '.\{0,120\}plugin contents changed.\{0,40\}' \
            "$(_s)/run-$n.err" "$(_s)/run-$n.jsonl" "$(_s)/run-$n.rollout.jsonl" | head -5
        return 1
    }
    run grep -m1 -E '^MMRY AI loaded [0-9]+ memories\. Read them now: ' "$(_s)/run-$n.delivered.txt"
    [[ "$status" -eq 0 ]] || {
        echo "conversation $n was not handed MMRY's memories. MMRY developer messages: $(cat "$(_s)/run-$n.delivered.txt")"
        echo "codex exec exit $(cat "$(_s)/run-$n.rc"); last stderr: $(tail -5 "$(_s)/run-$n.err")"
        return 1
    }
}

# _assert_trust N - after conversation N Codex still reads every MMRY hook as trusted, unchanged.
_assert_trust() {
    run diff "$(_s)/trust-trusted.txt" "$(_s)/trust-after-$1.txt"
    [[ "$status" -eq 0 ]] || {
        echo "after conversation $1 Codex's trust state for MMRY's hooks changed (< when trusted, > now):"
        echo "$output"
        return 1
    }
}

@test "codex trust: the first conversation after trusting MMRY is handed its memories" {
    _assert_session 1
    _assert_trust 1
}

@test "codex trust: the second conversation keeps hook trust and MMRY's hooks run" {
    _assert_session 2
}

@test "codex trust: the third conversation keeps hook trust and MMRY's hooks run" {
    _assert_session 3
}

@test "codex trust: after the second and third conversations hooks/list reads every MMRY hook trusted, hash unchanged" {
    _assert_trust 2
    _assert_trust 3
}

@test "codex trust: the plugin folder Codex fingerprints is byte-identical after three conversations" {
    run diff "$(_s)/root-installed.txt" "$(_s)/root-after.txt"
    [[ "$status" -eq 0 ]] || { echo "the installed plugin folder changed (< installed, > after three conversations):"; echo "$output"; return 1; }
}
