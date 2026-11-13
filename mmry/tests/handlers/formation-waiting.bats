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
    run _waiting "$(_notification permission_prompt 'Claude needs your permission to use mmry - memory_save (MCP)')"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    ! grep -q 'toolName' "$BODIES" || grep -q '"toolName":"mmry"' "$BODIES" || { cat "$BODIES"; return 1; }
    ! grep -q 'memory_save (MCP)' "$BODIES" || { cat "$BODIES"; return 1; }
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
