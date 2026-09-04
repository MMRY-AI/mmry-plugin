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

# A curl that records every invocation before answering, so "was the network reached" is a
# question about an observed fact rather than about how long something took.
_recording_curl_dir() {
    local dir="${BATS_TEST_TMPDIR}/curl-recorder"
    mkdir -p "$dir"
    cat > "${dir}/curl" <<'RECCURL'
#!/usr/bin/env bash
printf 'called\n' >> "${MMRY_TEST_CURL_LOG:?curl recorder needs MMRY_TEST_CURL_LOG}"
out=""; prev=""
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    prev="$arg"
done
[[ -n "$out" ]] && printf '%s' "${FAKE_BODY:-}" > "$out"
printf '%s' "${FAKE_CODE:-200}"
exit 0
RECCURL
    chmod +x "${dir}/curl"
    printf '%s' "$dir"
}

@test "hook: no state file means no network call at all" {
    # The cost of not being in a formation must be one file test.
    #
    # The previous version of this test argued that from a STOPWATCH: point the hook at the
    # discard port, and if it came back in under three seconds it cannot have paid a connect
    # timeout, so it cannot have touched the network. That is an inference from elapsed time, and
    # it fails for reasons that have nothing to do with the hook - it failed exactly that way in a
    # full-suite run with four other bats runs in flight, on code where the property held. A test
    # that reports a defect when the machine is busy is not measuring the code.
    #
    # So observe the call. A curl that records every invocation answers the question directly, and
    # answers it identically on an idle machine and a loaded one.
    local log="${BATS_TEST_TMPDIR}/curl-calls.log"
    local bin; bin="$(_recording_curl_dir)"

    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID"
    : > "$log"
    run env PATH="${bin}:${PATH}" MMRY_TEST_CURL_LOG="$log" \
        FAKE_CODE=200 FAKE_BODY="$VALID_TRANSMISSION" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        bash "${HANDLERS}/formation-check.sh"
    [ "$status" -eq 0 ]
    [ ! -s "$log" ] || {
        echo "a session in no formation reached the network $(wc -l < "$log") time(s)"
        return 1
    }

    # POSITIVE CONTROL. An empty log only means something if a call would have written to it. The
    # identical invocation WITH a state file must record one, or this test is passing because the
    # recorder was never on the path the handler actually resolves curl from.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    : > "$log"
    run env PATH="${bin}:${PATH}" MMRY_TEST_CURL_LOG="$log" \
        FAKE_CODE=200 FAKE_BODY="$VALID_TRANSMISSION" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        bash "${HANDLERS}/formation-check.sh"
    [ -s "$log" ] || {
        echo "the recorder logged nothing even when in a formation, so the assertion above proves nothing"
        return 1
    }
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
    # The win condition on this ticket is that the product stops being silent about the
    # limitation, and the help page is the shortest path a user has to the truth. It has to carry
    # BOTH halves: that an idle or closed session may not be reached, and the Claude Code version
    # floor that idle delivery depends on. The floor is the limitation that survives these fixes,
    # so leaving it only in the command page would be exactly the silence being fixed.
    local doc="${BATS_TEST_DIRNAME}/../../commands/help.md"
    run grep -qi "idle" "$doc"
    [ "$status" -eq 0 ]
    run grep -c "2\.1\.64" "$doc"
    [ "$output" -ge 1 ]
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

# ---------------------------------------------------------------------------------------------
# QA ROUND 2 (#31196)
# ---------------------------------------------------------------------------------------------
# Three defects that round 1 shipped, and the reason none of the tests above caught any of them:
# every test above sets MMRY_FORMATION_MODE, which is the seam that bypasses the payload parse,
# and the two tests named for concurrency pre-seed a lock and then run one process. A seam used in
# every test stops being a seam and becomes the only code path that has coverage.

# A PATH with every directory that holds a real jq removed, which is the ordinary state of a
# Windows Git Bash machine and of any host where setup installed the bundled binary instead. The
# bundled jq under vendor/ is deliberately left reachable: the point is that MMRY has a working jq
# and must find it, not that no jq exists anywhere.
_path_without_jq() {
    local out="" p
    local IFS=":"
    for p in $PATH; do
        [[ -e "$p/jq" || -e "$p/jq.exe" ]] && continue
        out="${out:+$out:}$p"
    done
    printf '%s' "$out"
}

_vendor_jq_dir() {
    printf '%s' "$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/vendor/jq"
}

@test "event: with no system jq the hook still reads the event and honours each runtime's contract" {
    # THE REGRESSION GUARD FOR QA ROUND 2 DEFECT 1. Round 1 resolved jq for this parse with a bare
    # `command -v jq`, thirty lines before the project's own resolver was sourced. On a machine
    # with no system jq - which lib-jq.sh's header names as the common case on Windows, and which
    # setup produces deliberately by installing a bundled binary rather than one on PATH - the
    # payload was never parsed, so hook_event was empty and the case fell through to "tool" for
    # every event. SessionStart then exited 2 into a runtime that discards it, and Stop ran a
    # single un-looped pass instead of polling. The headline deliverable did nothing, silently.
    #
    # This drives the handler the way Claude Code does: a real payload on stdin naming the event,
    # and NO MMRY_FORMATION_MODE. That is the whole point - the override is what hid the defect.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local nojq; nojq="$(_path_without_jq)"
    local vendor; vendor="$(_vendor_jq_dir)"

    # Sanity: the stripped PATH really has no jq on it, or this test proves nothing.
    run env PATH="$nojq" bash -c "command -v jq"
    [ "$status" -ne 0 ]

    local event expect_status
    for event in SessionStart UserPromptSubmit PostToolUse Stop; do
        case "$event" in
            SessionStart|UserPromptSubmit) expect_status=0 ;;
            *)                             expect_status=2 ;;
        esac
        bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
        rm -rf "${TMPDIR}/.mmry-formation-cs-$(_safe_sid_for_test)" \
               "${TMPDIR}/.mmry-formation-poll-$(_safe_sid_for_test)"

        printf '%s' "{\"session_id\":\"${CLAUDE_SESSION_ID}\",\"hook_event_name\":\"${event}\"}" \
            > "${BATS_TEST_TMPDIR}/payload.json"

        run bash -c "env PATH='${bin}:${nojq}' MMRY_JQ_VENDOR_DIR='${vendor}' \
                FAKE_CODE=200 FAKE_BODY='${VALID_TRANSMISSION}' \
                MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL='http://fake.invalid' \
                MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
                bash '${HANDLERS}/formation-check.sh' \
                < '${BATS_TEST_TMPDIR}/payload.json' 2>&1"

        [ "$status" -eq "$expect_status" ] || {
            echo "event ${event}: expected exit ${expect_status}, got ${status}: ${output}"
            return 1
        }
        [[ "$output" == *"FormationService.cs"* ]] || {
            echo "event ${event}: nothing was delivered without a system jq: ${output}"
            return 1
        }
        # The two additionalContext events must name themselves correctly, which is the part that
        # silently fell back to the PostToolUse contract.
        if [ "$expect_status" -eq 0 ]; then
            [[ "$output" == *"\"hookEventName\": \"${event}\""* ]] || {
                echo "event ${event}: wrong or missing hookEventName: ${output}"
                return 1
            }
        fi
    done
}

