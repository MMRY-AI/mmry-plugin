#!/usr/bin/env bats
# foundation-cross-surface.bats - the hook and /mmry:foundation-status, asked the same
# question in the same temp directory, must give the same answer (#31583 QA round 4).
#
# Nothing in this suite existed before round 4, and that absence is why one defect survived
# three rounds in three disguises. Every other suite exercises ONE surface. The customer
# experiences both, and the product actively sends them from one to the other: the hook
# refusal ends by telling them to run the command to confirm. Reviewers followed that
# instruction and were told the opposite thing in the same second.
#
#   4a the off-switch was derived twice and the two derivations disagreed
#   4b the command could not tell a vanished set from one never loaded
#   4c the delivery record outlived its session, so a new session was told its directives
#      had disappeared when it had never had any

load '../helpers/test-helper'

setup() {
    HOOK="$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    STATUSCMD="$PLUGIN_ROOT/hooks-handlers/foundation-status.sh"
    CACHE="$TEST_TMPDIR/mmry-foundation.md"
    CFG="$TEST_TMPDIR/mmry-config.json"
    export MMRY_CONFIG_FILE="$CFG"
    printf 'session-under-test' > "$TEST_TMPDIR/mmry-foundation.session"
}

_seed_valid_cache() {
    printf -- '- Identity: Eric builds MMRY.\n- Value: clarity.\n' > "$CACHE"
    local s b
    read -r s b < <(cksum < "$CACHE")
    printf 'mmry-foundation v1 entries=2 bytes=%s cksum=%s\n' "$b" "$s" > "${CACHE}.manifest"
}

# Does the hook actually inject? Bytes, not prose, so no wording change can soften it.
_hook_injects() {
    local out
    out="$(bash "$HOOK" 2>/dev/null)"
    [ -n "$out" ] && [[ "$out" == *'FOUNDATION memories'* ]]
}

_status_says_on() {
    bash "$STATUSCMD" 2>/dev/null | grep -qi 'Re-injection: ON'
}

_assert_agree() {
    local what="$1" hookv statusv
    if _hook_injects; then hookv=ON; else hookv=OFF; fi
    if _status_says_on; then statusv=ON; else statusv=OFF; fi
    [ "$hookv" = "$statusv" ] || {
        echo "DIVERGED on ${what}: the hook is ${hookv} and the command reports ${statusv}"
        bash "$STATUSCMD" 2>&1 | head -5
        return 1
    }
}

# 4a. The two controls come FIRST and deliberately. A test that only checked the broken
# config would pass equally against a command that always said OFF, which is the opposite
# failure and just as wrong.

@test "cross-surface: CONTROL a well-formed false switches BOTH off" {
    _seed_valid_cache
    printf '{"foundationReinject": false}\n' > "$CFG"
    ! _hook_injects
    ! _status_says_on
    _assert_agree "a well-formed false"
}

@test "cross-surface: CONTROL a well-formed true switches BOTH on" {
    _seed_valid_cache
    printf '{"foundationReinject": true}\n' > "$CFG"
    _hook_injects
    _status_says_on
    _assert_agree "a well-formed true"
}

@test "cross-surface: #31583 4a a config jq cannot parse must not split the two surfaces" {
    _seed_valid_cache
    # One trailing comma. The product tells the customer to hand-edit this file.
    printf '{"foundationReinject": false,}\n' > "$CFG"
    ! _hook_injects
    _assert_agree "a malformed config holding false"
}

@test "cross-surface: #31583 4a a duplicate key must not split the two surfaces" {
    _seed_valid_cache
    # jq takes last-wins, a text scan takes first-match. They disagreed by construction.
    printf '{"foundationReinject": false, "foundationReinject": true}\n' > "$CFG"
    _assert_agree "a duplicate foundationReinject key"
}

