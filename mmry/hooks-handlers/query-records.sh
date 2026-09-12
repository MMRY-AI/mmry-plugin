#!/usr/bin/env bash
# query-records.sh — read the records of a structured record type, filtered on their FIELDS.
#
# THIS IS WHAT THE WHOLE FEATURE IS FOR. Use it when the user's question depends on the VALUES
# rather than on the wording: how many, which ones, since when, sorted by what. A keyword search
# over prose is a scan and a judgement; this is a seek, and the answer is a count.
#
# Every record comes back with every field the type declares, blank where nothing was recorded,
# so you can compare and count without checking whether a key exists. Records saved under an
# older shape of the type are included and correctly attributed.
#
# Usage:
#   bash query-records.sh --format-id ID [--filter key=value]... [--order "key desc"]
#        [--page N] [--page-size N]
#
# Filters are ANDed. Repeating one key asks for a field holding BOTH values, which is coherent
# for a list field and empty for a single-valued one.

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "${PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"

FORMAT_ID="" ORDER="" PAGE="" PAGE_SIZE=""
FILTER_QUERY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --format-id) FORMAT_ID="$2"; shift 2 ;;
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

if [[ -z "$FORMAT_ID" ]]; then
    echo "Error: --format-id is required. Run list-formats.sh to find it." >&2
    exit 1
fi

if mmry_get_records "$FORMAT_ID" "$FILTER_QUERY" "$ORDER" "$PAGE" "$PAGE_SIZE"; then
    if [[ -n "${MMRY_JQ:-}" ]]; then
        printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '
            "\(.total) record(s) in \(.format.name):",
            "",
            (.entries[] |
                "id \(.id) | \(.topic // "(no topic)")",
                (.values | to_entries[] | "    \(.key): " + (if .value == null then "(blank)" elif (.value | type) == "array" then (.value | map(tostring) | join(", ")) else (.value | tostring) end)),
                "---")'
    else
        printf '%s\n' "$MMRY_RESPONSE"
    fi
else
    _mmry_format_error "read records"
    exit 1
fi
