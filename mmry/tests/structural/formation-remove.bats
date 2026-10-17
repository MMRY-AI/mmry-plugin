#!/usr/bin/env bats
# The lead or an administrator removes a member whose session has dropped (#32270).
#
# WHAT IS BEING GUARDED HERE, as distinct from the server-side suite. The API decides who may
# remove and what a removed member experiences. This file decides what the client can get wrong:
#
#   1. The member is named in the URL by ROSTER ENTRY and the verb is DELETE, with nothing in a
#      body that could claim standing (DD-77).
#   2. A wrong id is refused at the keyboard rather than turned into a request.
#   3. The lead is told what NOW STANDS, read from the entry the server returned (who removed it and
#      when), never what was asked for.
#   4. A refusal prints the SERVER's reason (#31195), and an unconfirmed failure claims nothing.
#   5. When the entry removed turns out to be THIS session's own, the local formation state is
#      cleared, exactly as leaving does, so this session stops listening to a group it is not in.
#   6. The roster marks a removed member as removed, with who removed it, and not as merely gone.
#
# Every refusal test is paired with a control proving the same setup CAN succeed (formation-say.bats).

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export CLAUDE_SESSION_ID="bats-remove-$$"
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
    if [[ "$prev" == "--data-binary" && -n "${FAKE_BODY_LOG:-}" ]]; then
        if [[ "$arg" == @* ]]; then cat "${arg#@}" >> "$FAKE_BODY_LOG"; else printf '%s' "$arg" >> "$FAKE_BODY_LOG"; fi
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

# The entry as the server returns it after a removal by somebody else: sessionId is null because
# the entry is not the caller's (#31235).
_removed_body() {
    printf '%s' '{"id":156,"sessionId":null,"userId":3,"email":"mac@example.com","userIsActive":true,"role":"Wingman","assignment":"port the Mac build","progress":"Abandoned","joinedDate":"2026-10-16T01:00:00","leftDate":"2026-10-16T02:14:33.1234567","removedByUserId":1,"removedByEmail":"lead@example.com"}'
}

_run_remove() {
    PATH="${bin}:${PATH}" MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-remove.sh" "$@"
}

# ---------------------------------------------------------------- the request

@test "remove: the member is addressed in the URL by roster entry, with DELETE and no body" {
    bash "${HANDLERS}/formation-state.sh" set 45 "$CLAUDE_SESSION_ID"
    bin="$(_fake_curl_dir)"
    local urls="${BATS_TEST_TMPDIR}/urls" methods="${BATS_TEST_TMPDIR}/methods" body="${BATS_TEST_TMPDIR}/body"
    : > "$urls"; : > "$methods"; : > "$body"

    FAKE_CODE=200 FAKE_BODY="$(_removed_body)" FAKE_URL_LOG="$urls" FAKE_METHOD_LOG="$methods" FAKE_BODY_LOG="$body" \
        _run_remove 156

    [ "$status" -eq 0 ]
    run cat "$urls"
    [[ "$output" == *"/api/formations/45/members/156"* ]] || return 1
    run cat "$methods"
    [[ "$output" == *"DELETE"* ]] || return 1
    # Nothing about the caller's standing is sent, because nothing at all is sent (DD-77).
    [ ! -s "$body" ]
}

@test "remove: a formation id given after the member is used instead of this session's" {
    # An administrator who never joined has no local formation; it names the one it means.
    bin="$(_fake_curl_dir)"
    local urls="${BATS_TEST_TMPDIR}/urls"
    : > "$urls"

    FAKE_CODE=200 FAKE_BODY="$(_removed_body)" FAKE_URL_LOG="$urls" _run_remove 156 45

    [ "$status" -eq 0 ]
    run cat "$urls"
    [[ "$output" == *"/api/formations/45/members/156"* ]] || return 1
}

# ---------------------------------------------------------------- the report

@test "remove: success reports who removed the member and when, read back from the server" {
    bash "${HANDLERS}/formation-state.sh" set 45 "$CLAUDE_SESSION_ID"
    bin="$(_fake_curl_dir)"

    FAKE_CODE=200 FAKE_BODY="$(_removed_body)" _run_remove 156

    [ "$status" -eq 0 ]
    [[ "$output" == *"Member 156"* ]] || return 1
    [[ "$output" == *"formation 45"* ]] || return 1
    [[ "$output" == *"lead@example.com"* ]] || return 1
    [[ "$output" == *"2026-10-16 02:14 UTC"* ]] || return 1
    # What the removed member now experiences, and that nobody else was touched.
    [[ "$output" == *"receives nothing further"* ]] || return 1
    [[ "$output" == *"refused"* ]] || return 1
    [[ "$output" == *"other windows"* ]] || return 1
    # This session's own state is untouched: it removed somebody else.
    run bash "${HANDLERS}/formation-state.sh" get "$CLAUDE_SESSION_ID"
    [[ "$output" == 45* ]] || return 1
}

@test "remove: when the entry removed is this session's own, local state is cleared as leaving does" {
    bash "${HANDLERS}/formation-state.sh" set 45 "$CLAUDE_SESSION_ID"
    bin="$(_fake_curl_dir)"
    local own
    own="$(_removed_body | sed "s/\"sessionId\":null/\"sessionId\":\"${CLAUDE_SESSION_ID}\"/")"

    FAKE_CODE=200 FAKE_BODY="$own" _run_remove 156

    [ "$status" -eq 0 ]
    [[ "$output" == *"this session's own place"* ]] || return 1
    run bash "${HANDLERS}/formation-state.sh" get "$CLAUDE_SESSION_ID"
    [ -z "$output" ]
}

