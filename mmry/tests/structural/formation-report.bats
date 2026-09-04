#!/usr/bin/env bats
# The close-out record at the client, and the one thing the client must not do to it (#31046).
#
# WHAT IS BEING GUARDED HERE. The server assembles the record: every member, the work it was given,
# and the state it ended in, including the members with nothing to show. This file guards that the
# client PRINTS THAT RENDERING rather than composing its own, because a second version written here
# would be a second answer, and the section a reimplementation drops first is the member who
# reported nothing - which is the only reason the record exists.
#
# It also guards the reader's own failures: a formation id that is not this session's, an
# unreachable service, and a body it cannot parse. None of them may produce a confident-looking
# record.
#
# Every refusal is paired with a control proving the same harness CAN succeed.

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export CLAUDE_SESSION_ID="bats-report-$$"
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
}

teardown() {
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
}

_fake_curl_dir() {
    local dir="${BATS_TEST_TMPDIR}/fake-bin"
    mkdir -p "$dir"
    cat > "${dir}/curl" <<'FAKECURL'
#!/usr/bin/env bash
out=""; prev=""; url=""
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    [[ "$prev" == "-X" && -n "${FAKE_METHOD_LOG:-}" ]] && printf '%s\n' "$arg" >> "$FAKE_METHOD_LOG"
    [[ "$arg" == http* ]] && url="$arg"
    prev="$arg"
done
[[ -n "${FAKE_URL_LOG:-}" ]] && printf '%s\n' "$url" >> "$FAKE_URL_LOG"
[[ -n "$out" ]] && printf '%s' "${FAKE_BODY:-}" > "$out"
printf '%s' "${FAKE_CODE:-200}"
exit 0
FAKECURL
    chmod +x "${dir}/curl"
    printf '%s' "$dir"
}

# A record with the case that matters in it: a member that reported nothing. The members array
# deliberately also carries a member the RECORD text does not mention, so a client that rebuilt the
# output from the structured data instead of printing the rendering would be visible.
_record_body() {
    cat <<'BODY'
{"formationId":42,"objective":"ship it","status":"Active","projectId":null,"taskId":null,
 "createdDate":"2026-09-04T09:00:00","debriefedDate":null,
 "summary":{"members":2,"unstarted":1,"accepted":0,"done":1,"blocked":0,"abandoned":0,"withoutAssignment":0},
 "members":[{"memberId":3,"sessionId":"a","email":"lead@x","role":"Lead","assignment":"coordinate","outcome":"Done","reported":true,"reportedDate":"2026-09-04T11:00:00","joinedDate":"2026-09-04T09:00:00","leftDate":null},
            {"memberId":7,"sessionId":"b","email":"wing@x","role":"Wingman","assignment":"the validator","outcome":"Unstarted","reported":false,"reportedDate":null,"joinedDate":"2026-09-04T09:05:00","leftDate":null},
            {"memberId":9,"sessionId":"c","email":"ghost@x","role":"Wingman","assignment":null,"outcome":"No assignment","reported":false,"reportedDate":null,"joinedDate":"2026-09-04T09:06:00","leftDate":null}],
 "record":"CLOSE-OUT RECORD, formation 42.\nOutcome: 2 members.\n  [Lead] lead@x (member 3)\n    outcome:  Done, reported 2026-09-04 11:00 UTC\n  [Wingman] wing@x (member 7)\n    assigned: >>> the validator <<<\n    outcome:  Unstarted. Nothing was ever reported against it.\nIt contains no messages."}
BODY
}

# ---------------------------------------------------------------- the request

@test "report: it reads the close-out route for this session's formation" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local urls="${BATS_TEST_TMPDIR}/urls"
    : > "$urls"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_record_body)" FAKE_URL_LOG="$urls" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-report.sh"

    [ "$status" -eq 0 ]
    run cat "$urls"
    [[ "$output" == *"/api/formations/42/close-out"* ]]
}

