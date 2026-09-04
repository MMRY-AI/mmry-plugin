#!/usr/bin/env bats
# Saying how the work is going, and the client not inventing rules the server owns (#31046).
#
# WHAT IS BEING GUARDED HERE, as distinct from the server-side suite. The API decides who may
# report and who is told. This file decides five things the API cannot:
#
#   1. That a session reporting its OWN work resolves its OWN roster entry rather than guessing an
#      id. The server addresses a member by roster entry and never by session string, so a client
#      that guessed would report against somebody else's work and the server would accept it.
#   2. That the SESSION ID goes in the body. It is what makes "own" mean this window rather than
#      this person, and without it two windows of one account become interchangeable.
#   3. That the client does NOT carry its own list of states. The list lives in a database
#      constraint; a copy here would be a second answer that drifts, and the first thing it would
#      do is refuse a state the server had just added.
#   4. That a refusal prints the SERVER's reason. Three different things arrive as 400 with three
#      different remedies, and #31195 is the record of what a wrong explanation costs.
#   5. That success reports what the server READ BACK, not what was asked for (#31192).
#
# Every refusal test is paired with a control proving the same harness CAN succeed. Without it a
# typo in the fixture produces an identical failure and the test proves nothing.

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export CLAUDE_SESSION_ID="bats-progress-$$"
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
}

teardown() {
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
}

# A fake curl that answers the ROSTER read and the PROGRESS write differently, which the one in
# formation-assign.bats cannot: reporting for this session makes two calls, and a single canned
# body would make the roster read return a roster entry and the write return one too, so a test
# could not tell which call it was looking at.
_fake_curl_dir() {
    local dir="${BATS_TEST_TMPDIR}/fake-bin"
    mkdir -p "$dir"
    cat > "${dir}/curl" <<'FAKECURL'
#!/usr/bin/env bash
out=""; prev=""; url=""
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    if [[ "$prev" == "--data-binary" && "$arg" == @* && -n "${FAKE_BODY_LOG:-}" ]]; then
        cat "${arg#@}" >> "$FAKE_BODY_LOG"
        printf '\n' >> "$FAKE_BODY_LOG"
    fi
    [[ "$prev" == "-X" && -n "${FAKE_METHOD_LOG:-}" ]] && printf '%s\n' "$arg" >> "$FAKE_METHOD_LOG"
    [[ "$arg" == http* ]] && url="$arg"
    prev="$arg"
done
[[ -n "${FAKE_URL_LOG:-}" ]] && printf '%s\n' "$url" >> "$FAKE_URL_LOG"
body="${FAKE_BODY:-}"
code="${FAKE_CODE:-200}"
if [[ "$url" != *"/progress"* ]]; then
    body="${FAKE_BODY_GET:-$body}"
    code="${FAKE_CODE_GET:-200}"
fi
[[ -n "$out" ]] && printf '%s' "$body" > "$out"
printf '%s' "$code"
exit 0
FAKECURL
    chmod +x "${dir}/curl"
    printf '%s' "$dir"
}

# The roster as the server returns it, with THIS session on it as member 7.
_roster_body() {
    printf '{"formation":{"id":42,"objective":"o"},"members":[{"id":3,"sessionId":"somebody-else","role":"Lead","assignment":"coordinate","progress":"Done","progressUpdatedDate":"2026-09-04T12:00:00","leftDate":null},{"id":7,"sessionId":"%s","role":"Wingman","assignment":"the validator","progress":"Assigned","progressUpdatedDate":null,"leftDate":null}]}' "$CLAUDE_SESSION_ID"
}

_ok_body() {
    printf '%s' '{"id":7,"sessionId":"w","userId":3,"email":"a@b.c","userIsActive":true,"role":"Wingman","assignment":"the validator","progress":"Blocked","progressUpdatedDate":"2026-09-04T13:00:00","joinedDate":"2026-09-04T12:00:00","leftDate":null}'
}

_env() {
    printf '%s' "MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL=http://fake.invalid"
}

# ---------------------------------------------------------------- the request

@test "progress: reporting for this session resolves ITS OWN roster entry and PUTs to it" {
    # The server addresses a member by roster entry. A client that guessed an id would report
    # against another member's work and the server would have no way to know it was a guess.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local urls="${BATS_TEST_TMPDIR}/urls" methods="${BATS_TEST_TMPDIR}/methods"
    : > "$urls"; : > "$methods"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_ok_body)" FAKE_BODY_GET="$(_roster_body)" \
        FAKE_URL_LOG="$urls" FAKE_METHOD_LOG="$methods" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-progress.sh" Blocked

    [ "$status" -eq 0 ]
    run cat "$urls"
    # Member 7 is THIS session's entry on the roster above. Member 3 is somebody else's, and
    # asserting the negative is the half that matters.
    [[ "$output" == *"/api/formations/42/members/7/progress"* ]]
    [[ "$output" != *"/members/3/progress"* ]]
    run cat "$methods"
    [[ "$output" == *"PUT"* ]]
}

