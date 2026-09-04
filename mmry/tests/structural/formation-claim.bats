#!/usr/bin/env bats
# Declaring an area, so two members are warned before they collide (#31044).
#
# WHAT IS BEING GUARDED HERE, as distinct from the server-side suite. The API decides what
# overlaps and who is warned. This file decides four things the API cannot:
#
#   1. That the repository is DERIVED rather than typed. Two members who spell one repository
#      differently are never warned about each other, and nothing anywhere detects that they have
#      not been. The git root is the value every session on the same checkout agrees on.
#   2. That the client NEVER computes overlap itself. The predicate exists once, in the procedure
#      (DD-78); a copy here would be a second answer that can drift from the one the warnings were
#      built on, which is what #31192 was, twice.
#   3. That a re-declaration is reported as having told NOBODY. The server deliberately does not
#      warn twice, and a caller that reported "both sides warned" on a repeat would leave a member
#      believing somebody had been told when they had not.
#   4. That the report does not overclaim. An overlap is two declared paths overlapping as text.
#      It is not two people editing one file, and nothing was blocked.
#
# Every refusal test is paired with a control proving the same setup CAN succeed.

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export CLAUDE_SESSION_ID="bats-claim-$$"
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
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

_no_overlap() {
    printf '%s' '{"claim":{"claimId":5,"formationId":42,"memberId":7,"repository":"mmry","pathPrefix":"src/Billing","claimedDate":"2026-09-04T12:00:00"},"isNew":true,"overlaps":[]}'
}

_one_overlap() {
    printf '%s' '{"claim":{"claimId":5,"formationId":42,"memberId":7,"repository":"mmry","pathPrefix":"src/Billing","claimedDate":"2026-09-04T12:00:00"},"isNew":true,"overlaps":[{"otherClaimId":3,"otherMemberId":9,"otherRepository":"mmry","otherPathPrefix":"src/Billing/Invoices.cs"}]}'
}

_repeat_with_overlap() {
    printf '%s' '{"claim":{"claimId":5,"formationId":42,"memberId":7,"repository":"mmry","pathPrefix":"src/Billing","claimedDate":"2026-09-04T12:00:00"},"isNew":false,"overlaps":[{"otherClaimId":3,"otherMemberId":9,"otherRepository":"mmry","otherPathPrefix":"src/Billing/Invoices.cs"}]}'
}

# ---------------------------------------------------------------- the request

@test "claim: the area is posted to the formation's claims route" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local urls="${BATS_TEST_TMPDIR}/urls" body="${BATS_TEST_TMPDIR}/req"
    : > "$urls"; : > "$body"

    PATH="${bin}:${PATH}" FAKE_CODE=201 FAKE_BODY="$(_no_overlap)" \
        FAKE_URL_LOG="$urls" FAKE_BODY_LOG="$body" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-claim.sh" "src/Billing"

    [ "$status" -eq 0 ]
    run cat "$urls"
    [[ "$output" == *"/api/formations/42/claims"* ]]
    run cat "$body"
    [[ "$output" == *'"pathPrefix":"src/Billing"'* ]]
    [[ "$output" == *'"repository":'* ]]
}

@test "claim: the repository is DERIVED from the git root, not left to be typed" {
    # Two members who spell one repository differently are never warned about each other, and
    # nothing detects that. The git root gives every session on the same checkout one answer.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local body="${BATS_TEST_TMPDIR}/req"
    : > "$body"

    # A real git repository, so the derivation is exercised rather than the fallback.
    local repo="${BATS_TEST_TMPDIR}/derived-name"
    mkdir -p "$repo"
    ( cd "$repo" && git init -q . 2>/dev/null ) || skip "git is not available"

    ( cd "$repo" && PATH="${bin}:${PATH}" FAKE_CODE=201 FAKE_BODY="$(_no_overlap)" \
        FAKE_BODY_LOG="$body" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        bash "${HANDLERS}/formation-claim.sh" "src/Billing" >/dev/null )

    run cat "$body"
    [[ "$output" == *'"repository":"derived-name"'* ]]
}

@test "claim: an explicit repository overrides the derivation" {
    # The escape hatch, for a checkout whose directory name is not what the team calls it.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local body="${BATS_TEST_TMPDIR}/req"
    : > "$body"

    PATH="${bin}:${PATH}" FAKE_CODE=201 FAKE_BODY="$(_no_overlap)" FAKE_BODY_LOG="$body" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-claim.sh" "src/Billing" "explicitly-named"

    [ "$status" -eq 0 ]
    run cat "$body"
    [[ "$output" == *'"repository":"explicitly-named"'* ]]
}

