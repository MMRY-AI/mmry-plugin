#!/usr/bin/env bats
# formation-waiting-approvals.bats - #34519 (DD-206 in MMRY-AI/mmry): a member's helper agents keep
# working on the commands the member already allows, a prompt that still stops a member names the
# program it waits to run, and a prompt that ended without being approved clears the waiting flag.
#
# MEASURED BEFORE BUILT (R:/Intranet/ClaudeAI/plans/MMRY/v1.38/34519/measure/result.md and the Seat A
# probes in R:/Intranet/ClaudeAI/plans/MMRY/v1.38/34519/seatA/, 2026-11-23):
#   Claude Code 2.1.330  helpers inherit settings-file allow rules. A background helper's refused
#                        request fires PermissionRequest (agent_id present) and then that helper's
#                        SubagentStop, and no Notification and no permission_denials entry: silent.
#                        A refused request (nobody answered) gives PermissionRequest and then NO event
#                        of its own: no PostToolUse, no PostToolUseFailure, no PermissionDenied. The
#                        agent's next tool call (PreToolUse, PostToolUse) or its Stop follows, and the
#                        refused call's tool_result is in the transcript by then. A broad rm is the same.
#   Codex 0.171.0        a sub-agent's PermissionRequest carries agent_id; an approval "for session" in
#                        the main thread is not passed to sub-agents; a PermissionRequest hook's allow
#                        answer IS honoured in app-server mode, for the main thread and a sub-agent.
#
# WHAT IS PINNED
#   A-01..04  Claude Code: a helper's request is reported as waiting from the PermissionRequest hook,
#             which prints nothing; the same prompt's later Notification makes no second call; the
#             helper's end clears it; the main thread's request still waits for the Notification.
#   C-01..06  Codex: allow ONLY for a request with agent_id repeating, byte for byte, a command the
#             same member approved in this session (its asked call ran); never without agent_id,
#             never for another command, never for a refused request, never on Claude Code, and the
#             approvals file holds digests only.
#   P-01..05  the program: the command's first word with any folder removed, under the tool name's
#             rule; never the rest of the command; none for an assignment, a quoted word or an MCP tool.
#   S-01..04  the stale flag: a prompt that timed out or was answered No, and a refused broad rm,
#             clear on the member's next tool call (measured baseline: about 9 minutes, at its Stop);
#             a call still open beside a parallel call does not clear.
#   S-05..06  fix round 1 (QA 34519, Seat E): the clear stays bounded in a long session (5 MB, 50 earlier
#             calls), and only the asked call's own result ends the wait.
#   C-07..10  fix round 1: an approval holds for the same call in the same folder only (DD-206: the
#             digest covers the working folder and the whole input); a helper's own run and a Claude
#             Code run are never recorded as an approval.

load '../helpers/test-helper'
load '../helpers/formation-waiting-helpers.sh'

ALLOW='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
JQ_BIN="$(command -v jq)"

_program_sent() { "$JQ_BIN" -r '.programName // "<none>"' < "$BODIES" | tail -1; }
_approved_file() { printf '%s' "$TEST_TMPDIR/.mmry-approved-$SID"; }

# A transcript holding one main-thread call of Bash with this command, and, when $3 is given, its result.
_tp_call() { # $1 path, $2 command, $3 "error" for a refused call's result, "ok" for a run, empty for none
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_ask","name":"Bash","input":{"command":"%s"}}]}}\n' "$2" > "$1"
    case "${3:-}" in
        error) printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_ask","is_error":true,"content":"The user did not approve"}]}}\n' >> "$1" ;;
        ok)    printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_ask","content":"done"}]}}\n' >> "$1" ;;
    esac
}
# Claude Code's PermissionRequest and PostToolUse naming a real transcript.
_cc_ask_tp() { # $1 command, $2 transcript
    printf '{"session_id":"%s","transcript_path":"%s","cwd":"/x","prompt_id":"p-1","permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"%s"},"permission_suggestions":[]}' "$SID" "$2" "$1"
}
_cc_post_tp() { # $1 command of the call that ran, $2 transcript
    printf '{"session_id":"%s","transcript_path":"%s","cwd":"/x","prompt_id":"p-1","permission_mode":"default","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":"ok","tool_use_id":"toolu_next","duration_ms":5}' "$SID" "$2" "$1"
}

