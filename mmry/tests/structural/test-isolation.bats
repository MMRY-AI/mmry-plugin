#!/usr/bin/env bats
# test-isolation.bats — #31434 QA round 2.
#
# THE INCIDENT THIS EXISTS FOR. mmry_load_config's discovery order ends at
# $HOME/.claude/mmry-config.json, so any suite that does not isolate HOME runs against the
# developer's real config and its live API key. Eleven suites did not, because the isolation
# lived in helpers/test-helper.bash and those eleven do not load it. Measured with a marker
# config in a sentinel HOME and logging shims on jq and curl: 11 of 11 reached it, and
# formation-delivery.bats put the marker key on a CURL COMMAND LINE, readable from the process
# table. Nothing left the machine only because that config's URL was a discard port.
#
# The fix moved isolation to helpers/isolate-home.bash, applied from run-tests.sh and from a
# setup_suite.bash in every test directory. This file guards the fix, because the failure mode
# was never "the code is wrong" - it was "a new suite forgets, and nothing says so".
#
# It checks the MECHANISM IS WIRED (structurally, per directory, so a new test directory with
# no setup_suite.bash fails here) and that IT WORKS (functionally, against a sentinel HOME
# carrying a marker config). Neither check can pass vacuously: both assert their sample size.

load '../helpers/test-helper'

TESTS_DIR=""

setup() {
    TESTS_DIR="$PLUGIN_ROOT/tests"
}

@test "isolation: every directory holding tests carries a setup_suite.bash that isolates HOME" {
    local dirs d count=0
    # Directories with .bats files, excluding the vendored bats/bats-assert/bats-support trees.
    dirs="$(cd "$TESTS_DIR" && find . -name '*.bats' -not -path './libs/*' \
            | sed 's|/[^/]*$||' | sort -u)"

    for d in $dirs; do
        [[ -f "$TESTS_DIR/$d/setup_suite.bash" ]]
        grep -q 'isolate-home.bash' "$TESTS_DIR/$d/setup_suite.bash"
        grep -q 'mmry_isolate_home' "$TESTS_DIR/$d/setup_suite.bash"
        count=$(( count + 1 ))
    done

    echo "test directories checked: ${count}" >&3
    # SAMPLE SIZE, the discipline this repo's other structural checks use: a find that matched
    # nothing would pass a loop over an empty list and report no problem.
    (( count >= 5 ))
}

@test "isolation: the suites that do NOT load the shared helper are the reason this exists" {
    # Stated as a fact about the tree rather than left in a comment. If a refactor ever makes
    # every suite load test-helper, this number drops and the assertion below says so - which
    # is the moment to reconsider, not to quietly delete the machinery.
    local optouts
    optouts="$(cd "$TESTS_DIR" && grep -L 'test-helper' $(find . -name '*.bats' -not -path './libs/*') | wc -l)"
    echo "suites that do not load helpers/test-helper.bash: ${optouts}" >&3
    (( optouts >= 1 ))
    # And they are covered anyway: every one of them lives in a directory checked above.
}

@test "isolation: run-tests.sh isolates HOME before it hands anything to bats" {
    local runner src_line disp_line
    runner="$TESTS_DIR/run-tests.sh"
    [[ -f "$runner" ]]

    src_line="$(grep -n 'mmry_isolate_home' "$runner" | head -1 | cut -d: -f1)"
    disp_line="$(grep -n '^case "\$CATEGORY" in' "$runner" | head -1 | cut -d: -f1)"
    [[ "$src_line" =~ ^[0-9]+$ ]]
    [[ "$disp_line" =~ ^[0-9]+$ ]]
    # ORDER, not mere presence. Isolating after the suites have run isolates nothing - and
    # "the call is in the file somewhere" is the shape of assertion this round had to fix
    # three of.
    (( src_line < disp_line ))
}