@test "claim: the free-text assignment is never sent as part of an area" {
    # DD-78 at the client. The comparison is on declared structure; a client that started sending
    # prose would invite the server to match it one day.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local body="${BATS_TEST_TMPDIR}/req"
    : > "$body"

    PATH="${bin}:${PATH}" FAKE_CODE=201 FAKE_BODY="$(_no_overlap)" FAKE_BODY_LOG="$body" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-claim.sh" "src/Billing"

    [ "$status" -eq 0 ]
    run cat "$body"
    [[ "$output" != *"assignment"* ]]
    # The control: the request was genuinely made and genuinely carried the area.
    [[ "$output" == *"src/Billing"* ]]
}

@test "claim: nothing in the client computes overlap" {
    # The predicate exists once, in usp_Mnemo_AddFormationClaim, and this is the guard that it has
    # not been quietly reimplemented here where nobody would think to look for it (#31192).
    run cat "${HANDLERS}/formation-claim.sh"
    [ "$status" -eq 0 ]
    [[ "$output" != *"pathPrefix ==" ]]
    run bash -c "grep -cE 'startswith|substr|\\\\bprefix\\\\b *=' '${HANDLERS}/formation-claim.sh' || true"
    [ "$output" = "0" ]
}

# ---------------------------------------------------------------- refusals at the keyboard

@test "claim: naming no area is refused before anything is sent" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local urls="${BATS_TEST_TMPDIR}/urls"
    : > "$urls"

    PATH="${bin}:${PATH}" FAKE_CODE=201 FAKE_BODY="$(_no_overlap)" FAKE_URL_LOG="$urls" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-claim.sh"

    [ "$status" -ne 0 ]
    [[ "$output" == *"Which area"* ]]
    [ ! -s "$urls" ]
}

@test "claim: the '.' the refusal recommends is sent verbatim, so the advice is followable" {
    # The refusal above tells a member to use '.' for the whole repository. That advice is only
    # worth printing if '.' actually survives the trip: a client that treated it as "no path" and
    # refused it, or helpfully expanded it to the working directory, would make the message name a
    # workaround the member cannot carry out. The server half of this is CL-17.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local urls="${BATS_TEST_TMPDIR}/urls" body="${BATS_TEST_TMPDIR}/req"
    : > "$urls"; : > "$body"

    PATH="${bin}:${PATH}" FAKE_CODE=201 FAKE_BODY="$(_no_overlap)"         FAKE_URL_LOG="$urls" FAKE_BODY_LOG="$body"         MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid"         run bash "${HANDLERS}/formation-claim.sh" "."

    [ "$status" -eq 0 ]
    # It was sent at all, rather than being caught by the empty-path refusal.
    run cat "$urls"
    [[ "$output" == *"/api/formations/42/claims"* ]]
    run cat "$body"
    [[ "$output" == *'"pathPrefix":"."'* ]]
    # And not expanded into an absolute path on the way, which would collide with nobody.
    [[ "$output" != *'"pathPrefix":"/'* ]]
}

@test "claim: a session in no formation is told so, and nothing is sent" {
    local bin; bin="$(_fake_curl_dir)"
    local urls="${BATS_TEST_TMPDIR}/urls"
    : > "$urls"

    PATH="${bin}:${PATH}" FAKE_CODE=201 FAKE_BODY="$(_no_overlap)" FAKE_URL_LOG="$urls" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-claim.sh" "src/Billing"

    [ "$status" -ne 0 ]
    [[ "$output" == *"not in a formation"* ]]
    [ ! -s "$urls" ]
}

@test "claim: --release with a non-numeric id is refused before anything is sent" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local urls="${BATS_TEST_TMPDIR}/urls"
    : > "$urls"

    PATH="${bin}:${PATH}" FAKE_CODE=204 FAKE_BODY='' FAKE_URL_LOG="$urls" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-claim.sh" --release "five"

    [ "$status" -ne 0 ]
    [[ "$output" == *"positive whole number"* ]]
    [ ! -s "$urls" ]
}

# ---------------------------------------------------------------- what it reports

@test "claim: no overlap is reported as no overlap" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=201 FAKE_BODY="$(_no_overlap)" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-claim.sh" "src/Billing"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Nobody else has declared an overlapping area"* ]]
    [[ "$output" != *"been told"* ]]
}

@test "claim: an overlap names the other member and says BOTH were told" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=201 FAKE_BODY="$(_one_overlap)" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-claim.sh" "src/Billing"

    [ "$status" -eq 0 ]
    [[ "$output" == *"member 9"* ]]
    [[ "$output" == *"src/Billing/Invoices.cs"* ]]
    [[ "$output" == *"each privately"* ]]
}

