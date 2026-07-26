#!/usr/bin/env bash
# search-memories.sh — Search memories by keyword.
# Usage: bash search-memories.sh <KEYWORDS> [SCOPE]

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "${PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"

KEYWORDS="${1:-}"
SCOPE="${2:-}"

if [[ -z "$KEYWORDS" ]]; then
    echo "Error: Keywords required as first argument" >&2
    exit 1
fi

if [[ -z "${MMRY_JQ:-}" ]]; then
    mmry_jq_unavailable_message
    exit 1
fi

if mmry_search_memories "$KEYWORDS" "$SCOPE"; then
    count="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" 'length')"
    echo "Found ${count} memories:"
    echo ""
    printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.[] | "\(.memoryTier) | \(.scope) | \(.topic)\n  \(.content)\n---"'
else
    _mmry_format_error
    exit 1
fi