# Only the executable lines of a shell file: any line whose first non-blank character is # is
# prose. Every absence check below MUST read this rather than the raw file. formation-check.sh
# explains each of these three defects in a comment that quotes the bad call by name, so a raw
# grep matches the explanation and reports the defect still present forever after it was fixed -
# a check that can never pass, which is the same class of useless as one that can never fail.
_code_only() {
    grep -v '^[[:space:]]*#' "$1"
}

# A copy of the real handler directory with ONE defect deliberately put back. This is the positive
# control for each behavioural test below: a test that asserts correct behaviour has never been
# watched fail, so it cannot yet be trusted to notice a regression. Each control runs its test's
# own scenario against the mutant and requires the round 1 symptom to reappear.
#
# BASE lets a mutation stack on the lagged-state copy the overlap test needs. The mutation is
# verified to have actually changed the file and to have left valid bash behind, because a
# no-op mutation would make the control a test of nothing.
_mutant_handler_dir() {
    local mutation="$1" base="${2:-$HANDLERS}"
    local dir="${BATS_TEST_TMPDIR}/handlers-mutant-${mutation}"
    rm -rf "$dir"; mkdir -p "$dir"
    cp "${base}"/*.sh "$dir"/
    local f="${dir}/formation-check.sh"

    case "$mutation" in
        # DEFECT 1: resolve jq with a bare `command -v jq` and never call the project's resolver,
        # which is what round 1 did.
        bare-command-v-jq)
            perl -0777 -pi -e 's{^source "\$\{HANDLER_DIR\}/lib-jq\.sh".*$}{MMRY_JQ="\$(command -v jq 2>/dev/null || true)"}m; s{^mmry_resolve_jq[^\n]*$}{:}m' "$f"
            ;;
        # DEFECT 2: read last-seen BEFORE taking the delivery mutex, restoring the round 1 order.
        read-before-lock)
            perl -0777 -pi -e 's{(\r?\n[ ]+_acquire "\$_mutex_dir" 120 \|\| return 1\r?\n[ ]+_held_mutex=1\r?\n)(\r?\n[ ]+local last_seen\r?\n[ ]+last_seen="\$\(bash[^\n]*\r?\n[ ]+last_seen="\$\{last_seen[^\n]*\r?\n)}{$2$1}s' "$f"
            ;;
        # DEFECT 3: take a lock's mtime with the GNU-only `date -r PATH`.
        date-r-mtime)
            perl -0777 -pi -e 's{stat -c %Y "\$1"}{date -r "\$1" +%s}g; s{stat -f %m "\$1"}{date -r "\$1" +%s}g' "$f"
            ;;
        *)
            echo "unknown mutation: ${mutation}" >&2; return 1 ;;
    esac

    if cmp -s "$f" "${base}/formation-check.sh"; then
        echo "mutation ${mutation} did not apply; the control that uses it would prove nothing" >&2
        return 1
    fi
    bash -n "$f" || { echo "mutation ${mutation} produced invalid bash" >&2; return 1; }
    printf '%s' "$dir"
}

@test "event: the parse uses the project's jq resolver, not a bare command -v" {
    # The absence half of the guard above, read from CODE ONLY for the reason given on _code_only.
    # A future edit reintroducing `command -v jq` here would pass the behavioural test on any
    # machine, so this is cheap insurance rather than the real guard.
    local code="${BATS_TEST_TMPDIR}/check-code.sh"
    _code_only "${HANDLERS}/formation-check.sh" > "$code"

    # Control for the stripper: the line that must be there still is.
    run grep -c 'source "${HANDLER_DIR}/lib-jq.sh"' "$code"
    [ "$output" -eq 1 ]
    run grep -c 'mmry_resolve_jq' "$code"
    [ "$output" -eq 1 ]

    run grep -n "command -v jq" "$code"
    [ -z "$output" ]
}

@test "control: the no-jq test fails against a handler that resolves jq with command -v" {
    # POSITIVE CONTROL for "with no system jq the hook still reads the event". That test asserts
    # each runtime's contract is honoured; this one shows the same scenario catches the round 1
    # handler, whose parse silently produced no event so every invocation fell through to the
    # PostToolUse contract. SessionStart is the starkest case: the correct answer is exit 0 with
    # additionalContext on stdout, and the mutant instead exits 2 with the raw block on stderr,
    # into a runtime that discards it.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local nojq; nojq="$(_path_without_jq)"
    local vendor; vendor="$(_vendor_jq_dir)"
    local mutant; mutant="$(_mutant_handler_dir bare-command-v-jq)"

    rm -rf "${TMPDIR}/.mmry-formation-cs-$(_safe_sid_for_test)" \
           "${TMPDIR}/.mmry-formation-poll-$(_safe_sid_for_test)"
    printf '%s' "{\"session_id\":\"${CLAUDE_SESSION_ID}\",\"hook_event_name\":\"SessionStart\"}" \
        > "${BATS_TEST_TMPDIR}/ctl-payload.json"

    run bash -c "env PATH='${bin}:${nojq}' MMRY_JQ_VENDOR_DIR='${vendor}' \
            FAKE_CODE=200 FAKE_BODY='${VALID_TRANSMISSION}' \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL='http://fake.invalid' \
            bash '${mutant}/formation-check.sh' \
            < '${BATS_TEST_TMPDIR}/ctl-payload.json' 2>&1"

    [ "$status" -eq 2 ] || {
        echo "expected the mutant to misread SessionStart as a tool call and exit 2, got ${status}: ${output}"
        return 1
    }
    [[ "$output" != *"hookEventName"* ]] || {
        echo "the mutant honoured the SessionStart contract, so the no-jq test proves nothing: ${output}"
        return 1
    }
}

# A handler directory that is the real thing except for a state double which performs the real read
# at the real moment and then holds the answer back until the test releases it. That is exactly a
# reader descheduled between reading last-seen and acting on it, and it is the interleaving the
# code's own comment claims cannot happen. Nothing about formation-check.sh is altered: it is
# copied verbatim and finds the double because it resolves its collaborators from its own directory.
#
# THE STALL APPLIES TO ONE NAMED CALL, NOT TO EVERY `get`. formation-check.sh reads state twice:
# once at the "am I in a formation at all" gate, and once inside _poll_once. The first version of
# this double stalled both, which does not overlap two readers - it holds the stalled one back past
# the other's entire cycle and runs them in sequence. The overlap test passed under that harness
# while a handler carrying the race delivered only once, so the harness, not the code, was deciding
# the result. Counting the calls per reader and stalling only the second is the whole difference
# between an overlap and a queue.
_lagged_handler_dir() {
    local dir="${BATS_TEST_TMPDIR}/handlers-lagged"
    rm -rf "$dir"; mkdir -p "$dir"
    cp "${HANDLERS}"/*.sh "$dir"/
    mv "${dir}/formation-state.sh" "${dir}/formation-state-real.sh"
    cat > "${dir}/formation-state.sh" <<'DOUBLE'
#!/usr/bin/env bash
out="$(bash "$(dirname "${BASH_SOURCE[0]}")/formation-state-real.sh" "$@" 2>/dev/null || true)"
if [ "${1:-}" = "get" ] && [ -n "${MMRY_TEST_GET_COUNT_FILE:-}" ]; then
    n=$(( $(cat "$MMRY_TEST_GET_COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$MMRY_TEST_GET_COUNT_FILE"
    if [ "$n" -eq "${MMRY_TEST_GET_LAG_ON_CALL:-2}" ]; then
        # Announce that the read has happened, then WAIT TO BE RELEASED rather than sleeping for a
        # fixed period. A fixed sleep makes the overlap a bet that the other reader finishes
        # inside it, and that bet is lost on a loaded machine - which silently turns a real double
        # delivery into a passing test. Both ends of the window are now events, not durations.
        [ -n "${MMRY_TEST_GET_SIGNAL_FILE:-}" ] && : > "$MMRY_TEST_GET_SIGNAL_FILE"
        w=0
        while [ ! -f "${MMRY_TEST_GET_RELEASE_FILE:-/nonexistent}" ] \
            && [ "$w" -lt "${MMRY_TEST_GET_LAG_MAX:-300}" ]; do
            sleep 0.1
            w=$(( w + 1 ))
        done
    fi
fi
printf '%s\n' "$out"
DOUBLE
    chmod +x "${dir}/formation-state.sh"
    printf '%s' "$dir"
}

# The two-reader overlap that both the test and its control run. It is a rendezvous, not a race:
#
#   1. Reader B is started and stalls the instant it has read last-seen inside _poll_once.
#   2. Reader A is released only once B has confirmed that read, and runs to completion.
#   3. B is then released and finishes.
#
# So B is guaranteed to be holding a last-seen value it read before A ran, and A is guaranteed to
# have finished before B acts on it. That is precisely the interleaving requirement 4 is about, and
# nothing in it depends on how fast the machine is. Both readers run out of the SAME handler
# directory, so the only thing that varies between the test and its control is the code under test.
#
# stdin is /dev/null deliberately: the handler reads a hook payload from stdin whenever stdin is
# not a tty, so without this each reader would first sit in `timeout 2 cat`.
#
# Echoes the number of times the batch was delivered across both readers, or "no-overlap" if the
# rendezvous never happened, which must fail the caller rather than be counted as a clean run.
_run_overlap() {
    local hdir="$1"
    local bin; bin="$(_fake_curl_since_dir)"
    local vendor; vendor="$(_vendor_jq_dir)"
    local aerr="${BATS_TEST_TMPDIR}/overlap-a.err" berr="${BATS_TEST_TMPDIR}/overlap-b.err"
    local sig="${BATS_TEST_TMPDIR}/overlap-b.read"
    local rel="${BATS_TEST_TMPDIR}/overlap-b.release"
    rm -f "$aerr" "$berr" "$sig" "$rel" "${BATS_TEST_TMPDIR}/overlap-b.count"
    rm -rf "${TMPDIR}/.mmry-formation-cs-$(_safe_sid_for_test)"
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"

    env PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$VALID_TRANSMISSION" \
        MMRY_JQ_VENDOR_DIR="$vendor" \
        MMRY_TEST_GET_COUNT_FILE="${BATS_TEST_TMPDIR}/overlap-b.count" \
        MMRY_TEST_GET_SIGNAL_FILE="$sig" MMRY_TEST_GET_RELEASE_FILE="$rel" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        bash "${hdir}/formation-check.sh" </dev/null >/dev/null 2>"$berr" &
    local bpid=$!

    local waited=0
    while [ ! -f "$sig" ] && [ "$waited" -lt 300 ]; do sleep 0.1; waited=$(( waited + 1 )); done
    if [ ! -f "$sig" ]; then
        : > "$rel"
        kill "$bpid" 2>/dev/null || true
        wait "$bpid" 2>/dev/null || true
        printf 'no-overlap'
        return 0
    fi

    env PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$VALID_TRANSMISSION" \
        MMRY_JQ_VENDOR_DIR="$vendor" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        bash "${hdir}/formation-check.sh" </dev/null >/dev/null 2>"$aerr" || true

    : > "$rel"
    wait "$bpid" || true

    printf '%s' "$(( $(grep -c "FormationService.cs" "$aerr" || true) + $(grep -c "FormationService.cs" "$berr" || true) ))"
}

@test "concurrency: two readers that genuinely overlap deliver the batch once, not twice" {
    # THE REGRESSION GUARD FOR QA ROUND 2 DEFECT 2. Round 1 read last-seen from disk BEFORE
    # acquiring the delivery mutex, while its own comment said the mutex was held "from before the
    # request until after seen is written". The read is the first half of the read-then-write that
    # must not interleave, so two concurrent readers - the background poller and a foreground hook,
    # which is precisely the pair this ticket created - could each capture the same stale value and
    # each show the member the same lines.
    #
    # The two earlier tests named for concurrency cannot reach this: both pre-seed a lock directory
    # and then run a single process, so nothing ever overlaps. This one runs two readers at once
    # and forces the losing interleaving rather than hoping to land inside a microsecond window.
    # Its companion control immediately below is what proves it can still see the race.
    local total; total="$(_run_overlap "$(_lagged_handler_dir)")"

    # If neither reader delivered, or the rendezvous never happened, this test would be passing
    # for the wrong reason. Say so rather than counting it as a clean run.
    [ "$total" != "no-overlap" ] || {
        echo "reader B never reached its state read, so the two readers never overlapped"
        return 1
    }
    [ "$total" != "0" ] || {
        echo "neither reader delivered anything; the overlap proves nothing"
        return 1
    }
    [ "$total" = "1" ] || {
        echo "the same batch was delivered ${total} times to one member"
        return 1
    }
}
@test "concurrency: the last-seen read happens inside the delivery mutex, not before it" {
    # The ordering half, read from CODE ONLY: _poll_once's comment describes the round 1 order in
    # order to explain what was wrong with it, so the prose has to go before the grep.
    local body="${BATS_TEST_TMPDIR}/poll_once.sh"
    sed -n '/^_poll_once()/,/^}/p' "${HANDLERS}/formation-check.sh" | grep -v '^[[:space:]]*#' > "$body"
    [ -s "$body" ]
    local acquire_line read_line
    acquire_line="$(grep -n '_acquire "\$_mutex_dir"' "$body" | head -1 | cut -d: -f1)"
    read_line="$(grep -n 'formation-state.sh" get' "$body" | head -1 | cut -d: -f1)"
    [ -n "$acquire_line" ]
    [ -n "$read_line" ]
    [ "$acquire_line" -lt "$read_line" ]
}

@test "control: the overlap test fails against a handler that reads last-seen before locking" {
    # POSITIVE CONTROL for "two readers that genuinely overlap deliver the batch once". Without it
    # that test is an assertion that a number equals 1, and a lagged double plus a rendezvous is a
    # lot of machinery to take on the word of a passing test. This runs the identical overlap
    # against a copy of the handler with the round 1 order restored - last-seen read, THEN lock -
    # and requires the member to be shown the batch twice.
    #
    # It has already earned its keep. The first version of this harness lagged every state read
    # instead of the poll read, which serialised the two readers rather than overlapping them, and
    # the test above passed anyway. This control was the only thing that noticed.
    local lagged; lagged="$(_lagged_handler_dir)"
    local mutant; mutant="$(_mutant_handler_dir read-before-lock "$lagged")"
    [ -n "$mutant" ]

    local total; total="$(_run_overlap "$mutant")"
    [ "$total" = "2" ] || {
        echo "the read-before-lock mutant delivered ${total} times, not 2; the overlap test above proves nothing"
        return 1
    }
}

# A `date` and a `stat` with BSD/macOS semantics, which is where the round 1 staleness check broke.
# On BSD `date -r` takes an epoch NUMBER, so handing it a path is an error, and `stat` has neither
# --version nor -c. Both stubs reject the GNU form exactly as the real tools do and delegate the
# supported form to the host's own binary, so what is under test is the handler's choice of
# invocation, not an imitation of a filesystem.
_bsd_tools_dir() {
    local dir="${BATS_TEST_TMPDIR}/bsd-bin"
    mkdir -p "$dir"
    cat > "${dir}/date" <<'BSDDATE'
#!/usr/bin/env bash
if [ "${1:-}" = "-r" ]; then
    case "${2:-}" in ''|*[!0-9]*) echo "date: illegal time format" >&2; exit 1 ;; esac
    a="$2"; shift 2; exec /usr/bin/date -d "@$a" "$@"
fi
exec /usr/bin/date "$@"
BSDDATE
    cat > "${dir}/stat" <<'BSDSTAT'
#!/usr/bin/env bash
case "${1:-}" in
    --version) echo "stat: illegal option -- -" >&2; exit 1 ;;
    -c)        echo "stat: illegal option -- c" >&2; exit 1 ;;
    -f)        fmt="$2"; shift 2
               case "$fmt" in
                   %m) exec /usr/bin/stat -c %Y "$@" ;;
                   *)  echo "stat: bad format $fmt" >&2; exit 1 ;;
               esac ;;
esac
exec /usr/bin/stat "$@"
BSDSTAT
    chmod +x "${dir}/date" "${dir}/stat"
    printf '%s' "$dir"
}

@test "locks: a lock left by a killed hook is reclaimed on BSD tools, not only on GNU" {
    # THE REGRESSION GUARD FOR QA ROUND 2 DEFECT 3. Round 1 read the lock's age with
    # `date -r <path>`, a GNU extension. On macOS that call errors, the mtime falls back to 0, the
    # `mtime -gt 0` guard reports "not stale", and a lock abandoned by a killed hook can never be
    # reclaimed - so delivery stays silenced for the rest of that session on every Mac, defeating
    # the mechanism this whole ticket is built on.
    #
    # Run on a Linux or Windows host this asserts the handler asks in a way BSD would answer. It is
    # not a substitute for running on Darwin, which the QA statement says plainly.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local bsd; bsd="$(_bsd_tools_dir)"

    # Sanity: the stubs really do refuse the GNU forms, or this test proves nothing.
    run env PATH="${bsd}:${PATH}" bash -c "date -r . +%s"
    [ "$status" -ne 0 ]
    run env PATH="${bsd}:${PATH}" bash -c "stat --version"
    [ "$status" -ne 0 ]

    local lock dir
    for lock in poll cs; do
        bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
        rm -rf "${TMPDIR}/.mmry-formation-cs-$(_safe_sid_for_test)" \
               "${TMPDIR}/.mmry-formation-poll-$(_safe_sid_for_test)"
        # A lock a killed hook left behind, well past any plausible age.
        dir="${TMPDIR}/.mmry-formation-${lock}-$(_safe_sid_for_test)"
        mkdir -p "$dir"
        touch -d "2020-01-01" "$dir" 2>/dev/null || touch -t 202001010000 "$dir"

        # `run env`, not a VAR=x prefix before `run`: `run` is a shell function, so an
        # assignment prefix on it is not reliably exported to the command it launches. Get that
        # wrong and the handler runs with the real GNU tools, reclaims the lock, and this test
        # passes without ever having exercised BSD semantics.
        run env PATH="${bsd}:${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$VALID_TRANSMISSION" \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
            MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
            bash "${HANDLERS}/formation-check.sh"

        [ "$status" -eq 2 ] || {
            echo "${lock} lock: abandoned lock was not reclaimed under BSD tools (exit ${status})"
            return 1
        }
        [[ "$output" == *"FormationService.cs"* ]] || {
            echo "${lock} lock: reclaimed but delivered nothing: ${output}"
            return 1
        }
    done
}

@test "locks: the staleness check does not use date -r on a path" {
    # The absence half of the guard above, and it reads CODE ONLY. `date -r` with a path reports
    # every lock as fresh on macOS, silently, so it must not come back - but the comment above
    # _lock_mtime names the defect in order to explain it, so a raw grep over the whole file
    # matches the explanation and fails forever AFTER the fix landed. That is what the first cut of
    # this test did, and it is why this one strips the prose first (#31196 QA round 2).
    local code="${BATS_TEST_TMPDIR}/check-code.sh"
    _code_only "${HANDLERS}/formation-check.sh" > "$code"

    # Control for the stripper itself: it must not have eaten the code it is meant to inspect.
    run grep -c "_lock_mtime()" "$code"
    [ "$output" -eq 1 ]

    run grep -n "date -r" "$code"
    [ -z "$output" ]
    run grep -c 'stat -c %Y' "$code"
    [ "$output" -eq 1 ]
    run grep -c 'stat -f %m' "$code"
    [ "$output" -eq 1 ]
}

@test "control: the reclaim test fails against a handler that reads mtime with date -r" {
    # POSITIVE CONTROL for "a lock left by a killed hook is reclaimed on BSD tools". That test
    # asserts a behaviour is PRESENT, and on its own it cannot show that the BSD stubs and the
    # stale lock are wired tightly enough to notice the behaviour being absent - nor even that the
    # stubs reached the handler at all, since a handler using real GNU tools passes it too. So run
    # the identical scenario against a copy of the handler carrying the round 1 bug and require it
    # to go quiet.
    #
    # This is also what proves the stub PATH propagates: GNU `date -r PATH` works, so if the stubs
    # were not in effect the mutant would reclaim the lock and deliver, and this would fail.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local bsd; bsd="$(_bsd_tools_dir)"
    local mutant; mutant="$(_mutant_handler_dir date-r-mtime)"

    local dir="${TMPDIR}/.mmry-formation-poll-$(_safe_sid_for_test)"
    rm -rf "$dir" "${TMPDIR}/.mmry-formation-cs-$(_safe_sid_for_test)"
    mkdir -p "$dir"
    touch -d "2020-01-01" "$dir" 2>/dev/null || touch -t 202001010000 "$dir"

    run env PATH="${bsd}:${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$VALID_TRANSMISSION" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
        bash "${mutant}/formation-check.sh"

    [ "$status" -eq 0 ] || {
        echo "the date -r mutant did not go quiet, so the reclaim test proves nothing: ${status} ${output}"
        return 1
    }
    [[ "$output" != *"FormationService.cs"* ]] || {
        echo "the date -r mutant still delivered, so the reclaim test proves nothing: ${output}"
        return 1
    }
}

@test "client: the transmissions query encodes both parameters, as its siblings do" {
    # An ISO timestamp's colons are reserved in a query string, and the session id is not ours to
    # assume the shape of. The claims endpoints already encoded; this one did not.
    local body="${BATS_TEST_TMPDIR}/transmissions.sh"
    sed -n '/^mmry_get_formation_transmissions()/,/^}/p' "${HANDLERS}/mmry-client.sh" > "$body"
    [ -s "$body" ]
    run grep -c 'sessionId=$(_mmry_urlencode "$session_id")' "$body"
    [ "$output" -eq 1 ]
    run grep -c 'since=$(_mmry_urlencode "$since")' "$body"
    [ "$output" -eq 1 ]
}

@test "docs: the count of delivery moments matches the number listed" {
    local doc="${BATS_TEST_DIRNAME}/../../commands/formation.md"
    run grep -c "are four moments a member receives" "$doc"
    [ "$output" -eq 1 ]
    run grep -c "are three moments a member receives" "$doc"
    [ "$output" -eq 0 ]
    # And the list really does have a fourth item, so the wording cannot be corrected by editing
    # the number alone.
    run grep -c "^4\. \*\*" "$doc"
    [ "$output" -eq 1 ]
    run grep -c "^5\. \*\*" "$doc"
    [ "$output" -eq 0 ]
}

@test "docs: the Claude Code version idle delivery needs is stated where support will look" {
    # asyncRewake is the whole mechanism and it arrived in Claude Code 2.1.64: 2.1.63 does not
    # carry the field in its hook-config schema at all. An older client drops the setting silently
    # rather than reporting it, so without this stated somewhere a reader finds, a support
    # conversation diagnoses an out-of-date client as a plugin fault.
    local doc="${BATS_TEST_DIRNAME}/../../commands/formation.md"
    run grep -c "2\.1\.64" "$doc"
    [ "$output" -ge 1 ]
    run grep -qi "claude --version" "$doc"
    [ "$status" -eq 0 ]
    run grep -c "2\.1\.64" "${HANDLERS}/formation-check.sh"
    [ "$output" -ge 1 ]
}
