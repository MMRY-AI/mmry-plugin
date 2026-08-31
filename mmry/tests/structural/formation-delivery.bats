#!/usr/bin/env bats
# Formation in-session delivery (#31012).
#
# The governing property is that this hook runs after EVERY tool call in EVERY session, so its
# failure modes matter more than its happy path. These tests are mostly about silence: the hook
# must never speak unless there is something to say, and must never fail a session.

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export CLAUDE_SESSION_ID="bats-formation-$$"
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true

    # The one well-formed transmission the transport tests share. Whether the hook speaks has to
    # turn on the response and on the tools available, never on a different fixture per test.
    VALID_TRANSMISSION='[{"senderRole":"lead","senderSessionID":"other-session","content":"Heads up: I am touching FormationService.cs","sentDate":"2026-08-30T12:00:00"}]'
}

teardown() {
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
}

# A fake curl on PATH is the transport for the failure-mode tests below, and it exists because QA
# round 2 found the previous versions of those tests unable to reach the guards they were named
# after. One served its malformed response from a Python-2-only module, so on a Python 3 host the
# server never started, the request was simply refused, and the hook went quiet for the wrong
# reason. The other pointed at a dead port, so the network guard returned before the parse stage was
# reached at all. Both had quietly become second copies of the "unreachable service" test.
#
# This shim takes the network out of the question. It answers with whatever body and status the test
# asks for, in bash, with no interpreter and no port, so the thing being varied is the response
# itself. Prints a directory to put at the front of PATH.
_fake_curl_dir() {
    local dir="${BATS_TEST_TMPDIR}/fake-bin"
    mkdir -p "$dir"
    cat > "${dir}/curl" <<'FAKECURL'
#!/usr/bin/env bash
# The client calls curl with -o <file> -w '%{http_code}', so the body belongs in the -o target and
# the status code on stdout. The URL is ignored: nothing here touches the network.
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

@test "state: set then get returns the formation id" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    run bash "${HANDLERS}/formation-state.sh" get "$CLAUDE_SESSION_ID"
    [ "$status" -eq 0 ]
    [[ "$output" == 4242* ]]
}

@test "state: a non-numeric formation id is refused" {
    run bash "${HANDLERS}/formation-state.sh" set "42; rm -rf /" "$CLAUDE_SESSION_ID"
    [ "$status" -ne 0 ]
    run bash "${HANDLERS}/formation-state.sh" get "$CLAUDE_SESSION_ID"
    [ -z "$output" ]
}

@test "state: seen records the newest timestamp alongside the id" {
    bash "${HANDLERS}/formation-state.sh" set 7 "$CLAUDE_SESSION_ID"
    bash "${HANDLERS}/formation-state.sh" seen "2026-08-29T10:00:00" "$CLAUDE_SESSION_ID"
    run bash "${HANDLERS}/formation-state.sh" get "$CLAUDE_SESSION_ID"
    [ "$output" = "7 2026-08-29T10:00:00" ]
}

@test "state: clear forgets the formation" {
    bash "${HANDLERS}/formation-state.sh" set 7 "$CLAUDE_SESSION_ID"
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID"
    run bash "${HANDLERS}/formation-state.sh" get "$CLAUDE_SESSION_ID"
    [ -z "$output" ]
}

