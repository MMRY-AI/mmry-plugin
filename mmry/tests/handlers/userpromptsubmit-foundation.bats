#!/usr/bin/env bats
# userpromptsubmit-foundation.bats — UserPromptSubmit Foundation re-injection handler (#30579).
# The handler inlines the session-local Foundation cache on every prompt, framed as
# authoritative. It must NEVER block a prompt: any problem -> emit nothing, exit 0.

load '../helpers/test-helper'
load '../helpers/foundation-set'

setup() {
    HANDLER="$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    CACHE="$TEST_TMPDIR/mmry-foundation.md"
    SET="$TEST_TMPDIR/mmry-foundation-set.md"
    # Every real session has one of these: SessionStart writes the session id here and clears
    # the delivery record beside it (#31583 QA round 4, finding 4c). Without it the handler
    # cannot tell its own delivery record from one an earlier session left in a shared temp
    # directory, and correctly fails safe by staying quiet. A fixture with no token is
    # therefore testing the no-SessionStart path, not the ordinary one.
    printf 'session-under-test' > "$TEST_TMPDIR/mmry-foundation.session"
}

# Seal whatever is staged in $CACHE into the set file the hook reads (#31583, #31597).
#
# The handler no longer believes a set just because it is not empty - it verifies the bytes
# against the record the writer put on the set file's first line. Tests that put a set in place by
# hand therefore stage the directives in $CACHE and seal them, exactly as mmry_write_foundation_cache
# would, or they are testing the refusal path by accident.
#
# $CACHE keeps the name plugin 2.9.1 writes, mmry-foundation.md, and since #31597 the hook never
# reads that name: every test here therefore also shows that a 2.9.1 file sitting beside the set is
# ignored. A test that means to damage what the hook reads acts on $SET, after sealing.
#
# Entry count defaults to the number of lines beginning "- ". That is good enough for
# fixtures; the production writer counts from the API response instead, because memory
# CONTENT can also contain such lines.
manifest_now() {
    fnd_seal "${1:-$CACHE}" "${2:-}" "$SET"
}

@test "userpromptsubmit-foundation: reinjects cached Foundation memories inline with authoritative framing" {
    printf -- '- Identity: Eric builds MMRY.\n- Value: clarity over cleverness.\n' > "$CACHE"
    manifest_now
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"hookEventName":"UserPromptSubmit"'* ]] || return 1
    [[ "$output" == *'"additionalContext"'* ]] || return 1
    [[ "$output" == *'FOUNDATION'* ]] || return 1
    [[ "$output" == *'authoritative'* ]] || return 1
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
    # The file the hook reads and ages is the set file, not the staged copy (#31597). Touching the
    # staged copy left the set file new, so this passed only when a second happened to elapse.
    touch -t 202001010000 "$SET"   # force the set to look stale
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

# #31597 r2, TC4 (Lead/PM decision 2026-10-06): an empty set is told to the customer once a session,
# so the first prompt that finds one says so on the customer's channel, and later prompts are silent.
@test "userpromptsubmit-foundation: an empty set tells the customer once, frames nothing, and exits 0" {
    : > "$CACHE"
    manifest_now
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")" = "" ] || return 1
    [[ "$(jq -r '.systemMessage' <<<"$output")" == *'this account has no Foundation directives'* ]] || return 1
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
    [[ "$output" == *'Directive 00'* ]] || return 1
    [[ "$output" == *'Directive 19'* ]] || return 1
    [[ "$output" == *'FinalDirective: this last line must arrive intact and uncut.'* ]] || return 1
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
    [[ "$output" == *'FinalDirective: this last line must arrive intact and uncut.'* ]] || return 1
    [[ "$output" != *'truncated'* ]] || return 1
    [ ${#output} -gt 7000 ]
}

@test "userpromptsubmit-foundation: #31411 no truncation is ever announced or logged" {
    _big_foundation_set > "$CACHE"
    manifest_now
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" != *'truncated'* ]] || return 1
    [[ "$output" != *'token cap'* ]] || return 1
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
    [[ "$output" == *'Eric builds MMRY.'* ]] || return 1
    [[ "$output" == *'clarity over cleverness.'* ]] || return 1
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
    # The exact observed failure, byte for byte, in the file the hook reads (#31597).
    printf -- '- x\n' > "$SET"
    [ "$(wc -c < "$SET" | tr -d ' ')" -eq 4 ]

    run bash "$HANDLER"
    [ "$status" -eq 0 ]                      # never blocks the prompt
    [[ "$output" == *'could not verify'* ]] || return 1  # reported to the assistant
    [[ "$output" == *'systemMessage'* ]] || return 1     # and to the customer, who can act on it
    # The stub itself must not be forwarded under the authoritative framing.
    [[ "$output" != *'authoritative directives that take precedence'* ]]
}

@test "userpromptsubmit-foundation: #31583 TC2 the right size with the wrong content is refused" {
    printf -- '- Identity: Eric builds MMRY.\n- Value: clarity over cleverness.\n' > "$CACHE"
    manifest_now
    local n rec
    n="$(wc -c < "$CACHE" | tr -d ' ')"
    rec="$(fnd_set_record)"
    # Same record, same byte count, different bytes. A check that only measured length would pass.
    fnd_set_with "$rec" "$(head -c "$n" /dev/zero | tr '\0' 'z')"
    [ "$(fnd_set_body | wc -c | tr -d ' ')" -eq "$n" ]

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'could not verify'* ]] || return 1
    [[ "$output" == *'do not match'* ]] || return 1
    [[ "$output" != *'zzzz'* ]]
}

