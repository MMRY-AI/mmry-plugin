#!/usr/bin/env bats
# formation-agent-scoped.bats - a formation message is shown to the session it is addressed to, not
# consumed by an agent that session dispatched (#31991).
#
# THE DEFECT. Claude Code runs the plugin's hooks for a dispatched agent's tool calls too, and it
# gives them the PARENT's session_id: the agent shares its parent's session, its Bash shell even
# inherits the parent's CLAUDE_CODE_SESSION_ID. So formation-check.sh, keyed by session id, took a
# dispatched agent's PostToolUse for the lead's own, printed the lead's pending messages into the
# agent's context and recorded them as seen. The agent cannot act on them and never reports them,
# and the lead, whose messages they were, never saw them.
#
# WHAT TELLS THEM APART, MEASURED (Claude Code 2.1.306, Windows 11, 2026-10-21; raw payloads in the
# docs/evidence/31991). A probe hook registered on every event, in a session that dispatched one agent:
#
#   parent's own events            session_id=S, no agent_id, no agent_type
#   dispatched agent's PostToolUse session_id=S, agent_id="add22966ec6f3f9bf", agent_type="general-purpose"
#   dispatched agent's SubagentStop session_id=S, agent_id, agent_type
#
# and in a session started with --agent (how a formation lead usually runs):
#
#   parent's own events            session_id=S, agent_type="probelead", NO agent_id
#
# So agent_type is NOT the test: it is present on a --agent lead's own events, and skipping on it
# would silence the lead itself. agent_id is the test. Codex is the same shape: codex-rs
# hooks/src/schema.rs serialises agent_id/agent_type only for a thread-spawned subagent
# (skip_serializing_if = "Option::is_none"), and its docs say subagent hooks carry the parent
# session id.
#
# Every test here drives the handler the way the host does: a real payload on stdin naming the event,
# and NO MMRY_FORMATION_MODE, which is a seam that once hid a defect of this kind (#31196 QA round 2).

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    # The developer's own session must never be the one under test: a dispatched agent's shell
    # inherits its parent's id, which is this defect, and must not become this suite's.
    unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID MMRY_FORMATION_MODE MMRY_HOST
    export CLAUDE_SESSION_ID="bats-agentscoped-$$"
    SID="$CLAUDE_SESSION_ID"
    bash "${HANDLERS}/formation-state.sh" clear "$SID" || true
    rm -rf "${TMPDIR}/.mmry-formation-cs-${SID}" "${TMPDIR}/.mmry-formation-poll-${SID}"

    # One DIRECTED message (it carries a recipient and an id), because a directed line is the one
    # whose seen-marking reaches the service: its id is reported as read on the next poll.
    PENDING='[{"transmissionID":901,"recipientMemberID":7,"senderMemberID":3,"senderName":"Lead","senderRole":"Lead","senderSessionID":null,"senderUserID":5,"content":"Directed: please rebase onto develop","sentDate":"2026-10-21T12:00:00"}]'

    CURL_LOG="${BATS_TEST_TMPDIR}/curl-calls.log"
    : > "$CURL_LOG"
    FAKE_BIN="$(_fake_server_dir)"
}

teardown() {
    bash "${HANDLERS}/formation-state.sh" clear "$SID" || true
}

# A curl that stands in for the service, in bash, with no network. It records every request URL, and
# it answers the way the service does: messages newer than `since`. The state record carries no
# `since` until something has been marked seen, and after that the one message here is not newer
# than it, so a repeated delivery could only come from the plugin and never from this fixture.
_fake_server_dir() {
    local dir="${BATS_TEST_TMPDIR}/fake-server"
    mkdir -p "$dir"
    cat > "${dir}/curl" <<'FAKECURL'
#!/usr/bin/env bash
out=""; prev=""; url=""
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    [[ "$arg" == http* ]] && url="$arg"
    prev="$arg"
done
printf '%s\n' "$url" >> "${MMRY_TEST_CURL_LOG:?}"
body="${FAKE_BODY:-[]}"
[[ "$url" == *"since="* ]] && body='[]'
[[ -n "$out" ]] && printf '%s' "$body" > "$out"
printf '200'
exit 0
FAKECURL
    chmod +x "${dir}/curl"
    printf '%s' "$dir"
}