# ---- R1, Claude Code ------------------------------------------------------------------------------

@test "A-01 34519 R1: a helper's request is reported as waiting from the PermissionRequest hook, which prints nothing" {
    run _ask "$(_cc_ask Bash "$BG" "touch probe-bg.txt")"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "printed (Claude Code reads it as a decision): $output"; return 1; }
    [ "$(_puts)" -eq 1 ] || { echo "a background helper's request was silent"; cat "$URLS"; return 1; }
    "$JQ_BIN" -e '.toolName == "Bash" and .programName == "touch"' < "$BODIES" >/dev/null || { cat "$BODIES"; return 1; }
    grep -q "^asker $BG\$" "$(_marker)" || { cat "$(_marker)"; return 1; }
}

@test "A-02 34519 R1: the same prompt's Notification after a helper's ask makes no second call" {
    _cc_raise Bash "$SUB"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
}

@test "A-03 34519 R1 and R2: a background helper's refused request clears when the helper stops (measured: SubagentStop 1.5 s later)" {
    _ask "$(_cc_ask Bash "$BG" "touch probe-bg.txt")" || true
    _stophook "$(_cc_subagent_stop "$BG")" || true
    _cleared_once
}

@test "A-04 34519 R1: the main thread's own request is not raised from the PermissionRequest hook; its Notification raises it" {
    run _ask "$(_cc_ask Bash "" "touch x")"
    [ -z "$output" ]
    [ "$(_puts)" -eq 0 ] || { cat "$URLS"; return 1; }
    _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash')"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
}

# ---- R1, Codex (DD-206) ---------------------------------------------------------------------------

# The member approves `git push` in its own thread: the asked call raises, then runs (its PostToolUse).
# The JSON is built in a variable first: bash 3.2 (macOS /bin/bash) mis-reads \" inside "$( )", which
# sent an empty or broken payload on the macOS runner (C-01, C-06, P-01, P-03 failed there, fix round 1).
_codex_member_approves() { # $1 command
    local ask="{\"command\":\"$1\",\"description\":\"d\"}" post="{\"command\":\"$1\"}"
    _waiting "$(_codex_ask Bash "" "$ask")"
    _check "$(_codex_post Bash "" "$post")" || true
}

@test "C-01 34519 R1 DD-206: Codex allows a helper repeating a command its member approved in this session, and raises nothing for it" {
    _codex_member_approves "git push origin main"
    _cleared_once
    : > "$URLS"; : > "$BODIES"
    run _waiting "$(_codex_ask Bash thread-sub-2 '{"command":"git push origin main","description":"d"}')"
    [ "$status" -eq 0 ]
    [ "$output" = "$ALLOW" ] || { echo "answered: [$output]"; return 1; }
    [ "$(_puts)" -eq 0 ] || { echo "an allowed request was reported as waiting"; cat "$URLS"; return 1; }
}

@test "C-02 34519 DD-206 mutant guard: without agent_id (the member itself) nothing is printed, even for an approved command" {
    _codex_member_approves "git push origin main"
    rm -f "$TEST_TMPDIR"/.mmry-waiting-*
    run _waiting "$(_codex_ask Bash "" '{"command":"git push origin main","description":"d"}')"
    [ -z "$output" ] || { echo "the member's own prompt was answered: $output"; return 1; }
}

