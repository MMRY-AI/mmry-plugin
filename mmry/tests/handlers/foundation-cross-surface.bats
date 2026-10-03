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

# A negated command is EXEMPT from errexit in bats unless it is the final statement, so
# `! _hook_injects` part-way through a test cannot fail it. This repository has found sixteen
# assertions of that shape and I added three more in this file before catching it the same way
# the others were caught: by breaking the thing and watching the suite stay green. These two
# wrappers return non-zero properly and say what they saw.
_refute_hook_injects() {
    if _hook_injects; then
        echo "the hook injected when it should have been switched off"
        return 1
    fi
}

_refute_status_says_on() {
    if _status_says_on; then
        echo "the command reported re-injection ON when it should have been off"
        return 1
    fi
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
    _refute_hook_injects
    _refute_status_says_on
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
    _refute_hook_injects
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
    _refute_hook_injects
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
    [[ "$output" != *'nothing yet in this session'* ]]
}

# Product showed that deleting the whole last-sent block left every status test green, so the
# one line answering "are they reaching my assistant RIGHT NOW" was guarded by nothing.
@test "cross-surface: #31583 R4 the last-sent line is covered, and proven so by removing it" {
    _seed_valid_cache
    printf '{"foundationReinject": true}\n' > "$CFG"
    bash "$HOOK" >/dev/null 2>&1

    run bash "$STATUSCMD"
    [[ "$output" == *'Last sent'* ]]
    [[ "$output" == *'2 directives'* ]]

    # The proof that this assertion can fail lives in the committed mutation harness (m21),
    # which removes the "Last sent" output from the command itself and runs this suite against
    # it. It used to live here: the block was excised from a copy and the test then checked that
    # the copy's output lacked the line, which could not fail, because removing the line is
    # exactly what guaranteed it was absent (#31583 QA round 5).
}

# #31583, security on QA round 4: the delivery record must describe a DELIVERY, not an intent.
# The worker used to write it before the supervisor had emitted anything, so a turn whose
# output never reached a reader was reported by the command as "Delivered: IN FULL, last sent
# 1 second ago". The turn below has no reader: its stdout is closed before the emit.
@test "cross-surface: #31583 a turn whose output reaches nobody is NOT recorded as delivered" {
    printf '{"foundationReinject": true}\n' > "$CFG"

    # CONTROL first: an ordinary turn with a reader does record its delivery, so the
    # assertion below cannot be satisfied by a record that is never written at all.
    _seed_valid_cache
    run bash "$HOOK"
    [[ "$output" == *'Eric builds MMRY'* ]]
    [ -e "$TEST_TMPDIR/mmry-foundation.status" ]

    # The same turn again, with nobody reading it.
    rm -f "$TEST_TMPDIR/mmry-foundation.status"
    bash "$HOOK" 2>/dev/null | head -c 0 || true
    sleep 1

    if [ -e "$TEST_TMPDIR/mmry-foundation.status" ]; then
        echo "a turn that delivered nothing was recorded as delivered: $(cat "$TEST_TMPDIR/mmry-foundation.status")"
        return 1
    fi
    run bash "$STATUSCMD"
    [[ "$output" == *'nothing yet in this session'* ]]
}


# #31583 QA round 5, 4d. The worker made its own on/off decision from the jq-parsed value while
# the supervisor and the command used the text scan, so wherever the scan read ON and jq read OFF
# the hook sent nothing and the command promised the next prompt would send it. Both configs
# below are QA's reproductions; the first is an ordinary hand-edit, a false appended after true.
@test "cross-surface: #31583 4d true-then-false duplicate keys must not split the hook from the command" {
    _seed_valid_cache
    printf '{"foundationReinject": true, "foundationReinject": false}\n' > "$CFG"
    _assert_agree "a true-then-false duplicate key"
}

@test "cross-surface: #31583 4d a nested key before the real one must not split the hook from the command" {
    _seed_valid_cache
    printf '{"x": {"foundationReinject": true}, "foundationReinject": false}\n' > "$CFG"
    _assert_agree "a nested foundationReinject before the top-level one"
}


