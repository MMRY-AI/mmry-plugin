#!/usr/bin/env bats
# codex-missing-tools.bats - #32602: when the MMRY tools are missing from a Codex conversation, the
# customer can find out why in one step (R2), restore them without changing the conversation's
# Formation membership (R3), and is told so by a Formation message instead of silence (R4).
#
# The tool server is hooks-handlers/mcp-server.sh. "Never started" is the state with no record of a
# start; "started" is the real server, run the way Codex runs it, with JSON-RPC on stdin. The API is
# a fake curl that logs every request, so a test can show that nothing reached MMRY AI.

load '../helpers/test-helper'

setup() {
    BIN="$TEST_TMPDIR/fake-bin"
    mkdir -p "$BIN" "$TEST_TMPDIR/codexhome"
    export REQLOG="$TEST_TMPDIR/requests.log"
    : > "$REQLOG"
    cat > "$BIN/curl" <<'FAKECURL'
#!/usr/bin/env bash
out=""; prev=""; url=""
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    case "$arg" in http://*|https://*) url="$arg" ;; esac
    prev="$arg"
done
printf '%s\n' "$url" >> "$REQLOG"
[[ -n "$out" ]] && printf '%s' "${FAKE_BODY:-[]}" > "$out"
printf '%s' "${FAKE_CODE:-200}"
exit 0
FAKECURL
    chmod +x "$BIN/curl"
    export PATH="$BIN:$PATH"
    export MMRY_HOST=codex CODEX_HOME="$TEST_TMPDIR/codexhome"
    export MMRY_API_KEY="fake-key" MMRY_API_URL="http://fake.invalid" MMRY_AUTH_METHOD="apikey"
    export MMRY_NO_SELF_UPDATE=1
    unset MMRY_CONFIG_FILE CODEX_SESSION_ID CODEX_THREAD_ID CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
    SID="conv-32602-$$"
    TS_DIR="$CODEX_HOME/mmry/tool-server"
    CHECK="$PLUGIN_ROOT/hooks-handlers/tools-check.sh"
    SERVER="$PLUGIN_ROOT/hooks-handlers/mcp-server.sh"
    TRANSMISSION='[{"senderRole":"lead","senderSessionID":"other-session","content":"Heads up: I am touching FormationService.cs","sentDate":"2026-10-22T12:00:00"}]'
    LIVE_PIDS=""
}

teardown() {
    local p
    [[ -n "${STOPFILE:-}" ]] && touch "$STOPFILE"
    for p in $LIVE_PIDS; do kill "$p" 2>/dev/null || true; done
    rm -rf "$TEST_TMPDIR"
}

# A process that is alive for the length of a test, standing in for a running server.
_live_pid() {
    sleep 120 &
    LIVE_PID=$!
    LIVE_PIDS="$LIVE_PIDS $LIVE_PID"
}

# Records exactly as the server writes them, for a server with process id $1 serving $SID.
_record_running_server() {
    mkdir -p "$TS_DIR"
    printf '%s\n%s\n' "$(date +%s)" "2.13.0" > "$TS_DIR/server-$1"
    printf '%s\n%s\n' "$1" "$(date +%s)" > "$TS_DIR/session-$SID"
}

# Starts the REAL server the way Codex does: initialize, then one tools/call for $SID, with stdin
# held open until $STOPFILE exists. Waits for the server to record this conversation.
_start_real_server() {
    STOPFILE="$TEST_TMPDIR/stop-server"
    local init call
    init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}'
    call="{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"formation_roster\",\"arguments\":{},\"_meta\":{\"sessionId\":\"$SID\"}}}"
    { printf '%s\n%s\n' "$init" "$call"; while [ ! -f "$STOPFILE" ]; do sleep 0.2; done; } \
        | bash "$SERVER" > "$TEST_TMPDIR/server.out" 2> "$TEST_TMPDIR/server.err" &
    SERVER_JOB=$!
    local i=0
    while (( i < 100 )); do
        [ -f "$TS_DIR/session-$SID" ] && return 0
        sleep 0.2; i=$(( i + 1 ))
    done
    return 1
}

