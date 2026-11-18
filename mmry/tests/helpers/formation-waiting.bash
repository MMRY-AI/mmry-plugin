# formation-waiting.bash - shared setup and helpers for formation-waiting.bats and
# formation-waiting-record.bats (#33452, #33898, #33900). Split out in #33900 round 4 so neither
# test file reaches the 64000-byte limit (structural/test-file-size.bats).

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
        # The service tells the lead "APPROVAL ANSWERED." on a clear, and only on a clear (DD-187 point 3,
        # FormationWaitingNotice.Cleared). The fake records that notice where the real one would send it.
        [[ "$code" == 2* && -n "${FAKE_NOTICE_LOG:-}" ]] && printf '%s\n' "APPROVAL ANSWERED. Member 31 is no longer waiting on a permission prompt." >> "$FAKE_NOTICE_LOG"
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
    NOTICES="$TEST_TMPDIR/lead-notices"; : > "$NOTICES"
    export FAKE_URL_LOG="$URLS" FAKE_BODY_LOG="$BODIES" FAKE_NOTICE_LOG="$NOTICES"
    export MMRY_API_KEY="fake-key" MMRY_API_URL="http://fake.invalid" MMRY_AUTH_METHOD="apikey"
    export MMRY_NO_SELF_UPDATE=1
    # #33900 drives Stop payloads: the idle watch they start is held to one second here.
    export MMRY_IDLE_POLL_SECONDS=1 MMRY_IDLE_POLL_INTERVAL=1
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


BG="a855439faab585b00"      # a background agent's id, as Claude Code gives it
SUB="ae33bbb23f8fc4e5f"     # a subagent that asks for approval itself

