#!/usr/bin/env bash
# create-format.sh — define a new structured record type (#31460).
#
# WHEN TO CREATE ONE, and the answer is usually DO NOT. Create a type when the user is going to
# record the same SHAPE of thing repeatedly and will later want to ask questions of it. Do NOT
# create one for a single fact, a one-off note, or anything you would not expect a second example
# of: that is an ordinary memory, and save-memory.sh is the right tool.
#
# RUN list-formats.sh FIRST and reuse what is already there.
#
# Usage:
#   bash create-format.sh --name NAME --fields JSON [--description D]
#        [--mode append|keyed|singleton] [--identity-field KEY]
#        [--match-hints "a, b, c"] [--visibility private|global]
#
#   --fields        a JSON ARRAY of field definitions. Each has a key, an optional label, and a
#                   type: text, number, date, bool, enum (with options), or list (with "of").
#                   Rough is fine - an unrecognised type is stored as text rather than refused.
#                     [{"key":"severity","label":"Severity","type":"number"},
#                      {"key":"triggers","label":"Triggers","type":"list","of":"text"}]
#   --mode          what makes two records the same one. "append" when every entry is new and
#                   nothing is ever revised (a symptom log, expenses). "keyed" when records are
#                   named things that each change on their own (tasks, contacts, recipes) - then
#                   --identity-field names the field whose value names a record. "singleton" when
#                   there is only ever one ("my spouse", "this laptop").
#   --match-hints   the words that mean a save belongs here, comma separated, IN THE USER'S OWN
#                   VOCABULARY: "migraine, headache, aura". This is what lets a later ORDINARY
#                   save be recognised and recorded here without the user asking. Leave it out
#                   and the type must always be named explicitly.
#   --visibility    "private" for the user alone, "global" for everyone on the account. An
#                   account-wide type requires the user to be an administrator; if they are not
#                   it is refused, and a private one is the thing to offer instead.

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "${PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"

NAME="" FIELDS="" DESCRIPTION="" MODE="append"
IDENTITY="" HINTS="" VISIBILITY="Private"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)           NAME="$2"; shift 2 ;;
        --fields)         FIELDS="$2"; shift 2 ;;
        --description)    DESCRIPTION="$2"; shift 2 ;;
        --mode)           MODE="$2"; shift 2 ;;
        --identity-field) IDENTITY="$2"; shift 2 ;;
        --match-hints)    HINTS="$2"; shift 2 ;;
        --visibility)     VISIBILITY="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$NAME" || -z "$FIELDS" ]]; then
    echo "Error: --name and --fields are required" >&2
    exit 1
fi

# The product's spelling, from the words a person actually uses. An unrecognised word is refused
# rather than quietly made private: a user who asked for an account-wide type and silently got a
# private one has been told it worked.
case "$(echo "$VISIBILITY" | tr '[:upper:]' '[:lower:]')" in
    global|organization|organisation|account|everyone) VISIBILITY="Global" ;;
    private|"") VISIBILITY="Private" ;;
    *) echo "Error: --visibility is 'private' or 'global'." >&2; exit 1 ;;
esac

if mmry_create_format "$NAME" "$FIELDS" "$DESCRIPTION" "$MODE" "$IDENTITY" "$HINTS" "$VISIBILITY"; then
    if [[ -n "${MMRY_JQ:-}" ]]; then
        printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '"Created record type \(.format.name) with id \(.format.rootId)."'
    else
        printf '%s\n' "$MMRY_RESPONSE"
    fi
else
    _mmry_format_error "create record type"
    exit 1
fi
