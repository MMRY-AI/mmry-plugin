#!/usr/bin/env bats
# codex-foundation-live.bats - J-016@codex, live, on a real Codex host (#33480).
#
# THE JOURNEY. An account administrator chooses, for each Foundation memory, the moments it is sent
# to the assistant. Codex raises three of the four: when a conversation starts (SessionStart), with
# every message (UserPromptSubmit) and when the assistant reloads memories (the memory_load tool).
# It gives no signal before a long conversation is shortened, so nothing is registered for that
# moment and a memory chosen only for it never reaches a Codex conversation. Each moment must
# deliver exactly the memories chosen for it, word for word; a memory with no moment chosen is
# delivered nowhere. handlers/foundation-moments.bats and codex-foundation-parts.bats prove the
# handlers against a mocked service; this file proves the journey with the real Codex CLI against
# the real service (DEV on loopback or Integration, never production):
#
#   1. Account A gets one Foundation memory per moment, one chosen for two moments and one with none
#      (helpers/live-foundation.bash); account B gets one chosen for every moment, and B's key sits
#      in this machine's Claude Code config, where a plugin reading the wrong credential finds it.
#   2. A private Codex home is made as codex-session-live.bats makes it: the signed-in auth.json
#      copied in (only copied: never read, printed or written back), MMRY installed from this
#      checkout with `codex plugin marketplace add` and `codex plugin add` as docs/codex.md tells a
#      customer, account A's config written where setup writes it, and every hook MMRY registers
#      trusted the way the CLI's trust review records it (hooks/list, then config/value/write of
#      each trusted_hash through Codex's app-server). --dangerously-bypass-hook-trust is NOT used,
#      and no sandbox setting is bypassed.
#   3. One real conversation, three turns, each a real model turn:
#        turn 1  `codex exec`: Codex runs SessionStart and UserPromptSubmit itself;
#        turn 2  `codex exec resume`: the model is asked to call MMRY's memory_load tool, which
#                Codex runs through the plugin's own MCP server;
#        turn 3  `codex exec resume`: a message after the reload.
#   4. What the conversation was handed is read back from Codex's own record of it (the rollout in
#      the Codex home's sessions folder), never from the plugin's files: the developer messages the
#      hooks added, each turn's own, the memories files they name, and memory_load's answer.
#
# NEEDS A REAL CODEX HOST: the Codex CLI, signed in. Without one it FAILS and says so; it is never
# skipped. Like codex-session-live.bats it is not in run-tests.sh's `integration` category (CI has
# no Codex); `run-tests.sh journeys` runs it.
#
#   MMRY_LIVE_CODEX_BIN   optional; the codex executable (default: codex on PATH)
#   MMRY_LIVE_CODEX_AUTH  the signed-in auth.json to copy into the private Codex home (required)
#   plus the account keys and MMRY_LIVE_API_URL described in helpers/live-journey.bash.
#
# The machine's real ~/.codex, ~/.claude, plugin caches and temporary folder are never written:
# HOME, CODEX_HOME, TMPDIR, TEMP and TMP all point inside BATS_FILE_TMPDIR.

load '../libs/bats-support/load'
load '../libs/bats-assert/load'
load '../helpers/live-journey'
load '../helpers/live-foundation'

