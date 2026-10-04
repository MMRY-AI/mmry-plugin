#!/usr/bin/env bats
# foundation-status.bats - /mmry:foundation-status (#31583 requirement 4).
#
# The command exists so a customer can ASK whether their standing directives are reaching
# their assistants, rather than finding out hours later that they were not. It shipped on
# this branch with no tests of its own, so nothing held it to the one property that makes
# it worth having: its answer must agree with what the re-injection handler actually does.
# A status command that reports health while the handler refuses the cache is worse than
# no status command, because it is the thing a customer would check first.
#
# #31597: the set and its record are ONE file now, mmry-foundation-set.md, the record on its first
# line. Tests stage the directives in $CACHE and seal them into $SET (helpers/foundation-set.bash);
# a test that damages what the command reads acts on $SET.

load '../helpers/test-helper'
load '../helpers/foundation-set'

setup() {
    STATUS_CMD="$PLUGIN_ROOT/hooks-handlers/foundation-status.sh"
    HANDLER="$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    CACHE="$TEST_TMPDIR/mmry-foundation.md"
    SET="$TEST_TMPDIR/mmry-foundation-set.md"
}

manifest_now() {
    fnd_seal "${1:-$CACHE}" "${2:-}" "$SET"
}

# The byte count the record on the set file's first line holds.
_recorded_bytes() {
    local r; r="$(fnd_set_record)"
    [[ "$r" =~ bytes=([0-9]+) ]] && printf '%s' "${BASH_REMATCH[1]}"
}

@test "foundation-status: a verified cache is reported as verified, with the count and size" {
    printf -- '- Identity: Eric builds MMRY.\n- Value: clarity over cleverness.\n' > "$CACHE"
    manifest_now

    run bash "$STATUS_CMD"
    [ "$status" -eq 0 ]
    [[ "$output" == *'VERIFIED'* ]] || return 1
    [[ "$output" == *'2 directives'* ]] || return 1
    [[ "$output" == *'Re-injection: ON'* ]]
}

@test "foundation-status: a damaged cache is reported as refused, not as healthy" {
    printf -- '- Identity: Eric builds MMRY.\n- Value: clarity over cleverness.\n' > "$CACHE"
    manifest_now
    local n
    n="$(wc -c < "$CACHE" | tr -d ' ')"
    fnd_set_with "$(fnd_set_record)" "$(head -c "$n" /dev/zero | tr '\0' 'z')"

    run bash "$STATUS_CMD"
    [ "$status" -eq 0 ]
    [[ "$output" == *'DAMAGED'* ]] || return 1
    [[ "$output" == *'REFUSED'* ]] || return 1
    run grep -c 'VERIFIED' <<<"$output"
    [ "$output" = "0" ]
}

# #31597. "FROM AN EARLIER PLUGIN VERSION" is retired. A cache with no manifest was what plugin 2.9.1
# wrote under the name this version used to read. The set now has its own file, so a 2.9.1 file is
# never read: it is not reported as an upgrade, as damage, or as anything else.
@test "foundation-status: #31597 a file left by plugin 2.9.1 is not read, not reported, and not used" {
    printf -- '- Identity: the OLD 2.9.1 copy.\n' > "$TEST_TMPDIR/mmry-foundation.md"
    rm -f "$SET"

    run bash "$STATUS_CMD"
    [ "$status" -eq 0 ]
    [[ "$output" == *'NOT LOADED YET'* ]] || return 1
    [[ "$output" != *'FROM AN EARLIER PLUGIN VERSION'* ]] || return 1
    [[ "$output" != *'VERIFIED'* ]]
}

@test "foundation-status: an account with genuinely no Foundation memories is told nothing is withheld" {
    : > "$CACHE"
    manifest_now "$CACHE" 0

    run bash "$STATUS_CMD"
    [ "$status" -eq 0 ]
    [[ "$output" == *'VALID and EMPTY'* ]]
}

@test "foundation-status: #31583 it never reports health for a cache the handler is refusing" {
    # The property that makes this command worth having. The two read the same record through
    # one routine, and this pins them together on the case that drift once actually produced - a
    # record claiming the set is empty beside a set full of directives. The handler refuses that.
    # The status command must not call it fine.
    printf -- '- Identity: Eric builds MMRY.\n- Value: clarity over cleverness.\n' > "$CACHE"
    local s b
    read -r s b < <(cksum < "$CACHE")
    fnd_set_with "mmry-foundation v2 entries=0 bytes=${b} cksum=${s}" "$(cat "$CACHE")"

    # What the handler does with it, measured here rather than assumed.
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'could not verify'* ]] || return 1

    # What the customer is told when they ask.
    run bash "$STATUS_CMD"
    [ "$status" -eq 0 ]
    run grep -c 'Nothing is being withheld' <<<"$output"
    [ "$output" = "0" ]
}

@test "foundation-status: #31583 QA a cache that verifies but holds only whitespace is REFUSED, not called VERIFIED" {
    # QA reproduced this directly: the hook refused the turn while this command reported
    # "VERIFIED - 2 directives, 8 characters" and "Delivered: IN FULL". The customer asking
    # the question was told the opposite of what was happening. The two readers had separate
    # copies of the verification and this branch existed in only one of them.
    printf '  \n \n  ' > "$CACHE"
    manifest_now "$CACHE" 2

    run bash "$STATUS_CMD"
    [ "$status" -eq 0 ]
    [[ "$output" == *'REFUSED'* ]] || return 1
    [[ "$output" == *'no readable text'* ]] || return 1
    run grep -c 'VERIFIED' <<<"$output"
    [ "$output" = "0" ]
    run grep -c 'IN FULL' <<<"$output"
    [ "$output" = "0" ]
}

