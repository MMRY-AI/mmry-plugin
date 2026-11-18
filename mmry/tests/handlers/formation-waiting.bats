#!/usr/bin/env bats
# formation-waiting.bats - the lead is told when a member is waiting on a permission prompt, and told
# when it continues (#33452, DD-187 in the API repository).
#
# The service half (the flag, the directed notice, the roster, the refusal of another member's id) is
# proven by the API repository's testing/backend/tests/formation-waiting.test.ts. This file proves the
# plugin's half, with the service faked:
#
#   TC1  a permission-prompt notification in a member session makes exactly ONE call naming the
#        member; a non-member session, an idle notification and a lead's own prompt make none; the
#        same prompt reported twice makes one call
#   TC3  the member's next tool call or prompt clears the flag (one DELETE), and only once
#   TC4  a prompt for a command carrying a planted secret sends, stores and prints the tool name and
#        never the planted string
#   Codex: the PermissionRequest payload does the same, and the hook prints nothing, because Codex
#        reads a PermissionRequest hook's stdout as an approval decision
#
# The network is a fake curl that answers like the service and records every request and body.

load '../helpers/test-helper'

PLANTED="PLANTED-SECRET-33452-sk-live-0f9c"

setup() {
    BIN="$TEST_TMPDIR/fake-bin"
    BODIES="$TEST_TMPDIR/bodies"
    URLS="$TEST_TMPDIR/urls"
    mkdir -p "$BIN"
    : > "$BODIES"; : > "$URLS"
    cat > "$BIN/curl" <<'FAKECURL'
#!/usr/bin/env bash
# A fake MMRY AI. Records "METHOD URL" and every request body; answers like the service would.
out=""; method="GET"; url=""; prev=""; body=""
for arg in "$@"; do
    case "$prev" in
        -o) out="$arg" ;;
        -X) method="$arg" ;;
        --data-binary|-d|--data) if [[ "$arg" == @* ]]; then body="$(cat "${arg#@}")"; else body="$arg"; fi ;;
    esac
    case "$arg" in http://*|https://*) url="$arg" ;; esac
    prev="$arg"
done
printf '%s %s\n' "$method" "$url" >> "$FAKE_URL_LOG"
[[ -n "$body" ]] && printf '%s\n' "$body" >> "$FAKE_BODY_LOG"
code=200; resp='{}'
case "$method $url" in
    "GET "*/api/formations/4242)
        resp='{"formation":{"id":4242},"members":[{"id":12,"sessionId":null,"role":"Lead","leftDate":null},{"id":31,"sessionId":"'"${FAKE_OWN_SID:-}"'","role":"'"${FAKE_OWN_ROLE:-Wingman}"'","leftDate":null}]}' ;;
    "PUT "*/members/*/waiting)
        resp='{"formationId":4242,"memberId":31,"waiting":true,"waitingSince":"2026-11-13T14:05:00","toolName":null,"leadTold":true,"outcome":"Set"}' ;;
    "DELETE "*/members/*/waiting*)
        code="${FAKE_CLEAR_CODE:-200}"
        resp='{"formationId":4242,"memberId":31,"waiting":false,"leadTold":true,"outcome":"Cleared"}' ;;
    "GET "*/transmissions/sent*) resp='{"formationId":4242,"member":true,"messages":[]}' ;;
    "GET "*/transmissions*) resp='[]' ;;
esac
[[ -n "$out" ]] && printf '%s' "$resp" > "$out"
printf '%s' "$code"
exit 0
FAKECURL
    chmod +x "$BIN/curl"
    export PATH="$BIN:$PATH"
    export FAKE_URL_LOG="$URLS" FAKE_BODY_LOG="$BODIES"
    export MMRY_API_KEY="fake-key" MMRY_API_URL="http://fake.invalid" MMRY_AUTH_METHOD="apikey"
    export MMRY_NO_SELF_UPDATE=1
    unset MMRY_HOST CODEX_HOME CODEX_SESSION_ID CODEX_THREAD_ID CLAUDE_SESSION_ID FAKE_OWN_ROLE FAKE_CLEAR_CODE MMRY_FORMATION_MODE
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/claudecfg"
    mkdir -p "$CLAUDE_CONFIG_DIR"
    SID="bbbb3333-waiting-$$"
    export CLAUDE_CODE_SESSION_ID="$SID" FAKE_OWN_SID="$SID"
    HH="$PLUGIN_ROOT/hooks-handlers"
    bash "$HH/formation-state.sh" set 4242 "$SID" >/dev/null
}

