#!/usr/bin/env bash
# save-entries.sh - save or update SEVERAL entries in one database in one request (#33317).
#
# Use this instead of running save-entry.sh once per entry whenever you are about to save or change
# more than one entry in the same database, for example correcting or renumbering a set of entries.
# It is the plugin's door to the same server code as the connector's mmry_entry_save_batch
# (#32943): the same limits, the same choice rules, the same privacy question and the same
# visibility rules.
#
# EACH ENTRY IS HANDLED ON ITS OWN, exactly as one entry save would handle it: one that is refused
# does not stop the others, and nothing is undone. Every entry is printed on its own line, in the
# order sent, as one of:
#   Entry N: saved, <outcome> (entry ID, visibility V)   structured.created, structured.updated, or
#                                                         text.degraded (words kept, fields NOT)
#   Entry N: NOT SAVED. Ask the user: <question>          put the question to the user and wait
#   Entry N: refused. Reason: <why>                       tell the user why
# Report what actually happened to each one, including the ones refused and why.
#
# A batch holds at most 25 entries and 100,000 characters (the server's limits, checked here too
# so a batch the server would refuse whole never leaves the machine). Send more in several batches.
#
# Usage:
#   bash save-entries.sh --database-id ID --entries '[{"entryId":41,"content":"...","fields":{"number":4}}, ...]'
#   bash save-entries.sh --database-id ID --entries-file PATH     # the same array, read from a file
#
# Each entry takes: content (required, the user's own words), fields (an object keyed by the
# database's field keys), and optionally topic, scope, entryId (to update that entry), entryName,
# visibility ('private', 'organization' or 'group'), group, personal (true or false) and questionId.
#
# --entries-file is for a batch too long for one command line (Windows caps a command line at
# 32,767 characters; a batch may be 100,000).

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "${PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"

# The server's defaults (EntryBatchOptions in the API). The server is the authority; these only
# stop a batch it would refuse whole from being sent, in the server's own words.
MAX_ENTRIES=25
MAX_CHARACTERS=100000

DATABASE_ID="" ENTRIES="" ENTRIES_FILE="" HAVE_ENTRIES=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --database-id)  DATABASE_ID="$2"; shift 2 ;;
        --entries)      ENTRIES="$2"; HAVE_ENTRIES=1; shift 2 ;;
        --entries-file) ENTRIES_FILE="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -n "$ENTRIES_FILE" ]]; then
    if [[ -n "$HAVE_ENTRIES" ]]; then
        echo "Error: give the entries once, with --entries or with --entries-file, not both." >&2
        exit 1
    fi
    if [[ ! -f "$ENTRIES_FILE" ]]; then
        echo "Error: cannot read the entries file: ${ENTRIES_FILE}" >&2
        exit 1
    fi
    IFS= read -r -d '' ENTRIES < "$ENTRIES_FILE" || true
    HAVE_ENTRIES=1
fi

if [[ -z "$DATABASE_ID" || -z "$HAVE_ENTRIES" ]]; then
    echo "Error: --database-id and --entries (or --entries-file) are required." >&2
    exit 1
fi

# 100000 -> 100,000, as the server writes its numbers.
_commas() {
    local n="$1" out=""
    while [[ ${#n} -gt 3 ]]; do
        out=",${n:${#n}-3}${out}"
        n="${n:0:${#n}-3}"
    done
    printf '%s%s' "$n" "$out"
}

# THE CAPS, BEFORE ANY REQUEST. Counted by jq, in characters (code points). The server counts
# UTF-16 units, which is never fewer, so nothing the server would accept is refused here; a batch
# of emoji right at the limit may still be refused by the server, in the same words.
if [[ -n "${MMRY_JQ:-}" ]]; then
    chars="$(printf '%s' "$ENTRIES" | "$MMRY_JQ" -Rs 'length' 2>/dev/null | tr -d '\r' || true)"
    if [[ "$chars" =~ ^[0-9]+$ ]] && (( chars > MAX_CHARACTERS )); then
        echo "Nothing was saved: this batch is $(_commas "$chars") characters and a batch may be at most $(_commas "$MAX_CHARACTERS"). Send the entries in smaller batches." >&2
        exit 1
    fi
    count="$(printf '%s' "$ENTRIES" | "$MMRY_JQ" 'if type == "array" then length else empty end' 2>/dev/null | tr -d '\r' || true)"
    if [[ "$count" =~ ^[0-9]+$ ]] && (( count > MAX_ENTRIES )); then
        echo "Nothing was saved: a batch may hold at most ${MAX_ENTRIES} entries and this one holds ${count}. Send them in batches of ${MAX_ENTRIES} or fewer." >&2
        exit 1
    fi
fi

# Up to 25 entries are saved one after another on the server. Allow for that, unless the caller
# has asked for a time of its own.
export MMRY_HTTP_MAX_TIME="${MMRY_HTTP_MAX_TIME:-120}"

if mmry_save_entries "$DATABASE_ID" "$ENTRIES"; then
    if [[ -n "${MMRY_JQ:-}" ]]; then
        printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '
            def outcome: (.entry.Outcome // .entry.outcome // "saved");
            def where:   "entry \(.entry.MemoryId // .entry.memoryId // "?")"
                         + (if (.entry.Visibility // .entry.visibility) then ", visibility \(.entry.Visibility // .entry.visibility)" else "" end);
            .summary,
            (.results[] |
                "Entry \(.position): " +
                (if .status == "saved" then
                    "saved, \(outcome) (\(where))"
                    + (if outcome == "text.degraded"
                       then ". The words were saved; the fields were NOT. Reason: \(.entry.Detail // .entry.detail // "no reason given")"
                       else "" end)
                 elif .status == "not saved" then
                    "NOT SAVED. Ask the user: \(.question.ask)\n"
                    + "  Nothing is stored for this entry yet. Wait for their answer, then send this entry again unchanged, "
                    + "with visibility set to their answer and questionId \(.question.questionId)."
                 else
                    "refused. Reason: \(.reason)"
                 end))' | tr -d '\r'
    else
        printf '%s\n' "$MMRY_RESPONSE"
    fi
else
    # Refused whole (over a limit, empty, not an array): the server's own sentence, plainly.
    message=""
    if [[ "$MMRY_HTTP_CODE" == "400" && -n "${MMRY_JQ:-}" ]]; then
        message="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.error // empty' 2>/dev/null | tr -d '\r' || true)"
    fi
    if [[ -n "$message" ]]; then
        echo "$message" >&2
    else
        _mmry_print_error "save entries"
    fi
    exit 1
fi
