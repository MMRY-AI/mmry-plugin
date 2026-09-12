#!/usr/bin/env bash
# list-formats.sh — the user's structured record types (#31460).
#
# WHAT A RECORD TYPE IS, because the name does not say it. It is a shape the user accumulates
# EXAMPLES of - every migraine and what preceded it, every expense, every job application - so
# that "how many of these had X" becomes an answer rather than a guess. A record is an ordinary
# memory that additionally carries named fields; the user's own words are always kept verbatim.
#
# CALL THIS BEFORE CREATING A NEW TYPE. Left to itself a model creates one type per conversation
# and leaves the account full of types holding one record each.
#
# Usage: bash list-formats.sh [--id FORMAT_ID] [--include-retired]
#   --id                one type in full: every field it collects and which it has stopped
#                       collecting
#   --include-retired   include types the user has retired. Usually omitted.

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "${PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"

FORMAT_ID=""
INCLUDE_RETIRED=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --id)              FORMAT_ID="$2"; shift 2 ;;
        --include-retired) INCLUDE_RETIRED="true"; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

ok=0
if [[ -n "$FORMAT_ID" ]]; then
    mmry_get_format "$FORMAT_ID" || ok=$?
else
    mmry_list_formats "$INCLUDE_RETIRED" || ok=$?
fi

if [[ $ok -ne 0 ]]; then
    _mmry_format_error "list record types"
    exit 1
fi

# THE TWO SHAPES ARE DIFFERENT AND THAT IS THE ROUTES' DOING, NOT AN OVERSIGHT HERE.
# GET /api/data-formats answers a flat ARRAY of chain summaries - id, name, how many records,
# what it is recognised by - and deliberately carries no field list, because a list of twenty
# types would otherwise return a hundred field definitions nobody asked for. The per-type read
# is where the fields are, which is why --id exists and why the skill says to call it before
# recording against a type you did not just create.
if [[ -z "${MMRY_JQ:-}" ]]; then
    printf '%s\n' "$MMRY_RESPONSE"
    exit 0
fi

if [[ -n "$FORMAT_ID" ]]; then
    printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '
        "Record type: \(.format.name)  (id \(.format.rootId), version \(.format.version) of \(.format.versions))",
        "Records held: \(.format.entries)",
        "Identity: \(.format.entryKeyMode)" + (if .format.identityField then " on \(.format.identityField)" else "" end),
        "Visible to: \(.format.visibility)",
        "Recognised by: " + (if (.format.matchHints // "") == "" then "(nothing - this type must be named explicitly)" else .format.matchHints end),
        "Fields:",
        (.fields[] | "  \(.key) (\(.type))" + (if .retired then "  [no longer collected]" else "" end))'
    exit 0
fi

count="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" 'length')"
if [[ "$count" == "0" ]]; then
    echo "No structured record types yet."
    echo "Create one with create-format.sh when the user is accumulating examples of a"
    echo "recurring shape they will later want to count or compare."
    exit 0
fi
echo "${count} record type(s):"
echo ""
printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.[] |
    "id \(.rootId) | \(.name) | \(.entries) record(s) | recognised by: " +
    (if (.matchHints // "") == "" then "(must be named explicitly)" else .matchHints end)'
echo ""
echo "Run with --id <id> for the fields a type collects."
