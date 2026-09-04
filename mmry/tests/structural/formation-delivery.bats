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

# LEAVING MOVED TO formation-leave.bats (#31194). Two tests lived here and both asserted the
# local-only contract that ticket removed: that leaving with no local record says "not in a
# formation", and that a leave prints "the roster still lists this session". Leaving now calls the
# service, so the first sentence is wrong (a session with no local record is exactly the one that
# is still on the roster and must ask to be released) and the second is a claim the product no
# longer makes.
#
# They are not merely deleted. Leaving has four outcomes now instead of one, and formation-leave.bats
# covers all four against a fake transport. These two also made no HTTP request at all, so they had
# no transport to fake and would now reach whatever service the developer's own config points at.

@test "command: /mmry:formation exists and is advertised in help" {
    [ -f "${BATS_TEST_DIRNAME}/../../commands/formation.md" ]
    run grep -c "formation" "${BATS_TEST_DIRNAME}/../../commands/help.md"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

# ---------------------------------------------------------------------------------------------
# IDLE DELIVERY (#31196)
# ---------------------------------------------------------------------------------------------
# The defect: delivery was registered on PostToolUse and nowhere else, so a member sitting idle -
# which is exactly when the lead has something to tell it - received nothing until it happened to
# run a tool on its own account. These cover the two registrations added to close that, and the
# wrapper defect found on the way, which had been swallowing delivery on every shipped version.

# A shim that honours the "since" parameter, which the plain one deliberately ignores. Needed to
# prove requirement 4: that a message delivered once is not delivered again. With a shim that
# answers identically every time, "it delivered twice" and "it correctly re-asked" are the same
# observation and nothing is being tested.
_fake_curl_since_dir() {
    local dir="${BATS_TEST_TMPDIR}/fake-bin-since"
    mkdir -p "$dir"
    cat > "${dir}/curl" <<'FAKECURL'
#!/usr/bin/env bash
out=""; prev=""; url=""
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    case "$arg" in http*) url="$arg" ;; esac
    prev="$arg"
done
# A request carrying a non-empty since= has already been told about this batch, so it gets nothing.
answer="${FAKE_BODY:-}"
case "$url" in
    *since=)  ;;
    *since=*) answer='[]' ;;
esac
[[ -n "$out" ]] && printf '%s' "$answer" > "$out"
printf '%s' "${FAKE_CODE:-200}"
exit 0
FAKECURL
    chmod +x "${dir}/curl"
    printf '%s' "$dir"
}

_safe_sid_for_test() {
    printf '%s' "$CLAUDE_SESSION_ID" | tr -c 'A-Za-z0-9._-' '_'
}

@test "wrapper: the registration preserves exit 2 rather than swallowing it" {
    # THE REGRESSION GUARD FOR THE DEFECT THIS TASK FOUND. Every shipped version from 2.6.0 to
    # 2.8.2 wrapped the handler in the shape '[ -f x ] && bash y || true'. In that shape the
    # trailing || true catches the handler's exit 2 and returns 0, so Claude Code was told
    # "nothing to report" and the message never entered the model's context. Delivery was not
    # late, it was absent, on the only event it was registered on. The guard must map the
    # missing-file case to 0 and nothing else.
    run grep -c 'formation-check || true' "${BATS_TEST_DIRNAME}/../../hooks/hooks.json"
    [ "$output" -eq 0 ]
}

@test "wired: the handler is registered on Stop with asyncRewake" {
    # asyncRewake is the entire mechanism. Without the flag the Stop hook is synchronous, so it
    # cannot wait for a message to arrive, and a plain Stop block is discarded when the turn ended
    # on a tool result. A Stop registration missing this flag is worse than no registration.
    run node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const s=(d.hooks.Stop||[]).flatMap(g=>g.hooks).filter(h=>h.command.includes("formation-check"));if(s.length!==1){console.log("expected 1, got "+s.length);process.exit(1);}if(s[0].asyncRewake!==true){console.log("asyncRewake not set");process.exit(1);}if(!(s[0].timeout>240)){console.log("timeout must outlast the poll budget");process.exit(1);}console.log("ok");' "${BATS_TEST_DIRNAME}/../../hooks/hooks.json"
    [ "$status" -eq 0 ]
}

@test "wired: the handler is registered on SessionStart for the missed-message sweep" {
    run node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const s=(d.hooks.SessionStart||[]).flatMap(g=>g.hooks).filter(h=>h.command.includes("formation-check"));process.exit(s.length===1?0:1);' "${BATS_TEST_DIRNAME}/../../hooks/hooks.json"
    [ "$status" -eq 0 ]
}

@test "idle: a pending message wakes the session, on stderr with exit 2" {
    # The case the task exists for, at handler level. Exit 2 is what asyncRewake turns into a wake.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$VALID_TRANSMISSION" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 2 ]
    [[ "$output" == *"FormationService.cs"* ]]
}