@test "C-03 34519 DD-206 mutant guard: a helper running another command, or one never approved, prints nothing and is raised" {
    _codex_member_approves "git push origin main"
    : > "$URLS"
    run _waiting "$(_codex_ask Bash thread-sub-2 '{"command":"git push origin main --force","description":"d"}')"
    [ -z "$output" ] || { echo "allowed a command the member never approved: $output"; return 1; }
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    rm -f "$(_approved_file)" "$TEST_TMPDIR"/.mmry-waiting-*
    run _waiting "$(_codex_ask Bash thread-sub-2 '{"command":"git push origin main","description":"d"}')"
    [ -z "$output" ] || { echo "allowed with no approval recorded: $output"; return 1; }
}

@test "C-04 34519 DD-206: a request the member refused (its turn ended with no run) is never recorded as approved" {
    _waiting "$(_codex_ask Bash "" '{"command":"git push origin main","description":"d"}')"
    _stophook "$(_codex_stop turn-77)" || true
    _cleared_once
    run _waiting "$(_codex_ask Bash thread-sub-2 '{"command":"git push origin main","description":"d"}')"
    [ -z "$output" ] || { echo "a refused command was allowed for a helper: $output"; return 1; }
}

@test "C-05 34519 DD-206: Claude Code never answers allow, even with an approval recorded" {
    _codex_member_approves "git push origin main"
    run _ask "$(_cc_ask Bash "$SUB" "git push origin main")"
    [ -z "$output" ] || { echo "Claude Code was answered: $output"; return 1; }
}

@test "C-06 34519 DD-206: the approvals file holds the tool and a digest only, and a session start forgets it" {
    _codex_member_approves "git push https://$PLANTED@host main"
    [ -f "$(_approved_file)" ] || { echo "no approval recorded"; return 1; }
    ! grep -q "$PLANTED" "$(_approved_file)" || { echo "the command was stored"; return 1; }
    ! grep -q "push" "$(_approved_file)" || { echo "the command was stored"; return 1; }
    grep -Eq '^Bash [0-9a-f]{64}$' "$(_approved_file)" || { cat "$(_approved_file)"; return 1; }
    _check '{"session_id":"'"$SID"'","hook_event_name":"SessionStart","source":"startup"}' || true
    [ ! -f "$(_approved_file)" ] || { echo "a session start kept the approvals"; return 1; }
}

# ---- R2, the program ------------------------------------------------------------------------------

@test "P-01 34519 R2: Codex sends the program only: the first word, never the arguments" {
    local ask="{\"command\":\"git push https://$PLANTED@host main\",\"description\":\"d\"}"
    _waiting "$(_codex_ask Bash "" "$ask")"
    [ "$(_program_sent)" = "git" ] || { cat "$BODIES"; return 1; }
    ! grep -q "$PLANTED" "$BODIES" || { echo "an argument was sent"; return 1; }
    ! grep -q "push" "$BODIES" || { echo "an argument was sent"; return 1; }
}

@test "P-02 34519 R2: a program given with a folder is sent without the folder" {
    _waiting "$(_codex_ask Bash "" '{"command":"/usr/local/bin/npm ci","description":"d"}')"
    [ "$(_program_sent)" = "npm" ] || { cat "$BODIES"; return 1; }
    ! grep -q "usr" "$BODIES" || { echo "a path was sent"; return 1; }
}

@test "P-03 34519 R2: a first word that is not a bare name (an assignment, a quoted word) sends no program" {
    local c ask
    for c in 'TOKEN=abc git push' '\"my tool\" run' '$(whoami)'; do
        rm -f "$TEST_TMPDIR"/.mmry-waiting-*; : > "$BODIES"
        ask="{\"command\":\"$c\",\"description\":\"d\"}"
        _waiting "$(_codex_ask Bash "" "$ask")"
        [ "$(_program_sent)" = "<none>" ] || { echo "for [$c]"; cat "$BODIES"; return 1; }
        "$JQ_BIN" -e '.toolName == "Bash"' < "$BODIES" >/dev/null || { cat "$BODIES"; return 1; }
    done
}

@test "P-04 34519 R2: an MCP tool's arguments never give a program" {
    _waiting "$(_codex_ask mcp__probe__run "" '{"command":"git push"}')"
    [ "$(_program_sent)" = "<none>" ] || { cat "$BODIES"; return 1; }
}

