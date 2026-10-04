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

# Fire every part the way Claude Code does, one process each, and gather what the assistant
# receives (#31411 QA round 2: TC5 must cover a set that needs more than one part). Each part's
# additionalContext is decoded with jq -b, its heading and label dropped (everything up to the first
# blank line), and the rest appended to delivered.txt. all-output.txt keeps the raw JSON of every
# part. Sets DELIVERED_PARTS.
_deliver_all() {
    local k f c
    : > "$TEST_TMPDIR/delivered.txt"; : > "$TEST_TMPDIR/all-output.txt"; DELIVERED_PARTS=0
    for k in 1 2 3 4 5 6; do
        f="$TEST_TMPDIR/part$k.json"
        bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh" --part "$k" < /dev/null > "$f" 2>/dev/null
        [ -s "$f" ] || continue
        cat "$f" >> "$TEST_TMPDIR/all-output.txt"
        jq -b -j '.hookSpecificOutput.additionalContext' "$f" > "$TEST_TMPDIR/ctx$k.txt" || return 1
        c="$(cat "$TEST_TMPDIR/ctx$k.txt"; printf .)"; c="${c%.}"
        printf '%s' "${c#*$'\n\n'}" >> "$TEST_TMPDIR/delivered.txt"
        DELIVERED_PARTS=$(( DELIVERED_PARTS + 1 ))
    done
}

# A Foundation set big enough that any surviving budget would bite. The old cut was at 6,000
# characters, so this is comfortably past it, and one memory's CONTENT is itself a bulleted
# list because that is the shape that broke entry counting once already.
_big_response() {
    local filler
    filler="$(printf 'w%.0s' $(seq 1 1600))"
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

    # What the model actually receives, read off every part the hook emits rather than recomputed
    # (#31411 QA round 2: TC5 has to cover a set that needs more than one part). Decoded with jq -b,
    # so a native Windows jq writes the bytes as they are, and compared as whole strings.
    _deliver_all || { echo "jq could not decode what the hook emitted"; return 1; }
    (( DELIVERED_PARTS >= 2 )) || { echo "control: the set fitted one part, so this would not test the split ($DELIVERED_PARTS)"; return 1; }
    local delivered stored
    delivered="$(cat "$TEST_TMPDIR/delivered.txt"; printf .)"; delivered="${delivered%.}"
    stored="$(<"$CACHE")"
    [ -n "$stored" ] || { echo "the cache was empty, so a comparison would prove nothing"; return 1; }
    [ "$delivered" = "$stored" ] || {
        echo "DIFFER: ${#delivered} delivered against ${#stored} stored; tails [${delivered: -60}] [${stored: -60}]"; return 1; }
}

@test "#31411 TC5: every directive session-start stored arrives, first to last" {
    export MOCK_CURL_RESPONSE="$(_big_response)"
    export MOCK_CURL_HTTP_CODE="200"

    bash -c "bash '$PLUGIN_ROOT/hooks-handlers/session-start.sh' 2>/dev/null" >/dev/null
    _deliver_all || return 1
    (( DELIVERED_PARTS >= 2 )) || { echo "control: one part only"; return 1; }
    local out; out="$(cat "$TEST_TMPDIR/all-output.txt")"

    # Named one by one, so a cut anywhere is caught rather than only at the two ends.
    local i
    for i in $(seq 1 9); do
        [[ "$out" == *"Directive $i"* ]] || { echo "lost Directive $i"; return 1; }
    done
    [[ "$out" == *'Values'* ]] || return 1
    [[ "$out" == *'Service'* ]] || return 1
    # And the tier filter held on the way through.
    [[ "$out" != *'not foundation'* ]]
}

@test "#31411 TC5: the two paths agree on the COUNT, not only on the text" {
    export MOCK_CURL_RESPONSE="$(_big_response)"
    export MOCK_CURL_HTTP_CODE="200"

    bash -c "bash '$PLUGIN_ROOT/hooks-handlers/session-start.sh' 2>/dev/null" >/dev/null

    # session-start's writer counts from the API response: ten Foundation memories, one of
    # which has three bulleted lines in its content, so a line count would say twelve.
    grep -q 'entries=10' "${CACHE}.manifest" || return 1

    bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh" < /dev/null >/dev/null
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
    stored_bytes="$(wc -c < "$CACHE" | tr -d ' ')"
    [ "$stored_bytes" -gt 7000 ]

    _deliver_all || return 1
    local out; out="$(cat "$TEST_TMPDIR/all-output.txt")"
    [[ "$out" == *'Directive 9'* ]] || return 1
    [[ "$out" != *'truncated'* ]] || return 1
    [ "$(wc -c < "$TEST_TMPDIR/delivered.txt" | tr -d ' ')" -gt 7000 ]
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
    # The marker is written by temp and rename since #31583 QA round 2 (_mmry_fnd_write).
    grep -q '_mmry_fnd_write "\$_INFLIGHT"' "$f"
    local report
    report="$(awk '
        /_mmry_fnd_write "\$_INFLIGHT"/              { inpath = 1; emitted = 0; noemit = 0; next }
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
