#!/usr/bin/env bats
# Leaving a formation (#31194).
#
# WHAT CHANGED AND WHY THIS FILE EXISTS. Leaving used to be local to this session: it cleared the
# delivery state and told the service nothing. The handler said so honestly, which was the best it
# could do, but the consequence was that the roster kept counting the session and the service
# refused its next join with a conflict. The session was bound to a formation it was no longer
# listening to, and the only ways out affected everybody else in it.
#
# Leaving now calls the service. That turns a handler with one outcome into a handler with four,
# and the whole risk of the change sits in what it SAYS about each of them:
#
#   THE COMMAND MAY NEVER REPORT A RELEASE THE SERVICE DID NOT PERFORM.
#
# A person who is told they left, and then cannot join anything, is worse off than one who is told
# plainly that the release was refused: the first has no idea anything is wrong. That is
# requirement 4 of the ticket and it is what every assertion below is for.
#
# The second rule is inherited from #31195 and formation-list.bats: A STATUS MAY ONLY BE REPORTED
# AS THE THING IT ACTUALLY PROVES. HTTP 000 is the client never having received an answer, so it
# is the only status entitled to the words "could not reach". A 403 is the service answering.
#
# Every test runs the published handler the way a user runs it, and the refusal cases are paired
# with a control proving the same harness CAN succeed. Without that control a typo in the fake
# transport produces an identical failure and the negative assertions pass while proving nothing.

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export CLAUDE_CODE_SESSION_ID="bats-leave-session"
    # Nothing here may read the developer's real configuration: mmry_load_config falls back to
    # ~/.claude/mmry-config.json, and a test that picks up a live API key would talk to production.
    export MMRY_CONFIG_FILE="${BATS_TEST_TMPDIR}/no-such-config.json"
}

# The same fake-curl transport as formation-list.bats, for the same reason: no interpreter and no
# port, so the variable under test is the server's answer rather than whether a test server
# started. Answers with FAKE_CODE and FAKE_BODY.
_fake_curl_dir() {
    local dir="${BATS_TEST_TMPDIR}/fake-bin"
    mkdir -p "$dir"
    cat > "${dir}/curl" <<'FAKECURL'
#!/usr/bin/env bash
out=""; prev=""
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    prev="$arg"
done
[[ -n "$out" ]] && printf '%s' "${FAKE_BODY:-}" > "$out"
printf '%s' "${FAKE_CODE:-200}"
exit 0
FAKECURL
    chmod +x "${dir}/curl"
    printf '%s' "$dir"
}

# A curl that never completes the request, which is what an unreachable service actually looks like
# to this client: real curl exits 7 when it cannot connect, mmry-client catches the non-zero exit
# and sets the 000 sentinel. Exiting 7 reproduces that branch hermetically; pointing a real curl at
# a dead port would make the test depend on how the host treats a closed port.
_failing_curl_dir() {
    local dir="${BATS_TEST_TMPDIR}/fail-bin"
    mkdir -p "$dir"
    cat > "${dir}/curl" <<'FAILCURL'
#!/usr/bin/env bash
exit 7
FAILCURL
    chmod +x "${dir}/curl"
    printf '%s' "$dir"
}

# Put this session in a formation, the way joining does.
_join_locally() {
    bash "${BATS_TEST_DIRNAME}/../../hooks-handlers/formation-state.sh" set "${1:-77}" "$CLAUDE_CODE_SESSION_ID"
}

_state() {
    bash "${BATS_TEST_DIRNAME}/../../hooks-handlers/formation-state.sh" get "$CLAUDE_CODE_SESSION_ID"
}

_run_leave() {
    local bin="$1"; shift
    PATH="${bin}:${PATH}" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        "$@" run bash "${HANDLERS}/formation-leave.sh"
}

@test "control: a released session is told so, and the local state is gone" {
    local bin; bin="$(_fake_curl_dir)"
    _join_locally 77

    PATH="${bin}:${PATH}" FAKE_CODE=200 \
        FAKE_BODY='{"formationId":77,"sessionId":"bats-leave-session","leftDate":"2026-09-03T12:00:00Z","formationStatus":"Active","memberCount":2,"activeMemberCount":2}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-leave.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"77"* ]]
    [[ "$output" == *"Left formation"* ]]
    # The whole point of the ticket, said out loud: this session can now go somewhere else.
    [[ "$output" == *"join another"* ]]
    # And the sentence the old handler had to print is gone, because it is no longer true.
    [[ "$output" != *"roster still lists"* ]]

    [ -z "$(_state)" ]
}

