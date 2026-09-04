#!/usr/bin/env bats
# Directed messages: an instruction reaches only its recipient (#31045).
#
# WHAT IS BEING GUARDED HERE, as distinct from the server-side suite. The API decides who receives
# a message. This file decides three things the API cannot:
#
#   1. That the client SENDS a recipient when one was given, and sends NO recipient field at all
#      when none was. The second half is requirement 4 at the client: an accidental recipient, or
#      an accidental absence, turns a private instruction into a broadcast or the reverse, and the
#      sender finds out from nobody.
#   2. That the sender is told WHICH of those two things happened. "Sent to the formation" and
#      "sent to one member and nobody else" are different facts about who now has an order.
#   3. That the receiving session can SEE that a message was meant for it, which is the whole
#      point: an instruction the model reads as ambient chatter has not been delivered in any
#      sense that matters.
#
# Every refusal test is paired with a control proving the same setup CAN succeed, per the standing
# rule in formation-say.bats: without it a typo in the harness produces an identical failure and
# the test proves nothing.

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export CLAUDE_SESSION_ID="bats-directed-$$"
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
    MESSAGE="rewrite the validator, it is yours"
}

teardown() {
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
}

# The same fake-curl transport the other formation suites use, with one addition: it records the
# REQUEST BODY. Asserting on the outcome alone cannot tell a message sent to one member from the
# same message broadcast to everybody, because the server's answer looks the same either way, and
# that difference is the entire feature.
_fake_curl_dir() {
    local dir="${BATS_TEST_TMPDIR}/fake-bin"
    mkdir -p "$dir"
    cat > "${dir}/curl" <<'FAKECURL'
#!/usr/bin/env bash
# The client calls curl with -o <file> -w '%{http_code}' and, for a POST, --data-binary @<file>.
out=""; prev=""; url=""
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    if [[ "$prev" == "--data-binary" && "$arg" == @* && -n "${FAKE_BODY_LOG:-}" ]]; then
        cat "${arg#@}" >> "$FAKE_BODY_LOG"
        printf '\n' >> "$FAKE_BODY_LOG"
    fi
    [[ "$arg" == http* ]] && url="$arg"
    prev="$arg"
done
[[ -n "${FAKE_URL_LOG:-}" ]] && printf '%s\n' "$url" >> "$FAKE_URL_LOG"
[[ -n "${FAKE_CALL_LOG:-}" ]] && printf 'call\n' >> "$FAKE_CALL_LOG"
[[ -n "$out" ]] && printf '%s' "${FAKE_BODY:-}" > "$out"
printf '%s' "${FAKE_CODE:-200}"
exit 0
FAKECURL
    chmod +x "${dir}/curl"
    printf '%s' "$dir"
}

# ---------------------------------------------------------------- sending

@test "say: a recipient is carried on the request as a number" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local body="${BATS_TEST_TMPDIR}/req-body"
    : > "$body"

    PATH="${bin}:${PATH}" FAKE_CODE=201 FAKE_BODY='{"transmissionId":7,"recipientMemberId":12,"stored":1}' \
        FAKE_BODY_LOG="$body" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-say.sh" "$MESSAGE" 12

    [ "$status" -eq 0 ]
    run cat "$body"
    [[ "$output" == *'"recipientMemberId":12'* ]]
    # Unquoted, because it is a number on the wire. A quoted value would be a string the server
    # has to coerce, and coercion is where a wrong recipient becomes a silent one.
    [[ "$output" != *'"recipientMemberId":"12"'* ]]
}

@test "say: with NO recipient the field is absent entirely, not sent as null (requirement 4)" {
    # THE REGRESSION THAT WOULD BE INVISIBLE. Every message before #31045 was a broadcast and must
    # stay one. An absent field and an explicit null are not the same request, and a client that
    # started sending null would be relying on the server to interpret it the same way forever.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local body="${BATS_TEST_TMPDIR}/req-body"
    : > "$body"

    PATH="${bin}:${PATH}" FAKE_CODE=201 FAKE_BODY='{"transmissionId":7,"recipientMemberId":null,"stored":1}' \
        FAKE_BODY_LOG="$body" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-say.sh" "$MESSAGE"

    [ "$status" -eq 0 ]
    run cat "$body"
    [[ "$output" != *"recipientMemberId"* ]]
    # The control: the request was genuinely made and genuinely carried the message, so the
    # absence above is about the recipient rather than about an empty body.
    [[ "$output" == *"$MESSAGE"* ]]
}

@test "say: a directed send is reported as reaching one member, not the formation" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=201 FAKE_BODY='{"transmissionId":7,"recipientMemberId":12,"stored":1}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-say.sh" "$MESSAGE" 12

    [ "$status" -eq 0 ]
    [[ "$output" == *"member 12"* ]]
    [[ "$output" == *"nobody else"* ]]
    # It must not read as a broadcast. A sender who believes four other people saw an instruction
    # that reached one has no way to discover the difference.
    [[ "$output" != *"The other members will see it"* ]]
}

