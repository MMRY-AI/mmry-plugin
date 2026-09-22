#!/usr/bin/env bats
# userpromptsubmit-foundation.bats — UserPromptSubmit Foundation re-injection handler (#30579).
# The handler inlines the session-local Foundation cache on every prompt, framed as
# authoritative. It must NEVER block a prompt: any problem -> emit nothing, exit 0.

load '../helpers/test-helper'

setup() {
    HANDLER="$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    CACHE="$TEST_TMPDIR/mmry-foundation.md"
    # Every real session has one of these: SessionStart writes the session id here and clears
    # the delivery record beside it (#31583 QA round 4, finding 4c). Without it the handler
    # cannot tell its own delivery record from one an earlier session left in a shared temp
    # directory, and correctly fails safe by staying quiet. A fixture with no token is
    # therefore testing the no-SessionStart path, not the ordinary one.
    printf 'session-under-test' > "$TEST_TMPDIR/mmry-foundation.session"
}

# Write the manifest that describes whatever is currently in the cache (#31583).
#
# The handler no longer believes a cache just because it is not empty - it verifies the
# bytes against what the writer recorded. Tests that put a cache in place by hand therefore
# have to record it too, exactly as mmry_write_foundation_cache would, or they are testing
# the refusal path by accident.
#
# Entry count defaults to the number of lines beginning "- ". That is good enough for
# fixtures; the production writer counts from the API response instead, because memory
# CONTENT can also contain such lines.
manifest_now() {
    local c="${1:-$CACHE}" n="${2:-}" s b
    read -r s b < <(cksum < "$c")
    if [[ -z "$n" ]]; then
        n="$(grep -c '^- ' "$c" 2>/dev/null || true)"
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
    fi
    printf 'mmry-foundation v1 entries=%s bytes=%s cksum=%s
' "$n" "$b" "$s" > "${c}.manifest"
}

@test "userpromptsubmit-foundation: reinjects cached Foundation memories inline with authoritative framing" {
    printf -- '- Identity: Eric builds MMRY.\n- Value: clarity over cleverness.\n' > "$CACHE"
    manifest_now
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"hookEventName":"UserPromptSubmit"'* ]]
    [[ "$output" == *'"additionalContext"'* ]]
    [[ "$output" == *'FOUNDATION'* ]]
    [[ "$output" == *'authoritative'* ]]
    [[ "$output" == *'clarity over cleverness'* ]]
}

@test "userpromptsubmit-foundation: emits valid JSON" {
    printf -- '- Foundation fact.\n' > "$CACHE"
    manifest_now
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    # Validate with jq if present, else python3 — the emitted context must parse.
    if command -v jq >/dev/null; then
        echo "$output" | jq . >/dev/null
    else
        echo "$output" | python3 -c 'import sys,json; json.load(sys.stdin)'
    fi
}

@test "userpromptsubmit-foundation: refresh disabled (0) creates no refresh lock" {
    printf -- '- Foundation fact.\n' > "$CACHE"
    manifest_now
    export MMRY_FOUNDATION_REFRESH_SECONDS=0
    export MMRY_API_KEY="test-key"
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMPDIR/.mmry-foundation-refresh" ]
}

@test "userpromptsubmit-foundation: a stale cache triggers a gated background refresh (lock created)" {
    printf -- '- Foundation fact.\n' > "$CACHE"
    manifest_now
    touch -t 202001010000 "$CACHE"   # force the cache to look stale
    export MMRY_FOUNDATION_REFRESH_SECONDS=1
    export MMRY_API_KEY="test-key"
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    # The lock is touched synchronously before the background fetch is spawned.
    [ -f "$TEST_TMPDIR/.mmry-foundation-refresh" ]
    # Still emitted the current (pre-refresh) cache this turn — non-blocking.
    [[ "$output" == *'Foundation fact'* ]]
}

