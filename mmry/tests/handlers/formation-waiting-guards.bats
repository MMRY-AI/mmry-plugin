#!/usr/bin/env bats
# formation-waiting-guards.bats - the waiting handler's own bare-name check, and the Codex route into
# the clear through codex-hook.sh (#33897, findings b1 and b5 of the 33452 QA; DD-187 in the API
# repository).
#
# b1. formation-waiting.sh drops any tool name that is not a bare name (letters, digits and _ . : -,
#     at most 64 characters) before it reaches the service. Nothing tested it: with the check removed,
#     every case in formation-waiting.bats still passed. The service would then refuse the request, and
#     the lead would never be told. Two paths reach the check with a name nothing else has refused:
#       Codex's PermissionRequest   tool_name comes straight from the payload
#       an MCP sentence             the name is built as mcp__<server>__<tool>; the transcript confirms
#                                   it, and only the check refuses one over 64 characters
#     A Claude Code sentence's bare word ("use Bash;") is also refused by the built-in list (#33898),
#     so G-03 holds with or without the check; it is here for requirement 2, not requirement 1.
#   G-01  Codex: a tool_name that is not bare tells the lead once, with no tool name (requirements 1, 2)
#   G-02  an MCP sentence whose built name is 65 characters tells the lead once, with no name (1, 2)
#   G-03  "use Bash;" tells the lead once, with no name (2)
#
# b5. No offline test drove a Codex payload through codex-hook.sh, the real Codex entry point, into
#     the clear. Every case below runs the command hooks/codex-hooks.json registers for the event,
#     as Codex runs it, with the payload on stdin, so removing a registration turns its case red.
#   G-04  Codex: the asked call's PostToolUse clears once and tells the lead once (requirement 3)
#   G-05  Codex: the person's next prompt clears once and tells the lead once (requirement 3)
#   G-06..G-09 (after #33900 merges) an unrelated Codex call, the asking turn's Stop, a subagent's
#         SubagentStop, all through codex-hook.sh, and Claude Code's ask record (requirements 1 to 3)
#
# The service is a fake curl that records every request and body, and records the lead's
# "APPROVAL ANSWERED." notice where the service would send it: only on a clear it accepts.

load '../helpers/test-helper'