@test "P-05 34519 R2: Claude Code takes the program from the ask record, and only for the tool it names" {
    _cc_raise Bash "" "Bash"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    [ "$(_program_sent)" = "ls" ] || { cat "$BODIES"; return 1; }
    grep -Eq '^program ls$' "$TEST_TMPDIR"/.mmry-waiting-* 2>/dev/null && { echo "the marker keeps the program"; return 1; }
    rm -f "$TEST_TMPDIR"/.mmry-waiting-*; : > "$BODIES"
    # No ask record: the Notification alone has no command, so no program.
    _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash')"
    [ "$(_program_sent)" = "<none>" ] || { cat "$BODIES"; return 1; }
}

# ---- R2, the stale flag (live evidence: cmo-mmry's flag stayed set from 11:58Z to 12:07Z) ----------

@test "S-01 34519 (a) and (b): a prompt that timed out or was answered No clears on the member's next tool call, not at its Stop" {
    local tp="$TEST_TMPDIR/transcript.jsonl"
    _tp_call "$tp" "rm -rf build"
    _ask "$(_cc_ask_tp "rm -rf build" "$tp")" || true
    _waiting "$(_notification_tp 'Claude needs your permission to use Bash' "$tp")"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    # Refused (timed out, or No): Claude Code writes the call's error result and the member goes on.
    _tp_call "$tp" "rm -rf build" error
    _check "$(_cc_post_tp "ls -la" "$tp")" || true
    _cleared_once
}

@test "S-02 34519 guard: a parallel call finishing while the asked call has no result yet clears nothing" {
    local tp="$TEST_TMPDIR/transcript.jsonl"
    _tp_call "$tp" "rm -rf build"
    _ask "$(_cc_ask_tp "rm -rf build" "$tp")" || true
    _waiting "$(_notification_tp 'Claude needs your permission to use Bash' "$tp")"
    _check "$(_cc_post_tp "ls -la" "$tp")" || true
    _held
}

