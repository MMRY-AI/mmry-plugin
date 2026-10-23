#!/usr/bin/env bash
# retire-format.sh - stop a database collecting new entries, keeping every entry it holds (#32443).
#
# PARITY WITH THE CONNECTOR. The MMRY connector has one tool per operation (mmry_format_rename,
# mmry_format_retire, mmry_format_reinstate); the plugin had all three only as switches on
# revise-format.sh. This file, rename-format.sh and reinstate-format.sh give each its own script,
# named the way the connector names it, so /mmry:database and the connector offer the same set.
#
# ONE CODE PATH. It hands straight to revise-format.sh --retire, which owns the request, the
# refusals and the output ("It still holds N entries." then what retiring means). Nothing is
# restated here, so the two can never disagree.
#
# NOTHING IS DELETED. A retired database keeps every entry; they stay readable and searchable and
# stay in the user's export. reinstate-format.sh starts it collecting again.
#
# Usage: bash retire-format.sh --id ID

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
    echo "Error: --id is required. Run list-formats.sh to find it." >&2
    exit 1
fi

exec bash "${HERE}/revise-format.sh" --id "$ID" --retire
