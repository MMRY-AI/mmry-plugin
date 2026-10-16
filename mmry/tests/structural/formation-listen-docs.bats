#!/usr/bin/env bats
# The customer documentation states what continuous listening costs, the minimum Claude Code
# version it needs, and how to limit it (#31850 requirement 4, test case 4).
#
# The figures are the measured ones: tokens per renewal from #32028 (about 30,000 in a session that
# had only just started, 570,000 to 880,000 in a long one), credits from the shipped schedule
# (formation-listen-limit.bats "cost:", about 70 in the first half hour and 1,580 over a full day at
# the default of 24 hours, with 51 renewals),
# and the version floor from the ceiling measured on 2.1.285 (docs/evidence/31721) and again on
# 2.1.292 (docs/evidence/31850). The website help page is checked in MMRY-AI/mmry by
# testing/backend/tests/formation-listening-cost.test.ts.

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
    FORMATION="${ROOT}/commands/formation.md"
    HELP="${ROOT}/commands/help.md"
    README="${ROOT}/README.md"
    DEFAULT_MIN="$(sed -n 's/^MMRY_FORMATION_LISTEN_DEFAULT_MINUTES=\([0-9]*\)$/\1/p' "${ROOT}/hooks-handlers/formation-check.sh")"
}

# "24 hours" for 1440, "90 minutes" for 90: how the pages spell the shipped default.
_default_words() {
    if (( DEFAULT_MIN % 60 == 0 )); then
        if (( DEFAULT_MIN == 60 )); then printf '1 hour'; else printf '%s hours' "$(( DEFAULT_MIN / 60 ))"; fi
    else
        printf '%s minutes' "$DEFAULT_MIN"
    fi
}

_has() { grep -qF -- "$2" "$1" || { echo "$(basename "$1") does not say: $2"; return 1; }; }

@test "docs: the formation page states the cost of a renewal in Claude usage, as measured" {
    _has "$FORMATION" "30,000 tokens"
    _has "$FORMATION" "570,000 to 880,000"
    _has "$FORMATION" "counts toward your Claude Code usage"
}

@test "docs: the formation page states the cost in MMRY credits, as measured" {
    _has "$FORMATION" "uses"
    _has "$FORMATION" "one credit"
    _has "$FORMATION" "about 70 times in the half hour after a turn"
    _has "$FORMATION" "at the default 24 hours uses about 1,580"
}

@test "docs: the formation page states the minimum Claude Code version for continuous listening" {
    _has "$FORMATION" "Continuous listening needs Claude Code 2.1.285 or newer"
    # And the versions the measurement rests on, so a reader can tell measured from assumed.
    _has "$FORMATION" "2.1.286"
    _has "$FORMATION" "2.1.292"
}

@test "docs: the formation page names the setting, its three kinds of value, and the shipped default" {
    [ -n "$DEFAULT_MIN" ] || { echo "no default constant in formation-check.sh"; return 1; }
    _has "$FORMATION" "formationListenMinutes"
    _has "$FORMATION" "MMRY_FORMATION_LISTEN_MINUTES"
    _has "$FORMATION" '"off"'
    _has "$FORMATION" '"unlimited"'
    _has "$FORMATION" "By default a session listens for $(_default_words) of quiet"
    # The renewals that default allows, from formation-listen-limit.bats "default:" (51 in 24 hours).
    _has "$FORMATION" "up to 51 renewals"
    # The count restarts with the member's own work, which is what makes the default fit continuous use.
    _has "$FORMATION" "A typed prompt, or a message the session receives,"
}

@test "docs: /mmry:help states the cost, the setting and the minimum version" {
    _has "$HELP" "570,000 to 880,000"
    _has "$HELP" "one MMRY credit"
    _has "$HELP" "formationListenMinutes"
    _has "$HELP" "Claude Code 2.1.285 or newer"
    _has "$HELP" "by default for $(_default_words) of quiet"
    _has "$HELP" "about 1,580 over a full day at the default $(_default_words)"
}

@test "docs: the README's settings table carries the key with the constant's default" {
    _has "$README" "| \`formationListenMinutes\` | \`${DEFAULT_MIN}\` |"
    _has "$README" "MMRY_FORMATION_LISTEN_MINUTES"
}

@test "docs: no page still promises listening without limit by default" {
    run grep -n "however long it sits idle\|for as long as they stay in the formation, or when" "$FORMATION" "$HELP" "$README"
    [ "$status" -ne 0 ] || { echo "an old unlimited promise remains: ${output}"; return 1; }
}

@test "control: the docs checks fail when the default changes and the pages do not" {
    # POSITIVE CONTROL. A one-line change to the default, with the pages left alone, must be caught.
    DEFAULT_MIN=480
    run _has "$FORMATION" "By default a session listens for $(_default_words) of quiet"
    [ "$status" -ne 0 ] || { echo "a changed default went unnoticed"; return 1; }
}