# _cx_rpc OUT WAIT_ID REQUEST... - one short app-server conversation (as codex-session-live.bats).
_cx_rpc() {
    local out="$1" wait_id="$2"; shift 2
    : > "$out"
    {
        printf '%s\n' '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"mmry-33480-live","version":"1"}}}' '{"method":"initialized"}'
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

# _turn N CMD... - one real Codex turn; keeps its events, its exit code and the rollout lines it added.
_turn() {
    local n="$1" S="$BATS_FILE_TMPDIR" rc=0 before=0 rollout
    shift
    rollout="$(find "$CODEX_HOME/sessions" -name 'rollout-*.jsonl' -type f 2>/dev/null | head -1)"
    [[ -n "$rollout" ]] && before="$(wc -l < "$rollout" | tr -d ' ')"
    ( cd "$S/work" && live_timeout 300 "$@" < /dev/null > "$S/state/turn$n.jsonl" 2> "$S/state/turn$n.err" ) || rc=$?
    printf '%s' "$rc" > "$S/state/turn$n.rc"
    rollout="$(find "$CODEX_HOME/sessions" -name 'rollout-*.jsonl' -type f 2>/dev/null)"
    printf '%s\n' "$rollout" > "$S/state/rollouts"
    [[ "$(printf '%s\n' "$rollout" | grep -c .)" == "1" ]] || { echo "turn $n: expected one Codex conversation record, found: ${rollout:-none}; codex said: $(tail -5 "$S/state/turn$n.err")" >&2; return 1; }
    tail -n +"$((before + 1))" "$rollout" > "$S/state/turn$n.rollout"
    # What MMRY's hooks put in front of the model this turn: every developer message, decoded.
    "$LIVE_JQ" -j 'select(.type=="response_item" and .payload.type=="message" and .payload.role=="developer") | .payload.content[]? | (.text? // empty) + "\n"' \
        "$S/state/turn$n.rollout" > "$S/state/turn$n.dev"
    # What MMRY's tools answered this turn.
    "$LIVE_JQ" -j 'select(.type=="response_item" and (.payload.type=="function_call_output" or .payload.type=="mcp_tool_call_output" or .payload.type=="custom_tool_call_output")) | (.payload.output | if type=="string" then . elif type=="array" then (map(.text? // "") | join("\n")) else tojson end) + "\n"' \
        "$S/state/turn$n.rollout" > "$S/state/turn$n.tools"
    return 0
}

# _memfile CTXFILE - the memories file a "MMRY AI loaded N memories. Read them now: PATH" names.
# The model decides how a tool's answer reaches its record: as the text, or as the whole MCP result
# printed as JSON (seen both ways). In the second the path is JSON-escaped and followed by '"}]...',
# so it is cut at the first quote and doubled backslashes are folded; a path has neither.
_memfile() {
    local line p q='"' b='\'
    line="$(grep -a -m1 'Read them now: ' "$1" 2>/dev/null | tr -d '\r')"
    p="${line##*Read them now: }"
    p="${p%%"$q"*}"
    p="${p//"$b$b"/"$b"}"
    [[ -n "$line" && "$p" != "$line" ]] || return 1
    live_unix_path "$p"
}

setup_file() {
    export PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$BATS_TEST_DIRNAME/../.." && pwd)}"
    export LIVE_SPEC_NAME="codex-foundation-live.bats"
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
    unset MMRY_HOST CLAUDE_PLUGIN_ROOT CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID MMRY_CONFIG_FILE MMRY_SESSION_AGENT_NAME
    export MMRY_API_URL="" MMRY_API_KEY="" MMRY_AUTH_METHOD="" MMRY_NO_SELF_UPDATE=1

    cp "$MMRY_LIVE_CODEX_AUTH" "$CODEX_HOME/auth.json"
    printf 'model_reasoning_effort = "low"\n\n[windows]\nsandbox = "elevated"\n' > "$CODEX_HOME/config.toml"

    live_foundation_plant_all "$S/state" || return 1
    live_write_config "$CODEX_HOME/mmry-config.json" "$MMRY_INTEGRATION_API_KEY"
    live_write_config "$HOME/.claude/mmry-config.json" "$MMRY_INTEGRATION_OTHER_API_KEY"

    live_timeout 120 "$CX_BIN" plugin marketplace add "$(_native_path "$market")" > "$S/state/install.out" 2>&1 \
        || { echo "codex plugin marketplace add failed: $(tail -3 "$S/state/install.out")" >&2; return 1; }
    live_timeout 120 "$CX_BIN" plugin add mmry@mmry-plugin >> "$S/state/install.out" 2>&1 \
        || { echo "codex plugin add failed: $(tail -3 "$S/state/install.out")" >&2; return 1; }

    # Trust every hook MMRY's Codex manifest registers, as a customer who accepted the plugin does.
    local wcwd allv want have untrusted write
    wcwd="$(_native_path "$S/work")"
    _cx_rpc "$S/state/hooks1.jsonl" 2 "$("$LIVE_JQ" -cn --arg w "$wcwd" '{id:2,method:"hooks/list",params:{cwds:[$w]}}')"
    allv="$("$LIVE_JQ" -c 'select(.id==2) | [.result.data[]?.hooks[]? | select(.pluginId=="mmry@mmry-plugin") | {key:.key, value:{trusted_hash:.currentHash}}] | from_entries' "$S/state/hooks1.jsonl")"
    want="$("$LIVE_JQ" -r '[.hooks[][].hooks[]] | length' "$PLUGIN_ROOT/hooks/codex-hooks.json")"
    have="$("$LIVE_JQ" -r 'keys | length' <<< "$allv")"
    (( want > 0 && have == want )) || { echo "Codex listed $have MMRY hooks, hooks/codex-hooks.json registers $want: $allv" >&2; return 1; }
    write="$("$LIVE_JQ" -cn --argjson v "$allv" '{id:3,method:"config/value/write",params:{keyPath:"hooks.state",mergeStrategy:"upsert",value:$v}}')"
    _cx_rpc "$S/state/hooks2.jsonl" 4 "$write" "$("$LIVE_JQ" -cn --arg w "$wcwd" '{id:4,method:"hooks/list",params:{cwds:[$w]}}')"
    untrusted="$("$LIVE_JQ" -r 'select(.id==4) | [.result.data[]?.hooks[]? | select(.pluginId=="mmry@mmry-plugin" and .trustStatus != "trusted") | "\(.eventName):\(.trustStatus)"] | join(",")' "$S/state/hooks2.jsonl" | head -1)"
    [[ -z "$untrusted" ]] || { echo "Codex did not record every MMRY hook as trusted (not trusted: ${untrusted})" >&2; return 1; }
    # The events Codex itself holds MMRY hooks for, for the before-shortening check.
    "$LIVE_JQ" -r 'select(.id==4) | [.result.data[]?.hooks[]? | select(.pluginId=="mmry@mmry-plugin") | .eventName] | unique | join(" ")' \
        "$S/state/hooks2.jsonl" > "$S/state/hook-events"

    # The same read-only sandbox on every turn: `exec` takes --sandbox, `exec resume` does not, so it
    # is given as the config value --sandbox sets. No sandbox or approval is bypassed.
    local -a exec_opts=(--skip-git-repo-check -c 'sandbox_mode="read-only"' --json)
    # Turn 1: the conversation starts with a first message.
    _turn 1 "$CX_BIN" exec "${exec_opts[@]}" -o "$S/state/turn1.last" \
        "Reply with the single word OK. Do not run any commands and do not call any tools." || return 1
    local thread
    thread="$("$LIVE_JQ" -r 'select(.type=="thread.started") | .thread_id' "$S/state/turn1.jsonl" | head -1)"
    [[ -n "$thread" ]] || { echo "codex exec reported no thread id: $(tail -5 "$S/state/turn1.err")" >&2; return 1; }
    printf '%s' "$thread" > "$S/state/thread"
    # The start and the reload write the same per-conversation memories file, and every resumed turn
    # starts with SessionStart again, so each is kept as soon as its own turn ends.
    _memfile "$S/state/turn1.dev" > "$S/state/start.file" || true
    if [[ -s "$S/state/start.file" ]]; then cp "$(cat "$S/state/start.file")" "$S/state/start.memories" 2>/dev/null || true; fi
    # Turn 2: the assistant reloads memories with MMRY's own tool.
    _turn 2 "$CX_BIN" exec resume "${exec_opts[@]}" -o "$S/state/turn2.last" "$thread" \
        "Call the memory_load tool from the mmry_plugin MCP server exactly once, with no arguments. Do not run any shell commands. Then reply with the single word OK." || return 1
    _memfile "$S/state/turn2.tools" > "$S/state/reload.file" || true
    if [[ -s "$S/state/reload.file" ]]; then cp "$(cat "$S/state/reload.file")" "$S/state/reload.memories" 2>/dev/null || true; fi
    # Turn 3: a message after the reload.
    _turn 3 "$CX_BIN" exec resume "${exec_opts[@]}" -o "$S/state/turn3.last" "$thread" \
        "Reply with the single word OK. Do not run any commands and do not call any tools." || return 1

    cat "$S/state"/turn*.rollout > "$S/state/rollout.jsonl"
    return 0
}

teardown_file() {
    live_resolve_jq >/dev/null 2>&1 || true
    live_service_url >/dev/null 2>&1 || return 0
    live_foundation_retire_all "$BATS_FILE_TMPDIR/state"
}

_s() { printf '%s' "$BATS_FILE_TMPDIR/state"; }

# _exactly FILE NAMES... - FILE holds exactly these planted memories, each whole, and no other.
_exactly() {
    local f="$1"; shift
    local want="$*" name
    [[ -f "$f" ]] || { echo "nothing was delivered: $f does not exist"; return 1; }
    run live_foundation_present "$(_s)" "$f"
    assert_output "$want"
    for name in "$@"; do
        live_foundation_whole "$(_s)" "$f" "$name" || { echo "${name} was delivered, but not word for word"; return 1; }
    done
}

# _prompt_context N - what the UserPromptSubmit hooks put before the model on turn N: the turn's
# developer messages other than the start-up one (which names the memories file).
_prompt_context() {
    grep -av 'Read them now: ' "$(_s)/turn$1.dev" > "$(_s)/turn$1.prompt" || true
    printf '%s' "$(_s)/turn$1.prompt"
}

@test "J-016 codex: the setup chose each memory's moments, as the API reads them back" {
    for n in START EVERY RELOAD SHORTEN BOTH NONE OTHER; do [[ -s "$(_s)/id-$n" ]]; done
}

@test "J-016 codex: each turn was a real Codex turn that ended normally" {
    for n in 1 2 3; do
        run cat "$(_s)/turn$n.rc"
        assert_output "0" || { echo "turn $n: $(tail -5 "$(_s)/turn$n.err")"; return 1; }
    done
}

@test "J-016 codex: when a conversation starts, exactly the memories chosen for it arrive, word for word" {
    run grep -a 'MMRY AI loaded [0-9]* memories' "$(_s)/turn1.dev"
    assert_output --regexp 'MMRY AI loaded [0-9]+ memories\. Read them now: '
    refute_output --partial 'WARNING FROM MMRY AI'
    _exactly "$(_s)/start.memories" START BOTH
}

@test "J-016 codex: with every message, exactly the memories chosen for it arrive, word for word, on each message" {
    _exactly "$(_prompt_context 1)" EVERY BOTH
    _exactly "$(_prompt_context 2)" EVERY BOTH
}

@test "J-016 codex: when the assistant reloads memories with memory_load, exactly the memories chosen for it arrive, word for word" {
    run grep -a 'MMRY AI loaded [0-9]* memories' "$(_s)/turn2.tools"
    assert_output --regexp 'MMRY AI loaded [0-9]+ memories\. Read them now: ' || {
        echo "memory_load was not answered by MMRY this turn; tool answers: $(head -c 600 "$(_s)/turn2.tools")"; return 1; }
    _exactly "$(_s)/reload.memories" RELOAD
}

@test "J-016 codex: after a reload, every message still carries exactly its own memories" {
    _exactly "$(_prompt_context 3)" EVERY BOTH
}

@test "J-016 codex: before a long conversation is shortened is not raised: nothing is registered and that memory never arrives" {
    run "$LIVE_JQ" -r '.hooks | has("PreCompact")' "$PLUGIN_ROOT/hooks/codex-hooks.json"
    assert_output "false"
    run cat "$(_s)/hook-events"
    refute_output ""
    refute_output --regexp '[Cc]ompact'
    local marker
    marker="$(cat "$(_s)/marker-SHORTEN")"
    run grep -rlaF -- "$marker" "$(_s)/rollout.jsonl" "$(_s)"/turn*.dev "$(_s)"/turn*.tools "$BATS_FILE_TMPDIR/tmp" "$CODEX_HOME/sessions"
    assert_failure 1
}

@test "J-016 codex: a memory with no moment chosen is delivered nowhere" {
    local marker
    marker="$(cat "$(_s)/marker-NONE")"
    run grep -rlaF -- "$marker" "$(_s)/rollout.jsonl" "$(_s)"/turn*.dev "$(_s)"/turn*.tools "$BATS_FILE_TMPDIR/tmp" "$BATS_FILE_TMPDIR/home" "$CODEX_HOME/sessions"
    assert_failure 1
}

@test "J-016 codex: nothing of another account is delivered on any moment" {
    local marker
    marker="$(cat "$(_s)/marker-OTHER")"
    run grep -rlaF -- "$marker" "$(_s)/rollout.jsonl" "$BATS_FILE_TMPDIR/tmp" "$CODEX_HOME/sessions"
    assert_failure 1
}
