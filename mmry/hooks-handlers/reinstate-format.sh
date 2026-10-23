#!/usr/bin/env bash
# reinstate-format.sh - start a retired database collecting entries again (#32443).
#
# PARITY WITH THE CONNECTOR. The MMRY connector has one tool per operation (mmry_format_rename,
# mmry_format_retire, mmry_format_reinstate); the plugin had all three only as switches on
# revise-format.sh. This file, rename-format.sh and retire-format.sh give each its own script,
# named the way the connector names it, so /mmry:database and the connector offer the same set.
#
# ONE CODE PATH. It hands straight to revise-format.sh --reinstate, which owns the request, the
# refusals and the output ("It still holds N entries." then "Collecting again."). Nothing is
# restated here, so the two can never disagree.
#
# Reinstating changes only whether the database COLLECTS. Every entry it held while retired was
# kept, so nothing needs restoring but the collecting. Find a retired id with list-formats.sh --include-retired.
#
# Usage: bash reinstate-format.sh --id ID

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --id|--format-id)
            [[ $# -ge 2 ]] || { echo "Error: --id needs the database's id." >&2; exit 1; }
            ID="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$ID" ]]; then
    echo "Error: --id is required. Run list-formats.sh --include-retired to find it." >&2
    exit 1
fi

exec bash "${HERE}/revise-format.sh" --id "$ID" --reinstate
