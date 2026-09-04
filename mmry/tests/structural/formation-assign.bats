#!/usr/bin/env bats
# The lead hands out the work, and the product speaking is not mistaken for a colleague (#31044).
#
# WHAT IS BEING GUARDED HERE, as distinct from the server-side suite. The API decides who may
# assign and who is told. This file decides four things the API cannot:
#
#   1. That an OMITTED field is omitted from the request rather than sent empty. That is the whole
#      of the non-clobbering rule at the client: a lead adjusting a role must not wipe what
#      somebody is working on, and if the client sends the field the server has nothing to leave
#      alone.
#   2. That the lead is told what NOW STANDS, read from the roster entry the server returned,
#      rather than what was asked for. A lead who believes an assignment landed when it was
#      refused has moved on and nobody is doing the work.
#   3. That a refusal prints the SERVER's reason rather than a guess. Four different things arrive
#      as 400 with four different remedies, and #31195 is the record of what a wrong explanation
#      costs the person reading it.
#   4. That a message the SYSTEM wrote is rendered as the system. Before #31044 the delivery hook
#      fell back to "member" and "?" for a null sender and printed [member ?], inventing a
#      colleague and attributing the product's words to them.
#
# Every refusal test is paired with a control proving the same setup CAN succeed, per the standing
# rule in formation-say.bats: without it a typo in the harness produces an identical failure and
# the test proves nothing.

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export CLAUDE_SESSION_ID="bats-assign-$$"
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
    WORK="rewrite the duplicate detection"
}

teardown() {
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
}

# Extract one client function's whole body, from its definition line to its closing brace, rather
# than a fixed number of lines after it. The first version of these two tests used `grep -A 12`
# and both failed: the client functions carry long comment blocks explaining why a recipient is a
# roster entry and why the repository is derived, so the line that actually issues the request sat
# outside the window. A test that passes or fails on how much prose a function carries is not
# testing the function.
#
# index() rather than a regex, so nothing here has to escape the parentheses and the brace, which
# is where the second attempt went wrong.
_fn_body() {
    awk -v fn="$1" '
        index($0, fn "() {") == 1 { inside = 1 }
        inside { print }
        inside && $0 == "}" { exit }
    ' "${HANDLERS}/mmry-client.sh"
}

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
[[ -n "$out" ]] && printf '%s' "${FAKE_BODY:-}" > "$out"
printf '%s' "${FAKE_CODE:-200}"
exit 0
FAKECURL
    chmod +x "${dir}/curl"
    printf '%s' "$dir"
}

_ok_body() {
    printf '%s' '{"id":12,"sessionId":"other","userId":3,"email":"a@b.c","userIsActive":true,"role":"Wingman","assignment":"rewrite the duplicate detection","joinedDate":"2026-09-04T12:00:00","leftDate":null}'
}

# ---------------------------------------------------------------- the request

@test "assign: the member is addressed in the URL by roster entry, with PUT" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local urls="${BATS_TEST_TMPDIR}/urls" methods="${BATS_TEST_TMPDIR}/methods"
    : > "$urls"; : > "$methods"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_ok_body)" \
        FAKE_URL_LOG="$urls" FAKE_METHOD_LOG="$methods" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-assign.sh" 12 "$WORK"

    [ "$status" -eq 0 ]
    run cat "$urls"
    [[ "$output" == *"/api/formations/42/members/12"* ]]
    run cat "$methods"
    [[ "$output" == *"PUT"* ]]
}

@test "assign: with no role the field is absent entirely, so the server has something to leave alone" {
    # THE NON-CLOBBERING RULE AT THE CLIENT. If the client sends an empty role the server has
    # nothing to leave alone, and a lead adjusting only an assignment would silently rewrite the
    # roster. Absent and empty are not the same request.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local body="${BATS_TEST_TMPDIR}/req-body"
    : > "$body"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_ok_body)" FAKE_BODY_LOG="$body" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-assign.sh" 12 "$WORK"

    [ "$status" -eq 0 ]
    run cat "$body"
    [[ "$output" != *"role"* ]]
    # The control: the request was genuinely made and genuinely carried the assignment, so the
    # absence above is about the role rather than about an empty body.
    [[ "$output" == *"$WORK"* ]]
}