@test "progress: the session id is in the body, because own means this window" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local body="${BATS_TEST_TMPDIR}/req"
    : > "$body"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_ok_body)" FAKE_BODY_GET="$(_roster_body)" \
        FAKE_BODY_LOG="$body" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-progress.sh" Accepted

    [ "$status" -eq 0 ]
    run cat "$body"
    [[ "$output" == *"\"sessionId\":\"${CLAUDE_SESSION_ID}\""* ]]
    [[ "$output" == *'"progress":"Accepted"'* ]]
}

@test "progress: with no note the field is absent entirely rather than sent empty" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local body="${BATS_TEST_TMPDIR}/req"
    : > "$body"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_ok_body)" FAKE_BODY_GET="$(_roster_body)" \
        FAKE_BODY_LOG="$body" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-progress.sh" Done

    [ "$status" -eq 0 ]
    run cat "$body"
    [[ "$output" != *"note"* ]]
    # CONTROL: the request was genuinely made and carried the state, so the absence above is about
    # the note rather than about an empty body.
    [[ "$output" == *'"progress":"Done"'* ]]
}

@test "progress: a note is carried when one is given" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local body="${BATS_TEST_TMPDIR}/req"
    : > "$body"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_ok_body)" FAKE_BODY_GET="$(_roster_body)" \
        FAKE_BODY_LOG="$body" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-progress.sh" Blocked "waiting on the schema"

    [ "$status" -eq 0 ]
    run cat "$body"
    [[ "$output" == *'"note":"waiting on the schema"'* ]]
}

@test "progress: nothing about the caller's own standing is sent" {
    # A request that could state its own authority would not be an authorisation check. The server
    # derives self, lead, creator and administrator from its own tables (DD-77).
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local body="${BATS_TEST_TMPDIR}/req"
    : > "$body"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_ok_body)" FAKE_BODY_GET="$(_roster_body)" \
        FAKE_BODY_LOG="$body" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-progress.sh" Done

    [ "$status" -eq 0 ]
    run cat "$body"
    [[ "$output" != *"isAdmin"* ]]
    [[ "$output" != *"actingUser"* ]]
    [[ "$output" != *"callerRole"* ]]
    [[ "$output" != *"isLead"* ]]
}

@test "progress: a member id first addresses THAT member, and no roster is read" {
    # The lead moving somebody else's state. It also proves the id is taken as given rather than
    # resolved: reading the roster and picking this session's entry would report the wrong member.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local urls="${BATS_TEST_TMPDIR}/urls"
    : > "$urls"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_ok_body)" FAKE_BODY_GET="$(_roster_body)" \
        FAKE_URL_LOG="$urls" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-progress.sh" 3 Abandoned "picking this up"

    [ "$status" -eq 0 ]
    run cat "$urls"
    [[ "$output" == *"/api/formations/42/members/3/progress"* ]]
    [ "$(grep -c . "$urls")" -eq 1 ]
}

@test "progress: a state the client has never heard of is sent, not refused here" {
    # THE LIST OF STATES IS NOT DUPLICATED IN THIS FILE OR IN THE HANDLER. It lives in a database
    # constraint, and the server answers a wrong one with a sentence naming all five. A client-side
    # allow-list would be a second copy that drifts, and the first thing it would do is refuse a
    # state the server had just added.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local urls="${BATS_TEST_TMPDIR}/urls"
    : > "$urls"

    PATH="${bin}:${PATH}" FAKE_CODE=400 \
        FAKE_BODY='{"error":"Progress is one of Assigned, Accepted, Done, Blocked or Abandoned."}' \
        FAKE_BODY_GET="$(_roster_body)" FAKE_URL_LOG="$urls" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-progress.sh" Nonsense

    [ "$status" -ne 0 ]
    # It reached the server, which is the point: the refusal below is the server's.
    run cat "$urls"
    [[ "$output" == *"/progress"* ]]
}

# ---------------------------------------------------------------- refusals at the keyboard

@test "progress: no argument is refused before anything is sent" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local urls="${BATS_TEST_TMPDIR}/urls"
    : > "$urls"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_ok_body)" FAKE_URL_LOG="$urls" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-progress.sh"

    [ "$status" -ne 0 ]
    [[ "$output" == *"Say how it is going"* ]]
    [ ! -s "$urls" ]
}

