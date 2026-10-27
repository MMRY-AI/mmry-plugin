#!/usr/bin/env bash
# revise-database.sh - change a database that already exists (#31460 QA round three, also-fix 9).
#
# WHY THIS FILE EXISTS. In the API repo, mmry-client.sh had carried the revise, rename, retire and
# reinstate functions since the surface was built and NOTHING CALLED ANY OF THEM: no handler
# script, no mention in SKILL.md. In THIS repo the published plugin had none of it - neither the
# client functions nor a handler - so the gap was total rather than partial (#31460). Either way
# the consequence for a user was identical: a Claude Code assistant could design
# a database and save entries in it, and then could not add a field to it - the one thing a person
# asks for the moment they use a database in anger, because the shape of what they are collecting is
# never right on the first attempt. Their only route was to create a SECOND database for the same
# thing, which is the exact outcome create-database.sh spends a paragraph warning against.
#
# FOUR OPERATIONS IN ONE FILE, because they are one decision with four answers, and an assistant
# choosing between four sibling scripts chooses wrong. The verbs are the product's:
#
#   --add-fields / --fields   PUBLISH A NEW VERSION. This is the one for "add a field".
#   --rename / --describe /   CORRECT WHAT IT IS CALLED, what it is for, or the words that help
#     --match-hints           the assistant choose it. Touches no field and no entry.
#   --retire                  STOP IT COLLECTING and keep everything it holds.
#   --reinstate               START IT COLLECTING AGAIN.
#
# NOTHING HERE EVER DELETES AN ENTRY, and there is no route that does. Revising publishes a NEW
# VERSION: every entry already stored stays where it is and stays readable, and the older ones
# simply have no value for a new field. Retiring is not deletion either - a retired database keeps
# every entry it holds and is readable; it just stops collecting new ones. Say that to the user
# in those words, because "retire" sounds destructive and is not.
#
# --fields REPLACES THE WHOLE FIELD LIST, it does not append to it. Read the database first with
# list-databases.sh --id ID, take the fields it reports, add yours, and send the whole array. A
# field you leave out is not deleted - the entries that carry it keep it and stay readable - but
# the new version stops collecting it, which is usually not what the user meant.
#
# Usage:
#   bash revise-database.sh --id ID --fields JSON [--rename NAME] [--describe TEXT] [--match-hints "a, b"]
#   bash revise-database.sh --id ID --rename NAME
#   bash revise-database.sh --id ID --describe "what it is for"
#   bash revise-database.sh --id ID --match-hints "migraine, headache, aura"
#   bash revise-database.sh --id ID --retire
#   bash revise-database.sh --id ID --reinstate

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "${PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"

ID="" FIELDS="" NAME="" DESCRIPTION="" HINTS=""
RETIRE=0 REINSTATE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --id)                     ID="$2"; shift 2 ;;
        --fields|--add-fields)    FIELDS="$2"; shift 2 ;;
        --rename|--name)          NAME="$2"; shift 2 ;;
        --describe|--description) DESCRIPTION="$2"; shift 2 ;;
        --match-hints)            HINTS="$2"; shift 2 ;;
        --retire)                 RETIRE=1; shift ;;
        --reinstate)              REINSTATE=1; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$ID" ]]; then
    echo "Error: --id is required. Run list-databases.sh to find it." >&2
    exit 1
fi

# THE TWO SWITCHES ARE REFUSED TOGETHER rather than one silently winning. "Retire it and bring it
# back" is not a coherent request, and picking an order for the caller would make the result
# depend on something they cannot see.
if [[ $RETIRE -eq 1 && $REINSTATE -eq 1 ]]; then
    echo "Error: --retire and --reinstate are opposites. Ask for one." >&2
    exit 1
fi

if [[ $RETIRE -eq 1 || $REINSTATE -eq 1 ]]; then
    if [[ -n "$FIELDS" || -n "$NAME" || -n "$DESCRIPTION" || -n "$HINTS" ]]; then
        echo "Error: --retire and --reinstate change whether a database COLLECTS, and take nothing else." >&2
        echo "       Run this twice if you mean to do both." >&2
        exit 1
    fi
fi

report() {
    # ONE OUTPUT SHAPE FOR ALL FOUR, so a caller reads the same shape whatever it asked for.
    #
    # The name is read out of the DATABASE BLOCK rather than echoed back from the arguments: what
    # matters is what the server stored, and on a rename those two differ precisely when
    # something went wrong.
    #
    # Retire and reinstate answer a different shape - they change whether a database collects, not
    # what it is - so they report the COUNT, which is the number the user actually wants to hear.
    # "Retired, it still holds 41 entries" is reassurance; a raw JSON object is not.
    if [[ -n "${MMRY_JQ:-}" ]]; then
        printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '
            if .database then
                "Database: \(.database.name) (id \(.database.rootId), version \(.database.version))"
            elif (.entries != null) then
                "It still holds \(.entries) " + (if .entries == 1 then "entry" else "entries" end) + "."
            else tostring end'
    else
        printf '%s\n' "$MMRY_RESPONSE"
    fi
}

fail() {
    _mmry_print_error "revise database"
    exit 1
}

if [[ $RETIRE -eq 1 ]]; then
    mmry_retire_database "$ID" || fail
    report
    echo "Retired. It keeps every entry it holds and they stay readable; it just stops collecting new ones."
    exit 0
fi

if [[ $REINSTATE -eq 1 ]]; then
    mmry_reinstate_database "$ID" || fail
    report
    echo "Collecting again."
    exit 0
fi

if [[ -n "$FIELDS" ]]; then
    # A NEW VERSION. The name, description and hints ride along when given, so "add a field and
    # also fix the hints" is one call and one version rather than two of each.
    mmry_revise_database "$ID" "$FIELDS" "$NAME" "$DESCRIPTION" "$HINTS" || fail
    report
    echo "Published a new version. Every entry already saved is unchanged and still readable;"
    echo "entries from before this version simply have no value for a field it just added."
    exit 0
fi

if [[ -n "$NAME" || -n "$DESCRIPTION" || -n "$HINTS" ]]; then
    mmry_rename_database "$ID" "$NAME" "$DESCRIPTION" "$HINTS" || fail
    report
    [[ -n "$HINTS" ]] && echo "Those words now help the assistant choose this database. A save becomes an entry when MMRY can tell which database it belongs to, by its name or by these words, and has values for its fields, supplied or as labelled lines such as \"Amount: 25\". Otherwise it stays an ordinary memory."
    exit 0
fi

echo "Error: nothing to change. Give --fields, --rename, --describe, --match-hints," >&2
echo "       --retire or --reinstate." >&2
exit 1