@test "userpromptsubmit-foundation: #31583 TC3 a removed cache behaves exactly as a damaged one" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    manifest_now
    # What SessionStart leaves once it has stored a set (#31597): the evidence that one existed.
    # With the record inside the set file, deleting the file deletes the record too, so without
    # this a set removed before its first delivery would be silent.
    bash -c 'source "$1/hooks-handlers/mmry-client.sh" >/dev/null 2>&1; mmry_foundation_mark_stored "$2" "" 1' _ "$PLUGIN_ROOT" "$TEST_TMPDIR"
    rm -f "$SET"

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'could not verify'* ]] || return 1
    [[ "$output" == *'the cache holding them is missing'* ]] || return 1
    [[ "$output" == *'systemMessage'* ]]
}

@test "userpromptsubmit-foundation: #31583 TC4 a valid cache is delivered in full and says NOTHING" {
    _big_foundation_set > "$CACHE"
    manifest_now
    local total
    # Spaces stripped: BSD wc pads the count ("      11"), and this is matched as text below, so on
    # macOS the assertion looked for "bytes=      11" beside a record holding "bytes=11" (#31411 QA,
    # Mac bench at 4733efa). It only showed once the assertion gained its || return 1 and could fail.
    total="$(wc -c < "$CACHE" | tr -d ' ')"

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    # The new check must not be satisfiable by warning all the time.
    [[ "$output" != *'could not verify'* ]] || return 1
    [[ "$output" != *'systemMessage'* ]] || return 1
    [[ "$output" == *'FinalDirective'* ]] || return 1

    # Delivered count against the account's true total, as the ticket asks for.
    [ -f "$TEST_TMPDIR/mmry-foundation.status" ]
    run cat "$TEST_TMPDIR/mmry-foundation.status"
    [[ "$output" == *"bytes=$total"* ]] || return 1
    [[ "$output" == *'entries=21'* ]]
}

@test "userpromptsubmit-foundation: #31597 a set file with no record line cannot be shown to be the account's own, so it is refused" {
    # Plain directives where the set file should be, the shape of the 2026-09-18 stub.
    printf -- '- Identity: Eric builds MMRY.\n' > "$SET"

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'could not verify'* ]] || return 1
    [[ "$output" != *'Eric builds MMRY'* ]]
}

@test "userpromptsubmit-foundation: #31583 a record that is present but malformed is refused, not ignored" {
    fnd_set_with 'mmry-foundation v2 garbage not a record' $'- Identity: Eric builds MMRY.\n'

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'could not verify'* ]] || return 1
    [[ "$output" != *'Eric builds MMRY'* ]]
}

