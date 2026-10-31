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
#
# Leave --page-size out (#33197, DD-165): the page is then sized to fit in one reply, so a wider
# database gives fewer entries per page. The output's Page line gives the page, how many per page
# and the total, and the Next page line the exact --page and --page-size to ask for next.
#
# EVERY PAGE FITS THE TOOL THAT PRINTS IT (#33197 round 2). This output reaches the assistant
# through its shell tool, which cuts it far below what a connector reply holds: Claude Code's Bash
# tool at 30,000 characters (BASH_MAX_OUTPUT_LENGTH when the customer set it), the Codex shell at
# 10,000 tokens, which Codex counts as 4 bytes a token (codex-rs models.json truncation_policy,
# utils/string APPROX_BYTES_PER_TOKEN), so 40,000 bytes. A page cut there loses its last entries
# with nothing to say so. So the API is asked to hold the entries to two thirds of the limit (the
# printed form is longer than the JSON for blank fields), and if the printed page is still over it
# the page is asked for again with a budget scaled down, at most three times. MMRY_REPLY_CHARACTERS
# overrides the limit. One entry longer than the limit on its own cannot be helped; it is printed
# with the Page lines first, which both tools keep.

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

# The output limit of the tool this script prints through, in bytes (bytes are never fewer than
# characters, so a byte count within it is within a character limit too).
_mmry_reply_limit() {
    if [[ "${MMRY_REPLY_CHARACTERS:-}" =~ ^[0-9]+$ ]] && (( MMRY_REPLY_CHARACTERS >= 1000 )); then
        printf '%s' "$MMRY_REPLY_CHARACTERS"
    elif [[ "$(mmry_host)" == "codex" ]]; then
        printf '%s' 40000
    elif [[ "${BASH_MAX_OUTPUT_LENGTH:-}" =~ ^[0-9]+$ ]] && (( BASH_MAX_OUTPUT_LENGTH >= 1000 )); then
        printf '%s' "$BASH_MAX_OUTPUT_LENGTH"
    else
        printf '%s' 30000
    fi
}

_render_page() {
    printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '
            "\(.total) " + (if .total == 1 then "entry" else "entries" end) + " in \(.database.name):",
            # #33197 (DD-165): the page, how many per page, the total and what to ask for next. The
            # API words it (and says when it shortened a page to fit one reply); an API before
            # #33197 sends no sentence, so the page is stated from the numbers it does send.
            (.paging // "Page \(.page // 1), \(.pageSize // (.entries | length)) per page, \(.total) in total."),
            (if .hasMore == true then "Next page: --page \((.page // 1) + 1) --page-size \(.pageSize)" else empty end),
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
}

LIMIT="$(_mmry_reply_limit)"
BUDGET=$(( LIMIT * 2 / 3 ))

if ! mmry_get_entries "$DATABASE_ID" "$FILTER_QUERY" "$ORDER" "$PAGE" "$PAGE_SIZE" "$BUDGET"; then
    _mmry_print_error "read entries"
    exit 1
fi

if [[ -z "${MMRY_JQ:-}" ]]; then
    printf '%s\n' "$MMRY_RESPONSE"
    exit 0
fi

OUT="$(_render_page)"
for _attempt in 1 2 3; do
    _bytes="$(LC_ALL=C; printf '%s' "${#OUT}")"
    (( _bytes <= LIMIT )) && break
    _count="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.entries | length')"
    [[ "$_count" =~ ^[0-9]+$ ]] && (( _count > 1 )) || break
    # Scale the budget by how far over the printed page came, with a tenth to spare.
    BUDGET=$(( BUDGET * LIMIT * 9 / 10 / _bytes ))
    (( BUDGET < 1 )) && BUDGET=1
    if ! mmry_get_entries "$DATABASE_ID" "$FILTER_QUERY" "$ORDER" "$PAGE" "$PAGE_SIZE" "$BUDGET"; then
        _mmry_print_error "read entries"
        exit 1
    fi
    OUT="$(_render_page)"
done
printf '%s\n' "$OUT"
