#!/usr/bin/env bash
# rename-format.sh - correct what a database is called, what it is for, or the words that help
#                    the assistant choose it (#32443).
#
# PARITY WITH THE CONNECTOR. The connector's mmry_format_rename takes a name, a description and
# match hints, and touches no field and no entry. This is the same operation, as its own script,
# beside retire-format.sh and reinstate-format.sh.
#
# ONE CODE PATH. It hands straight to revise-format.sh --rename/--describe/--match-hints, which
# owns the request and the output, so the two can never disagree. A value you leave out is left
# alone, not cleared. To change the FIELDS a database collects, use revise-format.sh --fields:
# that publishes a new version, which a rename never does.
#
# Usage:
#   bash rename-format.sh --id ID [--name NAME] [--description TEXT] [--match-hints "a, b"]

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ID="" ARGS=()

need() { [[ $2 -ge 2 ]] || { echo "Error: $1 needs a value." >&2; exit 1; }; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --id|--format-id)          need "$1" $#; ID="$2"; shift 2 ;;
        --name|--rename)           need "$1" $#; ARGS+=(--rename "$2"); shift 2 ;;
        --description|--describe)  need "$1" $#; ARGS+=(--describe "$2"); shift 2 ;;
        --match-hints)             need "$1" $#; ARGS+=(--match-hints "$2"); shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$ID" ]]; then
    echo "Error: --id is required. Run list-formats.sh to find it." >&2
    exit 1
fi

if [[ ${#ARGS[@]} -eq 0 ]]; then
    echo "Error: nothing to change. Give --name, --description or --match-hints." >&2
    exit 1
fi

exec bash "${HERE}/revise-format.sh" --id "$ID" "${ARGS[@]}"