_agent_part() { [[ -n "${1:-}" ]] && printf ',"agent_id":"%s","agent_type":"general-purpose"' "$1"; return 0; }
_cc_ask() { # $1 tool_name, $2 agent_id (optional), $3 command text
    printf '{"session_id":"%s","transcript_path":"/x","cwd":"/x","prompt_id":"p-1","permission_mode":"default","effort":"medium","hook_event_name":"PermissionRequest","tool_name":"%s","tool_input":{"command":"%s"},"permission_suggestions":[]%s}' "$SID" "$1" "${3:-ls}" "$(_agent_part "${2:-}")"
}
_cc_post() { # $1 tool_name, $2 agent_id (optional), $3 tool_input JSON (default: the one _cc_ask sends)
    local in="${3:-}"; [[ -n "$in" ]] || in='{"command":"ls"}'
    printf '{"session_id":"%s","transcript_path":"/x","cwd":"/x","prompt_id":"p-1","permission_mode":"default","hook_event_name":"PostToolUse","tool_name":"%s","tool_input":%s,"tool_response":"ok","tool_use_id":"toolu_1","duration_ms":5%s}' "$SID" "$1" "$in" "$(_agent_part "${2:-}")"
}
_cc_ask_in() { # $1 tool_name, $2 agent_id (optional), $3 tool_input JSON
    printf '{"session_id":"%s","transcript_path":"/x","cwd":"/x","prompt_id":"p-1","permission_mode":"default","effort":"medium","hook_event_name":"PermissionRequest","tool_name":"%s","tool_input":%s,"permission_suggestions":[]%s}' "$SID" "$1" "$3" "$(_agent_part "${2:-}")"
}
_cc_stop() { # $1 the background_tasks JSON array
    printf '{"session_id":"%s","transcript_path":"/x","cwd":"/x","prompt_id":"p-1","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"done","background_tasks":%s,"session_crons":[]}' "$SID" "${1:-[]}"
}
_cc_subagent_stop() { # $1 agent_id
    printf '{"session_id":"%s","transcript_path":"/x","cwd":"/x","hook_event_name":"SubagentStop","agent_id":"%s","agent_type":"general-purpose","stop_hook_active":false}' "$SID" "$1"
}
_cc_prompt() { # $1 prompt text (already JSON-escaped)
    printf '{"session_id":"%s","transcript_path":"/x","cwd":"/x","prompt_id":"p-2","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"%s"}' "$SID" "$1"
}
# Codex shapes, from codex-rs (openai/codex 9f80bb5): a shell command's PermissionRequest tool_input is
# {command, description} (sandboxing.rs PermissionRequestPayload::bash), its PostToolUse tool_input is
# {command} alone (context.rs ExecCommandToolOutput::post_tool_use_input), the same hook_command.
_codex_ask() { # $1 tool_name, $2 agent_id (optional), $3 tool_input JSON (optional)
    local in="${3:-}"; [[ -n "$in" ]] || in='{"command":"ls","description":"list the folder"}'
    printf '{"session_id":"%s","turn_id":"turn-77","transcript_path":null,"cwd":"/x","hook_event_name":"PermissionRequest","model":"gpt-5","permission_mode":"default","tool_name":"%s","tool_input":%s%s}' "$SID" "$1" "$in" "$(_agent_part "${2:-}")"
}
_codex_post() { # $1 tool_name, $2 agent_id (optional), $3 tool_input JSON (optional)
    local in="${3:-}"; [[ -n "$in" ]] || in='{"command":"ls"}'
    printf '{"session_id":"%s","turn_id":"turn-77","transcript_path":null,"cwd":"/x","hook_event_name":"PostToolUse","model":"gpt-5","permission_mode":"default","tool_name":"%s","tool_input":%s,"tool_response":"ok","tool_use_id":"call_1"%s}' "$SID" "$1" "$in" "$(_agent_part "${2:-}")"
}
_codex_stop() { # $1 turn_id
    printf '{"session_id":"%s","turn_id":"%s","transcript_path":null,"cwd":"/x","hook_event_name":"Stop","model":"gpt-5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null}' "$SID" "$1"
}
_codex_subagent_stop() { # $1 agent_id
    printf '{"session_id":"%s","turn_id":"turn-sub","transcript_path":null,"agent_transcript_path":null,"cwd":"/x","hook_event_name":"SubagentStop","model":"gpt-5","permission_mode":"default","stop_hook_active":false,"agent_id":"%s","agent_type":"worker","last_assistant_message":null}' "$SID" "$1"
}
# The registered stop hooks (B2): formation-waiting.sh --answer-hook, which reads the session from the payload.
_stophook() { printf '%s' "$1" | bash "$HH/formation-waiting.sh" --answer-hook; }
_ask() { printf '%s' "$1" | bash "$HH/formation-waiting.sh" --ask; }
# A Claude Code prompt as it arrives: PermissionRequest at once, the permission_prompt Notification 6 s later.
_cc_raise() { # $1 tool_name, $2 agent_id, $3 the sentence's tool part
    _ask "$(_cc_ask "$1" "${2:-}")" || true
    _waiting "$(_notification permission_prompt "Claude needs your permission to use ${3:-$1}")"
}
_answered() { grep -c 'APPROVAL ANSWERED\.' "$NOTICES" || true; }
_held() { # still waiting: no clear call, no notice, the marker in place
    [ "$(_deletes)" -eq 0 ] || { echo "a clear call was made"; cat "$URLS"; return 1; }
    [ "$(_answered)" -eq 0 ] || { echo "the lead was told the approval was answered"; cat "$NOTICES"; return 1; }
    [ -n "$(_marker)" ] || { echo "the marker is gone"; return 1; }
}
_cleared_once() {
    [ "$(_deletes)" -eq 1 ] || { echo "clear calls: $(_deletes)"; cat "$URLS"; return 1; }
    [ "$(_answered)" -eq 1 ] || { echo "notices: $(_answered)"; cat "$NOTICES"; return 1; }
    [ -z "$(_marker)" ] || { echo "the marker is still there"; return 1; }
}
_running_bg() { printf '[{"id":"%s","type":"subagent","status":"running","description":"x"}]' "$1"; }
