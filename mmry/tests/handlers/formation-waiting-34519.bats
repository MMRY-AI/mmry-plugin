#!/usr/bin/env bats
# formation-waiting-34519.bats - #34519 (DD-206): helpers keep working through permission prompts, and
# a prompt that still stops a member is raised with the program it waits to run and cleared as soon as
# it is over. Shared setup and helpers: helpers/formation-waiting-helpers.sh.
#
#   R1 Claude Code  a helper's request (agent_id), denied in the background with no prompt shown, is
#                   raised from the PermissionRequest hook so it is not silent. No allow answer, ever.
#   R1 Codex        the PermissionRequest handler answers allow ONLY for a helper (agent_id) repeating a
#                   command its member already approved in this session; everything else prints nothing.
#   R2              the program, the first word of a shell command with its path removed, is sent beside
#                   the tool name; never an argument, a path or the rest of the command.
#   stale flag      a prompt that timed out, was answered No, or was a built-in safety prompt clears on
#                   the asking agent's next tool call (PreToolUse), measured on Claude Code 2.1.331:
#                   the refused call has no PostToolUse or PostToolUseFailure, and the next event of that
#                   agent is its next call's PreToolUse.

load '../helpers/test-helper'
load '../helpers/formation-waiting-helpers.sh'

ALLOW='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'

_program_sent() { "$JQ_BIN" -r '.programName // "<none>"' < "$BODIES" | tail -1; }
_cc_pre() { # $1 tool_name, $2 agent_id (optional), $3 command text
    printf '{"session_id":"%s","transcript_path":"/x","cwd":"/x","prompt_id":"p-1","permission_mode":"default","effort":"medium","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"command":"%s"},"tool_use_id":"toolu_9"%s}' "$SID" "$1" "${3:-git status}" "$(_agent_part "${2:-}")"
}
_codex_pre() { # $1 tool_name, $2 agent_id (optional), $3 command text
    printf '{"session_id":"%s","turn_id":"turn-77","transcript_path":null,"cwd":"/x","hook_event_name":"PreToolUse","model":"gpt-5","permission_mode":"default","tool_name":"%s","tool_input":{"command":"%s"},"tool_use_id":"call_9"%s}' "$SID" "$1" "${3:-git status}" "$(_agent_part "${2:-}")"
}
_codex_req() { # $1 command text, $2 agent_id (optional): a Codex shell PermissionRequest
    _codex_ask Bash "${2:-}" "{\"command\":\"$1\",\"description\":\"run it\"}"
}
# A Codex member approves its own prompt for COMMAND: raise, then the asked call's PostToolUse.
_codex_member_approves() { # $1 command text
    _waiting "$(_codex_req "$1")" >/dev/null
    _check "$(_codex_post Bash "" "{\"command\":\"$1\"}")" >/dev/null || true
}

# ---- R1, Claude Code: a helper's request that no prompt shows is still raised -------------------

@test "P-01 R1 Claude Code: a helper's PermissionRequest with no prompt shown (a background denial) raises the wait, printing nothing" {
    run bash -c "printf '%s' '$(_cc_ask Bash "$BG" "git push origin main")' | bash '$HH/formation-waiting.sh' --ask"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "printed: $output"; return 1; }
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    "$JQ_BIN" -e '.toolName == "Bash" and .programName == "git"' < "$BODIES" >/dev/null || { cat "$BODIES"; return 1; }
    grep -q "^asker $BG$" "$(_marker)" || { cat "$(_marker)"; return 1; }
}

@test "P-02 R1 Claude Code: the main thread's PermissionRequest alone raises nothing; a foreground helper's later prompt makes no second call" {
    _ask "$(_cc_ask Bash "" "git status")" || true
    [ "$(_puts)" -eq 0 ] || { echo "the main thread's ask raised"; cat "$URLS"; return 1; }
    _ask "$(_cc_ask Bash "$SUB" "npm test")" || true
    _waiting "$(_notification permission_prompt "Claude needs your permission to use Bash")"
    [ "$(_puts)" -eq 1 ] || { echo "PUTs: $(_puts)"; cat "$URLS"; return 1; }
}

