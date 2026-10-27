#!/usr/bin/env bash
# entry-history.sh - what an entry USED TO hold, and when each value changed
#                     (#31384, ported to the published plugin by #31827).
#
# REACH FOR THIS BEFORE TELLING SOMEONE A VALUE HAS "ALWAYS" BEEN ANYTHING. It is what answers
# when a task moved to done, what a dose was before it was raised, and whether the user has
# already corrected this once. The changes come back oldest first, so reading them top to bottom
# is the entry's whole life, starting with the values it was created with.
#
# EIGHT NAMES IN THE LIST ARE NOT FIELDS but reserved keys, and each arrives with a plain-English
# label to show instead of the raw sentinel: the memory's own words, its topic, who can see it,
# its category, how long it lasts, its entry name, the retired entry it replaces, and the moment
# it was retired.
#
# '~content~' is the memory's own words and '~topic~' is its
# topic. Both can be corrected - in the account area as well as here - so both are kept in the history.
#
# An entry on another account and an entry that does not exist answer identically. That is
# deliberate, so do not report "it exists but you cannot see it" on a not-found: you do not know
# that, and saying it would be the disclosure the sameness exists to prevent.
#
# Usage:
#   bash entry-history.sh --database-id ID --entry-id ID

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "${PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"

DATABASE_ID="" ENTRY_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --database-id)
            [[ $# -ge 2 ]] || { echo "Error: --database-id needs the database's id." >&2; exit 1; }
            DATABASE_ID="$2"; shift 2 ;;
        --entry-id)
            [[ $# -ge 2 ]] || { echo "Error: --entry-id needs the entry's id." >&2; exit 1; }
            ENTRY_ID="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$DATABASE_ID" || -z "$ENTRY_ID" ]]; then
    echo "Error: --database-id and --entry-id are both required." >&2
    echo "       Get them from list-databases.sh and query-entries.sh." >&2
    exit 1
fi

# Both ids go into the request PATH, so anything but a positive whole number is refused here
# rather than sent: "../" in an id would otherwise address a different route.
for pair in "database-id:${DATABASE_ID}" "entry-id:${ENTRY_ID}"; do
    if [[ ! "${pair#*:}" =~ ^[1-9][0-9]{0,17}$ ]]; then
        echo "Error: --${pair%%:*} takes a positive whole number (got: ${pair#*:})." >&2
        exit 1
    fi
done

if mmry_get_entry_history "$DATABASE_ID" "$ENTRY_ID"; then
    if [[ -n "${MMRY_JQ:-}" ]]; then
        count="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.changes // (.history | length)')"
        if [[ "$count" == "0" ]]; then
            echo "Nothing has changed since this entry was saved."
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
    _mmry_print_error "read entry history"
    exit 1
fi
