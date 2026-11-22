#!/usr/bin/env bats
# formation-waiting-busy.bats - the plugin treats the service's busy answer, 409 "The formation is
# busy. Try again.", as busy and not as a refusal (#33902 test case 3, DD-187 in the API repository).
#
# #33902 moved the busy answer of PUT and DELETE /api/formations/{id}/members/{memberId}/waiting from
# 400 to 409, so a caller knows to try again. The plugin's two callers are formation-waiting.sh's raise
# (PUT) and its clear (DELETE). This file proves they read 409 as busy:
#
#   B-01  a 409 on the raise writes no marker and prints nothing, so the next prompt raises again
#   B-02  a 409 on the clear keeps the marker, the lead is not told the approval was answered, and
#         the next event that answers the prompt clears it with one more DELETE
#   B-03  a 409 on the clear of a Codex prompt, then the asked call's own PostToolUse clears it
#   B-04  contrast: a 400 on the clear is a refusal the service will never take back, so the marker goes
#
# The answering events are the person's next prompt and the asked tool's own PostToolUse: both answer
# the prompt before and after #33900 (which ties the clear to the answered prompt), so these cases hold
# on both.
#
# The setup below is the part of formation-waiting.bats's setup these cases need, with two additions:
# FAKE_SET_CODE sets the raise's status, and the lead's "APPROVAL ANSWERED." notice is recorded where the
# service would send it, only on a clear it accepts. When #33900 moves that setup into
# tests/helpers/formation-waiting-helpers.sh, this file can load it, once its fake PUT honours
# FAKE_SET_CODE.

load '../helpers/test-helper'

setup() {
    BIN="$TEST_TMPDIR/fake-bin"
    BODIES="$TEST_TMPDIR/bodies"
    URLS="$TEST_TMPDIR/urls"
    NOTICES="$TEST_TMPDIR/lead-notices"
    mkdir -p "$BIN"
    : > "$BODIES"; : > "$URLS"; : > "$NOTICES"
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
busy='{"error":"The formation is busy. Try again.","detail":null}'
code=200; resp='{}'
case "$method $url" in
    "GET "*/api/formations/4242|"GET "*/api/formations/4242"?sessionId="*)   # #31854: the read names the session
        resp='{"formation":{"id":4242},"members":[{"id":12,"sessionId":null,"role":"Lead","leftDate":null},{"id":31,"sessionId":"'"${FAKE_OWN_SID:-}"'","role":"Wingman","leftDate":null}]}' ;;
    "PUT "*/members/*/waiting)
        code="${FAKE_SET_CODE:-200}"
        resp='{"formationId":4242,"memberId":31,"waiting":true,"waitingSince":"2026-11-13T14:05:00","toolName":null,"leadTold":true,"outcome":"Set"}'
        [[ "$code" == 2* ]] || resp="$busy" ;;
    "DELETE "*/members/*/waiting*)
        code="${FAKE_CLEAR_CODE:-200}"
        resp='{"formationId":4242,"memberId":31,"waiting":false,"leadTold":true,"outcome":"Cleared"}'
        # The service tells the lead "APPROVAL ANSWERED." on a clear, and only on a clear it accepted
        # (DD-187 point 3). A busy answer recorded nothing, so nobody is told.
        if [[ "$code" == 2* ]]; then
            printf '%s\n' "APPROVAL ANSWERED. Member 31 is no longer waiting on a permission prompt." >> "$FAKE_NOTICE_LOG"
        else
            resp="$busy"
        fi ;;
    "GET "*/transmissions/sent*) resp='{"formationId":4242,"member":true,"messages":[]}' ;;
    "GET "*/transmissions*) resp='[]' ;;