# #31583 QA round 5, 4e. The command printed "Delivered: IN FULL" whenever the copy verified,
# without reading the evidence the hook writes when a prompt fails. Straight after a prompt the
# hook's own log recorded as FAILED, a customer who asked was told IN FULL.
_seed_big_cache() {
    # Two MB: loads in about 3 s here, so a 1 s deadline really does stop it, while a normal
    # deadline lets it through. Sized for the deadline, not for realism.
    yes -- '- Directive: keep every sentence short and every claim backed by something you ran.' \
        | head -n 25000 > "$CACHE"
    local s b
    read -r s b < <(cksum < "$CACHE")
    printf 'mmry-foundation v1 entries=25000 bytes=%s cksum=%s\n' "$b" "$s" > "${CACHE}.manifest"
}

@test "cross-surface: #31583 4e a prompt that fails after a delivery is reported as NOT delivered, then recovers" {
    printf '{"foundationReinject": true}\n' > "$CFG"
    _seed_big_cache

    # CONTROL: a prompt that succeeds is reported as delivered.
    bash "$HOOK" >/dev/null 2>&1
    run bash "$STATUSCMD"
    [[ "$output" == *'Delivered:    IN FULL on the most recent prompt'* ]]

    # The failure: the same set, stopped at a one-second deadline. The hook says so on the turn.
    sleep 1
    MMRY_FOUNDATION_DEADLINE_SECS=1 run bash "$HOOK"
    [[ "$output" == *'NOT applied'* ]]

    # And now the command says so too, instead of IN FULL.
    run bash "$STATUSCMD"
    [[ "$output" == *'NOT on the most recent prompt'* ]]
    [[ "$output" != *'IN FULL'* ]]
    [[ "$output" == *'took longer than the 1s limit'* ]]

    # CONTROL on the other side: the next prompt succeeds and the report recovers, so the
    # assertion above cannot be satisfied by a command that always says NOT.
    sleep 1
    bash "$HOOK" >/dev/null 2>&1
    run bash "$STATUSCMD"
    [[ "$output" == *'Delivered:    IN FULL on the most recent prompt'* ]]
}

@test "cross-surface: #31583 4e a failure logged by an EARLIER session is not this session news" {
    printf '{"foundationReinject": true}\n' > "$CFG"
    _seed_valid_cache
    printf '2026-01-01T00:00:00 foundation reinjection FAILED: deadline exceeded (10s), worker killed\n' > "$TEST_TMPDIR/mmry-foundation.log"
    # SessionStart for THIS session happens after that line was written.
    sleep 1
    printf 'session-under-test' > "$TEST_TMPDIR/mmry-foundation.session"

    run bash "$STATUSCMD"
    [[ "$output" != *'NOT on the most recent prompt'* ]]
    [[ "$output" == *'nothing yet in this session'* ]]
}

@test "cross-surface: #31583 4e a firing that never finished is reported as NOT delivered" {
    printf '{"foundationReinject": true}\n' > "$CFG"
    _seed_valid_cache
    bash "$HOOK" >/dev/null 2>&1
    sleep 1
    # What the harness leaves behind when it kills the hook past its budget.
    : > "$TEST_TMPDIR/.mmry-foundation-inflight"

    run bash "$STATUSCMD"
    [[ "$output" == *'NOT on the most recent prompt'* ]]
    [[ "$output" == *'stopped before it finished'* ]]
}

# QA round 5 quick tweak: nothing tested the session gate in the VERIFIED branch. A record
# another session wrote must not be shown as this session's delivery.
@test "cross-surface: #31583 a valid copy with another session record is not reported as delivered here" {
    printf '{"foundationReinject": true}\n' > "$CFG"
    _seed_valid_cache
    printf 'session-from-yesterday ok entries=2 bytes=45\n' > "$TEST_TMPDIR/mmry-foundation.status"

    run bash "$STATUSCMD"
    [[ "$output" == *'Stored copy:  VERIFIED'* ]]
    [[ "$output" != *'IN FULL'* ]]
    [[ "$output" != *'entries=2'* ]]
    [[ "$output" == *'nothing yet in this session'* ]]
}