@test "P-03 R1 Claude Code: no allow answer, even for a helper repeating a command the member approved" {
    _cc_raise Bash "" >/dev/null
    _check "$(_cc_post Bash "" '{"command":"ls"}')" >/dev/null || true
    run bash -c "printf '%s' '$(_cc_ask Bash "$SUB" "ls")' | bash '$HH/formation-waiting.sh' --ask"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "Claude Code was answered: $output"; return 1; }
}

# ---- R1, Codex: allow only for a helper repeating its member's approval (DD-206) -----------------

@test "P-04 R1 Codex: a helper repeating a command its member approved this session is answered allow, and nothing is raised" {
    _codex_member_approves "git status"
    : > "$URLS"
    run bash -c "printf '%s' '$(_codex_req "git status" "$SUB")' | bash '$HH/formation-waiting.sh'"
    [ "$status" -eq 0 ]
    [ "$output" = "$ALLOW" ] || { echo "got: [$output]"; return 1; }
    [ "$(_puts)" -eq 0 ] || { cat "$URLS"; return 1; }
}

@test "P-05 R1 Codex mutant: the same command WITHOUT agent_id (the member itself) prints nothing and is raised as before" {
    _codex_member_approves "git status"
    : > "$URLS"
    run bash -c "printf '%s' '$(_codex_req "git status")' | bash '$HH/formation-waiting.sh'"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "printed: $output"; return 1; }
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
}

@test "P-06 R1 Codex mutant: a helper with a command the member did not approve prints nothing and is raised" {
    _codex_member_approves "git status"
    : > "$URLS"
    local c
    for c in "git status --short" "git push" "rm -rf build"; do
        rm -f "$TEST_TMPDIR"/.mmry-waiting-*; : > "$URLS"
        run bash -c "printf '%s' '$(_codex_req "$c" "$SUB")' | bash '$HH/formation-waiting.sh'"
        [ -z "$output" ] || { echo "answered for [$c]: $output"; return 1; }
        [ "$(_puts)" -eq 1 ] || { echo "for [$c]"; cat "$URLS"; return 1; }
    done
}

@test "P-07 R1 Codex: a prompt the member did NOT approve (ended by Stop, or cleared by the next prompt) is never an approval" {
    _waiting "$(_codex_req "git status")" >/dev/null
    _stophook "$(_codex_stop turn-77)" || true
    _waiting "$(_codex_req "dotnet test")" >/dev/null
    _check "$(_cc_prompt "go on")" >/dev/null || true
    local c
    for c in "git status" "dotnet test"; do
        rm -f "$TEST_TMPDIR"/.mmry-waiting-*
        run bash -c "printf '%s' '$(_codex_req "$c" "$SUB")' | bash '$HH/formation-waiting.sh'"
        [ -z "$output" ] || { echo "answered for [$c]: $output"; return 1; }
    done
}

@test "P-08 R1 Codex: approvals belong to one session; a session start forgets them" {
    _codex_member_approves "git status"
    ls "$TEST_TMPDIR"/.mmry-approved-"$SID" >/dev/null 2>&1 || { echo "no approval record"; return 1; }
    ! grep -q "git status" "$TEST_TMPDIR"/.mmry-approved-"$SID" || { echo "the command itself was stored"; return 1; }
    _waiting "$(_codex_req "npm test")" >/dev/null
    printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"startup"}' "$SID" \
        | bash "$HH/formation-waiting.sh" --answer "$SID" SessionStart >/dev/null || true
    [ ! -e "$TEST_TMPDIR/.mmry-approved-$SID" ] || { echo "approvals outlived the session start"; return 1; }
}

# ---- R2: the program, never the rest of the command ----------------------------------------------

@test "P-09 R2 Codex: a command with arguments and a path sends the program only" {
    local c want
    while IFS='|' read -r c want; do
        rm -f "$TEST_TMPDIR"/.mmry-waiting-*; : > "$BODIES"
        _waiting "$(_codex_req "$c")" >/dev/null
        [ "$(_program_sent)" = "$want" ] || { echo "for [$c] sent $(_program_sent)"; cat "$BODIES"; return 1; }
        "$JQ_BIN" -e '.toolName == "Bash"' < "$BODIES" >/dev/null || { cat "$BODIES"; return 1; }
    done <<'EOF'
git push origin main --force|git
/usr/bin/git status|git
  dotnet test src/Mnemo.Api.Tests|dotnet
npm run build -- --prod|npm
EOF
    ! grep -q -E 'push|origin|status|src/|--prod|/usr/bin' "$BODIES" || { echo "more than the program was sent"; cat "$BODIES"; return 1; }
}