@test "isolation: isolating actually moves HOME off the real one and hides its config" {
    # The functional half. A sentinel home stands in for the developer's, carrying a marker
    # config in the exact location mmry_load_config falls through to. After isolation, that
    # file must be unreachable through $HOME.
    local sentinel probe
    sentinel="$TEST_TMPDIR/sentinel-home"
    mkdir -p "$sentinel/.claude"
    printf '{"apiKey":"MARKER-31434-NOT-A-REAL-KEY"}\n' > "$sentinel/.claude/mmry-config.json"

    # MMRY_TEST_HOME_BASE is unset for the probe deliberately: this very run is already
    # isolated, and mmry_isolate_home is idempotent, so inheriting it would make the probe
    # return early and pass without isolating anything.
    probe="$(env -u MMRY_TEST_HOME_BASE HOME="$sentinel" bash -c '
        source "'"$TESTS_DIR"'/helpers/isolate-home.bash"
        mmry_isolate_home
        printf "%s|%s|%s" \
            "$HOME" \
            "$( [[ -f "$HOME/.claude/mmry-config.json" ]] && echo CONFIG-VISIBLE || echo no-config )" \
            "$( [[ -d "$HOME/.claude" ]] && echo home-usable || echo HOME-BROKEN )"
    ')"

    echo "after isolation: ${probe}" >&3
    local new_home state usable
    new_home="${probe%%|*}"
    state="$(printf '%s' "$probe" | cut -d'|' -f2)"
    usable="$(printf '%s' "$probe" | cut -d'|' -f3)"

    [[ -n "$new_home" ]]
    [[ "$new_home" != "$sentinel" ]]
    [[ "$state" == "no-config" ]]
    # And it must be a usable HOME, not merely a different string: an isolation that pointed
    # HOME at nothing would hide the config and break every handler that writes under it.
    [[ "$usable" == "home-usable" ]]
}

@test "isolation: a suite that loads no helper at all still gets an isolated HOME" {
    # END TO END, through bats itself, because the structural checks above prove the wiring is
    # present and the functional one proves the function works - neither proves BATS applies it
    # to a file that opts out of everything. That gap is exactly what shipped.
    #
    # A generated probe suite is used rather than a real one: it loads nothing, so anything it
    # reports about HOME is the machinery's doing and not its own setup().
    local sandbox sentinel out
    sandbox="$TEST_TMPDIR/e2e-isolation"
    sentinel="$TEST_TMPDIR/e2e-sentinel"
    mkdir -p "$sandbox" "$sentinel/.claude"
    printf '{"apiKey":"MARKER-31434-NOT-A-REAL-KEY"}\n' > "$sentinel/.claude/mmry-config.json"

    cp "$TESTS_DIR/structural/setup_suite.bash" "$sandbox/setup_suite.bash"
    # setup_suite.bash resolves the helper relative to its own parent directory.
    mkdir -p "$TEST_TMPDIR/helpers"
    cp "$TESTS_DIR/helpers/isolate-home.bash" "$TEST_TMPDIR/helpers/isolate-home.bash"

    cat > "$sandbox/probe.bats" <<'PROBE'
@test "probe: HOME is not the one bats was launched with" {
    [[ "$HOME" != "$MMRY_SENTINEL_HOME" ]]
    [[ ! -f "$HOME/.claude/mmry-config.json" ]]
}
PROBE

    # -u MMRY_TEST_HOME_BASE for the same reason as the test above: the outer run is already
    # isolated, and an inherited base would let the inner setup_suite no-op instead of proving
    # anything.
    run env -u MMRY_TEST_HOME_BASE HOME="$sentinel" MMRY_SENTINEL_HOME="$sentinel" \
        "$TESTS_DIR/libs/bats-core/bin/bats" "$sandbox/probe.bats"
    # Printed only on failure. The nested run emits its own TAP lines, and echoing those into
    # this run's stream makes bats count them as tests of this file ("executed 6 instead of
    # expected 5") - a test file that miscounts its own tests is not a good place to assert
    # that other tests are honest.
    if [[ "$status" -ne 0 ]]; then echo "$output" >&3; fi
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"ok 1"* ]]
    echo "nested probe suite ran isolated: ok" >&3
}