@test "leave: a refused release is never reported as a release (#31194 requirement 4)" {
    # THE DEFECT THIS FILE GUARDS AGAINST. If the service refuses and the command still says the
    # session left, the person is left believing they can join elsewhere and cannot, with nothing
    # on screen to suggest anything went wrong. That is strictly worse than the local-only leave
    # this ticket replaced, because that one at least told the truth about its own limits.
    local bin; bin="$(_fake_curl_dir)"
    _join_locally 77

    PATH="${bin}:${PATH}" FAKE_CODE=403 FAKE_BODY='{"error":"That session belongs to another user."}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-leave.sh"

    [ "$status" -ne 0 ]
    [[ "$output" == *"403"* ]]
    [[ "$output" != *"Left formation"* ]]
    # It must also say what is still true of the world, not only that something failed.
    [[ "$output" == *"still"* ]]
    # #31195's rule: a 403 is the service answering, so it may not be dressed up as a network
    # problem. Barred as a bare substring so "unreachable" and any later rephrasing are caught.
    [[ "$output" != *"reach"* ]]
}

@test "leave: no answered status claims unreachability, whatever the code (#31195)" {
    # A handler taught only about 403 leaves the identical misreport waiting behind every other
    # code. The rule is about the 000 sentinel, not about a list of statuses, so this is too.
    local bin; bin="$(_fake_curl_dir)"

    for answered_code in 401 403 409 500 503; do
        _join_locally 77
        PATH="${bin}:${PATH}" FAKE_CODE="$answered_code" FAKE_BODY='{"error":"refused"}' \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
            run bash "${HANDLERS}/formation-leave.sh"

        [ "$status" -ne 0 ]
        [[ "$output" == *"$answered_code"* ]]
        [[ "$output" != *"reach"* ]]
        [[ "$output" != *"Left formation"* ]]
    done
}

@test "leave: a service that cannot be reached is reported as unreachable, and claims nothing" {
    local bin; bin="$(_failing_curl_dir)"
    _join_locally 77

    PATH="${bin}:${PATH}" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-leave.sh"

    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not reach the service"* ]]
    [[ "$output" != *"Left formation"* ]]
    # The honest half of the old behaviour, kept: delivery here HAS stopped, and the membership
    # may well still be live on the service.
    [[ "$output" == *"still"* ]]
}

@test "leave: delivery stops here even when the release was refused" {
    # Stopping delivery is the part this session can always do, and it is what the person asked
    # for. Leaving the state behind would keep the hook polling a formation they have finished
    # with, on top of whatever went wrong with the release.
    local bin; bin="$(_fake_curl_dir)"
    _join_locally 77

    PATH="${bin}:${PATH}" FAKE_CODE=500 FAKE_BODY='{"error":"boom"}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-leave.sh"

    [ "$status" -ne 0 ]
    [ -z "$(_state)" ]
}

@test "leave: a session the service holds no membership for is told exactly that" {
    # 404 is not a failure to report loudly: the session is not in a formation, which is the state
    # the person was asking for. It must still not be dressed up as a release that happened.
    local bin; bin="$(_fake_curl_dir)"
    _join_locally 77

    PATH="${bin}:${PATH}" FAKE_CODE=404 FAKE_BODY='{"error":"That session is not currently in a formation."}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-leave.sh"

    [ "$status" -eq 0 ]
    [[ "$output" != *"Left formation"* ]]
    [[ "$output" != *"reach"* ]]
    [[ "$output" == *"not"* ]]
    [ -z "$(_state)" ]
}

@test "leave: a session with no local record still asks the service to release it" {
    # THE RESCUE PATH, and the reason the route carries no formation id. Every session stranded by
    # the local-only leave is in exactly this state: the service still holds the membership and
    # this session no longer knows which formation it was. A handler that returned early on empty
    # local state would leave those sessions stuck for good.
    local bin; bin="$(_fake_curl_dir)"
    # Deliberately NOT joined locally.

    PATH="${bin}:${PATH}" FAKE_CODE=200 \
        FAKE_BODY='{"formationId":5,"sessionId":"bats-leave-session","leftDate":"2026-09-03T12:00:00Z","formationStatus":"Active","memberCount":1,"activeMemberCount":1}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-leave.sh"

    [ "$status" -eq 0 ]
    # The id comes from the service's answer, which is the only place it could have come from.
    [[ "$output" == *"5"* ]]
    [[ "$output" == *"Left formation"* ]]
}

@test "leave: with no session id it explains rather than guessing" {
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY='{}' \
        CLAUDE_SESSION_ID="" CLAUDE_CODE_SESSION_ID="" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-leave.sh"

    [ "$status" -ne 0 ]
    [[ "$output" == *"session"* ]]
    [[ "$output" != *"Left formation"* ]]
}
