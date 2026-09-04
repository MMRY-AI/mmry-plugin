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
# One line per invocation when a test asks for it, so a test can assert HOW MANY requests were
# made and not merely what came back. #31195 needed that to prove a 502 is not silently retried.
if [[ -n "${FAKE_CALL_LOG:-}" ]]; then printf 'call\n' >> "$FAKE_CALL_LOG"; fi
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

@test "say: a two-word message is sent, not refused for being short (#31122)" {
    # This test is the inverse of the one it replaces. The old ten-character floor was written on
    # the assumption that a very short message was probably a mistake; the real reason short
    # messages went nowhere was that the server ran them through AI extraction and dropped
    # whatever it judged not worth keeping. "files locked" is exactly what one window needs to
    # tell another.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=201 FAKE_BODY='{"transmissionId":7,"stored":1}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-say.sh" "ok"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Sent to formation"* ]]
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

@test "say: a 403 tells the sender to join from this window, and names both possible causes" {
    # The server answers 403 for not-a-member, for a closed-out formation and for another
    # account's formation, deliberately not distinguishing them: telling them apart would disclose
    # whether somebody else's formation exists. So the client names both causes the sender can act
    # on, and gives the command that fixes the common one.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=403 FAKE_BODY='{"message":"This session is not a current member of that formation.","stored":0}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-say.sh" "$MESSAGE"

    [ "$status" -ne 0 ]
    [[ "$output" == *"not a current member"* ]]
    [[ "$output" == *"closed out"* ]]
    [[ "$output" == *"join 42"* ]]
    [[ "$output" != *"Sent to formation"* ]]
}

@test "say: a 502 is reported as a server fault with the status code, never as a membership problem (#31195)" {
    # THE DEFECT THIS FILE NOW GUARDS. Reproduced in production on 2026-09-03: the Lead of a live
    # formation, with an intact roster, was told "the formation may have been closed out, or you may
    # no longer be a member of it". Both were false. A read of the formation at that moment returned
    # it Active with that session listed as Lead, and the true cause was on the server.
    #
    # The cost was not the wording. The operator's next move after reading that sentence is to check
    # the roster and re-join, so the message spent an investigation on the one place the fault was
    # not. A 502 says the server failed. It says nothing whatever about who is in the formation, and
    # the client is not entitled to invent that.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=502 FAKE_BODY='{"error":"Bad Gateway"}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-say.sh" "$MESSAGE"

    [ "$status" -ne 0 ]
    # What it must say: a server fault, the status code, and what to do next.
    [[ "$output" == *"server"* ]]
    [[ "$output" == *"502"* ]]
    [[ "$output" == *"Try again"* || "$output" == *"try again"* ]]
    # What it must never say. These are the two false explanations from the production report, plus
    # the re-join instruction that acting on them produces. "member" and "join" are barred outright
    # rather than pattern-matched loosely: a 502 branch has no business using either word.
    [[ "$output" != *"member"* ]]
    [[ "$output" != *"closed out"* ]]
    [[ "$output" != *"join"* ]]
    [[ "$output" != *"Sent to formation"* ]]
}

@test "say: the rest of the gateway family is treated the same way as a 502 (#31195)" {
    # 503 and 504 are the same kind of answer from the same layer, and a client that fixed only the
    # code it happened to be shown would leave the identical misreport one bad afternoon away.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    for gateway_code in 503 504; do
        PATH="${bin}:${PATH}" FAKE_CODE="$gateway_code" FAKE_BODY='{"error":"upstream"}' \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
            run bash "${HANDLERS}/formation-say.sh" "$MESSAGE"

        [ "$status" -ne 0 ]
        [[ "$output" == *"server"* ]]
        [[ "$output" == *"$gateway_code"* ]]
        [[ "$output" != *"member"* ]]
        [[ "$output" != *"closed out"* ]]
        [[ "$output" != *"Sent to formation"* ]]
    done
}

@test "say: an unmapped status names the code and claims nothing it cannot support (#31195)" {
    # The catch-all is where every status nobody anticipated lands, so it is the one branch that
    # must not guess. It may name the code and refuse to claim delivery. It may not narrate a cause.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=418 FAKE_BODY='{"error":"teapot"}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-say.sh" "$MESSAGE"

    [ "$status" -ne 0 ]
    [[ "$output" == *"418"* ]]
    [[ "$output" != *"member"* ]]
    [[ "$output" != *"closed out"* ]]
    [[ "$output" != *"Sent to formation"* ]]
}

@test "say: a 502 is sent once and not silently retried (#31195 decision)" {
    # The decision recorded on #31195 and in the handler: the client does NOT retry a failed send by
    # itself. The transmission POST carries no idempotency key, so a 502 raised after the row was
    # written would put the same instruction into the channel twice, and the other members cannot
    # tell a duplicate from a repeat. The sender is a person who is present and waiting, so the
    # retry is theirs to make. This test is what stops that decision being quietly reversed.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local log="${BATS_TEST_TMPDIR}/curl-calls.log"
    : > "$log"

    PATH="${bin}:${PATH}" FAKE_CODE=502 FAKE_BODY='{"error":"Bad Gateway"}' FAKE_CALL_LOG="$log" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-say.sh" "$MESSAGE"

    [ "$status" -ne 0 ]
    run wc -l < "$log"
    [ "${output// /}" -eq 1 ]
}

@test "say: a 404 still says the formation is gone, unchanged (#31195 regression guard)" {
    # The counterpart to the 502 fix. Correcting a server fault must not blur the statuses that DO
    # carry a cause: 404 means the formation is not there, and that sentence has to survive intact.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=404 FAKE_BODY='{"error":"not found"}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-say.sh" "$MESSAGE"

    [ "$status" -ne 0 ]
    [[ "$output" == *"no longer exists"* ]]
    [[ "$output" == *"leave"* ]]
    [[ "$output" != *"Sent to formation"* ]]
}

@test "say: an out-of-date plugin posting the old way passes the server answer through (#31122)" {
    # The server refuses hookType formation on /api/memories/process with a 400 naming the new
    # endpoint. The sender must see the server's own words rather than a summary, because they are
    # trying to work out why nothing arrived.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=400 FAKE_BODY='{"errors":{"hookType":["Use POST /api/formations/{formationId}/transmissions"]}}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-say.sh" "$MESSAGE"

    [ "$status" -ne 0 ]
    [[ "$output" == *"/api/formations/"* ]]
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

@test "client: the send function targets the formation endpoint, not memory processing (#31122)" {
    # The memory-processing route ran the message through AI extraction and stored it as a memory,
    # which dropped short messages and put coordination chatter in the customer recall, search and
    # export. The server now refuses that route outright, so a client still pointed at it would
    # fail every send.
    #
    # Comments are stripped before the negative assertion, deliberately. The function explains why
    # it moved and names the old route while doing so, and a check that cannot tell an explanation
    # from a request would fail on the documentation rather than on the behaviour.
    #
    # #31045: extracted by FUNCTION BOUNDARIES rather than by a fixed 26 lines. The function gained
    # the recipient argument and its explanation, which pushed the request line past that window, so
    # the test would have stopped covering the request it is named after while continuing to pass on
    # the comment block. A window measured in lines is a window that silently narrows.
    run bash -c "awk '/^mmry_send_formation_transmission\\(\\)/,/^}/' '${HANDLERS}/mmry-client.sh' | grep -v '^[[:space:]]*#'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/api/formations/"* ]]
    [[ "$output" == *"transmissions"* ]]
    [[ "$output" == *"content"* ]]
    [[ "$output" != *"/api/memories/process"* ]]
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

@test "debrief: a session in no formation is told there is nothing to close out" {
    run bash "${HANDLERS}/formation-debrief.sh" "This formation accomplished the migration and found the date bug"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not in a formation"* ]]
}

@test "debrief: refuses a summary too short to be worth keeping" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    run bash "${HANDLERS}/formation-debrief.sh" "done"
    [ "$status" -ne 0 ]
    [[ "$output" == *"too short"* ]]
}

