#!/usr/bin/env bats
# #31411 TEST CASE 5: the session-start path and the per-prompt path deliver the SAME set.
#
# The ticket singled this out as the one thing nobody had examined: "Whether the session start
# path applies the same budget as the per prompt reinjection was not established and needs
# checking before the change is called complete."
#
# It was still not examined after the first two rounds. unit/foundation-cache-write.bats was
# headed as the TC5 test and exercised mmry_write_foundation_cache DIRECTLY, never invoking
# session-start.sh; its own header conceded the link was "verified by reading both files".
# Reading two files is how the discrepancy would have been missed, not how it is found.
#
# The reason nobody had run session-start.sh in a test until now is worth stating, because it
# was not laziness: session-start.sh line 11 invoked self-update.sh against PLUGIN_ROOT, so a
# test that ran it could pull the RELEASED plugin over the branch under test. That happened
# twice on 2026-09-20. self-update.sh now refuses a git checkout, which is what makes this
# file possible at all.
#
# WHAT IS COMPARED. Not two computations of the same formula. The bytes session-start writes,
# against the text the per-prompt handler actually emits to the model.

load '../helpers/test-helper'
load '../helpers/mock-config'

setup() {
    setup_mock_curl
    create_test_config "http://localhost:5291" "test-api-key" "apikey"
    export CLAUDE_SESSION_ID="tc5-session"
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME/.claude/mmry/hooks-handlers" "$HOME/.claude/mmry/setup"
    CACHE="$TEST_TMPDIR/mmry-foundation.md"
}

# A Foundation set big enough that any surviving budget would bite. The old cut was at 6,000
# characters, so this is comfortably past it, and one memory's CONTENT is itself a bulleted
# list because that is the shape that broke entry counting once already.
_big_response() {
    local filler
    filler="$(printf 'w%.0s' $(seq 1 900))"
    printf '['
    local i
    for i in $(seq 1 9); do
        printf '{"memoryTier":"Foundation","topic":"Directive %s","content":"%s"},' "$i" "$filler"
    done
    # %s, NOT a printf format string, for the element carrying escapes. In a FORMAT string
    # printf converts \n to a real newline, which puts a control character inside a JSON
    # string value and makes the whole response invalid. jq then fails and session-start
    # exits 5 with no output at all, which cost me a bisect and briefly looked like the
    # product dying on large sets. It was my fixture.
    printf '%s' '{"memoryTier":"Foundation","topic":"Values","content":"Our values:\n- Justice\n- Joy\n- Service"},'
    printf '%s' '{"memoryTier":"Strategic","topic":"Ignored","content":"not foundation"}'
    printf ']'
}

@test "#31411 TC5: session-start writes the set, and the per-prompt hook delivers exactly it" {
    export MOCK_CURL_RESPONSE="$(_big_response)"
    export MOCK_CURL_HTTP_CODE="200"

    run bash -c "bash '$PLUGIN_ROOT/hooks-handlers/session-start.sh' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ -f "$CACHE" ]

    # Well past the cut this release removed, so a surviving budget could not hide.
    local stored_bytes
    stored_bytes="$(wc -c < "$CACHE")"
    [ "$stored_bytes" -gt 7000 ]

    # What the model actually receives, read off the emitted hook JSON rather than recomputed.
    run bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    [ "$status" -eq 0 ]
    local emitted="$output"

    # DECODED AND COMPARED AS BYTES, via files.
    #
    # The first cut of this hand-escaped the stored text and compared it against the raw JSON,
    # copying the approach used elsewhere in the suite. It failed, and not because the product
    # was wrong: the emitted JSON carried \r\n correctly and my replacement strings lost their
    # backslashes, so the test was comparing "rn" against "\r\n". Measured with od before
    # concluding anything.
    #
    # So the comparison goes through files instead. bash writes the emitted JSON byte for byte
    # with printf, python reads both in BINARY and compares. Nothing passes through a Windows
    # native binary's stdout, which is what rewrites \n as \r\n and corrupts exactly the bytes
    # under test.
    printf '%s' "$emitted" > "$TEST_TMPDIR/emitted.json"

    run python -c "
import io,json,sys
raw = io.open(sys.argv[1],'rb').read().decode('utf-8')
ctx = json.loads(raw)['hookSpecificOutput']['additionalContext']
stored = io.open(sys.argv[2],'rb').read().decode('utf-8')
# The handler reads the cache with \$(<file), which strips trailing newlines, and prefixes its
# framing. So the delivered text must END with exactly the stored set.
if ctx.endswith(stored.rstrip('\n').rstrip('\r\n')) or ctx.endswith(stored.rstrip()):
    print('MATCH')
else:
    print('DIFFER: ctx tail %r vs stored tail %r' % (ctx[-60:], stored.rstrip()[-60:]))
" "$(cygpath -w "$TEST_TMPDIR/emitted.json" 2>/dev/null || echo "$TEST_TMPDIR/emitted.json")" "$(cygpath -w "$CACHE" 2>/dev/null || echo "$CACHE")"
    [ "$output" = "MATCH" ]
}