PLANTED="PLANTED-SECRET-33897-sk-live-77aa"

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
code=200; resp='{}'
case "$method $url" in
    "GET "*/api/formations/4242|"GET "*/api/formations/4242"?sessionId="*)   # #31854: the read names the session
        resp='{"formation":{"id":4242},"members":[{"id":12,"sessionId":null,"role":"Lead","leftDate":null},{"id":31,"sessionId":"'"${FAKE_OWN_SID:-}"'","role":"Wingman","leftDate":null}]}' ;;
    "PUT "*/members/*/waiting)
        resp='{"formationId":4242,"memberId":31,"waiting":true,"waitingSince":"2026-11-13T14:05:00","toolName":null,"leadTold":true,"outcome":"Set"}' ;;
    "DELETE "*/members/*/waiting*)
        # The service tells the lead "APPROVAL ANSWERED." on a clear it accepts (DD-187 point 3).
        printf '%s\n' "APPROVAL ANSWERED. Member 31 is no longer waiting on a permission prompt." >> "$FAKE_NOTICE_LOG"
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
    export FAKE_URL_LOG="$URLS" FAKE_BODY_LOG="$BODIES" FAKE_NOTICE_LOG="$NOTICES"
    export MMRY_API_KEY="fake-key" MMRY_API_URL="http://fake.invalid" MMRY_AUTH_METHOD="apikey"
    export MMRY_NO_SELF_UPDATE=1
    # A Stop payload's idle watch, should any case reach one, is held to one second.
    export MMRY_IDLE_POLL_SECONDS=1 MMRY_IDLE_POLL_INTERVAL=1
    unset MMRY_HOST CODEX_HOME CODEX_SESSION_ID CODEX_THREAD_ID CLAUDE_SESSION_ID MMRY_FORMATION_MODE MMRY_CONFIG_FILE
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/claudecfg"
    CODEX_DIR="$TEST_TMPDIR/codex-home"
    mkdir -p "$CLAUDE_CONFIG_DIR" "$CODEX_DIR"
    SID="cccc4444-guards-$$"
    export CLAUDE_CODE_SESSION_ID="$SID" FAKE_OWN_SID="$SID"
    HH="$PLUGIN_ROOT/hooks-handlers"
    JQ="$(command -v jq)"
    bash "$HH/formation-state.sh" set 4242 "$SID" >/dev/null
}

teardown() {
    bash "$HH/formation-state.sh" clear "$SID" >/dev/null 2>&1 || true
    rm -f "$TEST_TMPDIR"/.mmry-waiting-* "$TEST_TMPDIR"/.mmry-asking-* 2>/dev/null || true
    mmry_teardown_tmp "$TEST_TMPDIR"
}

# ---- the payloads, as Claude Code and Codex send them ---------------------------------------
_notification() { # $1 the sentence, $2 transcript path (optional)
    printf '{"session_id":"%s","transcript_path":"%s","cwd":"/x","hook_event_name":"Notification","notification_type":"permission_prompt","message":"%s"}' "$SID" "${2:-/x}" "$1"
}
# Codex, from codex-rs: a shell command's PermissionRequest tool_input is {command, description}, its
# PostToolUse tool_input is {command} alone.
_codex_ask() { # $1 tool_name (already JSON-escaped)
    printf '{"session_id":"%s","turn_id":"turn-77","transcript_path":null,"cwd":"/x","hook_event_name":"PermissionRequest","model":"gpt-5","permission_mode":"default","tool_name":"%s","tool_input":{"command":"ls %s","description":"list the folder"}}' "$SID" "$1" "$PLANTED"
}
_codex_post() { # $1 tool_name, $2 command
    printf '{"session_id":"%s","turn_id":"turn-77","transcript_path":null,"cwd":"/x","hook_event_name":"PostToolUse","model":"gpt-5","permission_mode":"default","tool_name":"%s","tool_input":{"command":"%s"},"tool_response":"ok","tool_use_id":"call_1"}' "$SID" "$1" "$2"
}
_codex_prompt() { # $1 prompt text
    printf '{"session_id":"%s","turn_id":"turn-78","transcript_path":null,"cwd":"/x","hook_event_name":"UserPromptSubmit","model":"gpt-5","permission_mode":"default","prompt":"%s"}' "$SID" "$1"
}
# A transcript whose latest assistant message calls the named tool, not yet answered.
_transcript() { # $1 path, $2 tool name
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"%s","input":{"note":"%s"}}]}}\n' "$2" "$PLANTED" > "$1"
}

# ---- the routes ------------------------------------------------------------------------------
_waiting() { printf '%s' "$1" | bash "$HH/formation-waiting.sh"; }
# The command hooks/codex-hooks.json registers on EVENT for HANDLER (formation-check or
# formation-waiting), run as Codex runs it: through sh, with the payload on stdin. Empty, and so no
# call at all, when nothing is registered there.
_registered() { # $1 event, $2 handler
    "$JQ" -r --arg e "$1" --arg h "codex-hook.sh\" $2" \
        '[.hooks[$e][]?.hooks[]?.command | select(type == "string" and contains($h))][0] // ""' \
        "$PLUGIN_ROOT/hooks/codex-hooks.json" | tr -d '\r'
}
_codex_hook() { # $1 event, $2 handler, $3 payload
    local cmd
    cmd="$(_registered "$1" "$2")"
    [[ -n "$cmd" ]] || { echo "nothing registered on Codex $1 for $2"; return 0; }
    printf '%s' "$3" | env CODEX_HOME="$CODEX_DIR" sh -c "$cmd"
}

# ---- what the service saw --------------------------------------------------------------------
_puts() { grep -c '^PUT .*/api/formations/4242/members/31/waiting$' "$URLS" || true; }
_deletes() { grep -c '^DELETE .*/api/formations/4242/members/31/waiting?sessionId=' "$URLS" || true; }
_marker() { ls "$TEST_TMPDIR"/.mmry-waiting-* 2>/dev/null | head -1; }
_answered() { grep -c 'APPROVAL ANSWERED\.' "$NOTICES" || true; }
# The tool name each PUT sent, one line per PUT: "<none>" for absent, null or empty.
_tools_sent() { "$JQ" -r 'select(has("sessionId")) | (.toolName // "") | if . == "" then "<none>" else . end' < "$BODIES"; }
_reset() { : > "$URLS"; : > "$BODIES"; : > "$NOTICES"; rm -f "$TEST_TMPDIR"/.mmry-waiting-* 2>/dev/null || true; }
# Told once, with no tool name, and no part of the bad name or the prompt anywhere the service saw.
_told_once_unnamed() { # $1 the bad name (raw)
    [ "$(_puts)" -eq 1 ] || { echo "waiting calls: $(_puts)"; cat "$URLS"; return 1; }
    [ "$(_tools_sent)" = "<none>" ] || { echo "tool name sent: $(_tools_sent)"; return 1; }
    ! grep -qF -- "$1" "$BODIES" || { echo "the bad name reached the service"; cat "$BODIES"; return 1; }
    ! grep -qF -- "$PLANTED" "$BODIES" || { echo "the prompt reached the service"; return 1; }
    [ -n "$(_marker)" ] || { echo "no marker: the next event cannot clear"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# b1: the bare-name check

@test "G-01 33897 req1+2: Codex, a tool_name that is not a bare name tells the lead once, with no tool name" {
    local long; long="$(printf 'a%.0s' $(seq 1 65))"
    # Each raw name, then the same name escaped for the JSON payload.
    local -a raw=("Bash;" "Bash rm" "mcp__srv__tool;id" "Bash\$(id)" "$long" "apply_patch/x")
    local -a esc=("Bash;" "Bash rm" "mcp__srv__tool;id" "Bash\$(id)" "$long" "apply_patch/x")
    local i
    for i in "${!raw[@]}"; do
        _reset
        run _codex_hook PermissionRequest formation-waiting "$(_codex_ask "${esc[$i]}")"
        [ "$status" -eq 0 ]
        # Codex reads this hook's stdout as an approval decision: nothing, ever.
        [ -z "$output" ] || { echo "[${raw[$i]}] printed: $output"; return 1; }
        _told_once_unnamed "${raw[$i]}" || { echo "for the name [${raw[$i]}]"; return 1; }
    done
    # Control: a bare name is sent, so the case above is not passing because no name is ever sent.
    _reset
    _codex_hook PermissionRequest formation-waiting "$(_codex_ask apply_patch)"
    [ "$(_tools_sent)" = "apply_patch" ] || { echo "a bare name was not sent: $(_tools_sent)"; return 1; }
}

@test "G-02 33897 req1+2: an MCP sentence whose built name is over 64 characters tells the lead once, with no name" {
    local title tp built
    title="$(printf 'a%.0s' $(seq 1 53))"
    built="mcp__probe__${title}"            # 65 characters
    [ "${#built}" -eq 65 ]
    tp="$TEST_TMPDIR/transcript.jsonl"
    _transcript "$tp" "$built"
    run _waiting "$(_notification "Claude needs your permission to use probe - ${title} (MCP)" "$tp")"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "printed: $output"; return 1; }
    _told_once_unnamed "$built"

    # Control: one character shorter is a bare name, and the same path sends it.
    _reset
    title="${title%a}"; built="mcp__probe__${title}"
    _transcript "$tp" "$built"
    _waiting "$(_notification "Claude needs your permission to use probe - ${title} (MCP)" "$tp")"
    [ "$(_tools_sent)" = "$built" ] || { echo "the 64-character name was not sent: $(_tools_sent)"; return 1; }
}

@test "G-03 33897 req2: a Claude Code sentence naming Bash; tells the lead once, with no tool name" {
    run _waiting "$(_notification 'Claude needs your permission to use Bash;')"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "printed: $output"; return 1; }
    _told_once_unnamed "Bash;"
}

