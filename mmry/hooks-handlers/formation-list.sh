#!/usr/bin/env bash
# formation-list.sh - show this account's active formations, so a join does not need a guessed id.
set -euo pipefail

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HANDLER_DIR}/mmry-client.sh"

mmry_load_config || true

if ! mmry_get_active_formations; then
    echo "Could not reach the service (HTTP ${MMRY_HTTP_CODE:-0})."
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
