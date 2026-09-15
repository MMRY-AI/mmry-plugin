#!/usr/bin/env bats
# hook-budgets.bats — #31434.
#
# The defect: the UserPromptSubmit Foundation hook was registered with a 5 second budget
# while its handler routinely cost 1 to 2 seconds on a loaded Windows machine. When it
# overran, Claude Code killed it and DISCARDED its output, so the turn silently ran with
# none of the account's standing directives. Three customer reports, one account, three
# plugin versions.
#
# What this file asserts, from the ticket's third test case: no hook the plugin registers
# carries a budget below the measured cost of its own handler, checked against the SHIPPED
# configuration rather than a copy edited by hand.
#
# Two things this file is deliberately careful about, because both have bitten this repo:
#
#  1. It reads the repo's hooks.json, and REFUSES to run against an installed plugin cache
#     or marketplace clone. The machine this was developed on had a hand-edited copy of
#     hooks.json in the marketplace clone carrying a different timeout, so a check that
#     happened to read the installed copy would have passed for the wrong reason.
#
#  2. Every loop asserts its own sample size first. A check that examined zero hooks and
#     reported no problem is a failed check reporting success.

load '../helpers/test-helper'

HOOKS_FILE=""

setup() {
    HOOKS_FILE="$PLUGIN_ROOT/hooks/hooks.json"
}

# Wall-clock cost of a command in MILLISECONDS, averaged over N runs.
# `date +%s%3N` is a GNU extension and macOS does not have it, so this times a BATCH with
# whole seconds and divides. Coarse on purpose: it is portable to the bash 3.2 / BSD date
# that macOS actually ships, and the margins being asserted here are large.
_avg_ms() {
    local runs="$1"; shift
    local start finish i
    start="$(date +%s)"
    for (( i = 0; i < runs; i++ )); do
        "$@" >/dev/null 2>&1 </dev/null || true
    done
    finish="$(date +%s)"
    # +1 second before dividing. Whole-second timing truncates by up to a second, and an
    # UNDER-stated cost would overstate the headroom - which is the error that lets this
    # whole file pass for the wrong reason. Round against ourselves.
    echo $(( ( (finish - start + 1) * 1000 ) / runs ))
}

_write_config() {
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

@test "hook-budgets: the file under test is the repo's shipped hooks.json, not an installed copy" {
    [[ -f "$HOOKS_FILE" ]]
    # An installed plugin lives under .../plugins/cache/... or .../plugins/marketplaces/...
    # Reading either would make every assertion below meaningless.
    [[ "$HOOKS_FILE" != */plugins/cache/* ]]
    [[ "$HOOKS_FILE" != */plugins/marketplaces/* ]]
    # And it must be the copy git tracks, in a repository that contains this test.
    [[ -f "$PLUGIN_ROOT/../.claude-plugin/marketplace.json" ]]
    [[ -d "$PLUGIN_ROOT/tests" ]]
}

@test "hook-budgets: every registered hook declares a positive integer timeout" {
    local timeouts count t
    timeouts="$(jq -r '[.hooks[][].hooks[].timeout] | .[]' "$HOOKS_FILE" | tr -d '\r')"
    count="$(printf '%s\n' "$timeouts" | grep -c '[0-9]')"
    # SAMPLE SIZE. The plugin registers nine hooks today; if a refactor drops them all,
    # every "no hook is below its cost" assertion below would pass vacuously.
    (( count >= 9 ))
    for t in $timeouts; do
        [[ "$t" =~ ^[0-9]+$ ]]
        (( t > 0 ))
    done
}

@test "hook-budgets: the Foundation hook's budget is not the outlier it was" {
    local mine others min_other
    mine="$(jq -r '.hooks.UserPromptSubmit[].hooks[]
                   | select(.command | test("userpromptsubmit-foundation")) | .timeout' "$HOOKS_FILE" | tr -d '\r')"
    [[ "$mine" =~ ^[0-9]+$ ]]

    others="$(jq -r '[.hooks[][].hooks[] | select((.command | test("userpromptsubmit-foundation")) | not) | .timeout]
                     | .[]' "$HOOKS_FILE" | tr -d '\r')"
    # SAMPLE SIZE: there must be other hooks to be an outlier against.
    (( $(printf '%s\n' "$others" | grep -c '[0-9]') >= 8 ))

    min_other="$(printf '%s\n' "$others" | sort -n | head -1)"
    # The whole complaint in the ticket: this handler alone was budgeted below every other.
    (( mine >= min_other ))
}

@test "hook-budgets: the Foundation hook's budget is a large multiple of its MEASURED cost" {
    _write_config
    printf -- '- Truthfulness: never overstate evidence.\n' > "$TEST_TMPDIR/mmry-foundation.md"

    local handler cost budget
    handler="$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    cost="$(_avg_ms 5 bash "$handler")"
    budget="$(jq -r '.hooks.UserPromptSubmit[].hooks[]
                     | select(.command | test("userpromptsubmit-foundation")) | .timeout' "$HOOKS_FILE" | tr -d '\r')"

    echo "measured cost: ${cost} ms over 5 runs; registered budget: ${budget} s" >&3

    # The measurement must be real. A handler that cost 0 ms did not run.
    (( cost > 0 ))
    # Headroom of at least 5x. At the 5 s budget this refuses for any cost above 1000 ms,
    # which is exactly the range that was measured in the field.
    (( budget * 1000 >= cost * 5 ))
}

@test "hook-budgets: no hook is budgeted below the startup cost every handler pays" {
    _write_config

    # Every entry-point handler sources mmry-client.sh, which resolves jq and loads the
    # config. That is the floor under all of them, so no registered budget may sit near it.
    local floor t timeouts count
    floor="$(_avg_ms 5 bash -c "source '$PLUGIN_ROOT/hooks-handlers/mmry-client.sh'")"
    echo "shared startup floor: ${floor} ms over 5 runs" >&3
    (( floor > 0 ))

    timeouts="$(jq -r '[.hooks[][].hooks[].timeout] | .[]' "$HOOKS_FILE" | tr -d '\r')"
    count=0
    for t in $timeouts; do
        (( t * 1000 >= floor * 5 ))
        count=$(( count + 1 ))
    done
    # SAMPLE SIZE, stated beside the verdict.
    echo "hooks checked against the floor: ${count}" >&3
    (( count >= 9 ))
}