teardown() {
    bash "$HH/formation-state.sh" clear "$SID" >/dev/null 2>&1 || true
    rm -f "$TEST_TMPDIR"/.mmry-waiting-* 2>/dev/null || true
    mmry_teardown_tmp "$TEST_TMPDIR"
}

# The payloads, as Claude Code and Codex send them.
_notification() { # $1 notification_type, $2 message
    printf '{"session_id":"%s","transcript_path":"/x","cwd":"/x","hook_event_name":"Notification","notification_type":"%s","message":"%s"}' "$SID" "$1" "$2"
}
_permission_request() { # $1 tool_name, $2 command
    printf '{"session_id":"%s","transcript_path":null,"cwd":"/x","hook_event_name":"PermissionRequest","model":"gpt-5","permission_mode":"default","turn_id":"t1","tool_name":"%s","tool_input":{"command":"%s","description":"run it"}}' "$SID" "$1" "$2"
}
_event() { # $1 hook_event_name
    printf '{"session_id":"%s","hook_event_name":"%s","tool_name":"Bash","tool_input":{"command":"ls"}}' "$SID" "$1"
}

_waiting() { printf '%s' "$1" | bash "$HH/formation-waiting.sh"; }
_check() { printf '%s' "$1" | bash "$HH/formation-check.sh"; }
_puts() { grep -c '^PUT .*/api/formations/4242/members/31/waiting$' "$URLS" || true; }
_deletes() { grep -c '^DELETE .*/api/formations/4242/members/31/waiting?sessionId=' "$URLS" || true; }
_marker() { ls "$TEST_TMPDIR"/.mmry-waiting-* 2>/dev/null | head -1; }

# ---------------------------------------------------------------------------------------------
# TC1: one call naming the member, and none where there is nothing to tell
# ---------------------------------------------------------------------------------------------

@test "W-01 a permission prompt in a member session makes exactly one call naming the member" {
    run _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash')"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "printed: $output"; return 1; }
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    [ "$(grep -c '^PUT ' "$URLS")" -eq 1 ] || { cat "$URLS"; return 1; }
    grep -q "\"sessionId\":\"$SID\"" "$BODIES" || { cat "$BODIES"; return 1; }
    grep -q '"toolName":"Bash"' "$BODIES" || { cat "$BODIES"; return 1; }
    [ -n "$(_marker)" ] || { echo "no marker"; return 1; }
}

@test "W-02 a session in no formation makes no call at all" {
    bash "$HH/formation-state.sh" clear "$SID" >/dev/null
    run _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash')"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$URLS" ] || { cat "$URLS"; return 1; }
}

@test "W-03 an idle notification, and any other notification, make no call" {
    for t in idle_prompt auth_success elicitation_dialog agent_completed; do
        run _waiting "$(_notification "$t" 'Claude is waiting for your input')"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    [ ! -s "$URLS" ] || { cat "$URLS"; return 1; }
}

@test "W-04 the same prompt reported twice makes one call" {
    _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash')"
    _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash')"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
}

@test "W-05 a lead's own prompt makes no waiting call: there is nobody to tell" {
    export FAKE_OWN_ROLE=Lead
    run _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash')"
    [ "$status" -eq 0 ]
    [ "$(_puts)" -eq 0 ] || { cat "$URLS"; return 1; }
    [ -z "$(_marker)" ]
}

