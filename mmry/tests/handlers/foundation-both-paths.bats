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
load '../helpers/foundation-set'

setup() {
    setup_mock_curl
    create_test_config "http://localhost:5291" "test-api-key" "apikey"
    export CLAUDE_SESSION_ID="tc5-session"
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME/.claude/mmry/hooks-handlers" "$HOME/.claude/mmry/setup"
    CACHE="$TEST_TMPDIR/mmry-foundation-set.md"
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
    stored_bytes="$(fnd_set_body "$CACHE" | wc -c | tr -d ' ')"
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

    # NO INTERPRETER (#31411 QA round 2, on a real Mac). This used `python -c`, and macOS has had no
    # bare `python` since 12.3, so on a Mac the comparison never ran. jq decodes the JSON instead,
    # with -b so a native Windows jq writes the bytes as they are rather than turning every newline
    # into CRLF (measured: without -b, a two-line value came out with a CR before each LF). The cache is read with
    # $(<file), exactly as the handler reads it, which strips trailing newlines on both sides.
    jq -b -j '.hookSpecificOutput.additionalContext' "$TEST_TMPDIR/emitted.json" > "$TEST_TMPDIR/ctx.txt" || {
        echo "jq could not decode what the hook emitted"; return 1; }
    local ctx stored
    ctx="$(<"$TEST_TMPDIR/ctx.txt")"
    stored="$(fnd_set_body "$CACHE")"
    [ -n "$stored" ] || { echo "the cache was empty, so a suffix match would prove nothing"; return 1; }
    # The delivered text must END with exactly the stored set; the handler prefixes its framing.
    [[ "$ctx" == *"$stored" ]] || {
        echo "DIFFER: delivered tail [${ctx: -60}] vs stored tail [${stored: -60}]"; return 1; }
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
    [[ "$output" == *'Values'* ]] || return 1
    [[ "$output" == *'Service'* ]] || return 1
    # And the tier filter held on the way through.
    [[ "$output" != *'not foundation'* ]]
}

@test "#31411 TC5: the two paths agree on the COUNT, not only on the text" {
    export MOCK_CURL_RESPONSE="$(_big_response)"
    export MOCK_CURL_HTTP_CODE="200"

    bash -c "bash '$PLUGIN_ROOT/hooks-handlers/session-start.sh' 2>/dev/null" >/dev/null

    # session-start's writer counts from the API response: ten Foundation memories, one of
    # which has three bulleted lines in its content, so a line count would say twelve.
    [[ "$(fnd_set_record "$CACHE")" == *'entries=10 '* ]] || return 1

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
    stored_bytes="$(fnd_set_body "$CACHE" | wc -c | tr -d ' ')"
    [ "$stored_bytes" -gt 7000 ]

    run bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'Directive 9'* ]] || return 1
    [[ "$output" != *'truncated'* ]] || return 1
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
# CORRECTED (#31411 QA): this used to say the timing was not the problem and that it would take
# roughly 700 KB to reach the deadline. QA measured turns lost in silence at 400 KB. The timing
# is now fixed and bounded, see the escape in userpromptsubmit-foundation.sh and the R6 tests in
# hook-budgets.bats. The problem recorded here still stands on its own: IF a turn ran long, the
# next turn said nothing, because the evidence had already been deleted.
# ============================================================================

@test "#31411 the in-flight marker is cleared AFTER the emit, never before it" {
    # STRUCTURAL, and deliberately so. My first attempt at this raced a SIGKILL against the
    # handler and then asserted only `if [ -f "$marker" ]`, which is vacuous in precisely the
    # case it was written to catch: under the OLD ordering the marker is already gone, the
    # branch is skipped, and the test reports ok. Restoring the old ordering left it green.
    # An assertion that cannot fail is worse than no assertion, so this checks the ordering
    # itself, which is the thing that has to hold.
    local f="$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"

    # EVERY EXIT PATH, NOT JUST THE FIRST (#31411 split). This used to compare only the first
    # clear with the first emit. That held by accident of layout: the split added a path that
    # clears the marker and emits nothing, placed first, and the old check went red for a reason
    # that was not a defect, while a second clear moved above its emit lower down would have
    # passed it. Now each clear is walked back to the end of the previous exit path: it must
    # meet an emit first, or the path must say, in a comment, that it never emits.
    grep -q ': > "\$_INFLIGHT"' "$f"
    local report
    report="$(awk '
        /: > "\$_INFLIGHT"/                          { inpath = 1; emitted = 0; noemit = 0; next }
        !inpath                                        { next }
        /^[[:space:]]*exit 0[[:space:]]*$/             { emitted = 0; noemit = 0; next }
        /_mmry_emit(_escaped)? "/                      { emitted = 1 }
        /# NO EMIT ON THIS PATH/                       { noemit = 1 }
        /rm -f "\$_INFLIGHT"/ {
            clears++
            if (!emitted && !noemit) { bad = bad " " NR }
        }
        END { printf "clears=%d bad=%s", clears, bad }
    ' "$f")"
    echo "$report"
    # The premise: the supervisor really does clear the marker on several paths.
    [[ "$report" =~ clears=([0-9]+) ]] && (( BASH_REMATCH[1] >= 4 )) || {
        echo "found too few marker clears for this check to mean anything: $report"; return 1; }
    [[ "$report" == *"bad="* && "${report#*bad=}" == "" ]] || {
        echo "marker cleared before any emit on a path that emits, at line(s):${report#*bad=}"; return 1; }
}