@test "idle: nothing pending means the poller gives up quietly, and never wakes the model" {
    # Both halves matter. A Stop hook that exits 2 with nothing to say wakes the model for no
    # reason and is a worse defect than the one being fixed; a poller that never returned would
    # outlive the session it was watching. The budget bounds it, and this asserts it does stop.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY='[]' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "idle: a session in no formation starts no poller and makes no request" {
    # The fail-open budget. Most sessions are in no formation and must pay one file test, not a
    # four-minute background poll. A delivering shim is on PATH, so the silence is attributable.
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$VALID_TRANSMISSION" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -d "${TMPDIR}/.mmry-formation-poll-$(_safe_sid_for_test)" ]
}

@test "idle: a second poller does not start while one is already watching" {
    # Stop fires at the end of every turn. Without the lock a long conversation leaves one poller
    # per turn, all polling the same formation on the same interval.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    mkdir -p "${TMPDIR}/.mmry-formation-poll-$(_safe_sid_for_test)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$VALID_TRANSMISSION" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "concurrency: a held delivery mutex silences the other reader rather than double-delivering" {
    # Two readers now exist at once - the background poller and a PostToolUse hook - and the
    # last-seen timestamp alone does not stop them both reading the same batch before either
    # records it. Whoever does not hold the mutex says nothing.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    mkdir -p "${TMPDIR}/.mmry-formation-cs-$(_safe_sid_for_test)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$VALID_TRANSMISSION" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "no repeats: what the tool hook delivered, the idle poller does not deliver again" {
    # Requirement 4, across the two registrations rather than within one. Both must share the one
    # last-seen record, or a member sees every message twice: once on a tool call, once on idle.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_since_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$VALID_TRANSMISSION" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-check.sh"
    [ "$status" -eq 2 ]

    # The timestamp is now recorded, so the second reader sends since= and is told nothing is new.
    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$VALID_TRANSMISSION" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
        run bash "${HANDLERS}/formation-check.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "sessionstart: missed messages are surfaced as additionalContext, not as exit 2" {
    # Requirement 8, and the runtime difference that makes it necessary. SessionStart records an
    # exit 2 as an error and DISCARDS the text: a probe's codeword sent that way never reached the
    # model, while sibling hooks using additionalContext were read back verbatim. Delivering here
    # the way PostToolUse delivers would look healthy and surface nothing.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$VALID_TRANSMISSION" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_FORMATION_MODE=start \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 0 ]
    printf '%s' "$output" > "${BATS_TEST_TMPDIR}/ss.json"
    run node -e 'const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const a=o.hookSpecificOutput.additionalContext;if(o.hookSpecificOutput.hookEventName!=="SessionStart")process.exit(1);if(!a.includes("FormationService.cs"))process.exit(1);if(!/never shown|not running/.test(a))process.exit(1);console.log("ok");' "${BATS_TEST_TMPDIR}/ss.json"
    [ "$status" -eq 0 ]
}

@test "sessionstart: a fresh session with nothing pending says nothing at all" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY='[]' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_FORMATION_MODE=start \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "docs: the command page states when a member receives, and that idle may not" {
    # Requirement 8 is half documentation. The release win condition on #31139 is that the product
    # stops being silent about the limitation, so the text must say what happens when a session
    # cannot be reached and what the operator should do instead, not just describe the happy path.
    local doc="${BATS_TEST_DIRNAME}/../../commands/formation.md"
    run grep -qi "idle" "$doc"
    [ "$status" -eq 0 ]
    run grep -qi "may not receive" "$doc"
    [ "$status" -eq 0 ]
    run grep -qi "formation status" "$doc"
    [ "$status" -eq 0 ]
}

@test "docs: the help page does not promise delivery it cannot guarantee" {
    local doc="${BATS_TEST_DIRNAME}/../../commands/help.md"
    run grep -qi "idle" "$doc"
    [ "$status" -eq 0 ]
}

@test "wired: the handler is registered on UserPromptSubmit as the backstop" {
    run node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const s=(d.hooks.UserPromptSubmit||[]).flatMap(g=>g.hooks).filter(h=>h.command.includes("formation-check"));process.exit(s.length===1?0:1);' "${BATS_TEST_DIRNAME}/../../hooks/hooks.json"
    [ "$status" -eq 0 ]
}

@test "prompt: a returning human is told what was missed, as additionalContext" {
    # The one path that reaches a turn running no tools at all. It is not the idle fix - nobody is
    # typing in an idle session - it is what catches the member whose poller expired before their
    # human came back. The event name in the payload must match the event or Claude Code rejects it.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$VALID_TRANSMISSION" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_FORMATION_MODE=prompt \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 0 ]
    printf '%s' "$output" > "${BATS_TEST_TMPDIR}/ups.json"
    run node -e 'const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const h=o.hookSpecificOutput;if(h.hookEventName!=="UserPromptSubmit")process.exit(1);if(!h.additionalContext.includes("FormationService.cs"))process.exit(1);console.log("ok");' "${BATS_TEST_TMPDIR}/ups.json"
    [ "$status" -eq 0 ]
}

@test "prompt: nothing pending means the prompt is not touched" {
    # This runs on every prompt in every session. Any stray byte on stdout here is prepended to
    # somebody's context for no reason.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY='[]' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_FORMATION_MODE=prompt \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "prompt: a session in no formation costs one file test and says nothing" {
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$VALID_TRANSMISSION" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_FORMATION_MODE=prompt \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
