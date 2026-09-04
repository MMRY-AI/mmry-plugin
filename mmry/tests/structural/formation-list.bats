#!/usr/bin/env bats
# Listing this account's active formations (#31195).
#
# WHY THIS FILE EXISTS. formation-list.sh shipped with no coverage at all, and #31195 then added a
# branch to it that decides what an operator is told when the listing fails. A branch that chooses
# between "your network is down" and "the service refused you" is exactly the thing #31195 was
# raised about, so leaving it unguarded would have been the ticket's own defect committed inside
# the fix for it. QA said so on the PR and was right.
#
# The property under test is narrow and worth stating plainly: A STATUS CODE MAY ONLY BE REPORTED
# AS THE THING IT ACTUALLY PROVES. HTTP 000 is the client never having got an answer, so it is the
# only status entitled to the words "could not reach". A 401 or a 403 is the service answering, and
# telling somebody to check their network when their credential expired sends them to the one place
# the fault is not.
#
# Every assertion below runs the published handler the way a user runs it, and the refusal tests
# are paired with a control proving the same harness CAN succeed. Without that control a typo in
# the fake transport produces an identical failure and the negative assertions pass while proving
# nothing.

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
}

# The same fake-curl transport as formation-say.bats and formation-delivery.bats, for the same
# reason: no interpreter and no port, so the variable under test is the server's answer rather than
# whether a test server started. Answers with FAKE_CODE and FAKE_BODY.
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

# A curl that fails to complete the request, which is what an unreachable service actually looks
# like to this client: real curl exits 7 when it cannot connect, mmry-client catches the non-zero
# exit and sets the 000 sentinel. Exiting 7 here reproduces that branch exactly, and hermetically
# -- the alternative, pointing a real curl at a dead port, makes the test depend on how the host
# treats a closed port.
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

@test "control: the fake transport lists formations, so the failures below mean something" {
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 \
        FAKE_BODY='[{"id":42,"objective":"Ship the release","activeMemberCount":2}]' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-list.sh"

    [ "$status" -eq 0 ]
    # Asserted on the objective and the id rather than on the formatted layout: the handler prints
    # a jq-rendered line where jq resolves and the raw body where it does not, and both contain
    # these. The point of the control is that a success reached the user, not how it was arranged.
    [[ "$output" == *"42"* ]]
    [[ "$output" == *"Ship the release"* ]]
}

@test "list: a service that cannot be reached is reported as unreachable (#31195)" {
    # The half of the branch that was already right, kept so the fix cannot be undone from the
    # other side. When the request never completes, "could not reach the service" is the honest
    # sentence and it has to survive.
    #
    # A credential is supplied deliberately, so what produces the 000 here is the failed request
    # and not an absent API key. This test is about the network path only.
    local bin; bin="$(_failing_curl_dir)"

    PATH="${bin}:${PATH}" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-list.sh"

    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not reach the service"* ]]
}

@test "list: a 401 says the service refused it, never that the service was unreachable (#31195)" {
    # THE DEFECT THIS FILE GUARDS. The handler used to print "Could not reach the service (HTTP
    # 401)" -- a sentence that contradicts its own evidence, because a 401 IS the service
    # answering. The cost is a person sent to check their connection when what expired was their
    # credential.
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=401 FAKE_BODY='{"error":"Unauthorized"}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=stale-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-list.sh"

    [ "$status" -ne 0 ]
    # What it must say: that the listing failed, and which status came back, so the reader can act
    # on the real answer.
    [[ "$output" == *"401"* ]]
    [[ "$output" == *"Could not list"* ]]
    # What it must never say. "reach" is barred as a bare substring rather than matched as a
    # sentence, so "unreachable" and any later rephrasing are caught too.
    [[ "$output" != *"reach"* ]]

    # Deliberately NOT asserted: whether the response body is echoed after that sentence. How much
    # of a server error body belongs in front of a user is a separate question under its own
    # ticket, and pinning it here would make this test block that work.
}

@test "list: no answered status claims unreachability, whatever the code (#31195)" {
    # A fix that only taught the handler about 401 would leave the identical misreport waiting
    # behind every other code. The rule is about the 000 sentinel, not about a list of statuses, so
    # the test is too: a refusal, a different refusal, and two server faults all have to name
    # themselves and none of them may talk about reaching anything.
    local bin; bin="$(_fake_curl_dir)"

    for answered_code in 401 403 500 503; do
        PATH="${bin}:${PATH}" FAKE_CODE="$answered_code" FAKE_BODY='{"error":"refused"}' \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
            run bash "${HANDLERS}/formation-list.sh"

        [ "$status" -ne 0 ]
        [[ "$output" == *"$answered_code"* ]]
        [[ "$output" != *"reach"* ]]
    done
}