@test "#31411 TC5: every directive session-start stored arrives, first to last" {
    export MOCK_CURL_RESPONSE="$(_big_response)"
    export MOCK_CURL_HTTP_CODE="200"

    bash -c "bash '$PLUGIN_ROOT/hooks-handlers/session-start.sh' 2>/dev/null" >/dev/null
    run bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    [ "$status" -eq 0 ]

    # Named one by one, so a cut anywhere is caught rather than only at the two ends.
    local i
    for i in $(seq 1 9); do
        [[ "$output" == *"Directive $i"* ]] || { echo "lost Directive $i"; return 1; }
    done
    [[ "$output" == *'Values'* ]]
    [[ "$output" == *'Service'* ]]
    # And the tier filter held on the way through.
    [[ "$output" != *'not foundation'* ]]
}

@test "#31411 TC5: the two paths agree on the COUNT, not only on the text" {
    export MOCK_CURL_RESPONSE="$(_big_response)"
    export MOCK_CURL_HTTP_CODE="200"

    bash -c "bash '$PLUGIN_ROOT/hooks-handlers/session-start.sh' 2>/dev/null" >/dev/null

    # session-start's writer counts from the API response: ten Foundation memories, one of
    # which has three bulleted lines in its content, so a line count would say twelve.
    grep -q 'entries=10' "${CACHE}.manifest"

    bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh" >/dev/null
    run cat "$TEST_TMPDIR/mmry-foundation.status"
    [[ "$output" == *'entries=10'* ]]
}

@test "#31411 TC5: no token cap survives on either path" {
    export MOCK_CURL_RESPONSE="$(_big_response)"
    export MOCK_CURL_HTTP_CODE="200"
    # The tightest cap anyone could set, on the knob that is still parsed and must not bite.
    export MMRY_FOUNDATION_TOKEN_CAP=100

    bash -c "bash '$PLUGIN_ROOT/hooks-handlers/session-start.sh' 2>/dev/null" >/dev/null
    local stored_bytes
    stored_bytes="$(wc -c < "$CACHE")"
    [ "$stored_bytes" -gt 7000 ]

    run bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'Directive 9'* ]]
    [[ "$output" != *'truncated'* ]]
    [ ${#output} -gt 7000 ]
}

# ============================================================================
# #31411 QA: A FIRING KILLED DURING THE EMIT MUST STILL BE REPORTED.
#
# The in-flight marker was cleared before the emit, so everything after that point was
# unreported: the emit and its JSON escape run there, the watchdog only ever kills the
# WORKER, and the escape is parameter expansion whose cost grows faster than its input
# (measured on this host, worst case: 8 KB 57 ms, 128 KB 428 ms, 360 KB 2,720 ms).
#
# The timing is not the problem. Nothing a customer has comes close to the 10 s deadline; the
# largest Foundation set ever measured on the platform is 34,338 characters and it would take
# roughly 700 KB to reach it. The problem was that IF it ever ran long, the next turn would
# say nothing, because the evidence had already been deleted.
# ============================================================================

@test "#31411 the in-flight marker is cleared AFTER the emit, never before it" {
    # STRUCTURAL, and deliberately so. My first attempt at this raced a SIGKILL against the
    # handler and then asserted only `if [ -f "$marker" ]`, which is vacuous in precisely the
    # case it was written to catch: under the OLD ordering the marker is already gone, the
    # branch is skipped, and the test reports ok. Restoring the old ordering left it green.
    # An assertion that cannot fail is worse than no assertion, so this checks the ordering
    # itself, which is the thing that has to hold.
    local f="$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"

    # The region after the worker has been waited on. Every clear of the marker in it must
    # come after an emit, because everything between the two is unreported otherwise: the
    # watchdog kills only the worker, and the JSON escape runs in the emit.
    local first_clear first_emit
    first_clear="$(grep -n 'rm -f "\$_INFLIGHT"' "$f" | head -1 | cut -d: -f1)"
    first_emit="$(grep -n '_mmry_emit ' "$f" | grep -v '^[0-9]*:_mmry_emit()' | head -1 | cut -d: -f1)"

    [ -n "$first_clear" ]
    [ -n "$first_emit" ]
    # The premise: both were actually found, and the marker is written somewhere too.
    grep -q ': > "\$_INFLIGHT"' "$f"

    [ "$first_clear" -gt "$first_emit" ] || {
        echo "marker cleared at line $first_clear, before the first emit at line $first_emit"
        return 1
    }
}

@test "#31411 a clean firing clears the marker, so the next turn does NOT cry wolf" {
    export MOCK_CURL_RESPONSE='[{"memoryTier":"Foundation","topic":"T","content":"C"}]'
    export MOCK_CURL_HTTP_CODE="200"
    bash -c "bash '$PLUGIN_ROOT/hooks-handlers/session-start.sh' 2>/dev/null" >/dev/null

    bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh" >/dev/null
    [ ! -f "$TEST_TMPDIR/.mmry-foundation-inflight" ]

    run bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    [ "$status" -eq 0 ]
    [[ "$output" != *'PREVIOUS turn'* ]]
    [[ "$output" != *'previous turn'* ]]
}