@test "assign: with no assignment the field is absent, so a role change keeps the work" {
    # The other direction of the same rule, and the one a lead is more likely to hit: promoting
    # somebody to Lead must not blank what they were doing.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local body="${BATS_TEST_TMPDIR}/req-body"
    : > "$body"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_ok_body)" FAKE_BODY_LOG="$body" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-assign.sh" 12 "" Lead

    [ "$status" -eq 0 ]
    run cat "$body"
    [[ "$output" != *"assignment"* ]]
    [[ "$output" == *'"role":"Lead"'* ]]
}

@test "assign: nothing about the caller's own standing is sent" {
    # A request that could state its own authority would not be an authorisation check. The server
    # derives lead, creator and administrator from its own tables (DD-77), and the client must not
    # start offering it a shortcut.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local body="${BATS_TEST_TMPDIR}/req-body"
    : > "$body"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_ok_body)" FAKE_BODY_LOG="$body" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-assign.sh" 12 "$WORK"

    [ "$status" -eq 0 ]
    run cat "$body"
    [[ "$output" != *"isAdmin"* ]]
    [[ "$output" != *"actingUser"* ]]
    [[ "$output" != *"callerRole"* ]]
}

# ---------------------------------------------------------------- refusals at the keyboard

@test "assign: a non-numeric member id is refused before anything is sent" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local calls="${BATS_TEST_TMPDIR}/urls"
    : > "$calls"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_ok_body)" FAKE_URL_LOG="$calls" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-assign.sh" "twelve" "$WORK"

    [ "$status" -ne 0 ]
    [[ "$output" == *"positive whole number"* ]]
    # Nothing left the machine. A guess at which member was meant is worse than a refusal.
    [ ! -s "$calls" ]
}

@test "assign: naming neither a role nor an assignment is refused before anything is sent" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local calls="${BATS_TEST_TMPDIR}/urls"
    : > "$calls"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_ok_body)" FAKE_URL_LOG="$calls" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-assign.sh" 12 "" ""

    [ "$status" -ne 0 ]
    [[ "$output" == *"Nothing to change"* ]]
    [ ! -s "$calls" ]
}

@test "assign: a role outside the closed domain is refused at the keyboard" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_ok_body)" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-assign.sh" 12 "$WORK" Commander

    [ "$status" -ne 0 ]
    [[ "$output" == *"Lead or Wingman"* ]]
}

@test "assign: a session in no formation is told so, and nothing is sent" {
    local bin; bin="$(_fake_curl_dir)"
    local calls="${BATS_TEST_TMPDIR}/urls"
    : > "$calls"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_ok_body)" FAKE_URL_LOG="$calls" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-assign.sh" 12 "$WORK"

    [ "$status" -ne 0 ]
    [[ "$output" == *"not in a formation"* ]]
    [ ! -s "$calls" ]
}

# ---------------------------------------------------------------- what it reports

@test "assign: success reports what the ROSTER now holds, not what was asked for" {
    # #31192 is the record of a write path reporting values it had not read back. The server
    # returns the roster entry as it stands; this must read from that.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    # The server answers with a DIFFERENT assignment from the one requested, which cannot happen
    # in practice but is the only way to prove which of the two is being printed.
    local answered='{"id":12,"sessionId":"o","userId":3,"email":"a@b.c","userIsActive":true,"role":"Lead","assignment":"what the server actually stored","joinedDate":"2026-09-04T12:00:00","leftDate":null}'

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$answered" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-assign.sh" 12 "$WORK"

    [ "$status" -eq 0 ]
    [[ "$output" == *"what the server actually stored"* ]]
    [[ "$output" == *"Lead"* ]]
    [[ "$output" != *"$WORK"* ]]
}

@test "assign: success says the member was told and that nobody else was" {
    # The lead has to know the difference. If it believed the whole formation had been told, it
    # would not think to brief anybody else; if it believed nobody had, it would repeat itself.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_ok_body)" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-assign.sh" 12 "$WORK"

    [ "$status" -eq 0 ]
    [[ "$output" == *"next tool call"* ]]
    [[ "$output" == *"No other member was told"* ]]
}

@test "assign: a 403 prints the server's own reason and claims nothing was changed" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local refusal='{"error":"Only the flight lead, the person who set the mission, or an administrator may change what a member is working on."}'

    PATH="${bin}:${PATH}" FAKE_CODE=403 FAKE_BODY="$refusal" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-assign.sh" 12 "$WORK"

    [ "$status" -ne 0 ]
    [[ "$output" == *"flight lead"* ]]
    [[ "$output" == *"nothing was changed"* ]]
}