# The payloads, in the shape measured from Claude Code. $1 event, $2 "agent" | "lead" | "parent".
_payload() {
    local event="$1" who="$2"
    case "$who" in
        agent)  printf '{"session_id":"%s","hook_event_name":"%s","agent_id":"add22966ec6f3f9bf","agent_type":"general-purpose","tool_name":"Bash","tool_input":{"command":"echo probe-sub"}}' "$SID" "$event" ;;
        lead)   printf '{"session_id":"%s","hook_event_name":"%s","agent_type":"pm-engineering-mmry","tool_name":"Bash","tool_input":{"command":"echo probe-lead"}}' "$SID" "$event" ;;
        parent) printf '{"session_id":"%s","hook_event_name":"%s","tool_name":"Bash","tool_input":{"command":"echo probe-main"}}' "$SID" "$event" ;;
    esac
}

# Run formation-check.sh with a payload on stdin. $1 event, $2 who, $3 optional host ("codex").
_run_check() {
    local event="$1" who="$2" host="${3:-}"
    _payload "$event" "$who" > "${BATS_TEST_TMPDIR}/payload.json"
    rm -rf "${TMPDIR}/.mmry-formation-cs-${SID}" "${TMPDIR}/.mmry-formation-poll-${SID}"
    local hostenv="-u MMRY_HOST"
    [[ -n "$host" ]] && hostenv="MMRY_HOST=${host}"
    # stderr is captured on its own: on Claude Code the tool and idle routes deliver there.
    run bash -c "env ${hostenv} PATH='${FAKE_BIN}:${PATH}' MMRY_TEST_CURL_LOG='${CURL_LOG}' \
            FAKE_BODY='${PENDING}' \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL='http://fake.invalid' \
            MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
            bash '${HANDLERS}/formation-check.sh' < '${BATS_TEST_TMPDIR}/payload.json' 2>&1"
}

_state() { cat "${TMPDIR}/.mmry-formation-${SID}" 2>/dev/null || true; }

_join() {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$SID"
    STATE_BEFORE="$(_state)"
    [ "$STATE_BEFORE" = "4242" ] || { echo "fixture: unexpected join record: ${STATE_BEFORE}"; return 1; }
}

# Unread means all three: nothing printed, nothing written to the record, nothing told the service.
_assert_untouched() {
    local label="$1"
    [ "$status" -eq 0 ] || { echo "${label}: exit ${status}, expected 0: ${output}"; return 1; }
    [ -z "$output" ] || { echo "${label}: printed into the dispatched agent: ${output}"; return 1; }
    [ "$(_state)" = "$STATE_BEFORE" ] || {
        echo "${label}: the parent's record changed, so a message was marked seen: [$(_state)]"
        return 1
    }
    [ ! -s "$CURL_LOG" ] || {
        echo "${label}: the service was asked $(wc -l < "$CURL_LOG") time(s); a poll moves the read position: $(cat "$CURL_LOG")"
        return 1
    }
}

# ---------------------------------------------------------------------------------------------
# Ticket test case 1: a hook payload from a dispatched agent leaves the parent's pending messages
# unread and prints nothing.
# ---------------------------------------------------------------------------------------------

@test "tc1: a dispatched agent's PostToolUse leaves the parent's pending message unread and prints nothing" {
    _join
    _run_check PostToolUse agent
    _assert_untouched "dispatched agent PostToolUse"
}

@test "tc1: a dispatched agent is skipped on every event the handler serves, not only PostToolUse" {
    # The measured agent events are PostToolUse and SubagentStop; the rest are covered so a future
    # client that runs more of them inside an agent cannot reopen the defect. Stop is the idle watch:
    # it must not start a watch, and it must not leave a poller lock behind for the parent's own Stop.
    _join
    local event
    for event in PostToolUse SubagentStop Stop UserPromptSubmit SessionStart; do
        : > "$CURL_LOG"
        _run_check "$event" agent
        _assert_untouched "dispatched agent ${event}"
        [ ! -e "${TMPDIR}/.mmry-formation-poll-${SID}" ] || { echo "${event}: left a poller lock"; return 1; }
    done
}

@test "tc1 codex: a Codex sub-agent's PostToolUse leaves the parent's pending message unread" {
    # Codex delivers through additionalContext on stdout with exit 0, so on the defect the agent's
    # call would still exit 0: the empty output and the untouched record are what tell them apart.
    _join
    _run_check PostToolUse agent codex
    _assert_untouched "codex sub-agent PostToolUse"
}