@test "P-10 R2: a first word that is not a bare name (an assignment, a quote, a planted secret) sends no program, and the secret goes nowhere" {
    local c
    for c in "TOKEN=$PLANTED git push" "\\\"git\\\" status" "\$(curl x)" "C:\\\\tools\\\\git.exe status"; do
        rm -f "$TEST_TMPDIR"/.mmry-waiting-*; : > "$BODIES"
        _waiting "$(_codex_req "$c")" >/dev/null
        [ "$(_puts)" -ge 1 ] || { echo "not raised for [$c]"; return 1; }
        [ "$(_program_sent)" = "<none>" ] || [ "$(_program_sent)" = "git.exe" ] || { echo "for [$c] sent $(_program_sent)"; return 1; }
        ! grep -q "$PLANTED" "$BODIES" || { echo "the secret was sent"; return 1; }
    done
}

@test "P-11 R2 Claude Code: the program comes from the ask record; the Notification sentence never supplies one" {
    _ask "$(_cc_ask Bash "" "npm install left-pad")" || true
    _waiting "$(_notification permission_prompt "Claude needs your permission to use Bash")"
    [ "$(_program_sent)" = "npm" ] || { cat "$BODIES"; return 1; }
    ! grep -q "left-pad" "$BODIES" || { echo "an argument was sent"; return 1; }
    rm -f "$TEST_TMPDIR"/.mmry-waiting-*; : > "$BODIES"
    _waiting "$(_notification permission_prompt "Claude needs your permission to use Bash")"
    [ "$(_program_sent)" = "<none>" ] || { echo "no record, yet sent $(_program_sent)"; return 1; }
}

# ---- Stale flag: (a) timed out, (b) answered No, (c) a built-in safety prompt ---------------------

@test "S-01 (a) a prompt that timed out unanswered clears on the member's next tool call, and the lead is told once" {
    _cc_raise Bash "" >/dev/null
    _held
    _stophook "$(_cc_pre Bash "" "git status")" || true
    _cleared_once
}

@test "S-02 (b) a prompt answered No clears on the asking helper's next tool call; another agent's call does not" {
    _cc_raise Bash "$SUB" >/dev/null
    _stophook "$(_cc_pre Bash "" "git status")" || true
    _stophook "$(_cc_pre Bash "$BG" "git status")" || true
    _held
    _stophook "$(_cc_pre Read "$SUB" "x")" || true
    _cleared_once
}

@test "S-03 (c) a built-in safety prompt (no PermissionRequest, so no ask record) clears on the member's next tool call" {
    _waiting "$(_notification permission_prompt "Claude needs your permission to use Bash")"
    [ "$(_puts)" -eq 1 ]
    _held
    _stophook "$(_cc_pre Bash "" "ls")" || true
    _cleared_once
}

@test "S-04 Codex: a refused prompt clears on the asking agent's next tool call, also through formation-check" {
    _waiting "$(_codex_req "git push")" >/dev/null
    _held
    _stophook "$(_codex_pre Bash "$SUB" "ls")" || true
    _held
    _stophook "$(_codex_pre Bash "" "ls")" || true
    _cleared_once
}

@test "S-05 the PreToolUse hook is registered on both hosts, gated on a waiting marker, and prints nothing without one" {
    "$JQ_BIN" -e '[.hooks.PreToolUse[].hooks[].command] | any(test("formation-waiting.sh") and test("--answer-hook") and test("mmry-waiting-gate"))' \
        < "$PLUGIN_ROOT/hooks/hooks.json" >/dev/null || { echo "Claude Code: no gated PreToolUse"; return 1; }
    "$JQ_BIN" -e '[.hooks.PreToolUse[].hooks[] | select((.command // "") | test("formation-waiting --answer-hook"))] | length == 1' \
        < "$PLUGIN_ROOT/hooks/codex-hooks.json" >/dev/null || { echo "Codex: no gated PreToolUse"; return 1; }
    run bash -c "printf '%s' '$(_cc_pre Bash "" "ls")' | bash '$HH/formation-waiting.sh' --answer-hook"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(_deletes)" -eq 0 ]
}