@test "say: an UNDIRECTED send still reports the formation, unchanged (regression guard)" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=201 FAKE_BODY='{"transmissionId":7,"stored":1}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-say.sh" "$MESSAGE"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Sent to formation 42"* ]]
    [[ "$output" != *"nobody else"* ]]
}

@test "say: a non-numeric recipient is refused WITHOUT sending, so it is never broadcast instead" {
    # The failure this prevents is not the bad id. It is the message going to the whole formation
    # while the sender believes it went to one person, which is what dropping an unparseable
    # recipient and carrying on would do.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local calls="${BATS_TEST_TMPDIR}/curl-calls.log"
    : > "$calls"

    PATH="${bin}:${PATH}" FAKE_CODE=201 FAKE_BODY='{"transmissionId":7,"stored":1}' \
        FAKE_CALL_LOG="$calls" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-say.sh" "$MESSAGE" "12; rm -rf /"

    [ "$status" -ne 0 ]
    [[ "$output" == *"roster entry id"* ]]
    [[ "$output" != *"Sent to"* ]]
    run wc -l < "$calls"
    [ "${output// /}" -eq 0 ]
}

@test "say: a zero recipient is refused too, because no roster entry is ever zero" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    run bash "${HANDLERS}/formation-say.sh" "$MESSAGE" 0
    [ "$status" -ne 0 ]
    [[ "$output" != *"Sent to"* ]]
}

@test "control: the same setup with a valid recipient succeeds, so the refusals above mean something" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=201 FAKE_BODY='{"transmissionId":7,"recipientMemberId":12,"stored":1}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-say.sh" "$MESSAGE" 12

    [ "$status" -eq 0 ]
    [[ "$output" == *"Sent to member 12"* ]]
}

@test "say: a recipient refusal passes the SERVER's reason through and claims nothing was sent" {
    # The server refuses a recipient outside this formation, on another account, one who has left,
    # and the sender's own, each with 400 and its own sentence. The client may not summarise those
    # into a guess: #31195 is the record of what a wrong explanation costs the person reading it.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=400 \
        FAKE_BODY='{"message":"That member has left the formation, so a message addressed to them would reach nobody.","stored":0}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-say.sh" "$MESSAGE" 12

    [ "$status" -ne 0 ]
    [[ "$output" == *"has left the formation"* ]]
    [[ "$output" != *"Sent to"* ]]
}

@test "say: the old 400 body with no message field is still passed through whole (#31122)" {
    # The out-of-date-plugin case shares this branch. Its body has no message field, so the client
    # must fall back to the whole response rather than printing an empty explanation.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=400 \
        FAKE_BODY='{"errors":{"hookType":["Use POST /api/formations/{formationId}/transmissions"]}}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-say.sh" "$MESSAGE"

    [ "$status" -ne 0 ]
    [[ "$output" == *"/api/formations/"* ]]
    [[ "$output" != *"Sent to"* ]]
}

# ---------------------------------------------------------------- receiving

@test "delivery: a directed transmission is marked, and the guidance explains what that means" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local directed='[{"senderRole":"Lead","senderSessionID":"other-session","recipientMemberID":12,"content":"take the validator, it is yours","sentDate":"2026-09-04T12:00:00"}]'

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$directed" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 2 ]
    [[ "$output" == *"DIRECTED TO YOU: take the validator"* ]]
    [[ "$output" == *"addressed to this session specifically"* ]]
}

@test "delivery: an ambient transmission carries no marker and no directed guidance" {
    # The other half, and the one that decides whether the marker means anything. A marker on every
    # line is a marker on no line.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local ambient='[{"senderRole":"Wingman","senderSessionID":"other-session","recipientMemberID":null,"content":"the build is broken","sentDate":"2026-09-04T12:00:00"}]'

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$ambient" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 2 ]
    [[ "$output" == *"the build is broken"* ]]
    [[ "$output" != *"DIRECTED TO YOU"* ]]
    [[ "$output" != *"addressed to this session specifically"* ]]
}

@test "delivery: a message with no recipient field at all is ambient, not directed" {
    # An older server, or a proxy that strips unknown fields, must never make a broadcast look like
    # an order. Absent and null have to behave identically here.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local legacy='[{"senderRole":"Wingman","senderSessionID":"other-session","content":"files locked","sentDate":"2026-09-04T12:00:00"}]'

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$legacy" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 2 ]
    [[ "$output" == *"files locked"* ]]
    [[ "$output" != *"DIRECTED TO YOU"* ]]
}

@test "delivery: in a mixed batch only the directed line is marked" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local mixed='[{"senderRole":"Lead","senderSessionID":"s1","recipientMemberID":12,"content":"ORDER-FOR-ME","sentDate":"2026-09-04T12:00:00"},{"senderRole":"Wingman","senderSessionID":"s2","recipientMemberID":null,"content":"NEWS-FOR-EVERYONE","sentDate":"2026-09-04T12:00:01"}]'

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$mixed" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 2 ]
    [[ "$output" == *"DIRECTED TO YOU: ORDER-FOR-ME"* ]]
    [[ "$output" == *"NEWS-FOR-EVERYONE"* ]]
    [[ "$output" != *"DIRECTED TO YOU: NEWS-FOR-EVERYONE"* ]]
}