@test "#31411 a clean firing clears the marker, so the next turn does NOT cry wolf" {
    export MOCK_CURL_RESPONSE='[{"memoryTier":"Foundation","topic":"T","content":"C"}]'
    export MOCK_CURL_HTTP_CODE="200"
    bash -c "bash '$PLUGIN_ROOT/hooks-handlers/session-start.sh' 2>/dev/null" >/dev/null

    bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh" >/dev/null
    [ ! -f "$TEST_TMPDIR/.mmry-foundation-inflight" ]

    run bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    [ "$status" -eq 0 ]
    [[ "$output" != *'PREVIOUS turn'* ]] || return 1
    [[ "$output" != *'previous turn'* ]]
}

# #31597 test case: "Confirm the directives delivered to the assistant are byte-identical to those
# the service returned, with no added or lost characters."
#
# Compared against what the SERVICE sent, not against the stored file, so a fault in the writer
# cannot hide behind a reader that faithfully delivers it. The expected text is built here in bash,
# never through jq, because jq is the thing under suspicion: on Windows a native jq writes in text
# mode, and before this ticket every newline in the stored set arrived as CR LF. Content with a
# newline inside it, a tab, a quote, a backslash and non-ASCII text, so each kind of byte that an
# escape or a line-ending conversion could alter is present.
@test "#31597 TC: the set the assistant receives is byte-identical to what the service returned" {
    export MOCK_CURL_RESPONSE='[{"memoryTier":"Foundation","topic":"Identity","content":"Eric builds MMRY."},{"memoryTier":"Foundation","topic":"Values","content":"Our values:\n- Justice\n- Joy\tand \"care\" \\ café"},{"memoryTier":"Strategic","topic":"Ignored","content":"not foundation"}]'
    export MOCK_CURL_HTTP_CODE="200"
    local want
    want="- Identity: Eric builds MMRY."$'\n'"- Values: Our values:"$'\n'"- Justice"$'\n'"- Joy"$'\t'"and \"care\" \\ caf"$'\xc3\xa9'

    bash -c "bash '$PLUGIN_ROOT/hooks-handlers/session-start.sh' 2>/dev/null" >/dev/null
    bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh" > "$TEST_TMPDIR/emitted.json"
    jq -b -j '.hookSpecificOutput.additionalContext' "$TEST_TMPDIR/emitted.json" > "$TEST_TMPDIR/ctx.txt" || {
        echo "jq could not decode what the hook emitted"; return 1; }
    local ctx; ctx="$(cat "$TEST_TMPDIR/ctx.txt"; printf .)"; ctx="${ctx%.}"
    local body="${ctx#*$'\n\n'}"
    if [[ "$body" != "$want" ]]; then
        echo "delivered: $(printf '%s' "$body" | od -c | head -6)"
        echo "expected:  $(printf '%s' "$want" | od -c | head -6)"
        return 1
    fi
    [[ "$body" != *$'\r'* ]]
}

# #31597 test case: "Remove the stored directives entirely and confirm the customer is told they are
# missing." With the record inside the set file, deleting the file deletes the record too, so the
# evidence is the marker SessionStart leaves once it has stored a set. Removed here BEFORE any
# delivery, the case where nothing else could know a set had ever been there.
@test "#31597 TC: a set removed after SessionStart stored it, before any delivery, is reported missing" {
    export MOCK_CURL_RESPONSE="$(_big_response)"
    export MOCK_CURL_HTTP_CODE="200"

    bash -c "bash '$PLUGIN_ROOT/hooks-handlers/session-start.sh' 2>/dev/null" >/dev/null
    [ -f "$CACHE" ] || { echo "control: session-start did not store the set"; return 1; }
    rm -f "$CACHE"

    run bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'records 10 Foundation directives but the cache holding them is missing'* ]] || return 1
    [[ "$output" == *'systemMessage'* ]] || return 1
    [[ "$output" != *'Directive 1'* ]]
}
