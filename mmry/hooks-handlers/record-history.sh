#!/usr/bin/env bash
# record-history.sh - what a structured record USED TO hold, and when each value changed
#                     (#31384, ported to the published plugin by #31827).
#
# REACH FOR THIS BEFORE TELLING SOMEONE A VALUE HAS "ALWAYS" BEEN ANYTHING. It is what answers
# when a task moved to done, what a dose was before it was raised, and whether the user has
# already corrected this once. The changes come back oldest first, so reading them top to bottom
# is the record's whole life, starting with the values it was created with.
#
# EIGHT NAMES IN THE LIST ARE NOT FIELDS but reserved keys, and each arrives with a plain-English
# label to show instead of the raw sentinel: the memory's own words, its topic, who can see it,
# its category, how long it lasts, its record name, the retired record it replaces, and the moment
# it was retired.
#
# '~content~' is the memory's own words and '~topic~' is its
# topic. Both can be corrected - in the account area as well as here - so both are recorded.
#
# A record on another account and a record that does not exist answer identically. That is
# deliberate, so do not report "it exists but you cannot see it" on a not-found: you do not know
# that, and saying it would be the disclosure the sameness exists to prevent.
#
# Usage:
#   bash record-history.sh --format-id ID --record-id ID

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "${PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"

FORMAT_ID="" RECORD_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --format-id)
            [[ $# -ge 2 ]] || { echo "Error: --format-id needs the record type's id." >&2; exit 1; }
            FORMAT_ID="$2"; shift 2 ;;
        --record-id)
            [[ $# -ge 2 ]] || { echo "Error: --record-id needs the record's id." >&2; exit 1; }
            RECORD_ID="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$FORMAT_ID" || -z "$RECORD_ID" ]]; then
    echo "Error: --format-id and --record-id are both required." >&2
    echo "       Get them from list-formats.sh and query-records.sh." >&2
    exit 1
fi

# Both ids go into the request PATH, so anything but a positive whole number is refused here
# rather than sent: "../" in an id would otherwise address a different route.
for pair in "format-id:${FORMAT_ID}" "record-id:${RECORD_ID}"; do
    if [[ ! "${pair#*:}" =~ ^[1-9][0-9]{0,17}$ ]]; then
        echo "Error: --${pair%%:*} takes a positive whole number (got: ${pair#*:})." >&2
        exit 1
    fi
done

if mmry_get_record_history "$FORMAT_ID" "$RECORD_ID"; then
    if [[ -n "${MMRY_JQ:-}" ]]; then
        count="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.changes // (.history | length)')"
        if [[ "$count" == "0" ]]; then
            echo "Nothing has changed since this record was written."
        else
            printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '
                .history[]
                | "\(.changedAt)  \(.label // .field)  \(.kind)"
                  + "  was: \(.previous // "-")"
                  + "  now: \(.current // "-")"
                  + (if .changedBy then "  by \(.changedBy)" else "" end)'
        fi
    else
        printf '%s\n' "$MMRY_RESPONSE"
    fi
else
    _mmry_format_error "read record history"
    exit 1
fi