@test "userpromptsubmit-foundation: toggle off emits nothing and exits 0" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    manifest_now
    export MMRY_FOUNDATION_REINJECT=false
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "userpromptsubmit-foundation: missing cache emits nothing and never blocks (exit 0)" {
    rm -f "$CACHE"
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "userpromptsubmit-foundation: empty cache emits nothing and exits 0" {
    : > "$CACHE"
    manifest_now
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ============================================================================
# #31411 - THE SET IS DELIVERED IN FULL. THERE IS NO CEILING.
#
# What used to be here asserted the opposite: that a set over the cap was cut and that the
# cut was logged. That assertion defended the defect. The cut was a raw substring at
# cap*4 characters, so it landed wherever that character fell - on the account that
# surfaced it, mid-sentence inside a list of corporate values, with four of the eight
# values never reaching any assistant on any turn for fifty days.
#
# Each assertion below was shown to REFUSE by reinstating the cut, not observed to pass.
# See the mutation harness, m10 through m13.
# ============================================================================

# A large set is built from distinguishable parts so a partial delivery shows up as a
# MISSING NAMED PIECE rather than as a length that looks about right. A test that only
# compared lengths could not say WHICH end was lost.
_big_foundation_set() {
    local i
    for i in 00 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19; do
        printf -- '- Directive %s: %s\n' "$i" "$(printf 'w%.0s' $(seq 1 380))"
    done
    printf -- '- FinalDirective: this last line must arrive intact and uncut.\n'
}

@test "userpromptsubmit-foundation: #31411 a set far beyond the old cap is delivered COMPLETE, first line to last" {
    _big_foundation_set > "$CACHE"
    manifest_now
    # Well past the 6000-character cut this replaces.
    [ "$(wc -c < "$CACHE")" -gt 7000 ]

    run bash "$HANDLER"
    [ "$status" -eq 0 ]

    # PRESENCE, not merely the absence of a warning. A handler that emitted nothing at all
    # would satisfy "no truncation note" perfectly well.
    [[ "$output" == *'Directive 00'* ]]
    [[ "$output" == *'Directive 19'* ]]
    [[ "$output" == *'FinalDirective: this last line must arrive intact and uncut.'* ]]
    # And every one in between, so a cut anywhere is caught, not only at the two ends.
    local i
    for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18; do
        [[ "$output" == *"Directive $i"* ]] || { echo "lost Directive $i"; return 1; }
    done
}

@test "userpromptsubmit-foundation: #31411 the delivered text is byte-for-byte the stored set, not merely long enough" {
    _big_foundation_set > "$CACHE"
    manifest_now

    run bash "$HANDLER"
    [ "$status" -eq 0 ]

    # COMPARED ON THE WIRE, NOT AFTER DECODING, and that is not a shortcut - it is the only
    # form of this check that is trustworthy on every platform the plugin supports.
    #
    # The first two cuts of this test decoded the emitted JSON, once with python3 and once
    # with jq. Both FAILED on Windows and both failed for the same reason, which has nothing
    # to do with the handler: each is a Windows-native binary that opens stdout in text mode
    # and rewrites every \n as \r\n. The decoder corrupted the very bytes being compared and
    # reported the handler as having lost content it had delivered perfectly. Verified by od:
    # the raw JSON carried the correct \n escapes and the decoded output carried \r\n.
    #
    # So the expected string is built here with the same escaping the handler performs, and
    # the assertion is that those exact bytes appear in the emitted JSON. No subprocess, no
    # text-mode translation, and it pins the wire format rather than a reconstruction of it.
    local stored escaped
    stored="$(cat "$CACHE")"
    [ -n "$stored" ]
    escaped="${stored//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    escaped="${escaped//$'\015'/\\r}"
    escaped="${escaped//$'\011'/\\t}"
    escaped="${escaped//$'\012'/\\n}"

    [[ "$output" == *"$escaped"* ]]
}

@test "userpromptsubmit-foundation: #31411 an explicitly configured token cap does NOT cut the set" {
    _big_foundation_set > "$CACHE"
    manifest_now
    # The tightest cap anyone could set. Under the old code this kept 400 characters.
    export MMRY_FOUNDATION_TOKEN_CAP=100

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'FinalDirective: this last line must arrive intact and uncut.'* ]]
    [[ "$output" != *'truncated'* ]]
    [ ${#output} -gt 7000 ]
}

@test "userpromptsubmit-foundation: #31411 no truncation is ever announced or logged" {
    _big_foundation_set > "$CACHE"
    manifest_now
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" != *'truncated'* ]]
    [[ "$output" != *'token cap'* ]]
    # The old log line recorded the length AFTER the cut, so all 1,457 entries on the
    # affected machine read "had 6000 chars". Nothing may write that line any more.
    if [ -f "$TEST_TMPDIR/mmry-foundation.log" ]; then
        run grep -c 'truncated Foundation reinjection' "$TEST_TMPDIR/mmry-foundation.log"
        [ "$output" = "0" ]
    fi
}

@test "userpromptsubmit-foundation: #31411 control - a small set is delivered unchanged" {
    printf -- '- Identity: Eric builds MMRY.\n- Value: clarity over cleverness.\n' > "$CACHE"
    manifest_now
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'Eric builds MMRY.'* ]]
    [[ "$output" == *'clarity over cleverness.'* ]]
    [[ "$output" != *'truncated'* ]]
}

# ============================================================================
# #31583 - A CACHE IS VERIFIED OR REFUSED. "NOT EMPTY" IS NOT A CHECK.
#
# The four tests the ticket names, in its order, plus the states either side of them.
# ============================================================================

@test "userpromptsubmit-foundation: #31583 TC1 a four-byte stub is refused, reported, and never presented as guidance" {
    printf -- '- Identity: Eric builds MMRY.\n- Value: clarity over cleverness.\n' > "$CACHE"
    manifest_now
    # The exact observed failure, byte for byte.
    printf -- '- x\n' > "$CACHE"
    [ "$(wc -c < "$CACHE")" -eq 4 ]

    run bash "$HANDLER"
    [ "$status" -eq 0 ]                      # never blocks the prompt
    [[ "$output" == *'could not verify'* ]]  # reported to the assistant
    [[ "$output" == *'systemMessage'* ]]     # and to the customer, who can act on it
    # The stub itself must not be forwarded under the authoritative framing.
    [[ "$output" != *'authoritative directives that take precedence'* ]]
}

@test "userpromptsubmit-foundation: #31583 TC2 the right size with the wrong content is refused" {
    printf -- '- Identity: Eric builds MMRY.\n- Value: clarity over cleverness.\n' > "$CACHE"
    manifest_now
    local n
    n="$(wc -c < "$CACHE")"
    # Same byte count, different bytes. A check that only measured length would pass this.
    head -c "$n" /dev/zero | tr '\0' 'z' > "$CACHE"
    [ "$(wc -c < "$CACHE")" -eq "$n" ]

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'could not verify'* ]]
    [[ "$output" == *'do not match'* ]]
    [[ "$output" != *'zzzz'* ]]
}

