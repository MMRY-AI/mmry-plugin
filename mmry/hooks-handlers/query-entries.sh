#!/usr/bin/env bash
# query-entries.sh — read the entries of a database, filtered on their FIELDS.
#
# THIS IS WHAT THE WHOLE FEATURE IS FOR. Use it when the user's question depends on the VALUES
# rather than on the wording: how many, which ones, since when, sorted by what. A keyword search
# over prose is a scan and a judgement; this is a seek, and the answer is a count.
#
# Every entry comes back with every field the database declares, blank where nothing was saved,
# so you can compare and count without checking whether a key exists. Entries saved under an
# older shape of the database are included and correctly attributed.
#
# Usage:
#   bash query-entries.sh --database-id ID [--filter key=value]... [--order "key desc"]
#        [--page N] [--page-size N]
#
# Filters are ANDed. Repeating one key asks for a field holding BOTH values, which is coherent
# for a list field and empty for a single-valued one.

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "${PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"

DATABASE_ID="" ORDER="" PAGE="" PAGE_SIZE=""
FILTER_QUERY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --database-id) DATABASE_ID="$2"; shift 2 ;;
        --filter)
            pair="$2"; shift 2
            if [[ "$pair" != *=* ]]; then
                echo "Error: --filter takes key=value, e.g. --filter status=open" >&2
                exit 1
            fi
            key="${pair%%=*}"
            value="${pair#*=}"
            [[ -n "$FILTER_QUERY" ]] && FILTER_QUERY+="&" || true
            FILTER_QUERY+="field.$(_mmry_urlencode "$key")=$(_mmry_urlencode "$value")"
            ;;
        --order)     ORDER="$2"; shift 2 ;;
        --page)      PAGE="$2"; shift 2 ;;
        --page-size) PAGE_SIZE="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$DATABASE_ID" ]]; then
    echo "Error: --database-id is required. Run list-databases.sh to find it." >&2
    exit 1
fi

if mmry_get_entries "$DATABASE_ID" "$FILTER_QUERY" "$ORDER" "$PAGE" "$PAGE_SIZE"; then
    if [[ -n "${MMRY_JQ:-}" ]]; then
        printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '
            "\(.total) " + (if .total == 1 then "entry" else "entries" end) + " in \(.database.name):",
            "",
            (.entries[] |
                # The route answers entryKey, savedAt and note (the words the entry was saved from), not a
                # topic (#31827, read from Integration): printing .topic said "(no topic)" for
                # every entry and never showed the words.
                "id \(.id)"
                    + (if (.entryKey // "") != "" then " | \(.entryKey)" else "" end)
                    + (if (.savedAt // "") != "" then " | saved \(.savedAt)" else "" end),
                (if (.note // "") != "" then "    words: \(.note)" else empty end),
                (.values | to_entries[] | "    \(.key): " + (if .value == null then "(blank)" elif (.value | type) == "array" then (.value | map(tostring) | join(", ")) else (.value | tostring) end)),
                "---")'
    else
        printf '%s\n' "$MMRY_RESPONSE"
    fi
else
    _mmry_print_error "read entries"
    exit 1
fi