# ---------------------------------------------------------------------------------------------
# b5: the Codex route into the clear, through codex-hook.sh

@test "G-04 33897 req3: Codex, the asked call's PostToolUse through codex-hook.sh clears once and tells the lead once" {
    _codex_hook PermissionRequest formation-waiting "$(_codex_ask Bash)"
    [ "$(_puts)" -eq 1 ] || { echo "the raise made $(_puts) calls"; cat "$URLS"; return 1; }
    [ -n "$(_marker)" ] || { echo "no marker after the raise"; return 1; }

    run _codex_hook PostToolUse formation-check "$(_codex_post Bash "ls $PLANTED")"
    [ "$status" -eq 0 ]
    [ "$(_deletes)" -eq 1 ] || { echo "clear calls: $(_deletes)"; echo "$output"; cat "$URLS"; return 1; }
    [ "$(_answered)" -eq 1 ] || { echo "notices: $(_answered)"; return 1; }
    [ -z "$(_marker)" ] || { echo "the marker is still there"; return 1; }

    # Once: the next call of the same session asks nothing more.
    _codex_hook PostToolUse formation-check "$(_codex_post Bash "ls $PLANTED")" >/dev/null || true
    [ "$(_deletes)" -eq 1 ] || { echo "clear calls: $(_deletes)"; return 1; }
}