# ---------------------------------------------------------------- refusals at the keyboard

@test "remove: no member id is refused before anything is sent" {
    bash "${HANDLERS}/formation-state.sh" set 45 "$CLAUDE_SESSION_ID"
    bin="$(_fake_curl_dir)"
    local calls="${BATS_TEST_TMPDIR}/urls"; : > "$calls"

    FAKE_CODE=200 FAKE_BODY="$(_removed_body)" FAKE_URL_LOG="$calls" _run_remove

    [ "$status" -ne 0 ]
    [[ "$output" == *"Which member"* ]] || return 1
    [ ! -s "$calls" ]
}

@test "remove: a non-numeric member id is refused before anything is sent" {
    bash "${HANDLERS}/formation-state.sh" set 45 "$CLAUDE_SESSION_ID"
    bin="$(_fake_curl_dir)"
    local calls="${BATS_TEST_TMPDIR}/urls"; : > "$calls"

    FAKE_CODE=200 FAKE_BODY="$(_removed_body)" FAKE_URL_LOG="$calls" _run_remove "the-mac-one"

    [ "$status" -ne 0 ]
    [[ "$output" == *"positive whole number"* ]] || return 1
    [ ! -s "$calls" ]
}

@test "remove: with no formation here and none named, nothing is sent and the user is told how to name one" {
    bin="$(_fake_curl_dir)"
    local calls="${BATS_TEST_TMPDIR}/urls"; : > "$calls"

    FAKE_CODE=200 FAKE_BODY="$(_removed_body)" FAKE_URL_LOG="$calls" _run_remove 156

    [ "$status" -ne 0 ]
    [[ "$output" == *"not in a formation"* ]] || return 1
    [ ! -s "$calls" ]
}

# ---------------------------------------------------------------- refusals from the server

@test "remove: a 403 prints the server's own reason and claims nothing was changed" {
    bash "${HANDLERS}/formation-state.sh" set 45 "$CLAUDE_SESSION_ID"
    bin="$(_fake_curl_dir)"
    local refusal='{"error":"Only the flight lead, the person who set the mission, or an administrator may remove a member from a formation."}'

    FAKE_CODE=403 FAKE_BODY="$refusal" _run_remove 156

    [ "$status" -ne 0 ]
    [[ "$output" == *"flight lead"* ]] || return 1
    [[ "$output" == *"nobody was removed"* ]] || return 1
}

@test "remove: a 400 prints the server's reason rather than guessing" {
    bash "${HANDLERS}/formation-state.sh" set 45 "$CLAUDE_SESSION_ID"
    bin="$(_fake_curl_dir)"
    local refusal='{"error":"That member has already left the formation, so there is nobody to remove."}'

    FAKE_CODE=400 FAKE_BODY="$refusal" _run_remove 156

    [ "$status" -ne 0 ]
    [[ "$output" == *"already left the formation"* ]] || return 1
}

@test "remove: a 404 says the formation is gone or not this account's, and nothing more" {
    bash "${HANDLERS}/formation-state.sh" set 45 "$CLAUDE_SESSION_ID"
    bin="$(_fake_curl_dir)"

    FAKE_CODE=404 FAKE_BODY='{"error":"Resource not found"}' _run_remove 156

    [ "$status" -ne 0 ]
    [[ "$output" == *"Formation 45"* ]] || return 1
    [[ "$output" != *"flight lead"* ]] || return 1
}

@test "remove: a gateway failure is reported as unconfirmed, not as a refusal (#31195)" {
    bash "${HANDLERS}/formation-state.sh" set 45 "$CLAUDE_SESSION_ID"
    bin="$(_fake_curl_dir)"

    FAKE_CODE=502 FAKE_BODY='' _run_remove 156

    [ "$status" -ne 0 ]
    [[ "$output" == *"did not confirm"* ]] || return 1
    [[ "$output" != *"flight lead"* ]] || return 1
    # And it does not clear this session's own state on a failure it cannot read.
    run bash "${HANDLERS}/formation-state.sh" get "$CLAUDE_SESSION_ID"
    [[ "$output" == 45* ]] || return 1
}

# ---------------------------------------------------------------- the roster

@test "roster: a removed member is marked removed, with who removed it; one that left is not" {
    bash "${HANDLERS}/formation-state.sh" set 45 "$CLAUDE_SESSION_ID"
    bin="$(_fake_curl_dir)"
    local roster='{"formation":{"id":45,"objective":"ship the Mac build"},"members":[{"id":150,"sessionId":"s1","role":"Lead","email":"lead@example.com","leftDate":null},{"id":156,"sessionId":null,"role":"Wingman","email":"mac@example.com","leftDate":"2026-10-16T02:14:33","removedByUserId":1,"removedByEmail":"lead@example.com"},{"id":157,"sessionId":null,"role":"Wingman","email":"gone@example.com","leftDate":"2026-10-16T03:00:00","removedByUserId":null,"removedByEmail":null}]}'

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$roster" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-roster.sh"

    [ "$status" -eq 0 ]
    local removed left
    removed="$(printf '%s\n' "$output" | grep 'mac@example.com')"
    left="$(printf '%s\n' "$output" | grep 'gone@example.com')"
    [[ "$removed" == *"removed by lead@example.com; cannot be addressed"* ]] || return 1
    [[ "$left" == *"has left; cannot be addressed"* ]] || return 1
    [[ "$left" != *"removed"* ]] || return 1
}
