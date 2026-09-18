#!/usr/bin/env bash
# setup_suite.bash (tests/ root) — #31434 QA round 3.
#
# THE INVOCATION THE PER-DIRECTORY COPIES MISS. bats resolves its suite setup file from the
# DIRECTORY OF THE ARGUMENT it was given (libexec/bats-core/bats: for a directory argument,
# `dirname="$filename"`, then `$dirname/setup_suite.bash`); it does not walk upwards, and it
# does not look inside the directories a recursive run expands to. So
#
#     bats -r mmry/tests/            -> looks ONLY for mmry/tests/setup_suite.bash
#
# found nothing before this file existed, ran every suite in the tree with the developer's
# real $HOME, and said nothing about it. Silently running unisolated is the precise failure
# this change exists to remove, so the fix is to cover the shape rather than to document it.
#
# Same body as the per-directory copies; the logic lives once in helpers/isolate-home.bash.

setup_suite() {
    # shellcheck disable=SC1091
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/isolate-home.bash"
    mmry_isolate_home
}

teardown_suite() {
    # shellcheck disable=SC1091
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/isolate-home.bash"
    mmry_release_home
}