@test "userpromptsubmit-foundation: #31583 TC3 a removed cache behaves exactly as a damaged one" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    manifest_now
    rm -f "$CACHE"

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'could not verify'* ]]
    [[ "$output" == *'systemMessage'* ]]
}

@test "userpromptsubmit-foundation: #31583 TC4 a valid cache is delivered in full and says NOTHING" {
    _big_foundation_set > "$CACHE"
    manifest_now
    local total
    total="$(wc -c < "$CACHE")"

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    # The new check must not be satisfiable by warning all the time.
    [[ "$output" != *'could not verify'* ]]
    [[ "$output" != *'systemMessage'* ]]
    [[ "$output" == *'FinalDirective'* ]]

    # Delivered count against the account's true total, as the ticket asks for.
    [ -f "$TEST_TMPDIR/mmry-foundation.status" ]
    run cat "$TEST_TMPDIR/mmry-foundation.status"
    [[ "$output" == *"bytes=$total"* ]]
    [[ "$output" == *'entries=21'* ]]
}

@test "userpromptsubmit-foundation: #31583 a cache with no manifest cannot be shown to be the account's own, so it is refused" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    rm -f "${CACHE}.manifest"

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'could not verify'* ]]
    [[ "$output" != *'Eric builds MMRY'* ]]
}

@test "userpromptsubmit-foundation: #31583 a manifest that is present but malformed is refused, not ignored" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    printf 'garbage not a manifest\n' > "${CACHE}.manifest"

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'could not verify'* ]]
    [[ "$output" != *'Eric builds MMRY'* ]]
}

@test "userpromptsubmit-foundation: #31583 an account with genuinely NO Foundation memories is silent, not warned" {
    : > "$CACHE"
    printf 'mmry-foundation v1 entries=0 bytes=0 cksum=4294967295\n' > "${CACHE}.manifest"

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "userpromptsubmit-foundation: #31583 a session that has loaded nothing yet is silent, not warned" {
    rm -f "$CACHE" "${CACHE}.manifest"

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# #31583 TC3, the case the round-3 review measured as unreported.
#
# The test above and this one look alike and mean opposite things. There, nothing has ever
# been delivered, so nothing has been lost and silence is correct. Here a set WAS verified
# and delivered in this session and has since vanished from disk, which TC3 says must be
# reported exactly like damage. Before this fix both emitted nothing: QA delivered 294
# characters, deleted both files, fired again and got 0 characters, no systemMessage and no
# additionalContext. The deleted-cache-but-manifest-kept case was already reported, which is
# why the gap survived a round.
@test "userpromptsubmit-foundation: #31583 TC3 a set that DISAPPEARS after being delivered is reported, not passed over in silence" {
    printf -- '- Identity: Eric builds MMRY.
' > "$CACHE"
    manifest_now

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'Eric builds MMRY'* ]]

    # Both files, exactly as the reviewer did. Not just the cache.
    rm -f "$CACHE" "${CACHE}.manifest"
    [ ! -e "$CACHE" ]
    [ ! -e "${CACHE}.manifest" ]

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [[ "$output" == *'could not verify'* ]]
    [[ "$output" == *'disappeared'* ]]
    [[ "$output" == *'systemMessage'* ]]
}

# ============================================================================
# #31434 — the hook budget, the self-imposed deadline, and telling the customer.
#
# These tests drive the failure deliberately by making the handler SLOW, using the
# MMRY_JQ seam that lib-jq.sh already honours. No production test seam was added: a
# slow jq is exactly what a loaded machine produces. The shim answers --version
# instantly (the resolver probes it) and sleeps only on a real parse.
#
# Note the config file: with no config, mmry_load_config never invokes jq at all and
# the shim would never fire — a delay test that silently delays nothing is precisely
# the kind of check that cannot fail.
# ============================================================================

_make_slow_jq() {
    # $1 = seconds to sleep on a real parse
    local shim="$TEST_TMPDIR/slow-jq.sh"
    cat > "$shim" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == "--version" ]] && exec jq "\$@"; done
sleep $1
exec jq "\$@"
EOF
    chmod +x "$shim"
    printf '%s' "$shim"
}

_make_config() {
    cat > "$MMRY_CONFIG_FILE" <<'EOF'
{
  "apiUrl": "http://127.0.0.1:9",
  "authMethod": "apikey",
  "apiKey": "test-key",
  "foundationReinject": "true",
  "foundationReinjectTokenCap": 1500,
  "foundationRefreshSeconds": 0
}
EOF
}

_registered_timeout() {
    # The SHIPPED budget for this hook, read from the repo's hooks.json — not from an
    # installed cache and not from a hand-edited copy.
    jq -r '.hooks.UserPromptSubmit[].hooks[]
           | select(.command | test("userpromptsubmit-foundation")) | .timeout' \
        "$PLUGIN_ROOT/hooks/hooks.json"
}