@test "control: a confirmed debrief clears local state and says what happened" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY='{"id":42,"status":"Debriefed"}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-debrief.sh" "The schema migrated cleanly and the import bug was the date format"

    [ "$status" -eq 0 ]
    [[ "$output" == *"closed out"* ]]
    # The hook must stop polling a channel that will never serve again.
    run bash "${HANDLERS}/formation-state.sh" get "$CLAUDE_SESSION_ID"
    [ -z "$output" ]
}

@test "debrief: a 502 says the formation is still active and nothing was recorded" {
    # DD-70 server-side: a failed consolidation refuses to record the transition. The client must
    # say that plainly AND must keep the local state, because the formation is still live.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=502 FAKE_BODY='{"error":"consolidation failed"}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-debrief.sh" "The schema migrated cleanly and the import bug was the date format"

    [ "$status" -ne 0 ]
    [[ "$output" == *"left active"* ]]
    [[ "$output" != *"closed out"* ]]
    run bash "${HANDLERS}/formation-state.sh" get "$CLAUDE_SESSION_ID"
    [[ "$output" == 42* ]]
}

@test "debrief: a role refusal names who may close out, not a generic error" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=403 FAKE_BODY='{"error":"forbidden"}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-debrief.sh" "The schema migrated cleanly and the import bug was the date format"

    [ "$status" -ne 0 ]
    [[ "$output" == *"lead"* ]]
    [[ "$output" == *"administrator"* ]]
}

@test "command: /mmry:formation documents debrief, and help advertises it" {
    run grep -c "formation-debrief.sh" "${BATS_TEST_DIRNAME}/../../commands/formation.md"
    [ "$output" -ge 1 ]
    run grep -c "debrief" "${BATS_TEST_DIRNAME}/../../commands/help.md"
    [ "$output" -ge 1 ]
}
