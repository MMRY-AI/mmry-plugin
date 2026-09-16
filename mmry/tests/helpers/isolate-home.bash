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

mmry_isolate_home() {
    # Idempotent: run-tests.sh and setup_suite.bash may both fire in one run, and a second
    # isolated HOME would only orphan the first.
    if [[ -n "${MMRY_TEST_HOME_BASE:-}" && -d "${MMRY_TEST_HOME_BASE:-/nonexistent}" ]]; then
        return 0
    fi

    local base
    base="$(mktemp -d)" || return 1
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
}

mmry_release_home() {
    [[ -n "${MMRY_TEST_HOME_BASE:-}" ]] || return 0
    rm -rf "$MMRY_TEST_HOME_BASE" 2>/dev/null || true
}
