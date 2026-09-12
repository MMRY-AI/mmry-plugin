#!/usr/bin/env bash
# save-record.sh — record something against a structured record type, or update what is already
#                  recorded (#31460).
#
# UNLIKE save-memory.sh, THIS REFUSES. Here writing the record IS the request, so a field the
# type does not declare comes back as an error naming the field rather than quietly becoming an
# ordinary memory. Use "save-memory.sh --record-type" instead when the user asked you to remember
# something and the record is a decoration on that save.
#
# WHETHER THIS CREATES OR UPDATES IS NOT YOUR CHOICE and depends on what is already stored, so
# READ THE OUTCOME AND REPORT WHAT ACTUALLY HAPPENED:
#   structured.created  a new record
#   structured.updated  an existing one changed
#   text.degraded       the words were saved as an ordinary memory and the fields could NOT be
#                       stored. Say so plainly; never report a record that does not exist.
#
# An update changes ONLY the fields you send; anything you leave out keeps its current value.
#
# Usage:
#   bash save-record.sh --format-id ID --content "the user's own words" [--fields JSON]
#        [--topic T] [--scope S] [--record-id ID] [--record-name NAME]

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "${PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"

FORMAT_ID="" CONTENT="" FIELDS="" TOPIC="" SCOPE="" RECORD_ID="" RECORD_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --format-id)   FORMAT_ID="$2"; shift 2 ;;
        --content)     CONTENT="$2"; shift 2 ;;
        --fields)      FIELDS="$2"; shift 2 ;;
        --topic)       TOPIC="$2"; shift 2 ;;
        --scope)       SCOPE="$2"; shift 2 ;;
        --record-id)   RECORD_ID="$2"; shift 2 ;;
        --record-name) RECORD_NAME="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$FORMAT_ID" || -z "$CONTENT" ]]; then
    echo "Error: --format-id and --content are required. A record is still a memory and still" >&2
    echo "       needs the words it was saved from." >&2
    exit 1
fi

if mmry_create_record "$FORMAT_ID" "$CONTENT" "$FIELDS" "$TOPIC" "$SCOPE" "$RECORD_ID" "$RECORD_NAME"; then
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
    _mmry_format_error "save record"
    exit 1
fi
