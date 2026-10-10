#!/usr/bin/env bash
# search-memories.sh — Search memories by keyword.
# Usage: bash search-memories.sh [--ids] <KEYWORDS> [SCOPE]
#
# --ids (#31847): also print each memory's id, for correcting one. A correction replaces a memory
# by its id (save-memory.sh --supersedes), and the memories loaded at session start are the
# Foundation set, which a save cannot replace; so search is where the assistant finds the id of
# the memory being corrected. Without --ids the output is exactly what it always was.

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "${PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"

WITH_IDS=""
if [[ "${1:-}" == "--ids" ]]; then
    WITH_IDS=1
    shift
fi

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
    if [[ -n "$WITH_IDS" ]]; then
        printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.[] | "id \(.id) | \(.memoryTier) | \(.scope) | \(.topic)\n  \(.content)\n---"'
    else
        printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.[] | "\(.memoryTier) | \(.scope) | \(.topic)\n  \(.content)\n---"'
    fi
else
    _mmry_format_error
    exit 1
fi