esac
[[ -n "$out" ]] && printf '%s' "$resp" > "$out"
printf '%s' "$code"
exit 0
FAKECURL
    chmod +x "$BIN/curl"
    export PATH="$BIN:$PATH"
    export FAKE_URL_LOG="$URLS" FAKE_BODY_LOG="$BODIES" FAKE_NOTICE_LOG="$NOTICES"
    export MMRY_API_KEY="fake-key" MMRY_API_URL="http://fake.invalid" MMRY_AUTH_METHOD="apikey"
    export MMRY_NO_SELF_UPDATE=1
    # A Stop payload's idle watch, should any case reach one, is held to one second.
    export MMRY_IDLE_POLL_SECONDS=1 MMRY_IDLE_POLL_INTERVAL=1
    unset MMRY_HOST CODEX_HOME CODEX_SESSION_ID CODEX_THREAD_ID CLAUDE_SESSION_ID FAKE_SET_CODE FAKE_CLEAR_CODE MMRY_FORMATION_MODE
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/claudecfg"
    mkdir -p "$CLAUDE_CONFIG_DIR"
    SID="bbbb3333-busy-$$"
    export CLAUDE_CODE_SESSION_ID="$SID" FAKE_OWN_SID="$SID"
    HH="$PLUGIN_ROOT/hooks-handlers"
    bash "$HH/formation-state.sh" set 4242 "$SID" >/dev/null
}

teardown() {
    bash "$HH/formation-state.sh" clear "$SID" >/dev/null 2>&1 || true
    rm -f "$TEST_TMPDIR"/.mmry-waiting-* "$TEST_TMPDIR"/.mmry-asking-* 2>/dev/null || true
    mmry_teardown_tmp "$TEST_TMPDIR"
}

# The payloads, as Claude Code and Codex send them (the shapes formation-waiting.bats uses).
_notification() { # $1 the sentence
    printf '{"session_id":"%s","transcript_path":"/x","cwd":"/x","hook_event_name":"Notification","notification_type":"permission_prompt","message":"%s"}' "$SID" "$1"
}
_cc_prompt() { # $1 prompt text (already JSON-escaped)
    printf '{"session_id":"%s","transcript_path":"/x","cwd":"/x","prompt_id":"p-2","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"%s"}' "$SID" "$1"
}
# Codex, from codex-rs: a shell command's PermissionRequest tool_input is {command, description}, its
# PostToolUse tool_input is {command} alone.
_codex_ask() { # $1 tool_name
    printf '{"session_id":"%s","turn_id":"turn-77","transcript_path":null,"cwd":"/x","hook_event_name":"PermissionRequest","model":"gpt-5","permission_mode":"default","tool_name":"%s","tool_input":{"command":"ls","description":"list the folder"}}' "$SID" "$1"
}
_codex_post() { # $1 tool_name
    printf '{"session_id":"%s","turn_id":"turn-77","transcript_path":null,"cwd":"/x","hook_event_name":"PostToolUse","model":"gpt-5","permission_mode":"default","tool_name":"%s","tool_input":{"command":"ls"},"tool_response":"ok","tool_use_id":"call_1"}' "$SID" "$1"
}

_waiting() { printf '%s' "$1" | bash "$HH/formation-waiting.sh"; }
_check() { printf '%s' "$1" | bash "$HH/formation-check.sh"; }
_puts() { grep -c '^PUT .*/api/formations/4242/members/31/waiting$' "$URLS" || true; }
_deletes() { grep -c '^DELETE .*/api/formations/4242/members/31/waiting?sessionId=' "$URLS" || true; }
_marker() { ls "$TEST_TMPDIR"/.mmry-waiting-* 2>/dev/null | head -1; }
_answered() { grep -c 'APPROVAL ANSWERED\.' "$NOTICES" || true; }

SENTENCE='Claude needs your permission to use Bash'

# ---------------------------------------------------------------------------------------------
# The raise (PUT)