_stop_real_server() {
    touch "$STOPFILE"
    wait "$SERVER_JOB" 2>/dev/null || true
}

# ---------------------------------------------------------------------------------------------
# R2: one step says why
# ---------------------------------------------------------------------------------------------

@test "R2: a tool server that never started is reported not started, with the reason" {
    run bash "$CHECK" --session "$SID"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "MMRY tools: not started" ]
    [[ "$output" == *"Why: Codex has not started MMRY's tool server on this machine"* ]] || return 1
    [[ "$output" == *"codex resume $SID"* ]] || return 1
    [ ! -s "$REQLOG" ]
}

@test "R2: a tool server that did start is reported running, for this conversation" {
    _start_real_server
    run bash "$CHECK" --session "$SID"
    _stop_real_server
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "MMRY tools: running" ]
    [ "${lines[1]}" = "MMRY's tool server is running for this conversation." ]
    [[ "$output" != *"not started"* ]] || return 1
}

@test "R2: the real server records its start, its process, and the conversation it served" {
    _start_real_server
    local pid=""
    { IFS= read -r pid; } < "$TS_DIR/session-$SID"
    [ -f "$TS_DIR/launched" ]
    [ -f "$TS_DIR/server-$pid" ]
    _stop_real_server
    # Gone once it exits, so a stopped server can never read as running.
    [ ! -f "$TS_DIR/server-$pid" ]
}

@test "R2: once this conversation's server has stopped, it is reported not started, and why" {
    _start_real_server
    _stop_real_server
    run bash "$CHECK" --session "$SID"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "MMRY tools: not started" ]
    [[ "$output" == *"the tool server that served this conversation is no longer running"* ]] || return 1
}

@test "R2: a start that could not finish is reported with the reason it recorded" {
    mkdir -p "$TS_DIR"
    printf '%s\n%s\n' "$(date +%s)" "no usable jq was found, so it could not start" > "$TS_DIR/failed"
    run bash "$CHECK" --session "$SID"
    [ "${lines[0]}" = "MMRY tools: not started" ]
    [[ "$output" == *"stopped: no usable jq was found, so it could not start."* ]] || return 1
}

@test "R2: MMRY switched off in Codex's settings is named as the reason, ahead of anything else" {
    _live_pid
    _record_running_server "$LIVE_PID"
    printf '[plugins."mmry@mmry-plugin"]\nenabled = false\n' > "$CODEX_HOME/config.toml"
    run bash "$CHECK" --session "$SID"
    [ "${lines[0]}" = "MMRY tools: not started" ]
    [[ "$output" == *"MMRY is switched off in Codex's settings"* ]] || return 1
    [[ "$output" == *"codex plugin add mmry@mmry-plugin"* ]] || return 1
}

@test "R2: a launcher that is not executable is named, and --recover repairs it" {
    case "${OSTYPE:-}" in msys*|cygwin*|win32*) skip "Windows has no execute bit; Codex starts mmry-mcp.cmd there" ;; esac
    local plug="$TEST_TMPDIR/plug"
    mkdir -p "$plug/mcp" "$plug/hooks-handlers"
    cp "$PLUGIN_ROOT/codex-mcp.json" "$plug/"
    cp "$PLUGIN_ROOT/mcp/mmry-mcp" "$plug/mcp/"
    cp "$PLUGIN_ROOT/hooks-handlers/mcp-server.sh" "$plug/hooks-handlers/"
    chmod -x "$plug/mcp/mmry-mcp"
    CLAUDE_PLUGIN_ROOT="$plug" run bash "$CHECK" --session "$SID"
    [ "${lines[0]}" = "MMRY tools: not started" ]
    [[ "$output" == *"is not marked executable"* ]] || return 1
    CLAUDE_PLUGIN_ROOT="$plug" run bash "$CHECK" --session "$SID" --recover
    [[ "$output" == *"Repaired: the launcher Codex starts"* ]] || return 1
    [ -x "$plug/mcp/mmry-mcp" ]
}

