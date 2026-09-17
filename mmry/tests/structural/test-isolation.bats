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

# ---------------------------------------------------------------------------------------
# QA round 3. Four findings, each proved by the mechanism refusing where it used to allow.
# ---------------------------------------------------------------------------------------

@test "isolation: release refuses to delete a base it did not create, even when inherited" {
    # THE DESTRUCTIVE ONE. mmry_release_home used to rm -rf $MMRY_TEST_HOME_BASE on nothing
    # but "non-empty", and teardown_suite calls it unconditionally - so any inherited value
    # was a recursive delete of a directory this process never made. The stand-in here is a
    # directory with a file in it, which must survive.
    local victim
    victim="$TEST_TMPDIR/not-ours"
    mkdir -p "$victim/precious"
    printf 'do not delete me\n' > "$victim/precious/file.txt"

    run env MMRY_TEST_HOME_BASE="$victim" HOME="$victim" bash -c '
        source "'"$TESTS_DIR"'/helpers/isolate-home.bash"
        mmry_release_home
    '
    echo "release said: ${output}" >&3

    # Survived, contents and all.
    [[ -d "$victim/precious" ]]
    [[ -f "$victim/precious/file.txt" ]]
    # And it said so rather than failing silently - a quiet refusal is how a broken guard
    # looks from the outside too.
    [[ "$output" == *"refusing to delete"* ]]
    [[ "$output" == *"$victim"* ]]
}

@test "isolation: an inherited base does not satisfy the idempotent early return" {
    # The same unguarded trust, in the other direction and just as serious: the early return
    # used to accept any base that merely EXISTED, so an inherited MMRY_TEST_HOME_BASE made
    # mmry_isolate_home a no-op and left $HOME on the developer's real home - the exposure
    # this whole change closes, reintroduced through one environment variable.
    local sentinel decoy probe
    sentinel="$TEST_TMPDIR/inherit-sentinel"
    decoy="$TEST_TMPDIR/inherit-decoy"
    mkdir -p "$sentinel/.claude" "$decoy"
    printf '{"apiKey":"MARKER-31434-NOT-A-REAL-KEY"}\n' > "$sentinel/.claude/mmry-config.json"

    probe="$(env MMRY_TEST_HOME_BASE="$decoy" HOME="$sentinel" bash -c '
        source "'"$TESTS_DIR"'/helpers/isolate-home.bash"
        mmry_isolate_home
        printf "%s|%s" \
            "$HOME" \
            "$( [[ -f "$HOME/.claude/mmry-config.json" ]] && echo CONFIG-VISIBLE || echo no-config )"
    ')"
    echo "with an inherited base, HOME became: ${probe}" >&3

    local new_home state
    new_home="${probe%%|*}"
    state="$(printf '%s' "$probe" | cut -d'|' -f2)"

    # It isolated anyway, ignoring the inherited value instead of trusting it.
    [[ "$new_home" != "$sentinel" ]]
    [[ "$new_home" != "$decoy" ]]
    [[ "$state" == "no-config" ]]
    # And the decoy is untouched: ignoring it must not mean deleting it either.
    [[ -d "$decoy" ]]
}

@test "isolation: an exported MMRY_CONFIG_FILE cannot hand the real config to a suite" {
    # MMRY_CONFIG_FILE is the FIRST branch of mmry_load_config's discovery order, so it
    # outranks the plugin root AND $HOME. Emptying HOME while leaving it set is isolation in
    # name only. Proved through a suite that loads no helper, against the real client.
    #
    # WITH A CONTROL, because "the key did not appear" is exactly what a detector that cannot
    # see anything also reports: the identical probe is run once with the isolating
    # setup_suite.bash present and once without it, and the run without it MUST see the marker
    # key. If it does not, this test fails as inert rather than passing vacuously.
    local root marker
    root="$TEST_TMPDIR/cfgfile"
    marker="$root/planted-config.json"
    mkdir -p "$root/isolated/helpers" "$root/control"
    printf '{"apiUrl":"http://127.0.0.1:9","apiKey":"MARKER-31434-NOT-A-REAL-KEY","authMethod":"apikey"}\n' > "$marker"

    cp "$TESTS_DIR/setup_suite.bash" "$root/isolated/setup_suite.bash"
    # setup_suite.bash resolves the helper relative to its own directory.
    cp "$TESTS_DIR/helpers/isolate-home.bash" "$root/isolated/helpers/isolate-home.bash"

    cat > "$root/probe.bats" <<'PROBE'
@test "probe: which config did the client actually load" {
    source "$MMRY_CLIENT"
    mmry_load_config
    printf 'MMRY_CONFIG_FILE=[%s] key=[%s]\n' "${MMRY_CONFIG_FILE:-}" "${MMRY_API_KEY:-}"
    [[ "${MMRY_API_KEY:-}" == "${MMRY_EXPECT_KEY}" ]]
}
PROBE
    cp "$root/probe.bats" "$root/isolated/probe.bats"
    cp "$root/probe.bats" "$root/control/probe.bats"

    local bats_bin client
    bats_bin="$TESTS_DIR/libs/bats-core/bin/bats"
    client="$PLUGIN_ROOT/hooks-handlers/mmry-client.sh"

    # CONTROL: no setup_suite.bash in that directory, so nothing isolates. The exported
    # MMRY_CONFIG_FILE must win and the marker key must land in MMRY_API_KEY.
    run env -u MMRY_TEST_HOME_BASE -u CLAUDE_PLUGIN_ROOT \
        MMRY_CONFIG_FILE="$marker" MMRY_API_KEY="" MMRY_CLIENT="$client" \
        MMRY_EXPECT_KEY="MARKER-31434-NOT-A-REAL-KEY" \
        "$bats_bin" "$root/control/probe.bats"
    if [[ "$status" -ne 0 ]]; then echo "CONTROL FAILED - detector is inert: $output" >&3; fi
    [[ "$status" -eq 0 ]]
    echo "control (no isolation): the exported MMRY_CONFIG_FILE was loaded, as expected" >&3

    # ISOLATED: same probe, same exported MMRY_CONFIG_FILE, with the shipped setup_suite.bash
    # in place. The variable must be emptied and the marker key must not be reachable.
    run env -u MMRY_TEST_HOME_BASE -u CLAUDE_PLUGIN_ROOT \
        MMRY_CONFIG_FILE="$marker" MMRY_API_KEY="" MMRY_CLIENT="$client" \
        MMRY_EXPECT_KEY="" \
        "$bats_bin" "$root/isolated/probe.bats"
    if [[ "$status" -ne 0 ]]; then echo "$output" >&3; fi
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"MARKER-31434-NOT-A-REAL-KEY"* ]]
    # The planted file is still there, so the run above was a real opportunity to load it.
    [[ -f "$marker" ]]
    echo "isolated: MMRY_CONFIG_FILE emptied, marker key unreachable" >&3
}