@test "B-01 33902: a 409 on the raise writes no marker, prints nothing, and the next prompt raises again" {
    FAKE_SET_CODE=409 run _waiting "$(_notification "$SENTENCE")"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "printed to the member: $output"; return 1; }
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    [ -z "$(_marker)" ] || { echo "marker written on a 409: $(cat "$(_marker)")"; return 1; }

    # Nothing silences the next prompt: it makes its own call, and the service takes it this time.
    run _waiting "$(_notification "$SENTENCE")"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "printed to the member: $output"; return 1; }
    [ "$(_puts)" -eq 2 ] || { echo "PUT calls: $(_puts)"; cat "$URLS"; return 1; }
    [ -n "$(_marker)" ] || { echo "no marker after the 200 raise"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# The clear (DELETE)

@test "B-02 33902: a 409 on the clear keeps the marker, tells nobody, and the person's next prompt clears it" {
    _waiting "$(_notification "$SENTENCE")"
    [ -n "$(_marker)" ] || { echo "no marker after a 200 raise"; return 1; }

    FAKE_CLEAR_CODE=409 _check "$(_cc_prompt 'go on')" || true
    [ "$(_deletes)" -eq 1 ] || { echo "clear calls: $(_deletes)"; cat "$URLS"; return 1; }
    [ -n "$(_marker)" ] || { echo "marker dropped on a 409"; return 1; }
    [ "$(_answered)" -eq 0 ] || { echo "the lead was told the approval was answered"; cat "$NOTICES"; return 1; }

    _check "$(_cc_prompt 'and again')" || true
    [ "$(_deletes)" -eq 2 ] || { echo "clear calls: $(_deletes)"; cat "$URLS"; return 1; }
    [ "$(_answered)" -eq 1 ] || { echo "notices: $(_answered)"; cat "$NOTICES"; return 1; }
    [ -z "$(_marker)" ] || { echo "marker kept after the 200 clear"; return 1; }

    # Cleared once: a further event asks nothing.
    _check "$(_cc_prompt 'once more')" || true
    [ "$(_deletes)" -eq 2 ] || { echo "clear calls: $(_deletes)"; cat "$URLS"; return 1; }
}

@test "B-03 33902: a 409 on the clear of a Codex prompt keeps the marker, and the asked call's PostToolUse clears it" {
    run _waiting "$(_codex_ask Bash)"
    [ -z "$output" ] || { echo "Codex reads this hook's stdout as a decision: $output"; return 1; }
    [ -n "$(_marker)" ] || { echo "no marker after a 200 raise"; return 1; }

    FAKE_CLEAR_CODE=409 _check "$(_codex_post Bash)" || true
    [ "$(_deletes)" -eq 1 ] || { echo "clear calls: $(_deletes)"; cat "$URLS"; return 1; }
    [ -n "$(_marker)" ] || { echo "marker dropped on a 409"; return 1; }
    [ "$(_answered)" -eq 0 ] || { echo "the lead was told the approval was answered"; cat "$NOTICES"; return 1; }

    _check "$(_codex_post Bash)" || true
    [ "$(_deletes)" -eq 2 ] || { echo "clear calls: $(_deletes)"; cat "$URLS"; return 1; }
    [ "$(_answered)" -eq 1 ] || { echo "notices: $(_answered)"; cat "$NOTICES"; return 1; }
    [ -z "$(_marker)" ] || { echo "marker kept after the 200 clear"; return 1; }
}

@test "B-04 33902 contrast: a 400 on the clear is a refusal, so the marker goes, as today" {
    _waiting "$(_notification "$SENTENCE")"
    [ -n "$(_marker)" ] || { echo "no marker after a 200 raise"; return 1; }

    FAKE_CLEAR_CODE=400 _check "$(_cc_prompt 'go on')" || true
    [ "$(_deletes)" -eq 1 ] || { echo "clear calls: $(_deletes)"; cat "$URLS"; return 1; }
    [ -z "$(_marker)" ] || { echo "marker kept on a 400"; return 1; }
    [ "$(_answered)" -eq 0 ] || { echo "the lead was told on a refused clear"; cat "$NOTICES"; return 1; }

    # Nothing is left to clear: the next event asks nothing.
    _check "$(_cc_prompt 'and again')" || true
    [ "$(_deletes)" -eq 1 ] || { echo "clear calls: $(_deletes)"; cat "$URLS"; return 1; }
}