# #31597 r2, TC4: told once a session, not warned. It is not a fault, so none of the refusal words, and
# not on every prompt, which #31583 removed.
@test "userpromptsubmit-foundation: #31583 an account with genuinely NO Foundation memories is told once, not warned" {
    : > "$CACHE"
    manifest_now "$CACHE" 0    # a real empty set: record says none, body empty (#31597)

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'this account has no Foundation directives'* ]] || return 1
    [[ "$output" != *'could not verify'* ]] || return 1
    [[ "$output" != *'NOT applied'* ]] || return 1
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "userpromptsubmit-foundation: #31583 a session that has loaded nothing yet is silent, not warned" {
    rm -f "$CACHE" "$SET"

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
    [[ "$output" == *'Eric builds MMRY'* ]] || return 1

    # The set file, which holds the record too (#31597), and the staged copy.
    rm -f "$CACHE" "$SET"
    [ ! -e "$CACHE" ]
    [ ! -e "$SET" ]

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [[ "$output" == *'could not verify'* ]] || return 1
    [[ "$output" == *'disappeared'* ]] || return 1
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
    jq -r '[.hooks.UserPromptSubmit[].hooks[] | select(.command | test("userpromptsubmit-foundation")) | .timeout] | unique | if length == 1 then .[0] else "DISAGREE" end' \
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
    (( 6 > 5 )) || return 1
    (( 6 < budget )) || return 1

    start="$(date +%s)"
    MMRY_JQ="$shim" run bash "$HANDLER"
    elapsed=$(( $(date +%s) - start ))

    [ "$status" -eq 0 ]
    # Asserted on the INJECTED CONTENT, not on the absence of a warning.
    [[ "$output" == *'never overstate evidence'* ]] || return 1
    [[ "$output" == *'"hookEventName":"UserPromptSubmit"'* ]] || return 1
    # It really was slow — otherwise this test proves nothing about the budget.
    (( elapsed >= 5 )) || return 1
    # And it still finished inside the budget the plugin actually ships.
    (( elapsed < budget ))
}

@test "userpromptsubmit-foundation: slowed past the DEADLINE, the turn proceeds and the customer is told" {
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    manifest_now
    _make_config
    local shim start elapsed budget
    # LOAD (#31411 QA round 3, item 8). Bounded at 12 s against a 20 s jq, this stopwatch could fail on
    # a machine two other suites were loading while the handler did the right thing. The jq now takes a
    # minute and the bound sits at 30 s: a handler with no working deadline waits the whole minute, and
    # the right path does not take 30 s however busy the machine.
    shim="$(_make_slow_jq 60)"
    budget="$(_registered_timeout)"

    start="$(date +%s)"
    MMRY_JQ="$shim" MMRY_FOUNDATION_DEADLINE_SECS=3 run bash "$HANDLER"
    elapsed=$(( $(date +%s) - start ))

    # Did not hang: stopped itself at its own deadline, well inside the hook budget.
    [ "$status" -eq 0 ]
    (( elapsed >= 3 )) || return 1
    # Not waiting for the jq: a handler with no deadline takes the jq's 60 s.
    (( elapsed < 30 )) || return 1
    (( elapsed < budget )) || return 1
    # The user is told, in terms they can act on.
    [[ "$output" == *'systemMessage'* ]] || return 1
    [[ "$output" == *'NOT applied to this turn'* ]] || return 1
    # The remedy must name a command that EXISTS. This assertion previously read
    # '/mmry:reload-memories', which this plugin does not ship - so a green suite actively
    # defended handing a confused customer an unknown command at the one moment their
    # directives had just vanished. Now checked against commands/, not by eye.
    [[ "$output" == *'/mmry:load-memories'* ]] || return 1
    [ -f "$PLUGIN_ROOT/commands/load-memories.md" ]
    # The model is told too, so it cannot claim to be following directives it never got.
    [[ "$output" == *'running WITHOUT the account'* ]] || return 1
    # And it is still one valid JSON object.
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
    # It must NOT pretend to have delivered the Foundation set.
    [[ "$output" != *'never overstate evidence'* ]] || return 1
    # It must say the DEADLINE was hit, in the words reserved for that cause.
    [[ "$output" == *'exceeded'* ]] || return 1
    [[ "$output" != *'exit code'* ]] || return 1
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

    # LOAD (#31411 QA round 3, item 8). This stopwatch failed when two other suites shared the machine
    # and passed alone, while the handler took the correct crash path every time (17 of 17, QA #1). The
    # deadline is now a minute and the bound 30 s: a crash that waited for the deadline cannot finish
    # under 60, and a fast crash does not take 30 however busy the machine.
    start="$(date +%s)"
    MMRY_FOUNDATION_DEADLINE_SECS=60 PATH="$shimdir:$PATH" run "$real_bash" "$HANDLER"
    elapsed=$(( $(date +%s) - start ))

    [ "$status" -eq 0 ]
    # It failed FAST. Anything that took a deadline's worth of time is not this scenario.
    (( elapsed < 30 )) || return 1
    # Told as a failure, with the real exit code, and explicitly NOT as a duration.
    [[ "$output" == *'systemMessage'* ]] || return 1
    [[ "$output" == *'NOT applied to this turn'* ]] || return 1
    [[ "$output" == *'exit code'* ]] || return 1
    [[ "$output" == *'failure, not a slow turn'* ]] || return 1
    # The three lies the old single-branch version told, each asserted absent.
    [[ "$output" != *'exceeded'* ]] || return 1
    [[ "$output" != *'took over'* ]] || return 1
    [[ "$output" != *'Re-send the prompt to try again'* ]] || return 1
    # Still exactly one valid JSON object, and still no false claim of delivery.
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
    [[ "$output" != *'never overstate evidence'* ]] || return 1
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
    [[ "$output" == *'never overstate evidence'* ]] || return 1
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
    [[ "$output" == *'PREVIOUS turn'* ]] || return 1
    [[ "$output" == *'previous turn'* ]] || return 1          # the user-facing half
    # The miss is reported AND this turn's directives are still delivered.
    [[ "$output" == *'never overstate evidence'* ]] || return 1
    # The marker is consumed, so the report is not repeated forever.
    [ ! -f "$TEST_TMPDIR/.mmry-foundation-inflight" ]
}