@test "hook: a session in no formation is silent and does not fail" {
    run bash "${HANDLERS}/formation-check.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook: an unreachable service is silent and does not fail" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    # Port 9 is the discard port: nothing listens, so the request cannot succeed.
    MMRY_API_URL="http://127.0.0.1:9" run bash "${HANDLERS}/formation-check.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook: no state file means no network call at all" {
    # The cost of not being in a formation must be one file test. If the hook reached the network
    # first, pointing it at the discard port would still take the connect timeout; this asserts it
    # returns immediately instead.
    local start end
    start=$(date +%s)
    MMRY_API_URL="http://127.0.0.1:9" run bash "${HANDLERS}/formation-check.sh"
    end=$(date +%s)
    [ "$status" -eq 0 ]
    [ $((end - start)) -lt 3 ]
}

@test "hook: the handler is wired into PostToolUse" {
    run grep -c "formation-check" "${BATS_TEST_DIRNAME}/../../hooks/hooks.json"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "hook: hooks.json is still valid JSON after wiring" {
    run bash -c "cd '${BATS_TEST_DIRNAME}/../..' && python -c \"import json,io; json.load(io.open('hooks/hooks.json'))\" 2>/dev/null || node -e \"require('fs').readFileSync('hooks/hooks.json','utf8') && JSON.parse(require('fs').readFileSync('hooks/hooks.json','utf8'))\""
    [ "$status" -eq 0 ]
}

@test "hook: it never writes to stdout, only stderr" {
    # Claude Code discards stdout on exit 2. Anything printed there is invisible and would be a
    # silent failure to deliver.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    run bash -c "MMRY_API_URL=http://127.0.0.1:9 bash '${HANDLERS}/formation-check.sh' 2>/dev/null"
    [ -z "$output" ]
}

@test "client: the transmissions function exists and builds the since parameter" {
    run grep -A8 "^mmry_get_formation_transmissions()" "${HANDLERS}/mmry-client.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"transmissions?sessionId="* ]]
    [[ "$output" == *"since="* ]]
}

@test "transport: the fake curl delivers, so silence in the next two tests means something" {
    # The control. Without it "the hook was silent" proves nothing: a typo in the shim, a missing
    # key, a guard firing three steps earlier would each produce exactly the same silence, and both
    # failure-mode tests below would pass while exercising nothing. This asserts that the identical
    # setup DOES deliver, which is what makes the silence attributable to the one thing each of
    # those tests changes.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$VALID_TRANSMISSION" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 2 ]
    [[ "$output" == *"FormationService.cs"* ]]
}

@test "hook: a malformed response is silent and does not fail" {
    # 200 with a body that is not the array the hook expects, which is what an interposing proxy,
    # an error page, or a truncated read looks like from here. Anything but silence would put
    # half-parsed text in front of the model.
    #
    # Three shapes, because they fail at different guards: HTML never parses, truncated JSON parses
    # to nothing, and a JSON object parses fine but is the wrong type. The type check exists
    # precisely so the third one cannot slip through.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local body

    for body in \
        '<html>this is not json at all</html>' \
        '[{"content":"tru' \
        '{"error":"unexpected object where an array belongs"}'
    do
        PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$body" \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
            run bash "${HANDLERS}/formation-check.sh"

        [ "$status" -eq 0 ] || {
            echo "spoke on malformed body: $body"
            return 1
        }
        [ -z "$output" ] || {
            echo "output on malformed body: $body -> $output"
            return 1
        }
    done
}

@test "hook: with no jq available it is silent and does not fail" {
    # The response here is the same well-formed one the control test proves gets delivered, and the
    # transport is the same fake curl, so the only variable is whether jq exists. That matters: the
    # round 1 version of this test asserted silence against an unreachable URL, and the network
    # guard produces that silence on its own several steps before jq is ever consulted, so it could
    # not attribute the result to anything.
    #
    # MMRY_JQ_SKIP_SYSTEM and MMRY_JQ_VENDOR_DIR are the client library's own test seams; pointing
    # the vendor directory at an empty one leaves no usable jq at all, which is the condition on a
    # platform the bundled binary does not cover.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local emptydir="${BATS_TEST_TMPDIR}/no-jq"
    mkdir -p "$emptydir"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$VALID_TRANSMISSION" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_JQ="" MMRY_JQ_SKIP_SYSTEM=1 MMRY_JQ_VENDOR_DIR="$emptydir" \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook: a non-2xx response is silent even when its body would parse" {
    # A 500 whose body happens to be a valid transmission array. The status check has to come
    # first: the hook must not read a body it was told is an error, or a server having a bad day
    # starts dictating to sessions.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=500 FAKE_BODY="$VALID_TRANSMISSION" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "join: a non-numeric formation id is refused before any request is made" {
    run bash "${HANDLERS}/formation-join.sh" "42; curl evil.example.com"
    [ "$status" -ne 0 ]
    [[ "$output" == *"number"* ]]
}

@test "join: with no id it says what it needs rather than guessing" {
    run bash "${HANDLERS}/formation-join.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Which formation"* ]]
}

@test "leave: with no formation it says so and succeeds" {
    run bash "${HANDLERS}/formation-leave.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not in a formation"* ]]
}

@test "leave: it clears local state and is honest that the roster is untouched" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    run bash "${HANDLERS}/formation-leave.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"roster still lists this session"* ]]
    run bash "${HANDLERS}/formation-state.sh" get "$CLAUDE_SESSION_ID"
    [ -z "$output" ]
}

@test "command: /mmry:formation exists and is advertised in help" {
    [ -f "${BATS_TEST_DIRNAME}/../../commands/formation.md" ]
    run grep -c "formation" "${BATS_TEST_DIRNAME}/../../commands/help.md"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}
