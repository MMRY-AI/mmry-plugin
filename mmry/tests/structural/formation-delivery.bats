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

@test "hook: a malformed response is silent and does not fail" {
    # QA round 1 found this guarded in code but exercised by no test. A local server that answers
    # 200 with HTML instead of JSON is the real condition, so the guard is driven rather than
    # described. Anything but silence here would put half-parsed text in front of the model.
    command -v python >/dev/null 2>&1 || skip "python not available to serve a malformed response"
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"

    local port=18731
    python - "$port" <<'PYSRV' &
import sys, BaseHTTPServer
class H(BaseHTTPServer.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write('<html>this is not json at all</html>')
    def log_message(self, *a): pass
BaseHTTPServer.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PYSRV
    local srv=$!
    sleep 2

    MMRY_API_URL="http://127.0.0.1:${port}" run bash "${HANDLERS}/formation-check.sh"
    kill "$srv" 2>/dev/null || true

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook: with no jq available it is silent and does not fail" {
    # The other half of QA round 1's finding. MMRY_JQ_SKIP_SYSTEM and MMRY_JQ_VENDOR_DIR are the
    # library's own test seams, so pointing the vendor directory at an empty one leaves no usable
    # jq at all, which is the condition on an unsupported platform.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local emptydir="${BATS_TEST_TMPDIR}/no-jq"
    mkdir -p "$emptydir"

    MMRY_JQ="" MMRY_JQ_SKIP_SYSTEM=1 MMRY_JQ_VENDOR_DIR="$emptydir"         MMRY_API_URL="http://127.0.0.1:9" run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "join: a non-numeric formation id is refused before any request is made" {
    run bash "${HANDLERS}/formation-join.sh" "42; curl evil.example.com"
    [ "$status" -ne 0 ]
    [[ "$output" == *"number"* ]]
}

@test "join: with no id it says what it needs rather than guessing" {
    run bash "${HANDLERS}/formation-join.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Which formation"* ]]
}

@test "leave: with no formation it says so and succeeds" {
    run bash "${HANDLERS}/formation-leave.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not in a formation"* ]]
}

@test "leave: it clears local state and is honest that the roster is untouched" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    run bash "${HANDLERS}/formation-leave.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"roster still lists this session"* ]]
    run bash "${HANDLERS}/formation-state.sh" get "$CLAUDE_SESSION_ID"
    [ -z "$output" ]
}

@test "command: /mmry:formation exists and is advertised in help" {
    [ -f "${BATS_TEST_DIRNAME}/../../commands/formation.md" ]
    run grep -c "formation" "${BATS_TEST_DIRNAME}/../../commands/help.md"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}
