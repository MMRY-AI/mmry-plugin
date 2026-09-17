#!/usr/bin/env bash
# isolate-home.bash — #31434 QA round 2. The ONE place the test suite's HOME is isolated.
#
# WHY THIS IS NOT IN test-helper.bash ANY MORE.
#
# It was. test-helper.bash is the right place for anything a suite opts into - and that is
# exactly the problem: ELEVEN suites opt out by not loading it (the nine formation-*.bats,
# macos-hook-payload.bats and unit/hook-payload-read.bats). Ten of them invoke handlers that
# source mmry-client.sh, which runs mmry_load_config at source time. Its discovery order is
#
#     $MMRY_CONFIG_FILE (only while that file EXISTS) -> $CLAUDE_PLUGIN_ROOT/mmry-config.json
#     -> $HOME/.claude/mmry-config.json
#
# so a suite that set MMRY_CONFIG_FILE to a path that does not exist fell straight through to
# the developer's real config, complete with its live API key. Measured before this change, with
# a marker config in a sentinel HOME and logging shims on jq and curl: 11 of 11 suites reached
# it, and formation-delivery.bats put the marker key ON A CURL COMMAND LINE, where the process
# table can read it. Nothing left the machine only because the URL in that config pointed at a
# discard port - luck, not design.
#
# A protection each suite has to remember is a protection some suite will forget, and two did.
# So it lives here, and is applied from run-tests.sh (every sanctioned run) and from a
# setup_suite.bash in every test directory (any direct `bats path/to/one.bats` invocation).
# Neither route asks the suite's permission.

# The marker file written into a base this process created, and the only thing that makes a
# base deletable. #31434 QA round 3.
#
# WHY A MARKER AND NOT JUST THE VARIABLE. mmry_release_home used to `rm -rf` whatever
# $MMRY_TEST_HOME_BASE pointed at, on no test beyond "non-empty". The variable is exported, so
# it is inherited: a developer who exported it, a nested bats run, or a stale value left in a
# shell would hand an arbitrary directory to an unconditional recursive delete - and
# teardown_suite calls it on every run, no opt-in required. The same trust-the-inherited-value
# shape caused the uninstaller defect reviewed this week.
#
# The idempotent early return needs the identical predicate for the opposite reason: an
# inherited base that merely EXISTS used to satisfy it, so mmry_isolate_home would return
# early with $HOME still pointing at the developer's real home - the exact exposure this whole
# change exists to close, reintroduced through an environment variable.
_MMRY_TEST_HOME_MARKER=".mmry-test-home"
_MMRY_TEST_HOME_MAGIC="mmry-test-home:31434"

_mmry_owns_test_home() {
    local base="${MMRY_TEST_HOME_BASE:-}" home="${HOME:-}"

    [[ -n "$base" ]] || return 1
    [[ "$base" == /* ]] || return 1          # absolute paths only
    [[ "$base" != "/" ]] || return 1         # never the filesystem root
    [[ -d "$base" ]] || return 1
    if [[ -L "$base" ]]; then return 1; fi   # not a symlink pointing somewhere else
    [[ -f "$base/$_MMRY_TEST_HOME_MARKER" ]] || return 1
    grep -qx "$_MMRY_TEST_HOME_MAGIC" "$base/$_MMRY_TEST_HOME_MARKER" 2>/dev/null || return 1

    # And $HOME must currently live inside it. A base we created but are no longer using as
    # HOME is not something this call should be deleting either.
    [[ -n "$home" ]] || return 1
    [[ "$home" == "$base" || "$home" == "$base"/* ]] || return 1

    return 0
}

mmry_isolate_home() {
    # Idempotent: run-tests.sh and setup_suite.bash may both fire in one run, and a second
    # isolated HOME would only orphan the first. Guarded by ownership, not by existence - see
    # _mmry_owns_test_home. An inherited base this process did not create is ignored, and
    # isolation proceeds as if it were unset.
    if _mmry_owns_test_home; then
        return 0
    fi

    local base
    base="$(mktemp -d)" || return 1
    printf '%s\n' "$_MMRY_TEST_HOME_MAGIC" > "$base/$_MMRY_TEST_HOME_MARKER" || return 1
    MMRY_TEST_HOME_BASE="$base"
    export MMRY_TEST_HOME_BASE

    HOME="$base/home"
    export HOME
    mkdir -p "$HOME/.claude"

    # Deliberately NOT creating a config here. An empty HOME means the discovery order runs
    # off the end and the client falls back to its compiled-in defaults, which is the state
    # every suite that does not write its own config already assumes it is testing.
    #
    # These are emptied rather than left inherited so a developer with MMRY_API_KEY exported
    # in their shell cannot hand a live credential to the suite either. Empty is treated
    # exactly like unset by mmry_load_config.
    export MMRY_API_URL=""
    export MMRY_API_KEY=""
    export MMRY_AUTH_METHOD=""

    # MMRY_CONFIG_FILE is emptied for the same reason and with more force than the three
    # above: it is the FIRST branch of mmry_load_config's discovery order, so an inherited
    # value outranks both the plugin root and $HOME and hands the file it names - the
    # developer's real config, if that is what they exported - to every suite, isolated HOME
    # or not. Emptying HOME while leaving this set would be isolation in name only. Empty is
    # treated exactly like unset, because the discovery branch requires the file to exist.
    export MMRY_CONFIG_FILE=""
}

mmry_release_home() {
    [[ -n "${MMRY_TEST_HOME_BASE:-}" ]] || return 0

    # Already gone, nothing to do and nothing to report. run-tests.sh's EXIT trap fires after
    # the bats run whose teardown_suite already released the shared base, so this is the
    # ordinary end of every sanctioned run - not a refusal, and warning about it would train
    # the reader to ignore the warning that matters.
    [[ -e "$MMRY_TEST_HOME_BASE" ]] || { unset MMRY_TEST_HOME_BASE; return 0; }

    # teardown_suite calls this unconditionally, so the guard has to live here. Refusing
    # leaks a temp directory; not refusing deletes a directory this process never created.
    if ! _mmry_owns_test_home; then
        printf 'mmry_release_home: refusing to delete %s - this process did not create it (no %s marker, or $HOME is outside it)\n' \
            "$MMRY_TEST_HOME_BASE" "$_MMRY_TEST_HOME_MARKER" >&2
        return 0
    fi

    rm -rf "$MMRY_TEST_HOME_BASE" 2>/dev/null || true
    unset MMRY_TEST_HOME_BASE
}