@test "report: an id given on the command line is used, and no membership is needed" {
    # The record is for people who were never in the formation - the person who set the mission has
    # no screen of their own - so a session in no formation must still be able to read one by id.
    local bin; bin="$(_fake_curl_dir)"
    local urls="${BATS_TEST_TMPDIR}/urls"
    : > "$urls"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_record_body)" FAKE_URL_LOG="$urls" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-report.sh" 99

    [ "$status" -eq 0 ]
    run cat "$urls"
    [[ "$output" == *"/api/formations/99/close-out"* ]]
}

# ---------------------------------------------------------------- what it prints

@test "report: the member that reported nothing is in the output" {
    # THE ASSERTION THIS FEATURE TURNS ON. A record that quietly drops the silent member reads as
    # though everything went to plan.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_record_body)" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-report.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"wing@x (member 7)"* ]]
    [[ "$output" == *"Nothing was ever reported against it."* ]]
    # CONTROL: it prints the member that DID report too, so the line above is the record being
    # printed rather than a fixture that happens to contain one string.
    [[ "$output" == *"lead@x (member 3)"* ]]
}

@test "report: it prints the SERVER's rendering rather than rebuilding one" {
    # The body's members array carries member 9, which the rendered record does not mention. A
    # client that composed its own output from the structured data would show it; one that prints
    # the record cannot. The record is assembled in one place on purpose, and this is the client
    # half of that rule.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_record_body)" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-report.sh"

    [ "$status" -eq 0 ]
    [[ "$output" != *"ghost@x"* ]]
    [[ "$output" == *"CLOSE-OUT RECORD, formation 42."* ]]
    [[ "$output" == *"It contains no messages."* ]]
}

@test "report: with no jq it hands over the body rather than half-parsing it" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    # MMRY_JQ empty is how the client reports that it found no usable jq.
    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_record_body)" MMRY_JQ="" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-report.sh"

    [ "$status" -eq 0 ]
    # Something recognisably the record came back, rather than an empty success.
    [[ "$output" == *"CLOSE-OUT RECORD"* ]]
}

# ---------------------------------------------------------------- failures

@test "report: a session in no formation is told to give an id, and nothing is sent" {
    local bin; bin="$(_fake_curl_dir)"
    local urls="${BATS_TEST_TMPDIR}/urls"
    : > "$urls"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_record_body)" FAKE_URL_LOG="$urls" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-report.sh"

    [ "$status" -ne 0 ]
    [[ "$output" == *"Give the id instead"* ]]
    [ ! -s "$urls" ]

    # CONTROL: the same invocation WITH an id reaches the service, so the refusal above is the
    # missing state rather than a broken harness.
    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_record_body)" FAKE_URL_LOG="$urls" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-report.sh" 99
    [ "$status" -eq 0 ]
    [ -s "$urls" ]
}

@test "report: a 404 says the formation is not there or is not ours, and no record is invented" {
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=404 FAKE_BODY='{"error":"Formation not found."}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-report.sh" 99

    [ "$status" -ne 0 ]
    [[ "$output" == *"does not exist, or it belongs to another account"* ]]
    [[ "$output" != *"CLOSE-OUT RECORD"* ]]
}

@test "report: an unreachable service is reported as unreachable, not as an empty record" {
    # #31195: HTTP 000 is the only status that proves nothing was reached, and an empty record
    # printed confidently would read as a formation where nobody did anything.
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=000 FAKE_BODY='' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-report.sh" 99

    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not reach the service"* ]]
    [[ "$output" != *"CLOSE-OUT RECORD"* ]]
}

@test "report: a formation id that is not a number is refused before anything is sent" {
    local bin; bin="$(_fake_curl_dir)"
    local urls="${BATS_TEST_TMPDIR}/urls"
    : > "$urls"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_record_body)" FAKE_URL_LOG="$urls" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-report.sh" "forty-two"

    [ "$status" -ne 0 ]
    [[ "$output" == *"positive whole number"* ]]
    [ ! -s "$urls" ]
}