@test "R2: the check reaches no network and writes nothing, so it runs inside Codex's sandbox" {
    _live_pid
    _record_running_server "$LIVE_PID"
    local before after
    before="$(cd "$CODEX_HOME" && find . -type f | sort | xargs cksum 2>/dev/null)"
    run bash "$CHECK" --session "$SID"
    after="$(cd "$CODEX_HOME" && find . -type f | sort | xargs cksum 2>/dev/null)"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "MMRY tools: running" ]
    [ "$before" = "$after" ]
    [ ! -s "$REQLOG" ]
}

# ---------------------------------------------------------------------------------------------
# R3: the recovery keeps the Formation membership
# ---------------------------------------------------------------------------------------------

@test "R3: --recover leaves the Formation membership and its member id untouched" {
    # The membership: the file the delivery hook polls with, named by this conversation's id. MMRY
    # AI keeps member 275 against that id; the stand-in here is the record the service returns.
    bash "$PLUGIN_ROOT/hooks-handlers/formation-state.sh" set 59 "$SID"
    local marker="$TMPDIR/.mmry-formation-$SID"
    [ -f "$marker" ]
    local before; before="$(cksum < "$marker")"
    # The tool server that served this conversation has gone, which is the state being recovered.
    mkdir -p "$TS_DIR"
    printf '%s\n%s\n' "999999" "$(date +%s)" > "$TS_DIR/session-$SID"

    run bash "$CHECK" --session "$SID" --recover
    [ "$status" -eq 0 ]
    # The membership file is byte for byte what it was, and still names formation 59.
    [ -f "$marker" ]
    [ "$(cksum < "$marker")" = "$before" ]
    local fid; { IFS= read -r fid; } < "$marker"
    [ "$fid" = "59" ]
    # Nothing reached MMRY AI: no leave, no join, no session, so the member id held against this
    # conversation cannot have changed.
    [ ! -s "$REQLOG" ]
    # And the recovery reopens THIS conversation, the identity the member id belongs to.
    [[ "$output" == *"codex resume $SID"* ]] || return 1
    [[ "$output" == *"Formation 59: conversation $SID"* ]] || return 1
    [[ "$output" == *"Do not start a new conversation for it, do not leave and rejoin the Formation"* ]] || return 1
}

@test "R3: after the recovery the same conversation polls as the same member" {
    bash "$PLUGIN_ROOT/hooks-handlers/formation-state.sh" set 59 "$SID"
    run bash "$CHECK" --session "$SID" --recover
    # The reopened conversation's delivery hook asks for formation 59 under the same id as before.
    _live_pid
    _record_running_server "$LIVE_PID"
    PATH="$BIN:$PATH" FAKE_CODE=200 FAKE_BODY='[]' MMRY_FORMATION_MODE=tool CODEX_SESSION_ID="$SID" \
        run bash "$PLUGIN_ROOT/hooks-handlers/formation-check.sh" < /dev/null
    grep -q "/api/formations/59/" "$REQLOG"
    grep -q "$SID" "$REQLOG"
    if grep -q "/leave\|/join" "$REQLOG"; then return 1; fi
}

# ---------------------------------------------------------------------------------------------
# R4: a Formation message with no tools to answer it says so
# ---------------------------------------------------------------------------------------------

_deliver() {
    # $1 mode (tool or prompt); $2 handlers directory (default: the plugin's own)
    local hd="${2:-$PLUGIN_ROOT/hooks-handlers}"
    bash "$hd/formation-state.sh" set 4242 "$SID"
    PATH="$BIN:$PATH" FAKE_CODE=200 FAKE_BODY="$TRANSMISSION" \
        MMRY_FORMATION_MODE="$1" CODEX_SESSION_ID="$SID" \
        run bash "$hd/formation-check.sh" < /dev/null
}

@test "R4: a message delivered with the tool server not started says the tools are missing and how to restore them" {
    _deliver tool
    [ "$status" -eq 0 ]
    local ctx; ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" == *"FormationService.cs"* ]] || return 1
    [[ "$ctx" == *"MMRY TOOLS ARE MISSING FROM THIS CONVERSATION."* ]] || return 1
    [[ "$ctx" == *"The MMRY tools are missing from this conversation."* ]] || return 1
    [[ "$ctx" == *"codex resume $SID"* ]] || return 1
    [[ "$ctx" == *"tools-check.sh"* ]] || return 1
    [[ "$ctx" == *"do not leave and rejoin the Formation"* ]] || return 1
}