@test "userpromptsubmit-foundation: a clean firing reports nothing and leaves no marker" {
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    manifest_now
    rm -f "$TEST_TMPDIR/.mmry-foundation-inflight"

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'never overstate evidence'* ]] || return 1
    # No notice of any kind on a healthy turn — a nag on every prompt would be its own bug.
    [[ "$output" != *'systemMessage'* ]] || return 1
    [[ "$output" != *'PREVIOUS turn'* ]] || return 1
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

# ---------------------------------------------------------------------------------------------
# THE SAME TWO NOTICES, ON A CONFIGURED CODEX INSTALL (#31245 QA round 6).
#
# The round-4 fix in this handler makes an UNCONFIGURED Codex install exit silently rather than
# printing the crash notice. It did nothing for a CONFIGURED one, which is the ordinary case and
# still reaches both notices on any worker failure. QA reproduced 725 bytes of it on a configured
# install hitting the deadline, naming /mmry:load-memories - a command Codex customers cannot type
# - and ~/.claude/mmry-config.json, the OTHER product's file.
#
# Both branches are covered, because fixing the branch somebody looked at and leaving its sibling
# three lines below is the defect this task keeps repeating. Each is paired with its Claude control
# asserting the literal is unchanged, so a handler that "fixes" this by naming no remedy at all
# fails rather than passes.

_codex_home_with_credential() {
    # A Codex home that is NOT the default, because the customer this feature exists for is the one
    # who moved it, and a message built from a hardcoded ~/.codex would pass against the default.
    local d="$TEST_TMPDIR/codexhome"
    mkdir -p "$d/mmry"
    cat > "$d/mmry-config.json" <<'EOF'
{
  "apiUrl": "http://127.0.0.1:9",
  "authMethod": "apikey",
  "apiKey": "test-key",
  "foundationReinject": "true",
  "foundationReinjectTokenCap": 1500,
  "foundationRefreshSeconds": 0
}
EOF
    printf '%s' "$d"
}

@test "userpromptsubmit-foundation: a CONFIGURED Codex install past the deadline is told something it can do" {
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    manifest_now   # 31411 refuses a cache with no manifest beside it
    _make_config
    local shim codex
    shim="$(_make_slow_jq 20)"
    codex="$(_codex_home_with_credential)"

    MMRY_JQ="$shim" MMRY_FOUNDATION_DEADLINE_SECS=3 \
        MMRY_HOST=codex CODEX_HOME="$codex" \
        run bash "$HANDLER"

    [ "$status" -eq 0 ]
    # It still fires: a configured install is NOT silenced by the round-4 unconfigured-install
    # guard, and a test that merely asserted silence here would pass against the defect.
    [[ "$output" == *'systemMessage'* ]] || return 1
    [[ "$output" == *'NOT applied to this turn'* ]] || return 1
    [[ "$output" == *'exceeded'* ]] || return 1

    # THE DEFECT, ASSERTED AS ABSENT.
    [[ "$output" != *'/mmry:load-memories'* ]] || return 1
    [[ "$output" != *'~/.claude/mmry-config.json'* ]] || return 1

    # AND THE REMEDY, ASSERTED AS PRESENT. Absence alone is satisfied by a notice that stopped
    # offering any remedy at all, which is worse for the customer, not better.
    [[ "$output" == *"bash ${codex}/mmry/hooks-handlers/session-start.sh"* ]] || return 1
    [[ "$output" == *"${codex}/mmry-config.json"* ]] || return 1
    # The script it names is really there. A path that reads plausibly and is not on disk is the
    # same failure in a nicer font.
    [ -f "$PLUGIN_ROOT/hooks-handlers/session-start.sh" ]
}

