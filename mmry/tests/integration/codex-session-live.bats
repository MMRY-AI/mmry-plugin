#!/usr/bin/env bats
# codex-session-live.bats - J-011@codex, live, on a real Codex host (#33030).
#
# THE JOURNEY. A subscriber starts a new Codex conversation and their memories load on their own:
# the account's startup memories, its Foundation memories among them, reach the conversation, and
# the assistant is told to read them. handlers/codex-session.bats proves the handlers against a
# mocked service. This file proves the journey with the real Codex CLI against the real service
# (Integration, never production):
#
#   1. A Foundation memory with a marker unique to this run is planted in the test account (A), and
#      another in a second account (B).
#   2. A private Codex home is made: the signed-in auth.json copied in, MMRY installed from this
#      checkout with `codex plugin marketplace add` and `codex plugin add`, exactly as docs/codex.md
#      tells a customer, and account A's config written where setup writes it.
#   3. MMRY's session-start hook is trusted the way the customer trusts it, by recording its
#      trusted_hash in that home's config.toml. Codex has no flag for that, so the record is written
#      through Codex's own app-server (hooks/list for the key and hash, config/value/write to record
#      it), which is what the CLI's trust review writes. Only that one hook is trusted. Codex's
#      --dangerously-bypass-hook-trust is NOT used: the spec proves the trusted path a customer has.
#   4. One real conversation is started with `codex exec`. Codex itself runs the hook (on Windows
#      through codex-hook.cmd, elsewhere through codex-hook.sh), as it would for a customer.
#   5. What the conversation was handed is read back from Codex's own record of it, the rollout in
#      the Codex home's sessions folder: the developer message the hook added, the memories file it
#      names, and the Foundation copy the per-prompt hook restates.
#
# Each check fails if the plugin delivers nothing or another account's memories (account B's key
# sits in this machine's Claude Code config, ~/.claude/mmry-config.json, the other product's
# credential, where a plugin reading the wrong credential would find it).
# tests/mutation/run-33030-mutations.sh shows both.
#
# NEEDS A REAL CODEX HOST: the Codex CLI, signed in. Without one it FAILS and says so; it is never
# skipped. It is therefore not in run-tests.sh's `integration` category, which CI runs on a runner
# with no Codex; `run-tests.sh journeys` runs it.
#
#   MMRY_LIVE_CODEX_BIN   optional; the codex executable (default: codex on PATH)
#   MMRY_LIVE_CODEX_AUTH  the signed-in auth.json to copy into the private Codex home. Required,
#                         because HOME is already a private one when this file runs. The original is
#                         only read, never written.
#   plus the account keys described in helpers/live-journey.bash.
#
# The machine's real ~/.codex, ~/.claude, plugin caches and temporary folder are never written:
# HOME, CODEX_HOME, TMPDIR, TEMP and TMP all point inside BATS_FILE_TMPDIR.

load '../libs/bats-support/load'
load '../libs/bats-assert/load'
load '../helpers/live-journey'