@test "R4: the same notice reaches a prompt, and the JSON stays well formed" {
    _deliver prompt
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null
    local ctx; ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" == *"MMRY TOOLS ARE MISSING FROM THIS CONVERSATION."* ]] || return 1
    # Ends where the notice ends: the prompt path takes exactly one newline off, and no more.
    [[ "$ctx" == *"in their place." ]] || return 1
}

@test "R4: with the tool server running the delivered text is unchanged, byte for byte" {
    # The reference is the same delivery with the feature absent: a copy of the handlers without
    # lib-tool-server.sh, which is the delivery as it was before #32602.
    local ref="$TEST_TMPDIR/ref"
    mkdir -p "$ref"
    cp -R "$PLUGIN_ROOT/hooks-handlers" "$ref/"
    cp -R "$PLUGIN_ROOT/vendor" "$ref/" 2>/dev/null || true
    rm -f "$ref/hooks-handlers/lib-tool-server.sh"
    _deliver tool "$ref/hooks-handlers"
    local expected="$output"
    bash "$ref/hooks-handlers/formation-state.sh" clear "$SID" || true

    _live_pid
    _record_running_server "$LIVE_PID"
    _deliver tool
    [ "$status" -eq 0 ]
    [ -n "$expected" ]
    [ "$output" = "$expected" ]
    [[ "$output" != *"MISSING"* ]] || return 1
}

@test "R4: a running server not yet tied to this conversation keeps the text unchanged too" {
    _live_pid
    mkdir -p "$TS_DIR"
    printf '%s\n%s\n' "$(date +%s)" "2.13.0" > "$TS_DIR/server-$LIVE_PID"
    _deliver tool
    local ctx; ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" == *"FormationService.cs"* ]] || return 1
    [[ "$ctx" != *"MISSING"* ]] || return 1
}

@test "R4: a server Codex has started and that is still getting ready is not reported missing" {
    # A reopened conversation's SessionStart delivery can run while the server is still starting.
    _live_pid
    mkdir -p "$TS_DIR"
    printf '%s\n%s\n%s\n' "$(date +%s)" "$LIVE_PID" "$PLUGIN_ROOT" > "$TS_DIR/launched"
    _deliver prompt
    local ctx; ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" == *"FormationService.cs"* ]] || return 1
    [[ "$ctx" != *"MISSING"* ]] || return 1
    run bash "$CHECK" --session "$SID"
    [ "${lines[0]}" = "MMRY tools: running" ]
    [ "${lines[1]}" = "MMRY's tool server is starting. Check again in a few seconds." ]
}

@test "R4: a server record whose process is gone counts as not started" {
    mkdir -p "$TS_DIR"
    printf '%s\n%s\n' "$(date +%s)" "2.13.0" > "$TS_DIR/server-999999"
    printf '%s\n%s\n' "999999" "$(date +%s)" > "$TS_DIR/session-$SID"
    _deliver tool
    local ctx; ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" == *"MMRY TOOLS ARE MISSING FROM THIS CONVERSATION."* ]] || return 1
}

@test "R4: Claude Code has no tool server, and its delivery carries no notice" {
    bash "$PLUGIN_ROOT/hooks-handlers/formation-state.sh" set 4242 "$SID"
    PATH="$BIN:$PATH" FAKE_CODE=200 FAKE_BODY="$TRANSMISSION" \
        MMRY_FORMATION_MODE=tool CLAUDE_SESSION_ID="$SID" \
        run env -u MMRY_HOST -u CODEX_HOME bash "$PLUGIN_ROOT/hooks-handlers/formation-check.sh" < /dev/null
    [ "$status" -eq 2 ]
    [[ "$output" == *"FormationService.cs"* ]] || return 1
    [[ "$output" != *"MISSING"* ]] || return 1
}