@test "isolation: a plugin-root mmry-config.json is ignored by git" {
    # The one discovery branch HOME isolation cannot cover: $CLAUDE_PLUGIN_ROOT IS this
    # repository, so a real config dropped at mmry/mmry-config.json outranks $HOME for every
    # run in the checkout and is committable with a live key in it. config-loading.bats has
    # already left one there once.
    local repo_root
    repo_root="$(cd "$PLUGIN_ROOT/.." && pwd)"
    run git -C "$repo_root" check-ignore -v "$PLUGIN_ROOT/mmry-config.json"
    echo "check-ignore: ${output}" >&3
    [[ "$status" -eq 0 ]]
    # And the tracked example must NOT be swept up by the rule.
    run git -C "$repo_root" check-ignore -q "$PLUGIN_ROOT/mmry-config.example.json"
    [[ "$status" -ne 0 ]]
}

@test "isolation: the bare recursive invocation picks up a setup_suite and isolates" {
    # `bats -r mmry/tests/` resolves its suite setup file from the DIRECTORY ARGUMENT only -
    # it does not descend into the directories the recursion expands, and it does not walk
    # up. With no tests/setup_suite.bash it therefore ran the entire tree unisolated and said
    # nothing. Proved here against the shipped file, through a recursive run over a sandbox
    # laid out the same way: setup_suite.bash at the root, tests one level down.
    local sandbox sentinel
    sandbox="$TEST_TMPDIR/recursive"
    sentinel="$TEST_TMPDIR/recursive-sentinel"
    mkdir -p "$sandbox/helpers" "$sandbox/deep" "$sentinel/.claude"
    printf '{"apiKey":"MARKER-31434-NOT-A-REAL-KEY"}\n' > "$sentinel/.claude/mmry-config.json"

    cp "$TESTS_DIR/setup_suite.bash" "$sandbox/setup_suite.bash"
    cp "$TESTS_DIR/helpers/isolate-home.bash" "$sandbox/helpers/isolate-home.bash"

    cat > "$sandbox/deep/probe.bats" <<'PROBE'
@test "probe: a recursively collected suite still has an isolated HOME" {
    [[ "$HOME" != "$MMRY_SENTINEL_HOME" ]]
    [[ ! -f "$HOME/.claude/mmry-config.json" ]]
    [[ -z "${MMRY_CONFIG_FILE:-}" ]]
}
PROBE

    run env -u MMRY_TEST_HOME_BASE HOME="$sentinel" MMRY_SENTINEL_HOME="$sentinel" \
        "$TESTS_DIR/libs/bats-core/bin/bats" -r "$sandbox"
    if [[ "$status" -ne 0 ]]; then echo "$output" >&3; fi
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"ok 1"* ]]
    echo "bats -r over a directory with only a root setup_suite.bash: isolated" >&3
}

@test "isolation: the tests root carries the setup_suite.bash that the recursive shape needs" {
    # Structural companion to the run above: the sandbox proves the mechanism, this proves the
    # real tree has the file the real `bats -r mmry/tests/` invocation looks for, at the exact
    # path bats looks for it.
    [[ -f "$TESTS_DIR/setup_suite.bash" ]]
    grep -q 'isolate-home.bash' "$TESTS_DIR/setup_suite.bash"
    grep -q 'mmry_isolate_home' "$TESTS_DIR/setup_suite.bash"
    # And that lookup rule is bats's, not an assumption of ours - it reads
    # "$dirname/setup_suite.bash" where dirname is the argument when the argument is a
    # directory. If a bats upgrade changes that, this says so.
    grep -q 'potential_setup_suite_file="$dirname/setup_suite.bash"' \
        "$TESTS_DIR/libs/bats-core/libexec/bats-core/bats"
}
