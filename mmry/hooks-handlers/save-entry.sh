#!/usr/bin/env bash
# save-entry.sh — save an entry in a database, or update one already saved (#31460).
#
# UNLIKE save-memory.sh, THIS REFUSES. Here writing the entry IS the request, so a field the
# database does not declare comes back as an error naming the field rather than quietly becoming an
# ordinary memory. Use "save-memory.sh --database-name" instead when the user asked you to remember
# something and the entry is a decoration on that save.
#
# WHETHER THIS CREATES OR UPDATES IS NOT YOUR CHOICE and depends on what is already stored, so
# READ THE OUTCOME AND REPORT WHAT ACTUALLY HAPPENED:
#   structured.created  a new entry
#   structured.updated  an existing one changed
#   text.degraded       the words were saved as an ordinary memory and the fields could NOT be
#                       stored. Say so plainly; never report an entry that does not exist.
#
# An update changes ONLY the fields you send; anything you leave out keeps its current value.
#
# Usage:
#   bash save-entry.sh --database-id ID --content "the user's own words" [--fields JSON]
#        [--topic T] [--scope S] [--entry-id ID] [--entry-name NAME]

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "${PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"

DATABASE_ID="" CONTENT="" FIELDS="" TOPIC="" SCOPE="" ENTRY_ID="" ENTRY_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --database-id)   DATABASE_ID="$2"; shift 2 ;;
        --content)     CONTENT="$2"; shift 2 ;;
        --fields)      FIELDS="$2"; shift 2 ;;
        --topic)       TOPIC="$2"; shift 2 ;;
        --scope)       SCOPE="$2"; shift 2 ;;
        --entry-id)   ENTRY_ID="$2"; shift 2 ;;
        --entry-name) ENTRY_NAME="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$DATABASE_ID" || -z "$CONTENT" ]]; then
    echo "Error: --database-id and --content are required. An entry is still a memory and still" >&2
    echo "       needs the words it was saved from." >&2
    exit 1
fi

if mmry_save_entry "$DATABASE_ID" "$CONTENT" "$FIELDS" "$TOPIC" "$SCOPE" "$ENTRY_ID" "$ENTRY_NAME"; then
    if [[ -n "${MMRY_JQ:-}" ]]; then
        printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '"Outcome: \(.outcome)  (memory \(.memoryId))"'
        degraded="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r 'select(.outcome == "text.degraded") | .detail // "no reason given"')"
        if [[ -n "$degraded" ]]; then
            echo "The words were saved; the fields were NOT. Reason: ${degraded}"
        fi
    else
        printf '%s\n' "$MMRY_RESPONSE"
    fi
else
    _mmry_print_error "save entry"
    exit 1
fi
