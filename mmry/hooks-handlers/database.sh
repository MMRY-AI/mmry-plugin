#!/usr/bin/env bash
# database.sh - the one script behind /mmry:database (#32443).
#
# WHY A DISPATCHER. Each subcommand is an operation the AI database already has a script for. This
# file adds nothing to any of them: it picks the script, hands it the arguments unchanged, prints
# what that script printed, and ends a successful answer with the account page where the customer
# sees and corrects their entries themselves. Doing that in one place means every subcommand links
# to the portal, and a test can check each subcommand reaches the right script.
#
#   create   create-database.sh     set up a database
#   list     list-databases.sh      the databases, or one in full with --id
#   add      save-entry.sh          save a new entry
#   find     query-entries.sh       read entries, filtered on their fields
#   correct  save-entry.sh          change an entry already saved (needs --entry-id)
#   history  entry-history.sh       what an entry held before, and when it changed
#   retire   retire-database.sh     stop a database collecting; nothing is deleted
#   restore  reinstate-database.sh  start a retired database collecting again
#
# The scripts, their options and the client functions are named for databases and entries too
# (#32957, DD-164 in the mmry repository): --database-id names a database, --entry-id an entry.
#
# Usage: bash database.sh <subcommand> [the arguments of that subcommand's script]

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# The account page. Customer-facing, so it is the production address on every environment.
PORTAL_URL="https://mmryai.com/databases"

usage() {
    echo "Usage: database.sh <subcommand> [arguments]" >&2
    echo "Subcommands: create, list, add, find, correct, history, retire, restore." >&2
}

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

SUB="$1"; shift

has_flag() {
    local want="$1"; shift
    local a
    for a in "$@"; do [[ "$a" == "$want" ]] && return 0; done
    return 1
}

case "$SUB" in
    create)  SCRIPT="create-database.sh" ;;
    list)    SCRIPT="list-databases.sh" ;;
    add)
        # Adding is a new entry. Naming an existing one is a correction, and the two are kept
        # apart so "add" never quietly changes something the customer already saved.
        if has_flag --entry-id "$@"; then
            echo "Error: add saves a new entry. To change one already saved, use correct with --entry-id." >&2
            exit 1
        fi
        SCRIPT="save-entry.sh" ;;
    find)    SCRIPT="query-entries.sh" ;;
    correct)
        # A correction names the entry by id: the one way of naming an entry that cannot pick the
        # wrong one. Without it the server might create a new entry instead.
        if ! has_flag --entry-id "$@"; then
            echo "Error: correct needs --entry-id, the entry's id. Find it with find." >&2
            exit 1
        fi
        SCRIPT="save-entry.sh" ;;
    history) SCRIPT="entry-history.sh" ;;
    retire)  SCRIPT="retire-database.sh" ;;
    restore) SCRIPT="reinstate-database.sh" ;;
    *)
        echo "Error: unknown subcommand '$SUB'." >&2
        usage
        exit 1 ;;
esac

rc=0
bash "${HERE}/${SCRIPT}" "$@" || rc=$?
if [[ $rc -ne 0 ]]; then
    exit "$rc"
fi

echo ""
echo "See your databases and correct any entry yourself at ${PORTAL_URL}"