@test "claim: the report does not claim more than the match established" {
    # #31195 in a new place. An overlap is two declared paths overlapping as text. Telling somebody
    # they are editing the same file, when nothing established that, sends them to check a file
    # nobody else has open.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=201 FAKE_BODY="$(_one_overlap)" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-claim.sh" "src/Billing"

    [ "$status" -eq 0 ]
    [[ "$output" == *"overlap as text"* ]]
    [[ "$output" == *"Nothing is blocked"* ]]
    [[ "$output" != *"editing the same file."* ]]
}

@test "claim: a RE-declaration says nobody was told this time" {
    # The server deliberately does not warn twice. A caller reporting "both sides warned" on a
    # repeat would leave a member believing somebody had been told when they had not, which is the
    # same class of untruth as reporting an undelivered message as sent.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=201 FAKE_BODY="$(_repeat_with_overlap)" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-claim.sh" "src/Billing"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Already declared"* ]]
    [[ "$output" == *"Nobody was told this time"* ]]
    [[ "$output" != *"each privately"* ]]
    # The overlap is still reported, because it is still true.
    [[ "$output" == *"member 9"* ]]
}

@test "claim: a 400 prints the server's own reason rather than guessing" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local refusal='{"message":"An area cannot contain a line break or a control character.","claimed":0}'

    PATH="${bin}:${PATH}" FAKE_CODE=400 FAKE_BODY="$refusal" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-claim.sh" "src/Billing"

    [ "$status" -ne 0 ]
    [[ "$output" == *"line break or a control character"* ]]
    [[ "$output" == *"nothing was declared"* ]]
    [[ "$output" != *"not a current member"* ]]
}

@test "claim: a gateway failure does not blame the roster or standing (#31195)" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=503 FAKE_BODY='' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-claim.sh" "src/Billing"

    [ "$status" -ne 0 ]
    [[ "$output" == *"fault on the server side"* ]]
    [[ "$output" != *"not a current member"* ]]
}

# ---------------------------------------------------------------- listing and releasing

@test "claim --list: an empty answer is not reported as an empty formation" {
    # A caller who is not a current member is given an empty list too, on purpose, so this may not
    # report "nobody has declared anything" with any confidence.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY='[]' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-claim.sh" --list

    [ "$status" -eq 0 ]
    [[ "$output" == *"no longer a current member"* ]]
}

@test "claim --list: areas are listed with the id needed to release one" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local areas='[{"claimId":5,"formationId":42,"memberId":7,"repository":"mmry","pathPrefix":"src/Billing","claimedDate":"2026-09-04T12:00:00"}]'

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$areas" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-claim.sh" --list

    [ "$status" -eq 0 ]
    [[ "$output" == *"5"* ]]
    [[ "$output" == *"member 7"* ]]
    [[ "$output" == *"src/Billing"* ]]
}

@test "claim --release: a success says nobody was notified, because a release is not news" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local methods="${BATS_TEST_TMPDIR}/methods"
    : > "$methods"

    PATH="${bin}:${PATH}" FAKE_CODE=204 FAKE_BODY='' FAKE_METHOD_LOG="$methods" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-claim.sh" --release 5

    [ "$status" -eq 0 ]
    [[ "$output" == *"Released area 5"* ]]
    [[ "$output" == *"nobody was notified"* ]]
    run cat "$methods"
    [[ "$output" == *"DELETE"* ]]
}

@test "claim --release: somebody else's area is refused and reported as still held" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local refusal='{"message":"This session holds no such live area.","released":0}'

    PATH="${bin}:${PATH}" FAKE_CODE=400 FAKE_BODY="$refusal" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-claim.sh" --release 5

    [ "$status" -ne 0 ]
    [[ "$output" == *"Nothing was released"* ]]
    [[ "$output" == *"no such live area"* ]]
}

# ---------------------------------------------------------------- client and documentation

@test "client: the claim functions carry the session and use the right methods" {
    run _fn_body mmry_add_formation_claim
    [ "$status" -eq 0 ]
    [[ "$output" == *"sessionId"* ]]
    [[ "$output" == *"/claims"* ]]

    run _fn_body mmry_release_formation_claim
    [ "$status" -eq 0 ]
    [[ "$output" == *"DELETE"* ]]
}

@test "command: /mmry:formation documents declaring an area" {
    run cat "${BATS_TEST_DIRNAME}/../../commands/formation.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"claim"* ]]
    [[ "$output" == *"formation-claim.sh"* ]]
}

@test "command: the doc says leaving releases the areas on its own" {
    # The one thing a member would otherwise get wrong: releasing by hand before leaving, or
    # worrying that a departed session is still holding half the repository.
    run cat "${BATS_TEST_DIRNAME}/../../commands/formation.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Leaving the formation releases"* ]]
}
