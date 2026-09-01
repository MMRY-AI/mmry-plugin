#!/usr/bin/env bats
# Sending a transmission to a formation (#31104).
#
# WHY THIS FILE MATTERS MORE THAN ITS SIZE SUGGESTS. v1.21 shipped the receiving half of formation
# coordination with no way to speak, and it passed four QA rounds because #31012's two-party proof
# wrote the lead's message straight to the stored procedure. That is not a route a customer has, so
# nothing in the tests noticed that no customer could produce a transmission at all.
#
# So the rule for this file: every assertion is about what happens when the published handler is run
# the way a user runs it. And every test asserting a refusal is paired with the control below
# proving the same setup CAN succeed, because otherwise a typo in the harness produces an identical
# failure and the test proves nothing.

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export CLAUDE_SESSION_ID="bats-say-$$"
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
    MESSAGE="I am refactoring FormationService, please do not touch it"
}

teardown() {
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
}

# Same fake-curl transport as the delivery tests, for the same reason: no interpreter, no port, so
# the variable under test is the server's answer rather than whether a test server started.
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
    # Record the request body so a test can assert what was actually sent, not just the outcome.
    printf '%s' "$dir"
}

_env() {
    echo "MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL=http://fake.invalid"
}

@test "say: refuses with no message rather than sending an empty transmission" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    run bash "${HANDLERS}/formation-say.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Say what?"* ]]
}

@test "say: refuses a message too short to be worth interrupting anyone" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    run bash "${HANDLERS}/formation-say.sh" "ok"
    [ "$status" -ne 0 ]
    [[ "$output" == *"too short"* ]]
}

@test "say: a session in no formation is told so, and told how to fix it" {
    # No state set. This must not reach the network at all, and must not leave the user guessing.
    run bash "${HANDLERS}/formation-say.sh" "$MESSAGE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not in a formation"* ]]
    [[ "$output" == *"join"* ]]
}

@test "control: the fake transport succeeds, so the refusals below mean something" {
    # Without this, every failure assertion in this file could be passing because of a broken
    # harness rather than a working guard. This is the same setup as those tests with one thing
    # changed: the server says it stored the transmission.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=202 FAKE_BODY='{"message":"Stored 1 memory.","stored":1}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-say.sh" "$MESSAGE"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Sent to formation 42"* ]]
}

@test "say: a 2xx that stored nothing is reported as NOT sent" {
    # The defect this whole task exists to fix, in miniature. The processing path swallows an AI
    # failure and returns a result rather than throwing, so a success code alone proves nothing was
    # refused, not that anything was delivered. Reporting this as sent is how v1.21 shipped inert.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=202 FAKE_BODY='{"message":"Nothing was stored.","stored":0}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-say.sh" "$MESSAGE"

    [ "$status" -ne 0 ]
    [[ "$output" == *"recorded nothing"* ]]
    [[ "$output" != *"Sent to formation"* ]]
}

@test "say: a response with no stored count at all is reported as NOT sent" {
    # An older server, or a proxy that rewrites the body, must not read as success either.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=202 FAKE_BODY='{"message":"Memory submitted for processing."}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-say.sh" "$MESSAGE"

    [ "$status" -ne 0 ]
    [[ "$output" != *"Sent to formation"* ]]
}

@test "say: a 502 from the close-out guard says the formation is closed, not something generic" {
    # prod_037 refuses a transmission into a closed-out formation server side. The sender needs to
    # hear which of the two it is, because "not a member" sends them looking for a permissions
    # problem that does not exist.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=502 FAKE_BODY='{"message":"Nothing stored.","stored":0}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-say.sh" "$MESSAGE"

    [ "$status" -ne 0 ]
    [[ "$output" == *"closed out"* ]]
    [[ "$output" != *"Sent to formation"* ]]
}

@test "say: an unreachable service is reported, not swallowed" {
    # The opposite of formation-check.sh on purpose. The hook must fail open and silent because it
    # runs after every tool call. This runs because somebody asked and is waiting for an answer, so
    # silence would be the wrong behaviour.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    MMRY_API_URL="http://127.0.0.1:9" MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key \
        run bash "${HANDLERS}/formation-say.sh" "$MESSAGE"
    [ "$status" -ne 0 ]
    [ -n "$output" ]
    [[ "$output" != *"Sent to formation"* ]]
}

@test "say: non-numeric local state is refused rather than sent anywhere" {
    mkdir -p "${TMPDIR}"
    # Write corrupt state directly, bypassing the setter's own validation, to prove the sender
    # validates what it reads rather than trusting the file.
    printf '%s' "42; rm -rf /" > "${TMPDIR}/mmry-formation-${CLAUDE_SESSION_ID}"
    run bash "${HANDLERS}/formation-say.sh" "$MESSAGE"
    [ "$status" -ne 0 ]
    [[ "$output" != *"Sent to formation"* ]]
}

@test "client: the send function targets the process endpoint with the formation hook type" {
    # The only write path the server binds a formation on. #31011 QA deliberately made a formation
    # id on the public create-memory body bind nothing, so a send built on that route would return
    # success and bind nothing at all.
    run grep -A 14 "^mmry_send_formation_transmission()" "${HANDLERS}/mmry-client.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/api/memories/process"* ]]
    [[ "$output" == *"formation"* ]]
    [[ "$output" == *"formationId"* ]]
}

@test "command: /mmry:formation documents say, and help advertises it" {
    run grep -c "formation-say.sh" "${BATS_TEST_DIRNAME}/../../commands/formation.md"
    [ "$output" -ge 1 ]
    run grep -c "say" "${BATS_TEST_DIRNAME}/../../commands/help.md"
    [ "$output" -ge 1 ]
}

@test "command: the doc tells the model never to report a send it cannot confirm" {
    # The instruction that stops this regressing into the thing it fixed.
    run grep -c "Never report a message as sent unless the script said so" "${BATS_TEST_DIRNAME}/../../commands/formation.md"
    [ "$output" -ge 1 ]
}
