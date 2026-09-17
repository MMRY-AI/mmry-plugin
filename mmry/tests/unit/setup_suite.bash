#!/usr/bin/env bash
# setup_suite.bash — #31434 QA round 2.
#
# bats loads this automatically from the directory of the first test file in a run, and its
# exports reach every test. That makes it the one hook a suite cannot decline: eleven suites
# in this repo do not load helpers/test-helper.bash, and until now that meant they ran against
# the developer's real ~/.claude/mmry-config.json and its live API key.
#
# One copy per test directory, because bats resolves this file relative to the first test file
# it is given - `bats structural/formation-delivery.bats` must be as isolated as `run-tests.sh`.
# The logic itself is not duplicated; it lives in helpers/isolate-home.bash.

setup_suite() {
    # shellcheck disable=SC1091
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/helpers/isolate-home.bash"
    mmry_isolate_home
}

teardown_suite() {
    # shellcheck disable=SC1091
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/helpers/isolate-home.bash"
    mmry_release_home
}