# ---------------------------------------------------------------------------------------------
# Ticket test case 2: the parent's own hook payload still delivers and marks seen exactly once.
# ---------------------------------------------------------------------------------------------

@test "tc2: the parent's own PostToolUse delivers the message and marks it seen exactly once" {
    _join

    # First call: shown, and marked. The record now holds the message's time as last seen and its id
    # as owed to the service.
    _run_check PostToolUse parent
    [ "$status" -eq 2 ] || { echo "parent PostToolUse: exit ${status}, expected 2: ${output}"; return 1; }
    [[ "$output" == *"Directed: please rebase onto develop"* ]] || { echo "not delivered: ${output}"; return 1; }
    [ "$(grep -c 'please rebase' <<< "$output")" -eq 1 ] || { echo "shown more than once in one call: ${output}"; return 1; }
    [ "$(_state)" = $'4242\n2026-10-21T12:00:00\n901' ] || { echo "not marked seen as expected: [$(_state)]"; return 1; }

    # Second call: nothing new to show, and the owed id is reported to the service exactly once.
    : > "$CURL_LOG"
    _run_check PostToolUse parent
    [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "the parent was shown it again: ${status} ${output}"; return 1; }
    [ "$(grep -c 'shownIds=901' "$CURL_LOG")" -eq 1 ] || { echo "read report not sent once: $(cat "$CURL_LOG")"; return 1; }
    [ "$(_state)" = $'4242\n2026-10-21T12:00:00' ] || { echo "owed id not cleared: [$(_state)]"; return 1; }

    # Third call: the report is not repeated.
    : > "$CURL_LOG"
    _run_check PostToolUse parent
    [ -z "$output" ]
    ! grep -q 'shownIds=' "$CURL_LOG" || { echo "read reported twice: $(cat "$CURL_LOG")"; return 1; }
}

@test "tc2: the message a dispatched agent skipped is the one the parent is then shown, once" {
    # The ticket's scenario end to end: a lead with an agent running, a directed message sent
    # mid-run. The agent's tool call comes first and must leave it; the lead's next one gets it.
    _join
    _run_check PostToolUse agent
    _assert_untouched "dispatched agent, mid-run"

    _run_check PostToolUse parent
    [ "$status" -eq 2 ] || { echo "the lead did not get the message the agent left: ${status} ${output}"; return 1; }
    [[ "$output" == *"Directed: please rebase onto develop"* ]]
    [ "$(_state)" = $'4242\n2026-10-21T12:00:00\n901' ]
}

# ---------------------------------------------------------------------------------------------
# Requirement 3: delivery to the session itself on every existing path. Both kinds of parent: a
# plain session (no agent fields) and a --agent lead (agent_type, no agent_id).
# ---------------------------------------------------------------------------------------------

@test "req3: the session itself still receives on every path, plain or started with --agent" {
    local who event expect
    for who in parent lead; do
        for event in PostToolUse Stop UserPromptSubmit SessionStart; do
            bash "${HANDLERS}/formation-state.sh" clear "$SID" || true
            _join
            : > "$CURL_LOG"
            _run_check "$event" "$who"
            case "$event" in
                PostToolUse|Stop) expect=2 ;;
                *)                expect=0 ;;
            esac
            [ "$status" -eq "$expect" ] || { echo "${who} ${event}: exit ${status}, expected ${expect}: ${output}"; return 1; }
            [[ "$output" == *"Directed: please rebase onto develop"* ]] || { echo "${who} ${event}: not delivered: ${output}"; return 1; }
            if [ "$expect" -eq 0 ]; then
                [[ "$output" == *"\"hookEventName\": \"${event}\""* ]] || { echo "${who} ${event}: wrong contract: ${output}"; return 1; }
            fi
            [ "$(_state)" = $'4242\n2026-10-21T12:00:00\n901' ] || { echo "${who} ${event}: not marked seen: [$(_state)]"; return 1; }
        done
    done
}

@test "req3 codex: a Codex session's own PostToolUse still delivers as additionalContext" {
    _join
    _run_check PostToolUse parent codex
    [ "$status" -eq 0 ]
    [[ "$output" == *'"hookEventName":"PostToolUse"'* ]] || { echo "wrong contract: ${output}"; return 1; }
    [[ "$output" == *"please rebase onto develop"* ]]
    [ "$(_state)" = $'4242\n2026-10-21T12:00:00\n901' ]
}