@test "userpromptsubmit-foundation: req4 - and on Claude Code that deadline notice is unchanged" {
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    manifest_now   # 31411 refuses a cache with no manifest beside it
    _make_config
    local shim
    shim="$(_make_slow_jq 20)"

    MMRY_JQ="$shim" MMRY_FOUNDATION_DEADLINE_SECS=3 run bash "$HANDLER"

    [ "$status" -eq 0 ]
    [[ "$output" == *'systemMessage'* ]] || return 1
    [[ "$output" == *'/mmry:load-memories'* ]] || return 1
    [[ "$output" == *'~/.claude/mmry-config.json'* ]] || return 1
    [ -f "$PLUGIN_ROOT/commands/load-memories.md" ]
}

@test "userpromptsubmit-foundation: a CONFIGURED Codex install whose worker CRASHES gets the same treatment" {
    # The sibling branch. Round 4 fixed the notice's unconfigured case; this is the one three
    # lines below it in the same if/else, which round 5 shipped untouched.
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    manifest_now   # 31411 refuses a cache with no manifest beside it
    _make_config
    local shim codex
    shim="$TEST_TMPDIR/broken-jq.sh"
    cat > "$shim" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == "--version" ]] && exec jq "$@"; done
exit 9
EOF
    chmod +x "$shim"
    codex="$(_codex_home_with_credential)"

    MMRY_JQ="$shim" MMRY_HOST=codex CODEX_HOME="$codex" run bash "$HANDLER"

    [ "$status" -eq 0 ]
    if [[ "$output" != *'systemMessage'* ]]; then
        # The crash branch is reached through the worker's exit status, which some environments
        # swallow. Say so rather than passing silently on a test that checked nothing.
        skip "the worker did not exit non-zero in this environment; the deadline branch above covers the same two strings"
    fi
    [[ "$output" != *'/mmry:load-memories'* ]] || return 1
    [[ "$output" != *'~/.claude/mmry-config.json'* ]] || return 1
    [[ "$output" == *"bash ${codex}/mmry/hooks-handlers/session-start.sh"* ]]
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
    [[ "$ctx" == *'he said "no".'* ]] || return 1
    [[ "$ctx" == *'C:\Users\x'* ]] || return 1
    [[ "$ctx" == *'Ampersand & percent %'* ]] || return 1
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
    # LOAD (#31411 QA round 3, item 8). The orphan this exists for holds the descriptor until the
    # deadline, so the deadline is now a minute and the bound 30 s, where it was 12 and 6: a busy machine
    # no longer reaches the bound on the right path, and the orphan still holds the reader for 60.
    start="$(date +%s)"
    captured="$( { MMRY_FOUNDATION_DEADLINE_SECS=60 bash "$HANDLER" </dev/null; } 3>&1 )"
    elapsed=$(( $(date +%s) - start ))

    # The answer is right...
    [[ "$captured" == *'never overstate evidence'* ]] || return 1
    # ...and the reader was released as soon as it was produced, not at the deadline.
    echo "time to EOF with an extra inherited descriptor: ${elapsed}s against a 60s deadline" >&3
    (( elapsed < 30 ))
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
    local victim=$! i
    # Killed once it has written its marker and its out-file, not after a fixed 2 s (#31411 QA round 3,
    # item 8): on a loaded machine 2 s was not always enough to get that far, and the test then failed
    # on the kill landing early rather than on anything the handler did. Up to 30 s, polled; a handler
    # that never writes the marker still fails below.
    for (( i = 0; i < 300; i++ )); do
        [[ -f "$TEST_TMPDIR/.mmry-foundation-inflight" && -f "$TEST_TMPDIR/.mmry-foundation-out.$victim" ]] && break
        sleep 0.1
    done
    # It may already have finished if it never wrote the marker; the assertions below say so.
    kill -9 "$victim" 2>/dev/null || true
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
    [[ "$output" == *'NOT applied to this turn'* ]] || return 1

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
    [[ "$output" == *'NOT applied to this turn'* ]] || return 1

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
    [[ "$output" == *'NOT applied to this turn'* ]] || return 1

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
    # LOAD (#31411 QA round 3, item 8). The deadline is now a minute and the bound 30 s, where both were
    # 3: an off switch that was not honoured waits out the deadline behind the slow jq, and an honoured
    # one does not take 30 s however busy the machine.
    shim="$(_make_slow_jq 120)"

    _write_toggle_config '"false"'
    rm -f "$TEST_TMPDIR/.mmry-foundation-inflight"
    start="$(date +%s)"
    MMRY_JQ="$shim" MMRY_FOUNDATION_DEADLINE_SECS=60 run bash "$HANDLER"
    elapsed=$(( $(date +%s) - start ))

    [ "$status" -eq 0 ]
    [ -z "$output" ]
    (( elapsed < 30 ))
}

