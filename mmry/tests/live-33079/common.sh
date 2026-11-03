#!/usr/bin/env bash
# common.sh - shared setup for the 33079 R4 live J-016 proof (Integration only). Sourced, never run.
# NEVER prints a key. Do not run any of this under set -x.
J_REPO=/c/Users/ericbaroneai/repos/33079-j016-live
export PLUGIN_ROOT="$J_REPO/mmry"
J_EVID="${J_EVID:-/r/Intranet/ClaudeAI/plans/MMRY/v1.32.1/33079-j016-live}"
J_SCRATCH=/c/Users/ericbaroneai/scratch/33079-j016
J_KEYFILE=/c/Users/ericbaroneai/.mmry-test-secrets/integration-33030-a-apikey
export LIVE_SPEC_NAME="33079-j016-live"
# shellcheck disable=SC1091
source "$PLUGIN_ROOT/tests/helpers/live-journey.bash"
live_resolve_jq || return 1
live_service_url || return 1   # refuses anything but Integration / loopback
export LIVE_JQ LIVE_URL
J_KEY="$(tr -d '\r\n' < "$J_KEYFILE")"