@test "foundation-status: #31583 QA the off switch is reported, and it had no test at all" {
    # QA: "remove it and every suite still passes while the command reports Re-injection: ON
    # to a customer who has it switched off."
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    manifest_now
    export MMRY_FOUNDATION_REINJECT=false

    run bash "$STATUS_CMD"
    [ "$status" -eq 0 ]
    [[ "$output" == *'TURNED OFF'* ]] || return 1
    run grep -c 'Re-injection: ON' <<<"$output"
    [ "$output" = "0" ]
}

@test "foundation-status: the off switch control - ON is reported when it is on" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    manifest_now
    run bash "$STATUS_CMD"
    [ "$status" -eq 0 ]
    [[ "$output" == *'Re-injection: ON'* ]]
}

# ============================================================================
# EVERY state-to-label mapping (#31583 QA round 2).
#
# "three of the eight state-to-label mappings in the status command are asserted nowhere, so
# a typo in one of those tokens degrades silently to the catch-all." Counted at the time: of
# the five labels, only DAMAGED was asserted anywhere.
#
# A typo in a case arm is invisible without these: the state falls through to "*)", the
# customer still gets a refusal, and the label is just less useful. Nothing goes red.
#
# #31597: no-manifest is retired with its label (see the 2.9.1 test above). missing is kept, from
# the marker SessionStart leaves once it has stored a set.
# ============================================================================

@test "foundation-status: #31597 a set file with no record line maps to PRESENT BUT UNVERIFIABLE" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$SET"
    run bash "$STATUS_CMD"
    [[ "$output" == *'PRESENT BUT UNVERIFIABLE'* ]] || return 1
    [[ "$output" != *'FROM AN EARLIER PLUGIN VERSION'* ]]
}

@test "foundation-status: state bad-manifest maps to PRESENT BUT UNVERIFIABLE" {
    fnd_set_with 'garbage not a record' $'- Identity: Eric builds MMRY.\n'
    run bash "$STATUS_CMD"
    [[ "$output" == *'PRESENT BUT UNVERIFIABLE'* ]]
}

@test "foundation-status: state inconsistent maps to INCONSISTENT" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    local s b
    read -r s b < <(cksum < "$CACHE")
    fnd_set_with "mmry-foundation v2 entries=0 bytes=${b} cksum=${s}" "$(cat "$CACHE")"
    run bash "$STATUS_CMD"
    [[ "$output" == *'INCONSISTENT'* ]]
}

@test "foundation-status: state missing maps to MISSING" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    manifest_now
    # What SessionStart leaves once it has stored a set (#31597): its session token, and the marker.
    printf 'session-under-test' > "$TEST_TMPDIR/mmry-foundation.session"
    bash -c 'source "$1/hooks-handlers/mmry-client.sh" >/dev/null 2>&1; mmry_foundation_mark_stored "$2" "" 1' _ "$PLUGIN_ROOT" "$TEST_TMPDIR"
    rm -f "$SET"
    run bash "$STATUS_CMD"
    [[ "$output" == *'MISSING'* ]] || return 1
    [[ "$output" == *'records 1 Foundation directives but the cache holding them is missing'* ]]
}

@test "foundation-status: state size maps to DAMAGED, and says both numbers" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    manifest_now
    fnd_set_with "$(fnd_set_record)" $'- Identity: Eric builds MMRY, and rather more besides.\n'
    run bash "$STATUS_CMD"
    [[ "$output" == *'DAMAGED'* ]] || return 1
    # BOTH numbers, which is what this test is named for (#31583 QA round 4). It asserted
    # only the actual size, so the regression it exists to catch - printing that 28 bytes
    # does not match 28 bytes, because the size and checksum cases once shared one branch -
    # would have passed it. The record's size has to appear too, and the two have to differ, or
    # the sentence is the nonsense it was written to prevent.
    local _actual _recorded
    _actual="$(fnd_set_body | wc -c | tr -d ' ')"
    _recorded="$(_recorded_bytes)"
    [ -n "$_recorded" ]
    [ "$_actual" != "$_recorded" ]
    [[ "$output" == *"$_actual"* ]] || return 1
    [[ "$output" == *"$_recorded"* ]]
}

@test "foundation-status: state contents maps to DAMAGED, with the length-matched wording" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    manifest_now
    local n; n="$(wc -c < "$CACHE" | tr -d ' ')"
    fnd_set_with "$(fnd_set_record)" "$(head -c "$n" /dev/zero | tr '\0' 'z')"
    run bash "$STATUS_CMD"
    [[ "$output" == *'DAMAGED'* ]] || return 1
    [[ "$output" == *'right length'* ]]
}

@test "foundation-status: state blank maps to EMPTY OF TEXT" {
    printf '  \n \n  ' > "$CACHE"
    manifest_now "$CACHE" 2
    run bash "$STATUS_CMD"
    [[ "$output" == *'EMPTY OF TEXT'* ]]
}