@test "S-03 34519 (c): a refused broad rm clears on the member's next tool call, and on its Stop (measured: Stop follows)" {
    local tp="$TEST_TMPDIR/transcript.jsonl"
    _tp_call "$tp" "rm -rf ./junk/*"
    _ask "$(_cc_ask_tp "rm -rf ./junk/*" "$tp")" || true
    _waiting "$(_notification_tp 'Claude needs your permission to use Bash' "$tp")"
    _tp_call "$tp" "rm -rf ./junk/*" error
    _check "$(_cc_post_tp "git status" "$tp")" || true
    _cleared_once
    : > "$URLS"; : > "$NOTICES"
    _ask "$(_cc_ask_tp "rm -rf ./junk/*" "$tp")" || true
    _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash')"
    _check "$(_cc_stop '[]')" || true
    _cleared_once
}

@test "S-04 34519: the transcript is read as JSON: a later call's input naming the asked command does not end it" {
    local tp="$TEST_TMPDIR/transcript.jsonl"
    _tp_call "$tp" "rm -rf build"
    _ask "$(_cc_ask_tp "rm -rf build" "$tp")" || true
    _waiting "$(_notification_tp 'Claude needs your permission to use Bash' "$tp")"
    printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"tool_result toolu_ask is_error"}]}}\n' >> "$tp"
    _check "$(_cc_post_tp "echo toolu_ask" "$tp")" || true
    _held
}

# ---- fix round 1 (QA 34519, Seat E): the clear's cost, and the asked call only ------------------------

# A member session's transcript: $2 earlier Bash calls, each with a result of $3 bytes, then the asked call
# (toolu_ask, "rm -rf build") with no result yet.
_tp_long() { # $1 path, $2 earlier calls, $3 bytes in each earlier call's result
    local tp="$1" n="$2" pad i
    pad="$(printf '%0*d' "$3" 0)"
    : > "$tp"
    for ((i = 1; i <= n; i++)); do
        printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_e%s","name":"Bash","input":{"command":"echo call-%s"}}]}}\n' "$i" "$i" >> "$tp"
        printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_e%s","content":"%s"}]}}\n' "$i" "$pad" >> "$tp"
    done
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_ask","name":"Bash","input":{"command":"rm -rf build"}}]}}\n' >> "$tp"
}
# The whole next-call check (formation-check.sh, the synchronous PostToolUse hook, timeout 15 s) after the
# asked call was refused, in a session of $1 earlier calls of $2 bytes each. Sets CLEAR_S (whole seconds:
# SECONDS, because bash 3.2 has no finer clock, structural/bash32-portability.bats) and checks it cleared.
_timed_clear() {
    local tp="$TEST_TMPDIR/transcript.jsonl" t0 t1
    : > "$URLS"; : > "$NOTICES"; rm -f "$TEST_TMPDIR"/.mmry-waiting-* "$TEST_TMPDIR"/.mmry-asking-*
    _tp_long "$tp" "$1" "$2"
    _ask "$(_cc_ask_tp "rm -rf build" "$tp")" || true
    _waiting "$(_notification_tp 'Claude needs your permission to use Bash' "$tp")"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_ask","is_error":true,"content":"The user did not approve"}]}}\n' >> "$tp"
    t0=$SECONDS
    _check "$(_cc_post_tp "ls -la" "$tp")" || true
    t1=$SECONDS
    CLEAR_S=$(( t1 - t0 ))
    _cleared_once
}

# BOUND: 7 whole seconds (under 8 s) for the whole check at every size, about half the hook's 15 s limit. The whole check (not the
# clear alone) is what the limit applies to, and its fixed cost, with no transcript work at all, measured
# 2.2 to 4.0 s on the build PC under load; half the limit leaves that room on a slow runner while the old
# cost at 5 MB (37.9 s on the build PC, 50.8 s measured by QA) fails it five times over. The bound is the
# same at every size: the clear reads the transcript once, by the asked call's id, whatever its length.
@test "S-05 34519 fix 1: the next-call clear stays well inside the 15 s hook limit at one call, 1 MB and 5 MB (50 earlier calls)" {
    local size calls bytes over=""
    for size in "0 0" "10 100000" "50 100000"; do
        calls="${size% *}" bytes="${size#* }"
        _timed_clear "$calls" "$bytes" || { echo "not cleared at $calls calls"; return 1; }
        echo "# S-05 $calls earlier calls of $bytes bytes ($(wc -c < "$TEST_TMPDIR/transcript.jsonl" | tr -d ' ') bytes): whole check ${CLEAR_S} s" >&3
        [ "$CLEAR_S" -le 7 ] || over+=" ${CLEAR_S} s at $calls earlier calls of $bytes bytes;"
    done
    [ -z "$over" ] || { echo "the clear took$over"; return 1; }
}

@test "S-06 34519 fix 1 mutant guard: only the asked call's own result ends the wait, not an earlier or a parallel call of the same tool" {
    local tp="$TEST_TMPDIR/transcript.jsonl"
    : > "$tp"
    # An earlier call of the same tool with its result (whose text names the asked call), the asked call,
    # and a parallel call of the same tool, both still without a result when the prompt is raised.
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_e1","name":"Bash","input":{"command":"echo one"}}]}}\n' >> "$tp"
    printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_e1","content":"saw toolu_ask"}]}}\n' >> "$tp"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_ask","name":"Bash","input":{"command":"rm -rf build"}},{"type":"tool_use","id":"toolu_par","name":"Bash","input":{"command":"sleep 1"}}]}}\n' >> "$tp"
    _ask "$(_cc_ask_tp "rm -rf build" "$tp")" || true
    _waiting "$(_notification_tp 'Claude needs your permission to use Bash' "$tp")"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    # The parallel call finishes (its result names the asked call too); the asked call is still open.
    printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_par","content":"toolu_ask"}]}}\n' >> "$tp"
    _check "$(_cc_post_tp "sleep 1" "$tp")" || true
    _held
    # Then the asked call's own result: the next call clears.
    printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_ask","is_error":true,"content":"The user did not approve"}]}}\n' >> "$tp"
    _check "$(_cc_post_tp "ls -la" "$tp")" || true
    _cleared_once
}

# Codex 0.171.0's PermissionRequest as measured (measure/logs/codex): the payload carries cwd, and a shell
# command's tool_input holds command only.
_codex_ask_cwd() { # $1 agent_id (optional), $2 cwd, $3 tool_name, $4 tool_input JSON
    printf '{"session_id":"%s","turn_id":"turn-77","transcript_path":null,"cwd":"%s","hook_event_name":"PermissionRequest","model":"gpt-5","permission_mode":"default","tool_name":"%s","tool_input":%s%s}' "$SID" "$2" "$3" "$4" "$(_agent_part "${1:-}")"
}

@test "C-07 34519 fix 1 DD-206: the same command in another working folder is not allowed; in the same folder it is" {
    _waiting "$(_codex_ask_cwd "" /repo/a Bash '{"command":"git push origin main"}')"
    _check "$(_codex_post Bash "" '{"command":"git push origin main"}')" || true
    _cleared_once
    : > "$URLS"
    run _waiting "$(_codex_ask_cwd thread-sub-2 /repo/b Bash '{"command":"git push origin main"}')"
    [ -z "$output" ] || { echo "allowed in a folder the member never approved it in: $output"; return 1; }
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    rm -f "$TEST_TMPDIR"/.mmry-waiting-*
    run _waiting "$(_codex_ask_cwd thread-sub-2 /repo/a Bash '{"command":"git push origin main"}')"
    [ "$output" = "$ALLOW" ] || { echo "the same call in the same folder: [$output]"; return 1; }
}

@test "C-08 34519 fix 1 DD-206: an MCP call with another sibling argument is not allowed; the same input is" {
    _waiting "$(_codex_ask_cwd "" /repo/a mcp__probe__deploy '{"command":"deploy","env":"staging"}')"
    _check "$(_codex_post mcp__probe__deploy "" '{"command":"deploy","env":"staging"}')" || true
    _cleared_once
    run _waiting "$(_codex_ask_cwd thread-sub-2 /repo/a mcp__probe__deploy '{"command":"deploy","env":"production"}')"
    [ -z "$output" ] || { echo "allowed another argument: $output"; return 1; }
    rm -f "$TEST_TMPDIR"/.mmry-waiting-*
    run _waiting "$(_codex_ask_cwd thread-sub-2 /repo/a mcp__probe__deploy '{"command":"deploy","env":"staging"}')"
    [ "$output" = "$ALLOW" ] || { echo "the same input: [$output]"; return 1; }
}

@test "C-09 34519 fix 1 mutant guard (M-a): a helper's own approved run is never recorded as the member's approval" {
    _waiting "$(_codex_ask_cwd thread-sub-1 /repo/a Bash '{"command":"git push origin main"}')"
    _check "$(_codex_post Bash thread-sub-1 '{"command":"git push origin main"}')" || true
    _cleared_once
    [ ! -f "$(_approved_file)" ] || { echo "a helper's run was recorded:"; cat "$(_approved_file)"; return 1; }
    run _waiting "$(_codex_ask_cwd thread-sub-2 /repo/a Bash '{"command":"git push origin main"}')"
    [ -z "$output" ] || { echo "another helper was allowed on a helper's run: $output"; return 1; }
}

@test "C-10 34519 fix 1 mutant guard (M-b): a Claude Code member's approved run is never recorded as an approval" {
    _ask "$(_cc_ask Bash "" "git push origin main")" || true
    _waiting "$(_notification permission_prompt 'Claude needs your permission to use Bash')"
    _check "$(_cc_post Bash "" '{"command":"git push origin main"}')" || true
    _cleared_once
    [ ! -f "$(_approved_file)" ] || { echo "Claude Code recorded an approval:"; cat "$(_approved_file)"; return 1; }
}