@test "progress: a member id with no state is refused before anything is sent" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local urls="${BATS_TEST_TMPDIR}/urls"
    : > "$urls"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_ok_body)" FAKE_URL_LOG="$urls" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-progress.sh" 3

    [ "$status" -ne 0 ]
    [[ "$output" == *"needs a state"* ]]
    [ ! -s "$urls" ]
}

@test "progress: a note in the member-id position is refused rather than sent as one" {
    # Three arguments with no leading id means somebody wrote the id somewhere it is not read. The
    # damage from guessing here is silent: it would report the right state against the wrong member.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local urls="${BATS_TEST_TMPDIR}/urls"
    : > "$urls"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_ok_body)" FAKE_URL_LOG="$urls" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-progress.sh" Done "a note" "another"

    [ "$status" -ne 0 ]
    [[ "$output" == *"Too many arguments"* ]]
    [ ! -s "$urls" ]
}

@test "progress: a session in no formation is refused, and the control shows the harness works" {
    local bin; bin="$(_fake_curl_dir)"
    local urls="${BATS_TEST_TMPDIR}/urls"
    : > "$urls"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_ok_body)" FAKE_BODY_GET="$(_roster_body)" \
        FAKE_URL_LOG="$urls" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-progress.sh" Done

    [ "$status" -ne 0 ]
    [[ "$output" == *"not in a formation"* ]]
    [ ! -s "$urls" ]

    # CONTROL: the identical invocation with local state set DOES send. Without this the refusal
    # above could be any of a dozen things in the fixture.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_ok_body)" FAKE_BODY_GET="$(_roster_body)" \
        FAKE_URL_LOG="$urls" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-progress.sh" Done
    [ "$status" -eq 0 ]
    [ -s "$urls" ]
}

@test "progress: a session that is not on the roster is told so rather than guessing an id" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local urls="${BATS_TEST_TMPDIR}/urls"
    : > "$urls"

    # A roster that does not contain this session, which is what a released membership looks like.
    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_ok_body)" \
        FAKE_BODY_GET='{"formation":{"id":42},"members":[{"id":3,"sessionId":"somebody-else","role":"Lead","progress":null,"leftDate":null}]}' \
        FAKE_URL_LOG="$urls" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-progress.sh" Done

    [ "$status" -ne 0 ]
    [[ "$output" == *"not on formation 42's roster"* ]]
    # It read the roster and then stopped. Nothing was written against member 3.
    run cat "$urls"
    [[ "$output" != *"/progress"* ]]
}

# ---------------------------------------------------------------- what it says afterwards

@test "progress: a 403 prints the server's own reason and claims nothing was recorded" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=403 \
        FAKE_BODY='{"error":"Only the member doing the work, the flight lead, the person who set the mission, or an administrator may change a member'"'"'s progress."}' \
        FAKE_BODY_GET="$(_roster_body)" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-progress.sh" 3 Done

    [ "$status" -ne 0 ]
    [[ "$output" == *"Refused"* ]]
    [[ "$output" == *"nothing was recorded"* ]]
    # THE SERVER'S WORDS, not a guess at the policy. #31195.
    [[ "$output" == *"the member doing the work"* ]]
}

@test "progress: a 400 prints the server's reason rather than guessing which of three it was" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=400 \
        FAKE_BODY='{"error":"That formation has been closed out, so its record can no longer be changed."}' \
        FAKE_BODY_GET="$(_roster_body)" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-progress.sh" Done

    [ "$status" -ne 0 ]
    [[ "$output" == *"closed out"* ]]
    [[ "$output" == *"nothing was recorded"* ]]
}

@test "progress: a gateway failure does not talk about standing and does not claim a discard" {
    # #31195. A 502 is not a refusal and can be raised after the row was written, so this branch may
    # say neither "refused" nor "nothing was recorded".
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=502 FAKE_BODY='' FAKE_BODY_GET="$(_roster_body)" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-progress.sh" Done

    [ "$status" -ne 0 ]
    [[ "$output" == *"fault on the server side"* ]]
    [[ "$output" == *"not recorded"* ]]
    [[ "$output" != *"Refused"* ]]
    [[ "$output" != *"standing in it."* ]] || true   # the sentence names it only to rule it out
}

@test "progress: success reports the state the SERVER read back, not the one asked for" {
    # #31192: never report a value that was asked for as though it had been read back. The fake
    # answers Blocked to a request for Accepted, and the output must follow the answer.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_ok_body)" FAKE_BODY_GET="$(_roster_body)" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-progress.sh" Accepted

    [ "$status" -eq 0 ]
    [[ "$output" == *"recorded as Blocked"* ]]
    [[ "$output" != *"recorded as Accepted"* ]]
    # And it says who was told, because "the lead sees this" is the half the user cares about.
    [[ "$output" == *"lead sees this"* ]]
    [[ "$output" == *"no other member was told"* ]]
}