@test "userpromptsubmit-foundation: slowed past the OLD 5s budget, still delivers the directives inside the shipped one" {
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    manifest_now
    _make_config
    # 6 s of extra latency, not the 7 s this used to inject (#31434 QA).
    #
    # NOT a weakened premise - the premise is "past the OLD 5 s budget", and 6 is. What
    # changed underneath it is the SHIPPED DEADLINE, cut from 15 s to 10 s so the plugin wins
    # its race against the harness with a stated margin instead of losing it. The handler's own
    # overhead measured 2.5-3 s on Windows Git Bash, so a 10 s deadline tolerates roughly 7 s
    # of added latency, and a 7 s injection sat exactly on that boundary: measured three times
    # outside the harness at 10.0/10.9/11.2 s it delivered, and inside the harness it was
    # killed. A test that flips on which side of a boundary the machine lands is not evidence
    # either way.
    #
    # The narrowed tolerance is a real consequence of the lower deadline and it is recorded
    # rather than papered over: see the residual-exposure note in hook-budgets.bats.
    local shim budget start elapsed
    shim="$(_make_slow_jq 6)"
    budget="$(_registered_timeout)"
    # The premise of the test: 6s must be past the old budget and inside the new one.
    (( 6 > 5 ))
    (( 6 < budget ))

    start="$(date +%s)"
    MMRY_JQ="$shim" run bash "$HANDLER"
    elapsed=$(( $(date +%s) - start ))

    [ "$status" -eq 0 ]
    # Asserted on the INJECTED CONTENT, not on the absence of a warning.
    [[ "$output" == *'never overstate evidence'* ]]
    [[ "$output" == *'"hookEventName":"UserPromptSubmit"'* ]]
    # It really was slow — otherwise this test proves nothing about the budget.
    (( elapsed >= 5 ))
    # And it still finished inside the budget the plugin actually ships.
    (( elapsed < budget ))
}

@test "userpromptsubmit-foundation: slowed past the DEADLINE, the turn proceeds and the customer is told" {
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    manifest_now
    _make_config
    local shim start elapsed budget
    shim="$(_make_slow_jq 20)"
    budget="$(_registered_timeout)"

    start="$(date +%s)"
    MMRY_JQ="$shim" MMRY_FOUNDATION_DEADLINE_SECS=3 run bash "$HANDLER"
    elapsed=$(( $(date +%s) - start ))

    # Did not hang: stopped itself at its own deadline, well inside the hook budget.
    [ "$status" -eq 0 ]
    (( elapsed >= 3 ))
    (( elapsed < 12 ))
    (( elapsed < budget ))
    # The user is told, in terms they can act on.
    [[ "$output" == *'systemMessage'* ]]
    [[ "$output" == *'NOT applied to this turn'* ]]
    # The remedy must name a command that EXISTS. This assertion previously read
    # '/mmry:reload-memories', which this plugin does not ship - so a green suite actively
    # defended handing a confused customer an unknown command at the one moment their
    # directives had just vanished. Now checked against commands/, not by eye.
    [[ "$output" == *'/mmry:load-memories'* ]]
    [ -f "$PLUGIN_ROOT/commands/load-memories.md" ]
    # The model is told too, so it cannot claim to be following directives it never got.
    [[ "$output" == *'running WITHOUT the account'* ]]
    # And it is still one valid JSON object.
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
    # It must NOT pretend to have delivered the Foundation set.
    [[ "$output" != *'never overstate evidence'* ]]
    # It must say the DEADLINE was hit, in the words reserved for that cause.
    [[ "$output" == *'exceeded'* ]]
    [[ "$output" != *'exit code'* ]]
    # And it must leave a trace. A failure that drops the customer's directives and records
    # nothing is how this defect survived three reports without anyone being able to act on it.
    grep -q 'foundation reinjection FAILED' "$TEST_TMPDIR/mmry-foundation.log"
    grep -q 'deadline exceeded' "$TEST_TMPDIR/mmry-foundation.log"
}

@test "userpromptsubmit-foundation: a worker that CRASHES is not reported as a slow one (#31434)" {
    # Found by review. The supervisor branched on a non-zero worker exit alone, so every
    # worker failure was announced as a timeout: with a broken install the worker exits 127
    # in well under a second and the customer was told "loading took over 15s" and to re-send
    # the prompt. A false cause, a false duration, and a remedy that cannot work. The watchdog
    # now records that it was the one who killed the worker, and the absence of that record is
    # what makes this path distinguishable.
    #
    # Induced without adding any test seam to production code. The supervisor re-executes this
    # file as a worker via `bash`, resolved from PATH; a broken environment where that `bash`
    # fails is exactly how the field produces a fast non-zero. 127 is the code the review
    # observed. The supervisor itself is invoked by absolute path so that only the WORKER
    # spawn is affected.
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    manifest_now
    rm -f "$TEST_TMPDIR/.mmry-foundation-inflight"
    local start elapsed shimdir real_bash
    real_bash="$(command -v bash)"
    shimdir="$TEST_TMPDIR/broken-bash"
    mkdir -p "$shimdir"
    printf '#!/bin/sh\nexit 127\n' > "$shimdir/bash"
    chmod +x "$shimdir/bash"

    start="$(date +%s)"
    PATH="$shimdir:$PATH" run "$real_bash" "$HANDLER"
    elapsed=$(( $(date +%s) - start ))

    [ "$status" -eq 0 ]
    # It failed FAST. Anything that took a deadline's worth of time is not this scenario.
    (( elapsed < 5 ))
    # Told as a failure, with the real exit code, and explicitly NOT as a duration.
    [[ "$output" == *'systemMessage'* ]]
    [[ "$output" == *'NOT applied to this turn'* ]]
    [[ "$output" == *'exit code'* ]]
    [[ "$output" == *'failure, not a slow turn'* ]]
    # The three lies the old single-branch version told, each asserted absent.
    [[ "$output" != *'exceeded'* ]]
    [[ "$output" != *'took over'* ]]
    [[ "$output" != *'Re-send the prompt to try again'* ]]
    # Still exactly one valid JSON object, and still no false claim of delivery.
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
    [[ "$output" != *'never overstate evidence'* ]]
    # Logged as a crash, not as a deadline, so the log agrees with what the customer was told.
    grep -q 'foundation reinjection FAILED' "$TEST_TMPDIR/mmry-foundation.log"
    grep -q 'without hitting' "$TEST_TMPDIR/mmry-foundation.log"
    # Counted, not `! grep -q`: a `!`-negated command is exempt from `set -e`, so the
    # original form could not fail this test even when the log DID say 'deadline exceeded'
    # - the one thing this assertion exists to catch (#31434 QA).
    (( $(grep -c 'deadline exceeded' "$TEST_TMPDIR/mmry-foundation.log" || true) == 0 ))
}