# ---------------------------------------------------------------------------------------------
# THE UNCONFIGURED CODEX INSTALL (#31245 QA round 4).
#
# On a Codex install with no credential of its own, this handler fired on every prompt and exited
# 1 with zero bytes. The chain: the worker sources mmry-client.sh -> lib-jq.sh -> lib-host.sh,
# which refuses with `exit 1` rather than a return code, so the worker's own `|| exit 0` never
# saw it and the worker died with rc=1.
#
# After #31434 that stopped being silent and started being WRONG. The supervisor cannot tell a
# refusal from a broken install, so rc=1 took the crash branch and printed, on every prompt, a
# banner naming /mmry:load-memories - a slash command Codex customers cannot type - and
# ~/.claude/mmry-config.json, the OTHER product's config file, with "the usual cause is an
# incomplete plugin install", which is not the cause.
#
# These stage a real Codex install the way session-init.sh does, rather than asserting against a
# replica of it.

_stage_codex_install() {
    local root="$1"
    mkdir -p "$root/mmry/hooks-handlers" "$root/fakehome"
    cp "$PLUGIN_ROOT"/hooks-handlers/*.sh "$root/mmry/hooks-handlers/"
    printf 'codex\n' > "$root/mmry/.mmry-host"
    printf '%s/mmry/hooks-handlers/userpromptsubmit-foundation.sh' "$root"
}

@test "codex: an unconfigured Codex install emits NOTHING on a prompt, rather than a banner" {
    local root="$TEST_TMPDIR/codex-unconfigured" handler
    handler="$(_stage_codex_install "$root")"

    run env -u MMRY_CONFIG_FILE -u MMRY_HOST HOME="$root/fakehome" CODEX_HOME="$root" \
        bash "$handler"

    [ "$status" -eq 0 ]
    # ZERO BYTES. Not "no crash banner" - nothing at all, which is what every other
    # nothing-to-say path in this handler does.
    [ -z "$output" ]
}

@test "codex: and it does not name a slash command Codex cannot type, or the other product's config" {
    local root="$TEST_TMPDIR/codex-unconfigured-msg" handler
    handler="$(_stage_codex_install "$root")"

    run env -u MMRY_CONFIG_FILE -u MMRY_HOST HOME="$root/fakehome" CODEX_HOME="$root" \
        bash "$handler"

    # These three are the literal contents of the banner the merge produced. Asserted
    # separately from the emptiness check above so that a future change which emits SOMETHING
    # here still cannot emit THIS.
    [[ "$output" != *"/mmry:load-memories"* ]] || return 1
    [[ "$output" != *".claude/mmry-config.json"* ]] || return 1
    [[ "$output" != *"incomplete plugin install"* ]]
}

@test "codex: a CONFIGURED Codex install still re-injects - the guard is not a blanket off switch" {
    local root="$TEST_TMPDIR/codex-configured" handler
    handler="$(_stage_codex_install "$root")"
    printf '{"apiUrl":"http://127.0.0.1:9","authMethod":"apikey","apiKey":"k","foundationReinject":"true"}' \
        > "$root/mmry-config.json"
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    manifest_now   # 31411 refuses a cache with no manifest beside it

    run env -u MMRY_CONFIG_FILE -u MMRY_HOST HOME="$root/fakehome" CODEX_HOME="$root" \
        bash "$handler"

    [ "$status" -eq 0 ]
    [[ "$output" == *'FOUNDATION'* ]] || return 1
    [[ "$output" == *'never overstate evidence'* ]]
}

@test "req4 control: a Claude install with NO credential is unaffected by the Codex guard" {
    # The guard must key on the HOST, not on whether a credential happens to exist. A Claude
    # install has always re-injected from cache regardless, and still must.
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    manifest_now   # 31411 refuses a cache with no manifest beside it
    local fakehome="$TEST_TMPDIR/claude-nocred"
    mkdir -p "$fakehome/.claude"

    run env -u MMRY_CONFIG_FILE -u MMRY_HOST -u CODEX_HOME HOME="$fakehome" bash "$HANDLER"

    [ "$status" -eq 0 ]
    [[ "$output" == *'Eric builds MMRY'* ]]
}

@test "req4 control: a curated copy with NO lib-host.sh still re-injects, rather than going silent" {
    # "Could not ask the question" must not be treated as "the answer was refuse". hook-guard.sh
    # documents why such copies exist; collapsing the two would trade a Codex bug for a Claude one.
    local root="$TEST_TMPDIR/claude-curated"
    mkdir -p "$root/mmry/hooks-handlers" "$root/fakehome/.claude"
    cp "$PLUGIN_ROOT"/hooks-handlers/*.sh "$root/mmry/hooks-handlers/"
    rm -f "$root/mmry/hooks-handlers/lib-host.sh"
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    manifest_now   # 31411 refuses a cache with no manifest beside it

    run env -u MMRY_CONFIG_FILE -u MMRY_HOST -u CODEX_HOME HOME="$root/fakehome" \
        bash "$root/mmry/hooks-handlers/userpromptsubmit-foundation.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *'Eric builds MMRY'* ]]
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
    # A record that claims nothing, on a set file that holds two directives (#31597: one file).
    local s b
    read -r s b < <(cksum < "$CACHE")
    fnd_set_with "mmry-foundation v2 entries=0 bytes=${b} cksum=${s}" "$(cat "$CACHE")"

    run bash "$HANDLER"
    [ "$status" -eq 0 ]                      # never blocks the prompt
    [[ "$output" == *'could not verify'* ]] || return 1  # the assistant is told
    [[ "$output" == *'systemMessage'* ]] || return 1     # and so is the customer
    [[ "$output" == *'no directives at all'* ]] || return 1
    # And it must not be quietly forwarded under the authoritative framing either.
    [[ "$output" != *'authoritative directives that take precedence'* ]]
}
@test "userpromptsubmit-foundation: #31583 the empty-set path still stays silent when the cache really is empty" {
    # The control for the test above: this must not become "warn whenever entries=0".
    # Sealed for real (#31597): a set file whose record says no directives and whose body is empty.
    # #31597 r2, TC4: SessionStart has already told this session the set is empty, as it does when it
    # stores one, so the prompt has nothing to add.
    : > "$CACHE"
    manifest_now "$CACHE" 0
    [[ "$(fnd_set_record)" == 'mmry-foundation v2 entries=0 bytes=0 '* ]] || return 1
    printf 'session-under-test' > "$TEST_TMPDIR/.mmry-foundation-empty-told"

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# #31597. UPGRADE RECOVERY AND THE UPGRADE NOTICE ARE RETIRED, and these two replace their tests.
#
# Plugin 2.9.1 writes mmry-foundation.md with no record. Until #31597 this version read the same
# name, so the first prompt after an update found a cache with no manifest, refused it, told the
# customer it was an update and rebuilt it in the background. The set now lives in its own file
# with its record inside it, so the 2.9.1 file is simply never read: not delivered, not refused,
# not reported. These pin that.
@test "userpromptsubmit-foundation: #31597 the file plugin 2.9.1 writes is never read: the set file is delivered, the old file is not" {
    printf -- '- Identity: the CURRENT set.\n' > "$TEST_TMPDIR/staged-new.md"
    fnd_seal "$TEST_TMPDIR/staged-new.md" "" "$SET"
    # What 2.9.1 leaves behind, under the name this version used to read.
    printf -- '- Identity: the OLD 2.9.1 copy.\n' > "$TEST_TMPDIR/mmry-foundation.md"

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'the CURRENT set'* ]] || return 1
    [[ "$output" != *'the OLD 2.9.1 copy'* ]] || return 1
    [[ "$output" != *'systemMessage'* ]]
}

@test "userpromptsubmit-foundation: #31597 a 2.9.1 file with no set beside it is neither delivered nor reported as damage or an update" {
    printf -- '- Identity: the OLD 2.9.1 copy.\n' > "$TEST_TMPDIR/mmry-foundation.md"
    rm -f "$SET"

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    # Nothing was stored for this session, so there is nothing to say: the same as a session that
    # has loaded nothing yet.
    [ -z "$output" ]
}

@test "userpromptsubmit-foundation: #31583 a genuinely damaged copy still says so and still prescribes the rebuild" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    manifest_now
    # Somebody else's text under this account's record, in the file the hook reads (#31597).
    fnd_set_with "$(fnd_set_record)" $'- Identity: someone elses text!\n'

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'did not match the record'* ]] || return 1
    [[ "$output" == *'load-memories'* ]] || return 1
    [[ "$output" != *'just updated the MMRY plugin'* ]]
}


# #31411 R1: a Foundation memory with a control character in it must still produce valid JSON.
# The API stores a form feed and returns it as a valid escape; it arrives by pasting from a
# PDF or a word processor. Only tab, CR and LF used to be escaped, so the hook emitted the raw
# byte, strict JSON.parse refused the whole output, and the product recorded a delivery.
# jq is strict about this: it rejects an unescaped control character, which the control
# assertion below proves before the real one relies on it.
@test "userpromptsubmit-foundation: #31411 control characters in a directive still produce valid JSON, decoded intact" {
    # CONTROL: the parser used here really does refuse the raw byte.
    if printf '{"a":"x\fy"}' | jq -e .a >/dev/null 2>&1; then
        echo "jq accepted a raw form feed, so it cannot prove anything below"; return 1
    fi

    printf -- '- Pasted: page one\fpage two \001 and \037 end\n' > "$CACHE"
    manifest_now

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    local ctx
    ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')" || {
        echo "the hook emitted JSON that a strict parser refused"; return 1; }
    # Decoded intact: the form feed and both other control bytes are back where they were.
    [[ "$ctx" == *'page one'$'\f''page two'* ]] || return 1
    [[ "$ctx" == *$'\001'* ]] || return 1
    [[ "$ctx" == *$'\037'* ]]
}

# #31411: a worker whose own emit fails must say so, not exit 0. It used to exit 0
# unconditionally, so a failed write was handed back as a delivery. Its pending delivery
# record is withdrawn too, so nothing claims a turn that did not happen.
@test "userpromptsubmit-foundation: #31411 a worker whose emit fails exits non-zero and withdraws its delivery record" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    manifest_now
    local pending="$TEST_TMPDIR/pending-under-test"

    # Stdout closed: the final printf has nowhere to go.
    MMRY_FOUNDATION_WORKER=1 MMRY_FOUNDATION_PENDING="$pending" run bash -c 'exec >&-; bash "$1"' _ "$HANDLER"
    [ "$status" -ne 0 ]
    if [ -e "$pending" ]; then
        echo "a failed emit left a record claiming delivery: $(cat "$pending")"; return 1
    fi

    # CONTROL: the same worker with a working stdout exits 0 and DOES write the record, so
    # the assertions above are not satisfied by a worker that never writes one at all.
    MMRY_FOUNDATION_WORKER=1 MMRY_FOUNDATION_PENDING="$pending" run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [ -e "$pending" ]
}


# #31583 QA round 5: the refusal sentence "did not match the record MMRY wrote" was used for
# states where no record could be read and no comparison happened. bad-manifest is one.
@test "userpromptsubmit-foundation: #31583 an unreadable record is not described as a failed comparison" {
    fnd_set_with 'garbage not a record' $'- Identity: Eric builds MMRY.\n'

    run bash "$HANDLER"
    [[ "$output" == *'could not verify'* ]] || return 1
    [[ "$output" == *'could not be read'* ]] || return 1
    [[ "$output" != *'did not match the record'* ]]
}
