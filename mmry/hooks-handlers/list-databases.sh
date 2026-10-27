#!/usr/bin/env bash
# list-databases.sh — the user's databases (#31460).
#
# WHAT A DATABASE IS, because the name does not say it. It is a shape the user accumulates
# EXAMPLES of - every migraine and what preceded it, every expense, every job application - so
# that "how many of these had X" becomes an answer rather than a guess. An entry is an ordinary
# memory that additionally carries named fields; the user's own words are always kept verbatim.
#
# CALL THIS BEFORE CREATING A NEW DATABASE. Left to itself a model creates one database per
# conversation and leaves the account full of databases holding one entry each.
#
# Usage: bash list-databases.sh [--id DATABASE_ID] [--include-retired]
#   --id                one database in full: every field it collects and which it has stopped
#                       collecting
#   --include-retired   include databases the user has retired. Usually omitted.

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "${PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"

DATABASE_ID=""
INCLUDE_RETIRED=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --id)              DATABASE_ID="$2"; shift 2 ;;
        --include-retired) INCLUDE_RETIRED="true"; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

ok=0
if [[ -n "$DATABASE_ID" ]]; then
    mmry_get_database "$DATABASE_ID" || ok=$?
else
    mmry_list_databases "$INCLUDE_RETIRED" || ok=$?
fi

if [[ $ok -ne 0 ]]; then
    _mmry_print_error "list databases"
    exit 1
fi

# THE TWO SHAPES ARE DIFFERENT AND THAT IS THE ROUTES' DOING, NOT AN OVERSIGHT HERE.
# GET /api/databases answers a flat ARRAY of chain summaries - id, name, how many entries,
# the words that help the assistant choose it - and deliberately carries no field list, because a list of twenty
# databases would otherwise return a hundred field definitions nobody asked for. The per-type read
# is where the fields are, which is why --id exists and why the skill says to call it before
# saving an entry in a database you did not just create.
if [[ -z "${MMRY_JQ:-}" ]]; then
    printf '%s\n' "$MMRY_RESPONSE"
    exit 0
fi

if [[ -n "$DATABASE_ID" ]]; then
    printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '
        "Database: \(.database.name)  (id \(.database.rootId), version \(.database.version) of \(.database.versions))",
        "Entries held: \(.database.entries)",
        "Identity: \(.database.entryKeyMode)" + (if .database.identityField then " on \(.database.identityField)" else "" end),
        "Visible to: \(.database.visibility)",
        "Words that help choose it: " + (if (.database.matchHints // "") == "" then "(none - name this database when you save an entry to it)" else .database.matchHints end),
        "Fields:",
        (.fields[] | "  \(.key) (\(.type))" + (if .retired then "  [no longer collected]" else "" end))'
    exit 0
fi

count="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" 'length')"
if [[ "$count" == "0" ]]; then
    echo "No databases yet."
    echo "Create one with create-database.sh when the user is accumulating examples of a"
    echo "recurring shape they will later want to count or compare."
    exit 0
fi
echo "${count} database(s):"
echo ""
printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.[] |
    "id \(.rootId) | \(.name) | \(.entries) " + (if .entries == 1 then "entry" else "entries" end) + " | words that help choose it: " +
    (if (.matchHints // "") == "" then "(none)" else .matchHints end) + " | a save becomes an entry when it names this database" + (if (.matchHints // "") == "" then "" else " or contains these words" end) + " and has values for its fields"'
echo ""
echo "Run with --id <id> for the fields a database collects."
