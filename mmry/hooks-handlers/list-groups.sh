#!/usr/bin/env bash
# list-groups.sh — List permission groups the current user belongs to.
# Usage: bash list-groups.sh

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "${PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"

if [[ -z "${MMRY_JQ:-}" ]]; then
    mmry_jq_unavailable_message
    exit 1
fi

if mmry_get_my_groups; then
    count="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" 'length')"
    if [[ "$count" -eq 0 ]]; then
        echo "No groups found. Create one with the API or ask an admin."
    else
        echo "Found ${count} group(s):"
        echo ""
        printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.[] | "  ID: \(.id)  Name: \(.groupName)"'
    fi
else
    _mmry_format_error "list groups"
    exit 1
fi