@test "userpromptsubmit-foundation: MMRY_DEBUG captures the stderr the handler otherwise discards (#31434)" {
    # The supervisor must never let stderr reach the terminal - it deliberately kills a
    # background job and the shell announces that at a moment nobody controls. But a feature
    # born of three unreproducible customer reports cannot also ship with field diagnostics
    # hard-wired to /dev/null, or the fourth report is just as unreproducible. MMRY_DEBUG
    # redirects rather than discards; the terminal contract is unchanged either way.
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    manifest_now
    local dbg="$TEST_TMPDIR/mmry-foundation-debug.log"

    # Default: nothing is captured anywhere.
    rm -f "$dbg"
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [ ! -f "$dbg" ]

    # Debug on: the same run is still clean on both of the customer's channels...
    rm -f "$dbg"
    MMRY_DEBUG=1 run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'never overstate evidence'* ]]
    # ...and the diagnostics now have somewhere to land.
    [ -f "$dbg" ]
}

@test "userpromptsubmit-foundation: a firing cut short by the harness is reported on the NEXT firing" {
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    manifest_now
    # The marker the supervisor leaves behind when it never reaches its own exit.
    : > "$TEST_TMPDIR/.mmry-foundation-inflight"

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'PREVIOUS turn'* ]]
    [[ "$output" == *'previous turn'* ]]          # the user-facing half
    # The miss is reported AND this turn's directives are still delivered.
    [[ "$output" == *'never overstate evidence'* ]]
    # The marker is consumed, so the report is not repeated forever.
    [ ! -f "$TEST_TMPDIR/.mmry-foundation-inflight" ]
}

@test "userpromptsubmit-foundation: a clean firing reports nothing and leaves no marker" {
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    manifest_now
    rm -f "$TEST_TMPDIR/.mmry-foundation-inflight"

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'never overstate evidence'* ]]
    # No notice of any kind on a healthy turn — a nag on every prompt would be its own bug.
    [[ "$output" != *'systemMessage'* ]]
    [[ "$output" != *'PREVIOUS turn'* ]]
    [ ! -f "$TEST_TMPDIR/.mmry-foundation-inflight" ]
}

@test "userpromptsubmit-foundation: no false alarm when there were no directives to lose" {
    # Marker present, but nothing to inject. Reporting a loss here would be a lie.
    rm -f "$CACHE"
    : > "$TEST_TMPDIR/.mmry-foundation-inflight"

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "userpromptsubmit-foundation: an absurd deadline value falls back to the default rather than disabling the guard" {
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    manifest_now
    MMRY_FOUNDATION_DEADLINE_SECS="not-a-number" run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'never overstate evidence'* ]]
}

@test "userpromptsubmit-foundation: awkward characters survive into valid JSON and come back out intact (#31434)" {
    # The escaping used to be `sed ':a;N;$!ba;s/\n/\n/g'`. That label-and-branch form is a GNU
    # extension and the BSD sed macOS ships rejects it, so on a Mac the error text went into the
    # handler's output and the emitted "JSON" was not JSON. The macOS CI leg had been red on
    # "emits valid JSON" since before this ticket, which is what an unread CI leg buys you.
    #
    # Asserted by ROUND-TRIPPING the content back out of the JSON, not by eyeballing the string:
    # a test that only checked "contains a backslash" would pass on double-escaped output too.
    printf -- '- Quote: he said "no".\n- Backslash: C:\Users\x\n- Tab:\tafter\n- Ampersand & percent %%\n' > "$CACHE"
    manifest_now

    run bash "$HANDLER"
    [ "$status" -eq 0 ]

    local ctx
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" == *'he said "no".'* ]]
    [[ "$ctx" == *'C:\Users\x'* ]]
    [[ "$ctx" == *'Ampersand & percent %'* ]]
    # The newlines are real newlines again after the round trip, not a literal backslash-n.
    [ "$(printf '%s' "$ctx" | wc -l)" -ge 4 ]
    # And a tab is a tab.
    printf '%s' "$ctx" | grep -q "$(printf 'Tab:\tafter')"
}