@test "delivery: the hook still fails open and silent when the response is malformed" {
    # The governing rule of this hook is unchanged by any of the above: it runs after every tool
    # call in every session and must never disturb one.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY='{"not":"an array"}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------- the roster

@test "roster: lists the member id, the role and who has left" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local roster='{"formation":{"id":42,"objective":"migrate the billing schema"},"members":[{"id":11,"sessionId":"s1","role":"Lead","email":"lead@example.com","assignment":"coordinate","leftDate":null},{"id":12,"sessionId":"s2","role":"Wingman","email":"wing@example.com","assignment":null,"leftDate":null},{"id":9,"sessionId":"s0","role":"Wingman","email":"gone@example.com","assignment":null,"leftDate":"2026-09-03T10:00:00"}]}'

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$roster" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-roster.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"migrate the billing schema"* ]]
    [[ "$output" == *"11"* ]]
    [[ "$output" == *"wing@example.com"* ]]
    # A member who has gone is SHOWN and marked rather than omitted, so the server's refusal to
    # address them is legible instead of baffling.
    [[ "$output" == *"has left; cannot be addressed"* ]]
    # And it says what the ids are for, because an id list with no instruction is a puzzle.
    [[ "$output" == *"--to"* ]]
}

@test "roster: it reads THIS session's formation when given no id" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local urls="${BATS_TEST_TMPDIR}/urls.log"
    : > "$urls"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY='{"formation":{"id":4242,"objective":"x"},"members":[]}' \
        FAKE_URL_LOG="$urls" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-roster.sh"

    [ "$status" -eq 0 ]
    run cat "$urls"
    [[ "$output" == *"/api/formations/4242"* ]]
}

@test "roster: a session in no formation is told so, and does not reach the network" {
    local bin; bin="$(_fake_curl_dir)"
    local calls="${BATS_TEST_TMPDIR}/curl-calls.log"
    : > "$calls"

    PATH="${bin}:${PATH}" FAKE_CALL_LOG="$calls" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-roster.sh"

    [ "$status" -ne 0 ]
    [[ "$output" == *"not in a formation"* ]]
    run wc -l < "$calls"
    [ "${output// /}" -eq 0 ]
}

@test "roster: an unreachable service is reported, not swallowed" {
    # The opposite of formation-check.sh on purpose. Somebody asked for this and is waiting.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    MMRY_API_URL="http://127.0.0.1:9" MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key \
        run bash "${HANDLERS}/formation-roster.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not reach the service"* ]]
}

@test "roster: a 404 says the formation is gone rather than blaming the network (#31195)" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=404 FAKE_BODY='{"error":"not found"}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-roster.sh"

    [ "$status" -ne 0 ]
    [[ "$output" == *"does not exist"* ]]
    [[ "$output" != *"Could not reach the service"* ]]
}

# ---------------------------------------------------------------- client and docs

@test "client: the roster function reads one formation" {
    run bash -c "awk '/^mmry_get_formation\\(\\)/,/^}/' '${HANDLERS}/mmry-client.sh' | grep -v '^[[:space:]]*#'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/api/formations/"* ]]
}

@test "client: the send function passes the recipient through as an integer field" {
    # Extracted by function boundaries rather than by a fixed number of lines, so the assertion
    # does not silently stop covering the request the moment the function grows.
    run bash -c "awk '/^mmry_send_formation_transmission\\(\\)/,/^}/' '${HANDLERS}/mmry-client.sh' | grep -v '^[[:space:]]*#'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"#recipientMemberId"* ]]
    [[ "$output" == *"transmissions"* ]]
    [[ "$output" != *"/api/memories/process"* ]]
}

@test "command: /mmry:formation documents directing a message and the roster" {
    run grep -c "formation-roster.sh" "${BATS_TEST_DIRNAME}/../../commands/formation.md"
    [ "$output" -ge 1 ]
    run grep -c -- "--to" "${BATS_TEST_DIRNAME}/../../commands/formation.md"
    [ "$output" -ge 1 ]
    run grep -c -- "--to" "${BATS_TEST_DIRNAME}/../../commands/help.md"
    [ "$output" -ge 1 ]
}

@test "command: the doc tells the model when to direct and when to broadcast" {
    # Without this the model has a new capability and no judgement about it, and the likeliest
    # outcome is that it directs everything, which is as wrong as directing nothing.
    run grep -c "When to direct and when to broadcast" "${BATS_TEST_DIRNAME}/../../commands/formation.md"
    [ "$output" -ge 1 ]
}

@test "command: the doc forbids reporting a directed send as a broadcast" {
    run grep -c "Never describe a directed message as" "${BATS_TEST_DIRNAME}/../../commands/formation.md"
    [ "$output" -ge 1 ]
}