@test "cross-surface: #31583 4a an unusable jq must not split the two surfaces" {
    _seed_valid_cache
    printf '{"foundationReinject": false}\n' > "$CFG"
    # A broken jq is the exact circumstance the hook scan was hardened against, so the
    # command must not be the one surface that still needs jq to answer.
    export MMRY_JQ="$TEST_TMPDIR/no-such-jq"
    ! _hook_injects
    _assert_agree "an unresolvable jq"
}

@test "cross-surface: #31583 4b a set that vanished is called vanished by BOTH surfaces" {
    _seed_valid_cache
    printf '{"foundationReinject": true}\n' > "$CFG"

    run bash "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *'Eric builds MMRY'* ]]

    rm -f "$CACHE" "${CACHE}.manifest"

    run bash "$HOOK"
    [[ "$output" == *disappeared* ]]

    run bash "$STATUSCMD"
    [ "$status" -eq 0 ]
    [[ "$output" == *DISAPPEARED* ]]
    [[ "$output" != *'NOT LOADED YET'* ]]
}

@test "cross-surface: #31583 4c CONTROL a brand new session with nothing on disk is silent on both" {
    printf '{"foundationReinject": true}\n' > "$CFG"
    rm -f "$CACHE" "${CACHE}.manifest" "$TEST_TMPDIR/mmry-foundation.status"

    run bash "$HOOK"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run bash "$STATUSCMD"
    [[ "$output" == *'NOT LOADED YET'* ]]
    [[ "$output" != *DISAPPEARED* ]]
}

@test "cross-surface: #31583 4c a record left by an EARLIER session is not this session own" {
    printf '{"foundationReinject": true}\n' > "$CFG"
    rm -f "$CACHE" "${CACHE}.manifest"

    # Exactly the state of any new session whose SessionStart fetch failed on a machine an
    # earlier session used. Before the fix this produced 932 characters of "your directives
    # have disappeared", on every prompt, forever, having never delivered anything.
    printf 'session-from-yesterday ok entries=2 bytes=45\n' > "$TEST_TMPDIR/mmry-foundation.status"

    local i
    for i in 1 2 3; do
        run bash "$HOOK"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done

    run bash "$STATUSCMD"
    [[ "$output" == *'NOT LOADED YET'* ]]
    [[ "$output" != *DISAPPEARED* ]]
    # And it must not quote another session numbers back as this session delivery.
    [[ "$output" != *'entries=2 bytes=45'* ]]
}

@test "cross-surface: #31583 4c THIS session record is recognised, so the fix is not just silence" {
    _seed_valid_cache
    printf '{"foundationReinject": true}\n' > "$CFG"

    run bash "$HOOK"
    [[ "$output" == *'Eric builds MMRY'* ]]

    [ -e "$TEST_TMPDIR/mmry-foundation.status" ]
    run bash "$STATUSCMD"
    [[ "$output" == *'Last sent'* ]]
    [[ "$output" != *'not yet in this session'* ]]
}

# Product showed that deleting the whole last-sent block left every status test green, so the
# one line answering "are they reaching my assistant RIGHT NOW" was guarded by nothing.
@test "cross-surface: #31583 R4 the last-sent line is covered, and proven so by removing it" {
    _seed_valid_cache
    printf '{"foundationReinject": true}\n' > "$CFG"
    bash "$HOOK" >/dev/null 2>&1

    run bash "$STATUSCMD"
    [[ "$output" == *'Last sent'* ]]
    [[ "$output" == *entries=2* ]]

    # Remove the block from a COPY and prove the assertion above goes red. Without this the
    # test proves only that the line exists today, not that anything would notice its loss.
    local copy="$TEST_TMPDIR/status-without-lastsent.sh"
    grep -v 'Last sent' "$STATUSCMD" > "$copy"
    if grep -q 'Last sent' "$copy"; then
        echo "the excision did not land, so the proof below would be vacuous"
        return 1
    fi
    run bash "$copy"
    [[ "$output" != *'Last sent'* ]]
}
