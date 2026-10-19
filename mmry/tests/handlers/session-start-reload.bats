#!/usr/bin/env bats
# session-start.sh when /mmry:load-memories re-runs it mid-session (#32346).
#
# A manual reload runs the handler in the Bash tool with NO hook payload on stdin, but with the
# session's own id in the environment (CLAUDE_CODE_SESSION_ID, which the Bash tool sets). That used
# to be reported as the #31385 fault ("could not learn its own session id ... report it"), which is
# false: the id is known. A start with no id from any source is still a fault and still says so.
#
# Where the reload's effects are asserted: the registered id (the formation features key on it) and
# the Foundation session marker. The formation sweep is deliberately NOT run on a reload (it is
# payload-id only, see session-start.sh), so there is nothing for requirement 3 to restore there.

load '../helpers/test-helper'
load '../helpers/mock-config'

setup() {
    setup_mock_curl
    create_test_config "http://localhost:5291" "test-api-key" "apikey"
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME/.claude/mmry/hooks-handlers" "$HOME/.claude/mmry/setup"
    unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID MMRY_HOST CODEX_HOME || true
    FAULT_LOG="${TEST_TMPDIR}/mmry-hook-read-faults.log"
    rm -f "$FAULT_LOG"
}

# Run the handler with an EMPTY stdin (what the Bash tool gives it). Extra args are env assignments.
_reload() {
    : > "${TEST_TMPDIR}/curl-log.txt"
    : > "${TEST_TMPDIR}/empty.json"
    run bash -c "env \"\$@\" HOME='${HOME}' TEST_TMPDIR='${TEST_TMPDIR}' TMPDIR='${TEST_TMPDIR}' \
            MMRY_TMPDIR='${TEST_TMPDIR}' MMRY_CONFIG_FILE='${MMRY_CONFIG_FILE}' \
            CLAUDE_PLUGIN_ROOT='${PLUGIN_ROOT}' \
            bash '${PLUGIN_ROOT}/hooks-handlers/session-start.sh' < '${TEST_TMPDIR}/empty.json'" _ "$@"
}

_registered_session_id() {
    sed -n 's/.*"sessionId":"\([^"]*\)".*/\1/p' "${TEST_TMPDIR}/curl-log.txt" | head -1
}

@test "reload: req1 empty input with CLAUDE_CODE_SESSION_ID set loads memories and shows no fault warning" {
    _reload CLAUDE_CODE_SESSION_ID=env-sess-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"loaded"* ]] || { echo "memories not loaded: ${output}"; return 1; }
    [[ "$output" != *"WARNING FROM MMRY AI"* ]] || { echo "false warning: ${output}"; return 1; }
    [[ "$output" != *"could not be read from stdin"* ]]
}

@test "reload: req1 the same holds when the id arrives as CLAUDE_SESSION_ID" {
    _reload CLAUDE_SESSION_ID=env-sess-2
    [[ "$output" == *"loaded"* ]] || return 1
    [[ "$output" != *"WARNING FROM MMRY AI"* ]]
}

@test "reload: req1 a reload leaves no fault breadcrumb for support to chase" {
    _reload CLAUDE_CODE_SESSION_ID=env-sess-1
    [ ! -s "$FAULT_LOG" ] || { echo "breadcrumb written: $(cat "$FAULT_LOG")"; return 1; }
}

@test "reload: req2 empty input and no session id anywhere still warns" {
    _reload
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING FROM MMRY AI"* ]] || { echo "no warning: ${output}"; return 1; }
    [[ "$output" == *"could not be read from stdin"* ]] || return 1
    [[ "$output" == *"loaded"* ]]
}

@test "reload: req2 a Codex start with empty input still warns even if an id is in the environment" {
    _reload MMRY_HOST=codex CLAUDE_CODE_SESSION_ID=env-sess-1
    [[ "$output" == *"WARNING FROM MMRY AI"* ]] || { echo "Codex behaviour changed: ${output}"; return 1; }
    [[ "$output" == *"could not be read from stdin"* ]]
}

@test "reload: req3 the registered session id is the environment id after a manual reload" {
    _reload CLAUDE_CODE_SESSION_ID=env-sess-1
    [ "$status" -eq 0 ]
    [ "$(_registered_session_id)" = "env-sess-1" ] || { cat "${TEST_TMPDIR}/curl-log.txt"; return 1; }
    [ "$(cat "${TEST_TMPDIR}/mmry-foundation.session")" = "env-sess-1" ]
}

@test "reload: req3 CLAUDE_SESSION_ID wins over CLAUDE_CODE_SESSION_ID, as the chain always did" {
    _reload CLAUDE_SESSION_ID=first CLAUDE_CODE_SESSION_ID=second
    [ "$(_registered_session_id)" = "first" ]
}
