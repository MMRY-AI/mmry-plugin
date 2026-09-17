#!/usr/bin/env bash
# Run MMRY AI plugin tests
# Usage: ./run-tests.sh [category]
#   category: structural, unit, handlers, e2e, integration, all, offline (default)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

CATEGORY="${1:-offline}"
BATS="./libs/bats-core/bin/bats"

if [[ ! -x "$BATS" ]]; then
    echo "Error: BATS not found. Run 'git submodule update --init --recursive' first." >&2
    exit 1
fi

# ISOLATE HOME BEFORE ANY TEST RUNS (#31434 QA round 2).
#
# Not in helpers/test-helper.bash, because eleven suites do not load it and therefore ran
# against the developer's real ~/.claude/mmry-config.json and its live API key. Isolation a
# suite can decline is isolation some suite will decline. Applied here, where nothing in a
# test file can opt out of it, and again from each directory's setup_suite.bash so a direct
# `bats structural/one.bats` is isolated too. See helpers/isolate-home.bash.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/helpers/isolate-home.bash"
mmry_isolate_home
trap 'mmry_release_home' EXIT

case "$CATEGORY" in
    structural)  "$BATS" structural/ ;;
    unit)        "$BATS" unit/ ;;
    handlers)    "$BATS" handlers/ ;;
    e2e)         "$BATS" e2e/ ;;
    integration) "$BATS" integration/ ;;
    offline)     "$BATS" structural/ unit/ handlers/ e2e/ ;;
    all)         "$BATS" structural/ unit/ handlers/ e2e/ integration/ ;;
    *)
        echo "Usage: $0 [structural|unit|handlers|e2e|integration|offline|all]" >&2
        exit 1
        ;;
esac