@test "G-05 33897 req3: Codex, the person's next prompt through codex-hook.sh clears once and tells the lead once" {
    _codex_hook PermissionRequest formation-waiting "$(_codex_ask Bash)"
    [ -n "$(_marker)" ] || { echo "no marker after the raise"; return 1; }

    run _codex_hook UserPromptSubmit formation-check "$(_codex_prompt 'carry on')"
    [ "$status" -eq 0 ]
    [ "$(_deletes)" -eq 1 ] || { echo "clear calls: $(_deletes)"; echo "$output"; cat "$URLS"; return 1; }
    [ "$(_answered)" -eq 1 ] || { echo "notices: $(_answered)"; return 1; }
    [ -z "$(_marker)" ] || { echo "the marker is still there"; return 1; }

    _codex_hook UserPromptSubmit formation-check "$(_codex_prompt 'and again')" >/dev/null || true
    [ "$(_deletes)" -eq 1 ] || { echo "clear calls: $(_deletes)"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# After #33900: the clear follows the answered prompt (DD-187 point 7). Through codex-hook.sh, as
# above. These cases need #33900's code: on develop before it, any event clears and Codex registers
# no Stop or SubagentStop route.

_codex_stop() { # $1 turn_id
    printf '{"session_id":"%s","turn_id":"%s","transcript_path":null,"cwd":"/x","hook_event_name":"Stop","model":"gpt-5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null}' "$SID" "$1"
}
_codex_sub_ask() { # $1 agent_id: a thread-spawned subagent's PermissionRequest
    printf '{"session_id":"%s","turn_id":"turn-sub","transcript_path":null,"cwd":"/x","hook_event_name":"PermissionRequest","model":"gpt-5","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"ls","description":"list"},"agent_id":"%s","agent_type":"worker"}' "$SID" "$1"
}
_codex_subagent_stop() { # $1 agent_id
    printf '{"session_id":"%s","turn_id":"turn-sub","transcript_path":null,"agent_transcript_path":null,"cwd":"/x","hook_event_name":"SubagentStop","model":"gpt-5","permission_mode":"default","stop_hook_active":false,"agent_id":"%s","agent_type":"worker","last_assistant_message":null}' "$SID" "$1"
}
_held() { # still waiting: no clear call, no notice, the marker in place
    [ "$(_deletes)" -eq 0 ] || { echo "a clear call was made"; cat "$URLS"; return 1; }
    [ "$(_answered)" -eq 0 ] || { echo "the lead was told the approval was answered"; return 1; }
    [ -n "$(_marker)" ] || { echo "the marker is gone"; return 1; }
}
_cleared_once() {
    [ "$(_deletes)" -eq 1 ] || { echo "clear calls: $(_deletes)"; cat "$URLS"; return 1; }
    [ "$(_answered)" -eq 1 ] || { echo "notices: $(_answered)"; return 1; }
    [ -z "$(_marker)" ] || { echo "the marker is still there"; return 1; }
}

@test "G-06 33897 req3 (after 33900): Codex, an unrelated tool call through codex-hook.sh clears nothing; the asked call then does" {
    _codex_hook PermissionRequest formation-waiting "$(_codex_ask Bash)"
    [ -n "$(_marker)" ] || { echo "no marker after the raise"; return 1; }
    _codex_hook PostToolUse formation-check "$(_codex_post Bash 'git status')" >/dev/null || true
    _codex_hook PostToolUse formation-check "$(_codex_post apply_patch "ls $PLANTED")" >/dev/null || true
    _held
    _codex_hook PostToolUse formation-check "$(_codex_post Bash "ls $PLANTED")" >/dev/null || true
    _cleared_once
}

@test "G-07 33897 req3 (after 33900): Codex, the asking turn's Stop through codex-hook.sh clears once; another turn's Stop does not" {
    _codex_hook PermissionRequest formation-waiting "$(_codex_ask Bash)"
    [ -n "$(_marker)" ] || { echo "no marker after the raise"; return 1; }
    run _codex_hook Stop formation-waiting "$(_codex_stop turn-99)"
    [ -z "$output" ] || { echo "printed: $output"; return 1; }
    _held
    run _codex_hook Stop formation-waiting "$(_codex_stop turn-77)"
    [ -z "$output" ] || { echo "printed: $output"; return 1; }
    _cleared_once
}

@test "G-08 33897 req3 (after 33900): Codex, a subagent's prompt clears on its SubagentStop through codex-hook.sh, not on the main turn's Stop" {
    _codex_hook PermissionRequest formation-waiting "$(_codex_sub_ask sub-41)"
    [ -n "$(_marker)" ] || { echo "no marker after the raise"; return 1; }
    _codex_hook Stop formation-waiting "$(_codex_stop turn-sub)" >/dev/null || true
    _codex_hook SubagentStop formation-waiting "$(_codex_subagent_stop sub-99)" >/dev/null || true
    _held
    run _codex_hook SubagentStop formation-waiting "$(_codex_subagent_stop sub-41)"
    [ -z "$output" ] || { echo "printed: $output"; return 1; }
    _cleared_once
}

@test "G-09 33897 req1+2 (after 33900): Claude Code's ask record never keeps a name that is not bare, and Bash; is sent unnamed" {
    local rec="$TEST_TMPDIR/.mmry-asking-$SID"
    printf '{"session_id":"%s","transcript_path":"/x","cwd":"/x","prompt_id":"p-1","permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"Bash;","tool_input":{"command":"ls"},"permission_suggestions":[]}' "$SID" \
        | bash "$HH/formation-waiting.sh" --ask
    [ -f "$rec" ] || { echo "no ask record written"; return 1; }
    grep -qx 'tool -' "$rec" || { echo "the record kept:"; cat "$rec"; return 1; }
    ! grep -qF 'Bash;' "$rec" || { cat "$rec"; return 1; }
    run _waiting "$(_notification 'Claude needs your permission to use Bash;')"
    [ -z "$output" ] || { echo "printed: $output"; return 1; }
    _told_once_unnamed "Bash;"
}