@test "userpromptsubmit-foundation: nothing is left holding an inherited descriptor after it exits (#31434)" {
    # THE BUG THIS EXISTS FOR, and the reason to distrust a green suite.
    #
    # The supervisor's first watchdog was `( sleep "$DEADLINE"; kill ... ) &`, killed after the
    # wait. Killing the subshell ORPHANS its sleep, and the orphan keeps every descriptor it
    # inherited. Whoever reads the hook waits for the LAST WRITER to close, not for the handler
    # to exit - so the reader sat there for the entire deadline while the handler had long since
    # produced its answer.
    #
    # Two things this assertion had to get right, both learned by getting them wrong:
    #
    #  1. stdout alone does NOT catch it. The old watchdog redirected its own stdout to
    #     /dev/null, so `bash handler | cat` finished in about 500 ms either way.
    #  2. Measuring bats' own `run` does not catch it reliably either - the first version of
    #     this test did that, and it passed against the broken watchdog.
    #
    # So it reproduces the condition directly: attach an EXTRA descriptor to the same pipe the
    # output is read from, then measure time to EOF. Measured this way: 15155/15170/15155 ms
    # with the orphan against a 15 s deadline, 494/515/604/567/572 ms without it.
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    manifest_now
    rm -f "$TEST_TMPDIR/.mmry-foundation-inflight"

    local start elapsed captured
    start="$(date +%s)"
    captured="$( { MMRY_FOUNDATION_DEADLINE_SECS=12 bash "$HANDLER" </dev/null; } 3>&1 )"
    elapsed=$(( $(date +%s) - start ))

    # The answer is right...
    [[ "$captured" == *'never overstate evidence'* ]]
    # ...and the reader was released as soon as it was produced, not at the deadline.
    echo "time to EOF with an extra inherited descriptor: ${elapsed}s against a 12s deadline" >&3
    (( elapsed < 6 ))
}

@test "userpromptsubmit-foundation: a firing killed outright LEAVES the marker, end to end (#31434)" {
    # Found by mutation, not by inspection. The test above creates the in-flight marker by hand
    # and asserts it is READ. Deleting the line that WRITES it therefore changed nothing and the
    # whole suite stayed green - a handler that never records a firing can never report a lost
    # one, which is the entire feature. This drives the real sequence instead.
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    manifest_now
    rm -f "$TEST_TMPDIR/.mmry-foundation-inflight"
    cat > "$MMRY_CONFIG_FILE" <<'EOF'
{
  "apiUrl": "http://127.0.0.1:9",
  "authMethod": "apikey",
  "apiKey": "test-key",
  "foundationReinject": "true",
  "foundationRefreshSeconds": 0
}
EOF
    local shim; shim="$(_make_slow_jq 20)"

    # SIGKILL, because that is what the harness does on timeout: no trap, no cleanup, nothing.
    MMRY_JQ="$shim" bash "$HANDLER" >/dev/null 2>&1 </dev/null &
    local victim=$!
    sleep 2
    kill -9 "$victim" 2>/dev/null
    wait "$victim" 2>/dev/null || true

    # The evidence that a turn was lost has to survive the kill, or nobody can ever be told.
    [ -f "$TEST_TMPDIR/.mmry-foundation-inflight" ]

    # The same kill ORPHANS this firing's out-file - the worker outlives its supervisor and
    # goes on writing to a file no one will ever read. Deleting the sweep that reaps it turned
    # nothing red until these two lines existed, so a leak that grows with every timeout in the
    # customer's temp directory was shipping untested. The condition already existed here; only
    # the assertions were missing.
    [ -f "$TEST_TMPDIR/.mmry-foundation-out.$victim" ]

    # And the next firing picks it up and says so, on both channels.
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'PREVIOUS turn'* ]]
    [[ "$output" == *'previous turn'* ]]
    [[ "$output" == *'never overstate evidence'* ]]
    [ ! -f "$TEST_TMPDIR/.mmry-foundation-inflight" ]
    # ...and that same firing reaps the orphan, because its supervisor no longer exists.
    [ ! -f "$TEST_TMPDIR/.mmry-foundation-out.$victim" ]
}

# ============================================================================
# #31434 QA - the off switch the failure notices recommend.
#
# Both failure notices tell the customer to set foundationReinject to false. That advice was
# INERT on the path that gave it: the toggle was read only by the worker, via mmry_load_config,
# and the crash branch runs precisely when the worker could not run. A reviewer set it in the
# config AND in the environment and the banner fired anyway, on every prompt, with no way to
# stop it. These tests exist so that cannot ship again.
#
# Each one carries its CONTROL in the same test - a run that must produce the banner - because
# "no banner" is the passing state here, and a test whose pass condition is silence will also
# pass when the handler has simply stopped working.
# ============================================================================

_make_broken_bash() {
    # A PATH bash that fails instantly: the supervisor re-execs this file as a worker via
    # `bash` resolved from PATH, so this is how the field produces a fast non-zero exit.
    local d="$TEST_TMPDIR/broken-bash"
    mkdir -p "$d"
    printf '#!/bin/sh
exit 127
' > "$d/bash"
    chmod +x "$d/bash"
    printf '%s' "$d"
}

_write_toggle_config() {
    # $1 = the raw JSON value for foundationReinject
    cat > "$MMRY_CONFIG_FILE" <<EOF
{
  "apiUrl": "http://127.0.0.1:9",
  "authMethod": "apikey",
  "apiKey": "test-key",
  "foundationReinject": $1,
  "foundationReinjectTokenCap": 1500,
  "foundationRefreshSeconds": 0
}
EOF
}

