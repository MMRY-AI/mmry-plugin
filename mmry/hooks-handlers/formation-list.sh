#!/usr/bin/env bash
# formation-list.sh - show this account's active formations, so a join does not need a guessed id.
set -euo pipefail

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HANDLER_DIR}/mmry-client.sh"

mmry_load_config || true

if ! mmry_get_active_formations; then
    # #31195: this said "could not reach the service" for every failure, including the ones that
    # prove the opposite. A 401 or a 403 is the service answering, and sending somebody to look at
    # their network when the real answer was "your credential expired" is the same defect as the
    # formation 502: a status reported as a cause it does not support. HTTP 000 IS the unreachable
    # case and mmry-client puts its explanation in MMRY_RESPONSE, so that is passed through.
    if [[ "${MMRY_HTTP_CODE:-0}" == "000" ]]; then
        echo "Could not reach the service. ${MMRY_RESPONSE:-}"
    else
        echo "Could not list this account's formations (HTTP ${MMRY_HTTP_CODE:-0}). ${MMRY_RESPONSE:-}"
    fi
    exit 1
fi

if [[ -z "${MMRY_JQ:-}" ]]; then
    echo "$MMRY_RESPONSE"
    exit 0
fi

count="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r 'if type == "array" then length else 0 end' 2>/dev/null || printf '0')"
if [[ "$count" == "0" ]]; then
    echo "No active formations on this account."
    exit 0
fi

printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '
    if type == "array" then
        .[] | "  " + (.id | tostring) + "  " + (.objective // "(no objective)")
              + "  (" + ((.activeMemberCount // 0) | tostring) + " active member(s))"
    else empty end' 2>/dev/null || echo "$MMRY_RESPONSE"
exit 0
