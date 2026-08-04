#!/usr/bin/env bash
# make-private.sh - Restrict a memory you saved so only you can see it (#29901).
#
# Backs the "make it private" follow-through on the sensitive-content nudge: memories are
# shared with the organization by default, so a user needs a one-step way to pull one back.
#
# Usage:
#   bash make-private.sh                # the most recent memory you saved
#   bash make-private.sh 1234           # a specific memory id
#   bash make-private.sh 1234 group 7   # or scope it to a group you belong to
#
# Only the person who saved a memory can change its scope; the server enforces that and
# returns 403 otherwise.

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "${PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"

if [[ -z "${MMRY_JQ:-}" ]]; then
    mmry_jq_unavailable_message
    exit 1
fi

MEMORY_ID="${1:-}"
TARGET="${2:-private}"
GROUP_ID="${3:-}"

# Default to the caller's most recently created memory, which is what "make it private"
# means right after a save.
if [[ -z "$MEMORY_ID" ]]; then
    if ! mmry_get_memories; then
        _mmry_format_error "look up your recent memories"
        exit 1
    fi
    MEMORY_ID="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '
        (if type == "object" then (.items // .memories // []) else . end)
        | sort_by(.createdDate) | reverse | .[0].id // empty')"
    if [[ -z "$MEMORY_ID" ]]; then
        echo "No memories found to restrict."
        exit 1
    fi
fi

case "$(printf '%s' "$TARGET" | tr '[:upper:]' '[:lower:]')" in
    private) VIS="Private" ;;
    global)  VIS="Global" ;;
    group)
        VIS="Group"
        if [[ -z "$GROUP_ID" ]]; then
            echo "A group id is required: make-private.sh <id> group <groupId>"
            exit 1
        fi
        ;;
    *) echo "Unknown target: ${TARGET} (use private, global, or group <id>)"; exit 1 ;;
esac

if mmry_set_memory_visibility "$MEMORY_ID" "$VIS" "$GROUP_ID"; then
    case "$VIS" in
        Private) echo "Done. That memory is now visible only to you." ;;
        Global)  echo "Done. That memory is now shared with your organization." ;;
        Group)   echo "Done. That memory is now shared with the selected group only." ;;
    esac
else
    # 403 here means the caller did not save that memory.
    _mmry_format_error "change that memory's visibility"
    exit 1
fi