@test "userpromptsubmit-foundation: foundationReinject=false in CONFIG silences the crash notice it recommends (#31434 QA)" {
    printf -- '- Truthfulness: never overstate evidence.
' > "$CACHE"
manifest_now
    local real_bash shimdir
    real_bash="$(command -v bash)"
    shimdir="$(_make_broken_bash)"

    # CONTROL FIRST: with the toggle ON, this exact scenario must produce the banner.
    # Without it the test would also pass against a handler that did nothing at all.
    _write_toggle_config '"true"'
    rm -f "$TEST_TMPDIR/.mmry-foundation-inflight"
    PATH="$shimdir:$PATH" run "$real_bash" "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'NOT applied to this turn'* ]]

    # Now the remedy the notice just handed the customer.
    _write_toggle_config '"false"'
    rm -f "$TEST_TMPDIR/.mmry-foundation-inflight"
    PATH="$shimdir:$PATH" run "$real_bash" "$HANDLER"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "userpromptsubmit-foundation: a JSON boolean false is honoured too, not just the string (#31434 QA)" {
    # The README documents `false`; mmry_load_config tostring's it into "false". The supervisor
    # reads the file without jq, so the bare boolean is the spelling most likely to be missed.
    printf -- '- Truthfulness: never overstate evidence.
' > "$CACHE"
manifest_now
    local real_bash shimdir
    real_bash="$(command -v bash)"
    shimdir="$(_make_broken_bash)"

    _write_toggle_config 'true'
    rm -f "$TEST_TMPDIR/.mmry-foundation-inflight"
    PATH="$shimdir:$PATH" run "$real_bash" "$HANDLER"
    [[ "$output" == *'NOT applied to this turn'* ]]

    _write_toggle_config 'false'
    rm -f "$TEST_TMPDIR/.mmry-foundation-inflight"
    PATH="$shimdir:$PATH" run "$real_bash" "$HANDLER"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "userpromptsubmit-foundation: the ENVIRONMENT off switch silences the crash notice, and outranks the config (#31434 QA)" {
    printf -- '- Truthfulness: never overstate evidence.
' > "$CACHE"
manifest_now
    local real_bash shimdir
    real_bash="$(command -v bash)"
    shimdir="$(_make_broken_bash)"
    # The config says ON throughout, so a pass here can only come from the environment override
    # being honoured - and it must be honoured by the SUPERVISOR, since no worker ever starts.
    _write_toggle_config '"true"'

    rm -f "$TEST_TMPDIR/.mmry-foundation-inflight"
    PATH="$shimdir:$PATH" run "$real_bash" "$HANDLER"
    [[ "$output" == *'NOT applied to this turn'* ]]

    rm -f "$TEST_TMPDIR/.mmry-foundation-inflight"
    MMRY_FOUNDATION_REINJECT=false PATH="$shimdir:$PATH" run "$real_bash" "$HANDLER"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "userpromptsubmit-foundation: the off switch also silences the DEADLINE notice (#31434 QA)" {
    # The other half of the same promise, and the path the customer is most likely trying to
    # escape. The opt-out is answered before the worker exists, so an opted-out customer does
    # not even wait out a deadline to be told about a feature they switched off.
    printf -- '- Truthfulness: never overstate evidence.
' > "$CACHE"
manifest_now
    local shim start elapsed
    shim="$(_make_slow_jq 30)"

    _write_toggle_config '"false"'
    rm -f "$TEST_TMPDIR/.mmry-foundation-inflight"
    start="$(date +%s)"
    MMRY_JQ="$shim" MMRY_FOUNDATION_DEADLINE_SECS=3 run bash "$HANDLER"
    elapsed=$(( $(date +%s) - start ))

    [ "$status" -eq 0 ]
    [ -z "$output" ]
    (( elapsed < 3 ))
}

# ============================================================================
# #31583 - "entries=0" IS A CLAIM ABOUT THE CACHE, AND IT HAS TO BE CHECKED TOO.
#
# The verification gate is bytes + cksum, and entries is not part of it. That is correct
# for a mismatch in either direction but ONE value of entries short-circuits the gate
# entirely: zero. Zero means "this account has no Foundation memories", and the handler
# answers it by going silent, which is right for an account that genuinely has none.
#
# Measured, not reasoned: with a manifest reading entries=0 beside a cache holding 914
# bytes of real directives, the handler exits 0 and emits NOTHING AT ALL. The directives
# are withheld and nobody is told - the precise shape of this ticket, reached through the
# one field the gate does not check. A manifest left behind by an older writer, a partial
# write, or anything on the machine that drops a plausible manifest next to a good cache
# gets there.
#
# So the empty claim is checked against the file the same way every other claim is.
# ============================================================================

@test "userpromptsubmit-foundation: #31583 a manifest claiming no directives beside a cache full of them is refused, not obeyed" {
    printf -- '- Identity: Eric builds MMRY.\n- Value: clarity over cleverness.\n' > "$CACHE"
    manifest_now
    # Same bytes, same checksum, only the count claims the set is empty.
    local s b
    read -r s b < <(cksum < "$CACHE")
    printf 'mmry-foundation v1 entries=0 bytes=%s cksum=%s\n' "$b" "$s" > "${CACHE}.manifest"

    run bash "$HANDLER"
    [ "$status" -eq 0 ]                      # never blocks the prompt
    [[ "$output" == *'could not verify'* ]]  # the assistant is told
    [[ "$output" == *'systemMessage'* ]]     # and so is the customer
    # And it must not be quietly forwarded under the authoritative framing either.
    [[ "$output" != *'authoritative directives that take precedence'* ]]
}

@test "userpromptsubmit-foundation: #31583 the empty-set path still stays silent when the cache really is empty" {
    # The control for the test above: this must not become "warn whenever entries=0".
    : > "$CACHE"
    printf 'mmry-foundation v1 entries=0 bytes=0 cksum=4294967295\n' > "${CACHE}.manifest"

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# #31583 UPGRADE RECOVERY. Found while verifying TC4, not reported by review.
#
# A cache written by a plugin older than this one has no manifest, because the manifest is
# what this ticket introduced. Refusing it is correct and must stay correct: writing a
# manifest for whatever is on disk would bless the four-byte stub the ticket exists to catch.
# What was wrong is that nothing rebuilt it, so the customer was warned on EVERY prompt for
# the rest of the session and it never cleared. Measured before the fix on a manifest-less
# cache: refused three times out of three, 922 characters of notice each time, no manifest
# ever appearing. The age-gated daily refresh cannot cover it, because an unmanifested cache
# is typically brand new and its age is zero.
#
# The stub below replaces the refresh with one that succeeds, because the point of the test is
# what the customer experiences on the NEXT prompt, not whether the network works.
_plugin_with_working_refresh() {
    RECOVER_ROOT="$TEST_TMPDIR/recover-plugin"
    cp -R "$PLUGIN_ROOT" "$RECOVER_ROOT"
    local client="$RECOVER_ROOT/hooks-handlers/mmry-client.sh"
    awk '{ print } /^mmry_refresh_foundation_cache\(\) \{$/ {
        print "    printf -- '"'"'- Rebuilt: the set came back.\n'"'"' > \"$2\""
        # NO manifest helper call here (#31583 QA round 4). The first version of this stub
        # called mmry_write_foundation_manifest_for, which does not exist: it returned 127
        # and the fallback below always ran, so the call was decoration that read like logic.
        print "        local _s _b; read -r _s _b < <(cksum < \"$2\")"
        print "        printf '"'"'mmry-foundation v1 entries=1 bytes=%s cksum=%s\n'"'"' \"$_b\" \"$_s\" > \"$2.manifest\""
        print "    }"
        print "    return 0"
    }' "$client" > "$client.tmp"
    mv "$client.tmp" "$client"

    # Anchored to POSITION, the round-2 lesson: assert the line immediately after the header
    # is the injected one, so a pattern that stops matching cannot leave the real refresh in
    # place while the test goes green against the healthy path.
    local after
    after="$(awk '/^mmry_refresh_foundation_cache\(\) \{$/ { getline; print; exit }' "$client")"
    case "$after" in
        *Rebuilt*) : ;;
        *) echo "injection did not land: line after the header was [$after]"; return 1 ;;
    esac
}

@test "userpromptsubmit-foundation: #31583 a cache from an OLDER plugin is refused once, then rebuilt, not warned about forever" {
    _plugin_with_working_refresh

    # Exactly what an upgrading customer has on disk: good content, no manifest.
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    [ ! -e "${CACHE}.manifest" ]

    # Prompt 1: refused, correctly, because nothing here can be verified.
    MMRY_API_KEY=dummy run bash "$RECOVER_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'could not verify'* ]]

    # The recovery was ATTEMPTED, which is the whole fix. Before it, nothing happened at all.
    [ -e "$TEST_TMPDIR/.mmry-foundation-rebuild" ]

    # The background rebuild is detached, so give it a moment to land rather than racing it.
    local _i=0
    while [ $_i -lt 50 ] && [ ! -e "${CACHE}.manifest" ]; do _i=$(( _i + 1 )); sleep 0.1; done
    [ -e "${CACHE}.manifest" ]

    # Prompt 2: the customer is out of it. Delivered, and silent.
    MMRY_API_KEY=dummy run bash "$RECOVER_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'Rebuilt'* ]]
    [[ "$output" != *'could not verify'* ]]
    [[ "$output" != *'systemMessage'* ]]
}

# #31583 QA round 4. One sentence used to cover every refusal, telling the customer the local
# copy "did not match the record MMRY wrote". For the states where there IS no record, no
# comparison happened and the sentence contradicted its own first clause. Six of eight
# reviewers raised it, and no-manifest is the state EVERY upgrading customer meets.
@test "userpromptsubmit-foundation: #31583 an upgraded customer is told it is an upgrade, not damage" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    rm -f "${CACHE}.manifest"

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'upgrading the MMRY plugin'* ]]
    [[ "$output" == *'next prompt will use it'* ]]
    [[ "$output" == *'No action needed'* ]]
    # And it must NOT claim a comparison that never happened, nor prescribe a rebuild the
    # customer does not need to run.
    [[ "$output" != *'did not match the record'* ]]
}

@test "userpromptsubmit-foundation: #31583 a genuinely damaged copy still says so and still prescribes the rebuild" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    manifest_now
    # Same length, different bytes: the classic substitution, where a comparison really did
    # happen and really did fail.
    printf -- '- Identity: someone elses text!\n' > "$CACHE"

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'did not match the record'* ]]
    [[ "$output" == *'load-memories'* ]]
    [[ "$output" != *'upgrading the MMRY plugin'* ]]
}