@test "W-06 a tool name that is not a bare name is left out, and the member is still reported" {
    # #33898: this case used the MCP sentence and accepted the server name "mmry"; the MCP form now has
    # its own cases (W-26 on). A word that is not a bare name is still left out, never trimmed.
    run _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash;id')"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    ! grep -q 'toolName' "$BODIES" || grep -q '"toolName":null' "$BODIES" || { cat "$BODIES"; return 1; }
    ! grep -q 'Bash' "$BODIES" || { cat "$BODIES"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# TC3: the next tool call or prompt clears it
# ---------------------------------------------------------------------------------------------

@test "W-07 the next tool call clears the flag with one call, and only once" {
    _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash')"
    run _check "$(_event PostToolUse)"
    [ "$(_deletes)" -eq 1 ] || { cat "$URLS"; return 1; }
    grep -q "waiting?sessionId=$SID" "$URLS"
    [ -z "$(_marker)" ] || { echo "marker left: $(_marker)"; return 1; }
    run _check "$(_event PostToolUse)"
    [ "$(_deletes)" -eq 1 ] || { cat "$URLS"; return 1; }
}

@test "W-08 the next prompt clears the flag too" {
    _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash')"
    run _check "$(_event UserPromptSubmit)"
    [ "$(_deletes)" -eq 1 ] || { cat "$URLS"; return 1; }
    [ -z "$(_marker)" ]
}

@test "W-09 with nothing reported, a tool call clears nothing" {
    run _check "$(_event PostToolUse)"
    [ "$(_deletes)" -eq 0 ] || { cat "$URLS"; return 1; }
}

@test "W-10 a clear the service did not confirm is kept for the next event; a refused one is dropped" {
    _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash')"
    FAKE_CLEAR_CODE=500 _check "$(_event PostToolUse)" || true
    [ -n "$(_marker)" ] || { echo "marker dropped on a 500"; return 1; }
    FAKE_CLEAR_CODE=404 _check "$(_event PostToolUse)" || true
    [ -z "$(_marker)" ] || { echo "marker kept on a 404"; return 1; }
    [ "$(_deletes)" -eq 2 ]
}

@test "W-11 after a clear, the next prompt is reported again" {
    _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash')"
    _check "$(_event PostToolUse)" || true
    _waiting "$(_notification permission_prompt 'Claude needs your permission to use Edit')"
    [ "$(_puts)" -eq 2 ] || { cat "$URLS"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# TC4: the tool name, never the prompt
# ---------------------------------------------------------------------------------------------

@test "W-12 a prompt for a command carrying a planted secret sends and keeps the tool name only" {
    run _waiting "$(_notification permission_prompt "Claude needs your permission to use Bash with curl -H Authorization: $PLANTED")"
    [ "$status" -eq 0 ]
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    grep -q '"toolName":"Bash"' "$BODIES" || { cat "$BODIES"; return 1; }
    ! grep -q "$PLANTED" "$BODIES" "$URLS" || { echo "planted string sent"; return 1; }
    ! grep -rq "$PLANTED" "$TEST_TMPDIR"/.mmry-* 2>/dev/null || { echo "planted string stored"; return 1; }
    [[ "$output" != *"$PLANTED"* ]]
}

# ---------------------------------------------------------------------------------------------
# Codex: the PermissionRequest hook
# ---------------------------------------------------------------------------------------------

@test "W-13 Codex PermissionRequest: one call with the tool name, nothing of the command, nothing printed" {
    run _waiting "$(_permission_request Bash "export TOKEN=$PLANTED && curl https://x")"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "printed (Codex would read it as a decision): $output"; return 1; }
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    grep -q '"toolName":"Bash"' "$BODIES" || { cat "$BODIES"; return 1; }
    ! grep -q "$PLANTED" "$BODIES" "$URLS" || { echo "planted string sent"; return 1; }
}

@test "W-14 Codex PermissionRequest for an MCP tool sends its bare name" {
    run _waiting "$(_permission_request mcp__mmry__memory_save '')"
    grep -q '"toolName":"mcp__mmry__memory_save"' "$BODIES" || { cat "$BODIES"; return 1; }
}

@test "W-15 a payload naming no event the handler serves makes no call" {
    run _waiting "$(_event PostToolUse)"
    [ "$status" -eq 0 ]
    [ ! -s "$URLS" ] || { cat "$URLS"; return 1; }
}

@test "W-16 an unreachable service is silent and leaves no marker" {
    cat > "$BIN/curl" <<'DOWN'
#!/usr/bin/env bash
printf '%s\n' "DOWN $*" >> "$FAKE_URL_LOG"
printf '000'
exit 7
DOWN
    chmod +x "$BIN/curl"
    run _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash')"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$(_marker)" ]
}

# ---------------------------------------------------------------------------------------------
# TC2 in the plugin: the roster shows which members are waiting
# ---------------------------------------------------------------------------------------------

_roster() { # $1 the roster body the fake service returns
    cat > "$BIN/curl" <<'ROSTERCURL'
#!/usr/bin/env bash
out=""; prev=""
for arg in "$@"; do [[ "$prev" == "-o" ]] && out="$arg"; prev="$arg"; done
[[ -n "$out" ]] && printf '%s' "$FAKE_ROSTER" > "$out"
printf '200'
ROSTERCURL
    chmod +x "$BIN/curl"
    FAKE_ROSTER="$1" run bash "$HH/formation-roster.sh" 4242
}
_HEAD='{"formation":{"id":4242,"objective":"o"},"members":[{"id":3,"role":"Lead","email":"l@x.y","leftDate":null},'

@test "W-17 the roster marks a waiting member with the time and the tool" {
    _roster "${_HEAD}"'{"id":12,"role":"Wingman","email":"m@x.y","progress":"Accepted","waitingSince":"2026-11-13T14:05:42.1234567","waitingTool":"Bash","leftDate":null}]}'
    [ "$status" -eq 0 ]
    local line; line="$(printf '%s\n' "$output" | tr -d '\r' | grep 'm@x.y')"
    [[ "$line" == *"  (waiting on a permission prompt since 14:05 UTC, for Bash)" ]] || { echo "$output"; return 1; }
}

@test "W-18 without a tool name the mark names none; a member not waiting reads exactly as before" {
    _roster "${_HEAD}"'{"id":12,"role":"Wingman","email":"m@x.y","waitingSince":"2026-11-13T14:05:42","waitingTool":null,"leftDate":null}]}'
    local line; line="$(printf '%s\n' "$output" | tr -d '\r' | grep 'm@x.y')"
    [[ "$line" == *"  (waiting on a permission prompt since 14:05 UTC)" ]] || { echo "$output"; return 1; }

    _roster "${_HEAD}"'{"id":12,"role":"Wingman","email":"m@x.y","progress":"Accepted","leftDate":null}]}'
    local before="$output"
    _roster "${_HEAD}"'{"id":12,"role":"Wingman","email":"m@x.y","progress":"Accepted","waitingSince":null,"waitingTool":null,"leftDate":null}]}'
    [ "$output" = "$before" ] || { echo "--- absent"; echo "$before"; echo "--- null"; echo "$output"; return 1; }
    [[ "$output" != *"permission prompt"* ]]
}

# ---------------------------------------------------------------------------------------------
# #33901: a marker left by a crash, a failed clear, an earlier turn or a departure never silences the
# next prompt, and one prompt is still one call
# ---------------------------------------------------------------------------------------------

_permission_request_turn() { # $1 tool_name, $2 turn_id
    printf '{"session_id":"%s","transcript_path":null,"cwd":"/x","hook_event_name":"PermissionRequest","model":"gpt-5","permission_mode":"default","turn_id":"%s","tool_name":"%s","tool_input":{"command":"ls","description":"run it"}}' "$SID" "$2" "$1"
}

@test "W-19 33901 req1: a marker a crashed process left is removed at session start without a clear call, and the next prompt makes exactly one call" {
    # What the process that crashed while its prompt was open left behind.
    printf '%s\n' "4242 31" > "$TEST_TMPDIR/.mmry-waiting-$SID"
    run _check "$(_event SessionStart)"
    [ "$(_deletes)" -eq 0 ] || { echo "a session start sent a clear"; cat "$URLS"; return 1; }
    [ -z "$(_marker)" ] || { echo "marker kept at session start: $(_marker)"; return 1; }
    _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash')"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    [ -n "$(_marker)" ]
}

@test "W-20 33901 req1: a marker whose clear did not go through does not silence the next prompt" {
    _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash')"
    # The member answered and carried on, but the service did not confirm the clear: the marker stays.
    FAKE_CLEAR_CODE=500 _check "$(_event PostToolUse)" || true
    [ -n "$(_marker)" ] || { echo "marker dropped on a 500"; return 1; }
    # The next prompt is a new one, and the lead must hear about it: exactly one more call.
    _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash')"
    [ "$(_puts)" -eq 2 ] || { cat "$URLS"; return 1; }
    # ...and that prompt reported twice is still one call.
    _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash')"
    [ "$(_puts)" -eq 2 ] || { cat "$URLS"; return 1; }
}

@test "W-21 33901 req1: Codex, a marker from an earlier turn does not silence a prompt in a new turn" {
    _waiting "$(_permission_request_turn Bash turn-0001)"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    run _waiting "$(_permission_request_turn Bash turn-0002)"
    [ -z "$output" ] || { echo "printed: $output"; return 1; }
    [ "$(_puts)" -eq 2 ] || { cat "$URLS"; return 1; }
}

@test "W-22 33901 req1: a marker naming another formation does not silence a prompt in this one" {
    printf '%s\n' "9999 77" > "$TEST_TMPDIR/.mmry-waiting-$SID"
    _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash')"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    read -r f m < "$TEST_TMPDIR/.mmry-waiting-$SID"
    [ "$f $m" = "4242 31" ] || { echo "marker not replaced: $f $m"; return 1; }
}

@test "W-23 33901 req2: leaving the formation while waiting removes that session's marker, and no other" {
    _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash')"
    [ -n "$(_marker)" ] || { echo "no marker to leave with"; return 1; }
    printf '%s\n' "4242 55" > "$TEST_TMPDIR/.mmry-waiting-other-session-1"
    run bash "$HH/formation-leave.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -e "$TEST_TMPDIR/.mmry-waiting-$SID" ] || { echo "marker left after leave"; return 1; }
    [ -f "$TEST_TMPDIR/.mmry-waiting-other-session-1" ] || { echo "another session's marker was removed"; return 1; }
}

@test "W-24 33901 req2: after leaving and joining again, the first prompt tells the lead" {
    _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash')"
    run bash "$HH/formation-leave.sh"
    bash "$HH/formation-state.sh" set 4242 "$SID" >/dev/null
    _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash')"
    [ "$(_puts)" -eq 2 ] || { cat "$URLS"; return 1; }
}

@test "W-25 33901 req3: two reports of one prompt make one call, for Claude Code and for Codex" {
    _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash')"
    _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash')"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    _check "$(_event PostToolUse)" || true
    [ "$(_deletes)" -eq 1 ] || { cat "$URLS"; return 1; }
    _waiting "$(_permission_request_turn Bash turn-0003)"
    _waiting "$(_permission_request_turn Bash turn-0003)"
    [ "$(_puts)" -eq 2 ] || { cat "$URLS"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# #33898: for an MCP tool the lead is told the tool's own name, mcp__<server>__<tool>, or no name.
# The sentences are Claude Code's own (2.1.322): "Claude needs your permission to use <server> -
# <tool title or name> (MCP)", the server as configured (a plugin's is plugin:<plugin>:<server>), and
# the tool name the server part normalised exactly as Claude Code builds it (any character outside
# A-Z a-z 0-9 _ - becomes _).
# ---------------------------------------------------------------------------------------------

_notification_tp() { # $1 message, $2 transcript path
    printf '{"session_id":"%s","transcript_path":"%s","cwd":"/x","hook_event_name":"Notification","notification_type":"permission_prompt","message":"%s"}' "$SID" "$2" "$1"
}
_tool_sent() { "$JQ_BIN" -r '.toolName // "<none>"' < "$BODIES" | head -1; }
# A transcript whose latest assistant message calls each named tool (one tool_use per name, in order).
_transcript() { # $1 path, $2.. tool names
    local tp="$1" n i=0; shift
    : > "$tp"
    for n in "$@"; do
        i=$((i + 1))
        printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_%s","name":"%s","input":{"note":"%s"}}]}}\n' "$i" "$n" "$PLANTED" >> "$tp"
    done
}
# The tool_result Claude Code writes when a call has run (answered), one per id.
_tool_result() { # $1 path, $2.. tool_use ids
    local tp="$1" id; shift
    for id in "$@"; do
        printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":"done"}]}}\n' "$id" >> "$tp"
    done
}
# A fresh ask record as 33900's --ask writes it (.mmry-asking-<session>), here left over from an
# earlier prompt. 33898 alone never reads one; the stack must not let it supply a name on its own.
_leftover_ask() { # $1 tool name
    printf 'asker -\ntool %s\ninput -\nat %s\n' "$1" "$(date +%s)" > "$TEST_TMPDIR/.mmry-asking-$SID"
}

# #33898 round 2 (QA finding A1), tightened in round 3 (C1, below): the sentence builds the name and
# the session's own transcript must hold it as the one still-waiting call of its server. The transcript never
# supplies a name of its own, so a title, another call of the same server, or a subagent's call that is
# not in the main transcript all send no name, and the lead's tool sentence is left out.

@test "W-26 33898 req1: the MCP sentence names the tool, mcp__mmry__memory_save, not the server" {
    JQ_BIN="$(command -v jq)"
    local tp="$TEST_TMPDIR/transcript.jsonl"
    _transcript "$tp" mcp__mmry__memory_save
    run _waiting "$(_notification_tp 'Claude needs your permission to use mmry - memory_save (MCP)' "$tp")"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    [ "$(_tool_sent)" = "mcp__mmry__memory_save" ] || { cat "$BODIES"; return 1; }
}

@test "W-27 33898 req1: a plugin's MCP server is named as Claude Code names it, mcp__plugin_<plugin>_<server>__<tool>" {
    JQ_BIN="$(command -v jq)"
    local tp="$TEST_TMPDIR/transcript.jsonl"
    _transcript "$tp" mcp__plugin_mmry_mmry__memory_save
    run _waiting "$(_notification_tp 'Claude needs your permission to use plugin:mmry:mmry - memory_save (MCP)' "$tp")"
    [ "$(_tool_sent)" = "mcp__plugin_mmry_mmry__memory_save" ] || { cat "$BODIES"; return 1; }
}

@test "W-28 33898 req1 (A1): a tool shown by its title sends no name, even with a call of that server in the transcript" {
    JQ_BIN="$(command -v jq)"
    local tp="$TEST_TMPDIR/transcript.jsonl"
    _transcript "$tp" mcp__plugin_acme_files__save_file
    run _waiting "$(_notification_tp 'Claude needs your permission to use plugin:acme:files - Save a file (MCP)' "$tp")"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    [ "$(_tool_sent)" = "<none>" ] || { cat "$BODIES"; return 1; }
    ! grep -q "$PLANTED" "$BODIES" "$URLS" || { echo "planted string sent"; return 1; }
    ! grep -rq "$PLANTED" "$TEST_TMPDIR"/.mmry-waiting-* || { echo "planted string stored"; return 1; }
}

@test "W-33 33898 req1 (A1, probe QA-1): a transcript holding only ANOTHER call of the server sends no name" {
    JQ_BIN="$(command -v jq)"
    local tp="$TEST_TMPDIR/transcript.jsonl"
    _transcript "$tp" mcp__mmry__memory_search
    run _waiting "$(_notification_tp 'Claude needs your permission to use mmry - memory_save (MCP)' "$tp")"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    [ "$(_tool_sent)" = "<none>" ] || { cat "$BODIES"; return 1; }
    ! grep -q 'memory_search' "$BODIES" "$TEST_TMPDIR"/.mmry-waiting-* || { echo "another tool was named"; return 1; }
}

@test "W-34 33898 req1 (A1, C1): the one still-waiting exact call is named, past answered calls of the server and of that tool" {
    JQ_BIN="$(command -v jq)"
    local tp="$TEST_TMPDIR/transcript.jsonl"
    # toolu_1 memory_save (answered), toolu_2 memory_search (answered), toolu_3 memory_save (waiting).
    _transcript "$tp" mcp__mmry__memory_save mcp__mmry__memory_search mcp__mmry__memory_save
    _tool_result "$tp" toolu_1 toolu_2
    run _waiting "$(_notification_tp 'Claude needs your permission to use mmry - memory_save (MCP)' "$tp")"
    [ "$(_tool_sent)" = "mcp__mmry__memory_save" ] || { cat "$BODIES"; return 1; }
    # The waiting call written to the transcript twice (one id) is still one call.
    : > "$BODIES"; rm -f "$TEST_TMPDIR"/.mmry-waiting-*
    tail -n 3 "$tp" | head -n 1 >> "$tp"
    run _waiting "$(_notification_tp 'Claude needs your permission to use mmry - memory_save (MCP)' "$tp")"
    [ "$(_tool_sent)" = "mcp__mmry__memory_save" ] || { cat "$tp" "$BODIES"; return 1; }
}

# #33898 round 3 (QA finding C1, lead 439's ruling 2026-11-18): the transcript must tie the name to
# THIS prompt. A name is sent only when its call is still waiting (no tool_result carries its id) and
# is the only still-waiting call of its server in the transcript; otherwise the sentence is left out.
# A leftover ask record never supplies a name on its own.

@test "W-37 33898 req1 (C1, probe P-01): a bare-word title equal to another tool's real name sends no name" {
    JQ_BIN="$(command -v jq)"
    local tp="$TEST_TMPDIR/transcript.jsonl"
    # read_file ran earlier and was answered; write_file, whose title is "read_file", is the one asking.
    _transcript "$tp" mcp__acme__read_file mcp__acme__write_file
    _tool_result "$tp" toolu_1
    run _waiting "$(_notification_tp 'Claude needs your permission to use acme - read_file (MCP)' "$tp")"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    [ "$(_tool_sent)" = "<none>" ] || { cat "$BODIES"; return 1; }
}

@test "W-38 33898 req1 (C1, probe P-02): a name string inside another call's input is not a call, and sends no name" {
    JQ_BIN="$(command -v jq)"
    local tp="$TEST_TMPDIR/transcript.jsonl"
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_9","name":"mcp__acme__write_file","input":{"meta":{"name":"mcp__acme__Save"}}}]}}' > "$tp"
    run _waiting "$(_notification_tp 'Claude needs your permission to use acme - Save (MCP)' "$tp")"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    [ "$(_tool_sent)" = "<none>" ] || { cat "$BODIES"; return 1; }
}

@test "W-39 33898 req1 (C1): a leftover ask record never supplies a name on its own" {
    JQ_BIN="$(command -v jq)"
    local tp="$TEST_TMPDIR/transcript.jsonl"
    # The record and the transcript name a call that has already been answered.
    _transcript "$tp" mcp__acme__write_file
    _tool_result "$tp" toolu_1
    _leftover_ask mcp__acme__write_file
    run _waiting "$(_notification_tp 'Claude needs your permission to use acme - write_file (MCP)' "$tp")"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    [ "$(_tool_sent)" = "<none>" ] || { cat "$BODIES"; return 1; }
    # A titled MCP prompt with a leftover record naming a tool of that server: no name.
    : > "$BODIES"; rm -f "$TEST_TMPDIR"/.mmry-waiting-*
    _leftover_ask mcp__acme__write_file
    run _waiting "$(_notification_tp 'Claude needs your permission to use acme - Write a file (MCP)' "$tp")"
    [ "$(_tool_sent)" = "<none>" ] || { cat "$BODIES"; return 1; }
    [ "$(_puts)" -eq 2 ] || { cat "$URLS"; return 1; }
}

@test "W-40 33898 req1 (C1): two still-waiting calls of one server send no name, even when one matches exactly" {
    JQ_BIN="$(command -v jq)"
    local tp="$TEST_TMPDIR/transcript.jsonl"
    _transcript "$tp" mcp__mmry__memory_save mcp__mmry__memory_search
    run _waiting "$(_notification_tp 'Claude needs your permission to use mmry - memory_save (MCP)' "$tp")"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    [ "$(_tool_sent)" = "<none>" ] || { cat "$BODIES"; return 1; }
    # Two waiting calls of the same tool are no better: either could be the one asking.
    : > "$BODIES"; rm -f "$TEST_TMPDIR"/.mmry-waiting-*
    _transcript "$tp" mcp__mmry__memory_save mcp__mmry__memory_save
    run _waiting "$(_notification_tp 'Claude needs your permission to use mmry - memory_save (MCP)' "$tp")"
    [ "$(_tool_sent)" = "<none>" ] || { cat "$BODIES"; return 1; }
    [ "$(_puts)" -eq 2 ] || { cat "$URLS"; return 1; }
}

@test "W-35 33898 req1 (A1, probe QA-2): a titled tool called in parallel with another tool of the server sends no name" {
    JQ_BIN="$(command -v jq)"
    local tp="$TEST_TMPDIR/transcript.jsonl"
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"mcp__plugin_acme_files__save_file","input":{}},{"type":"tool_use","id":"toolu_2","name":"mcp__plugin_acme_files__list_files","input":{}}]}}' > "$tp"
    run _waiting "$(_notification_tp 'Claude needs your permission to use plugin:acme:files - Save a file (MCP)' "$tp")"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    [ "$(_tool_sent)" = "<none>" ] || { cat "$BODIES"; return 1; }
}

@test "W-36 33898 req1 (A1): a subagent's prompt, its call absent from the main transcript or no transcript at all, sends no name" {
    JQ_BIN="$(command -v jq)"
    local tp="$TEST_TMPDIR/transcript.jsonl"
    # The main thread called nothing of this server; the subagent's call lives in its own transcript.
    _transcript "$tp" Bash
    run _waiting "$(_notification_tp 'Claude needs your permission to use mmry - memory_save (MCP)' "$tp")"
    [ "$(_tool_sent)" = "<none>" ] || { cat "$BODIES"; return 1; }
    # No readable transcript: nothing establishes the name.
    : > "$BODIES"; rm -f "$TEST_TMPDIR"/.mmry-waiting-*
    run _waiting "$(_notification permission_prompt 'Claude needs your permission to use mmry - memory_save (MCP)')"
    [ "$(_puts)" -eq 2 ] || { cat "$URLS"; return 1; }
    [ "$(_tool_sent)" = "<none>" ] || { cat "$BODIES"; return 1; }
}

@test "W-29 33898 req1: an MCP sentence that cannot be read sends no name, and the member is still reported" {
    JQ_BIN="$(command -v jq)"
    for m in 'Claude needs your permission to use plugin:acme:files - Save a file (MCP)' \
             'Claude needs your permission to use mmry (MCP)' \
             'Claude needs your permission to use mmry - memory_save (MCP) and more'; do
        : > "$BODIES"; rm -f "$TEST_TMPDIR"/.mmry-waiting-*
        run _waiting "$(_notification permission_prompt "$m")"
        [ "$(grep -c '^PUT ' "$BODIES" "$URLS" | tail -1 | cut -d: -f2)" -ge 1 ] || { cat "$URLS"; return 1; }
        [ "$(_tool_sent)" = "<none>" ] || { echo "for: $m"; cat "$BODIES"; return 1; }
    done
    [ "$(_puts)" -eq 3 ] || { cat "$URLS"; return 1; }
}

@test "W-30 33898 req1: a server and tool longer than 64 characters send no name, never a shortened one" {
    JQ_BIN="$(command -v jq)"
    local srv="a-very-long-mcp-server-name-for-testing" tl="an_equally_long_tool_name_here"
    run _waiting "$(_notification permission_prompt "Claude needs your permission to use $srv - $tl (MCP)")"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    [ "$(_tool_sent)" = "<none>" ] || { cat "$BODIES"; return 1; }
    ! grep -q 'mcp__a-very' "$BODIES" || { echo "a shortened name was sent"; return 1; }
}

@test "W-31 33898 req3: a planted secret after the MCP tool name reaches neither the call, the marker nor the output" {
    JQ_BIN="$(command -v jq)"
    run _waiting "$(_notification permission_prompt "Claude needs your permission to use mmry - memory_save (MCP) $PLANTED")"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "printed: $output"; return 1; }
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    ! grep -q "$PLANTED" "$BODIES" "$URLS" || { echo "planted string sent"; return 1; }
    ! grep -rq "$PLANTED" "$TEST_TMPDIR"/.mmry-waiting-* || { echo "planted string stored"; return 1; }
    run _waiting "$(_notification permission_prompt "Claude needs your permission to use mmry - memory_save $PLANTED (MCP)")"
    ! grep -q "$PLANTED" "$BODIES" "$URLS" || { echo "planted string sent"; return 1; }
}

@test "W-32 33898 req2: Bash and Write send exactly the names they sent before" {
    JQ_BIN="$(command -v jq)"
    _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash')"
    [ "$(_tool_sent)" = "Bash" ] || { cat "$BODIES"; return 1; }
    _check "$(_event UserPromptSubmit)" || true
    : > "$BODIES"
    _waiting "$(_notification permission_prompt 'Claude needs your permission to use Write')"
    [ "$(_tool_sent)" = "Write" ] || { cat "$BODIES"; return 1; }
}