# _cx_rpc OUT WAIT_ID REQUEST... - one short app-server conversation. Sends initialize and each
# request, keeps stdin open until the response to WAIT_ID arrives (or 90 seconds), then closes it.
_cx_rpc() {
    local out="$1" wait_id="$2"; shift 2
    : > "$out"
    {
        printf '%s\n' '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"mmry-33030-live","version":"1"}}}' '{"method":"initialized"}'
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

setup_file() {
    export PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$BATS_TEST_DIRNAME/../.." && pwd)}"
    export LIVE_SPEC_NAME="codex-session-live.bats"
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
    unset MMRY_HOST CLAUDE_PLUGIN_ROOT CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID MMRY_CONFIG_FILE
    export MMRY_API_URL="" MMRY_API_KEY="" MMRY_AUTH_METHOD="" MMRY_NO_SELF_UPDATE=1

    cp "$MMRY_LIVE_CODEX_AUTH" "$CODEX_HOME/auth.json"
    # The sandbox setting the signed-in home carries on Windows (codex-second-opinion-howto.md);
    # nothing from that home that names a service is copied.
    printf 'model_reasoning_effort = "low"\n\n[windows]\nsandbox = "elevated"\n' > "$CODEX_HOME/config.toml"

    live_plant_both "$S/state" || return 1
    live_write_config "$CODEX_HOME/mmry-config.json" "$MMRY_INTEGRATION_API_KEY"
    live_write_config "$HOME/.claude/mmry-config.json" "$MMRY_INTEGRATION_OTHER_API_KEY"

    live_timeout 120 "$CX_BIN" plugin marketplace add "$(_native_path "$market")" > "$S/state/install.out" 2>&1 \
        || { echo "codex plugin marketplace add failed: $(tail -3 "$S/state/install.out")" >&2; return 1; }
    live_timeout 120 "$CX_BIN" plugin add mmry@mmry-plugin >> "$S/state/install.out" 2>&1 \
        || { echo "codex plugin add failed: $(tail -3 "$S/state/install.out")" >&2; return 1; }

    # Trust MMRY's session-start hook, and only it.
    local wcwd key hash write run_trust
    wcwd="$(_native_path "$S/work")"
    _cx_rpc "$S/state/hooks1.jsonl" 2 "$("$LIVE_JQ" -cn --arg w "$wcwd" '{id:2,method:"hooks/list",params:{cwds:[$w]}}')"
    key="$("$LIVE_JQ" -r 'select(.id==2) | .result.data[]?.hooks[]? | select(.pluginId=="mmry@mmry-plugin" and .eventName=="sessionStart" and (.command|test("session-init"))) | .key' "$S/state/hooks1.jsonl" | head -1)"
    hash="$("$LIVE_JQ" -r --arg k "$key" 'select(.id==2) | .result.data[]?.hooks[]? | select(.key==$k) | .currentHash' "$S/state/hooks1.jsonl" | head -1)"
    [[ -n "$key" && -n "$hash" ]] || { echo "Codex listed no MMRY session-start hook; installed plugin hooks: $("$LIVE_JQ" -c 'select(.id==2)|[.result.data[]?.hooks[]?.key]' "$S/state/hooks1.jsonl")" >&2; return 1; }
    write="$("$LIVE_JQ" -cn --arg k "$key" --arg h "$hash" '{id:3,method:"config/value/write",params:{keyPath:"hooks.state",mergeStrategy:"upsert",value:{($k):{trusted_hash:$h}}}}')"
    _cx_rpc "$S/state/hooks2.jsonl" 4 "$write" "$("$LIVE_JQ" -cn --arg w "$wcwd" '{id:4,method:"hooks/list",params:{cwds:[$w]}}')"
    run_trust="$("$LIVE_JQ" -r --arg k "$key" 'select(.id==4) | .result.data[]?.hooks[]? | select(.key==$k) | .trustStatus' "$S/state/hooks2.jsonl" | head -1)"
    [[ "$run_trust" == "trusted" ]] || { echo "Codex did not record the session-start hook as trusted (status: ${run_trust:-none})" >&2; return 1; }

    # One real conversation. The prompt asks for nothing the model must do with tools; the hook
    # runs before the model sees it.
    local rc=0
    ( cd "$S/work" && live_timeout 300 "$CX_BIN" exec --skip-git-repo-check --sandbox read-only --json \
        -o "$S/state/last-message.txt" "Reply with the single word OK. Do not run any commands." \
        < /dev/null > "$S/state/exec.jsonl" 2> "$S/state/exec.err" ) || rc=$?
    printf '%s' "$rc" > "$S/state/exec.rc"

    local rollouts
    rollouts="$(find "$CODEX_HOME/sessions" -name 'rollout-*.jsonl' -type f 2>/dev/null)"
    printf '%s\n' "$rollouts" > "$S/state/rollouts"
    if [[ "$(printf '%s\n' "$rollouts" | grep -c .)" != "1" ]]; then
        echo "expected one Codex conversation record, found: ${rollouts:-none}; codex exec said: $(tail -5 "$S/state/exec.err")" >&2
        return 1
    fi
    cp "$rollouts" "$S/state/rollout.jsonl"
    # Every developer message in the conversation that MMRY's hook added.
    "$LIVE_JQ" -r 'select(.type=="response_item" and .payload.type=="message" and .payload.role=="developer") | .payload.content[]? | .text? // empty' \
        "$S/state/rollout.jsonl" | tr -d '\r' | grep 'MMRY AI' > "$S/state/delivered.txt" || true

    live_startup_ids "$MMRY_INTEGRATION_API_KEY" "$(_hook_cwd "$S/work")" > "$S/state/expected-ids" || return 1
}

# The working directory as the hook sees it. Codex starts the hook in the folder's long Windows
# path, and Git Bash shows that as /c/...; this shell may know the same folder as /tmp/....
_hook_cwd() {
    local p d
    if command -v cygpath >/dev/null 2>&1; then
        p="$(cygpath -w -l "$1")"
        d="$(printf '%s' "${p:0:1}" | tr '[:upper:]' '[:lower:]')"
        p="${p:2}"
        printf '/%s%s' "$d" "${p//\\//}"
    else
        (cd "$1" && pwd -P)
    fi
}

teardown_file() {
    live_resolve_jq >/dev/null 2>&1 || true
    live_service_url >/dev/null 2>&1 || return 0
    live_retire_both "$BATS_FILE_TMPDIR/state"
}

_s() { printf '%s' "$BATS_FILE_TMPDIR/state"; }

_context() { grep -m1 'MMRY AI loaded [0-9]* memories' "$(_s)/delivered.txt" 2>/dev/null || true; }

_delivered_file() {
    local ctx p
    ctx="$(_context)"
    p="${ctx##*Read them now: }"
    [[ -n "$ctx" && "$p" != "$ctx" ]] || return 1
    live_unix_path "$p"
}

@test "J-011 codex: a real Codex conversation is handed MMRY's context saying memories loaded" {
    run _context
    assert_output --regexp '^MMRY AI loaded [0-9]+ memories\. Read them now: ' || {
        echo "developer messages from MMRY in the conversation: $(cat "$(_s)/delivered.txt")"
        echo "codex exec exit $(cat "$(_s)/exec.rc"); last stderr: $(tail -5 "$(_s)/exec.err")"
        return 1
    }
}

@test "J-011 codex: the conversation gets exactly the account's startup memories" {
    local f n expected
    f="$(_delivered_file)" || { echo "the conversation was told of no memories file: $(cat "$(_s)/delivered.txt")"; return 1; }
    [[ -f "$f" ]] || { echo "the memories file the conversation was told to read does not exist: $f"; return 1; }
    expected="$(cat "$(_s)/expected-ids")"
    [[ -n "$expected" ]] || { echo "the service returned no startup memories for account A"; return 1; }
    run live_file_ids "$f"
    assert_output "$expected"
    n="$(printf '%s\n' "$expected" | wc -l | tr -d ' ')"
    run _context
    assert_output --partial "MMRY AI loaded ${n} memories."
}

@test "J-011 codex: the planted Foundation memory is among them" {
    local f na ia
    f="$(_delivered_file)" || { echo "the conversation was told of no memories file: $(cat "$(_s)/delivered.txt")"; return 1; }
    na="$(cat "$(_s)/nonce-a")"; ia="$(cat "$(_s)/id-a")"
    run grep -c "Marker ${na}\." "$f"
    assert_output "1"
    run grep -x "id: ${ia}" "$f"
    assert_success
}

@test "J-011 codex: the Foundation copy restated on each prompt holds the planted directive" {
    local na sets
    na="$(cat "$(_s)/nonce-a")"
    sets="$(ls "$BATS_FILE_TMPDIR"/tmp/mmry-foundation-set.*.md 2>/dev/null)"
    [[ -n "$sets" ]] || { echo "no Foundation copy was written for this conversation"; return 1; }
    run grep -l "Marker ${na}\." $sets
    assert_success
}

@test "J-011 codex: nothing of another account reaches the conversation" {
    local nb ib f
    nb="$(cat "$(_s)/nonce-b")"; ib="$(cat "$(_s)/id-b")"
    f="$(_delivered_file)" || { echo "the conversation was told of no memories file: $(cat "$(_s)/delivered.txt")"; return 1; }
    run grep -rl -e "$nb" "$f" "$(_s)/rollout.jsonl" "$BATS_FILE_TMPDIR/tmp"
    assert_failure 1
    run grep -x "id: ${ib}" "$f"
    assert_failure 1
}