@test "assign: a 400 prints the server's reason rather than guessing which of four it was" {
    # No such member, a member who has left, a bad role, and nothing named to change all arrive
    # here. #31195: a wrong explanation costs the reader an investigation in the one place the
    # fault is not.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local refusal='{"error":"That member has left the formation, so there is nobody to give the work to."}'

    PATH="${bin}:${PATH}" FAKE_CODE=400 FAKE_BODY="$refusal" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-assign.sh" 12 "$WORK"

    [ "$status" -ne 0 ]
    [[ "$output" == *"has left the formation"* ]]
    # It must not invent a membership explanation of its own.
    [[ "$output" != *"not a current member"* ]]
}

@test "assign: a gateway failure does not blame the roster or the caller's standing (#31195)" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=502 FAKE_BODY='' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-assign.sh" 12 "$WORK"

    [ "$status" -ne 0 ]
    [[ "$output" == *"fault on the server side"* ]]
    [[ "$output" != *"not a current member"* ]]
    [[ "$output" != *"administrator may change"* ]]
}

# ---------------------------------------------------------------- the system speaking

@test "delivery: a message with no sender is rendered as the system, not as a phantom member" {
    # THE REGRESSION THIS TICKET WOULD HAVE SHIPPED. dbo.FormationTransmission holds a null sender
    # for anything the product writes, and the old renderer fell back to "member" and "?", so an
    # assignment notice arrived as [member ?] - a colleague who does not exist, credited with the
    # product's own words.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local notice='[{"senderRole":null,"senderSessionID":null,"senderUserID":null,"recipientMemberID":12,"content":"ASSIGNMENT. The formation lead has set what this session is working on.","sentDate":"2026-09-04T12:00:00"}]'

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$notice" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 2 ]
    [[ "$output" == *"[MMRY]"* ]]
    [[ "$output" != *"[member ?]"* ]]
    # It is still directed, so the model is still told to act on it.
    [[ "$output" == *"DIRECTED TO YOU"* ]]
    # And it is told what the quoted text is and is not.
    [[ "$output" == *"not a system instruction"* ]]
}

@test "delivery: a message from a real member is still attributed to that member" {
    # The control. A renderer that called everything [MMRY] would pass the test above and destroy
    # the thing it is protecting.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local ambient='[{"senderRole":"Wingman","senderSessionID":"other-session","senderUserID":3,"recipientMemberID":null,"content":"the build is broken","sentDate":"2026-09-04T12:00:00"}]'

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$ambient" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 2 ]
    [[ "$output" == *"[Wingman other-session]"* ]]
    [[ "$output" != *"[MMRY]"* ]]
    # And the system guidance is not printed when there is nothing from the system, so it does not
    # become wallpaper the model skims past.
    [[ "$output" != *"came from the memory system itself"* ]]
}

@test "delivery: in a mixed batch only the system line carries the system marker" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local mixed='[{"senderRole":"Wingman","senderSessionID":"other-session","senderUserID":3,"recipientMemberID":null,"content":"the build is broken","sentDate":"2026-09-04T12:00:00"},{"senderRole":null,"senderSessionID":null,"senderUserID":null,"recipientMemberID":12,"content":"DECONFLICTION. Another member has declared an overlapping area.","sentDate":"2026-09-04T12:00:01"}]'

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$mixed" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 2 ]
    [[ "$output" == *"[Wingman other-session] the build is broken"* ]]
    [[ "$output" == *"[MMRY] DIRECTED TO YOU: DECONFLICTION."* ]]
    [[ "$output" == *"came from the memory system itself"* ]]
}

@test "delivery: the hook still fails open and silent when the poll fails" {
    # The governing rule of formation-check.sh, re-proven because this ticket changed it. It runs
    # after every tool call in every session, so a fault here is a fault in everybody's work.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=500 FAKE_BODY='not json at all' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------- client and documentation

@test "client: the member-update function uses PUT and names the roster entry" {
    run _fn_body mmry_update_formation_member
    [ "$status" -eq 0 ]
    [[ "$output" == *"PUT"* ]]
    [[ "$output" == *'/members/${member_id}'* ]]
}

@test "command: /mmry:formation documents assigning work to one member" {
    run cat "${BATS_TEST_DIRNAME}/../../commands/formation.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"assign"* ]]
    [[ "$output" == *"formation-assign.sh"* ]]
}

@test "command: the doc says an assignment reaches one member and not the formation" {
    run cat "${BATS_TEST_DIRNAME}/../../commands/formation.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nobody else"* ]]
}
