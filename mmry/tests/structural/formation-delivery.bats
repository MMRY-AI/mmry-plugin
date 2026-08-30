#!/usr/bin/env bats
# Formation in-session delivery (#31012).
#
# The governing property is that this hook runs after EVERY tool call in EVERY session, so its
# failure modes matter more than its happy path. These tests are mostly about silence: the hook
# must never speak unless there is something to say, and must never fail a session.

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export CLAUDE_SESSION_ID="bats-formation-$$"
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
}

teardown() {
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
}

@test "state: set then get returns the formation id" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    run bash "${HANDLERS}/formation-state.sh" get "$CLAUDE_SESSION_ID"
    [ "$status" -eq 0 ]
    [[ "$output" == 4242* ]]
}

@test "state: a non-numeric formation id is refused" {
    run bash "${HANDLERS}/formation-state.sh" set "42; rm -rf /" "$CLAUDE_SESSION_ID"
    [ "$status" -ne 0 ]
    run bash "${HANDLERS}/formation-state.sh" get "$CLAUDE_SESSION_ID"
    [ -z "$output" ]
}

@test "state: seen records the newest timestamp alongside the id" {
    bash "${HANDLERS}/formation-state.sh" set 7 "$CLAUDE_SESSION_ID"
    bash "${HANDLERS}/formation-state.sh" seen "2026-08-29T10:00:00" "$CLAUDE_SESSION_ID"
    run bash "${HANDLERS}/formation-state.sh" get "$CLAUDE_SESSION_ID"
    [ "$output" = "7 2026-08-29T10:00:00" ]
}

@test "state: clear forgets the formation" {
    bash "${HANDLERS}/formation-state.sh" set 7 "$CLAUDE_SESSION_ID"
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID"
    run bash "${HANDLERS}/formation-state.sh" get "$CLAUDE_SESSION_ID"
    [ -z "$output" ]
}

@test "hook: a session in no formation is silent and does not fail" {
    run bash "${HANDLERS}/formation-check.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook: an unreachable service is silent and does not fail" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    # Port 9 is the discard port: nothing listens, so the request cannot succeed.
    MMRY_API_URL="http://127.0.0.1:9" run bash "${HANDLERS}/formation-check.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook: no state file means no network call at all" {
    # The cost of not being in a formation must be one file test. If the hook reached the network
    # first, pointing it at the discard port would still take the connect timeout; this asserts it
    # returns immediately instead.
    local start end
    start=$(date +%s)
    MMRY_API_URL="http://127.0.0.1:9" run bash "${HANDLERS}/formation-check.sh"
    end=$(date +%s)
    [ "$status" -eq 0 ]
    [ $((end - start)) -lt 3 ]
}

@test "hook: the handler is wired into PostToolUse" {
    run grep -c "formation-check" "${BATS_TEST_DIRNAME}/../../hooks/hooks.json"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "hook: hooks.json is still valid JSON after wiring" {
    run bash -c "cd '${BATS_TEST_DIRNAME}/../..' && python -c \"import json,io; json.load(io.open('hooks/hooks.json'))\" 2>/dev/null || node -e \"require('fs').readFileSync('hooks/hooks.json','utf8') && JSON.parse(require('fs').readFileSync('hooks/hooks.json','utf8'))\""
    [ "$status" -eq 0 ]
}

@test "hook: it never writes to stdout, only stderr" {
    # Claude Code discards stdout on exit 2. Anything printed there is invisible and would be a
    # silent failure to deliver.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    run bash -c "MMRY_API_URL=http://127.0.0.1:9 bash '${HANDLERS}/formation-check.sh' 2>/dev/null"
    [ -z "$output" ]
}

@test "client: the transmissions function exists and builds the since parameter" {
    run grep -A8 "^mmry_get_formation_transmissions()" "${HANDLERS}/mmry-client.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"transmissions?sessionId="* ]]
    [[ "$output" == *"since="* ]]
}
