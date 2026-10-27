#!/usr/bin/env bash
# retire-database.sh - stop a database collecting new entries, keeping every entry it holds (#32443).
#
# PARITY WITH THE CONNECTOR. The MMRY connector has one tool per operation (mmry_database_rename,
# mmry_database_retire, mmry_database_reinstate); the plugin had all three only as switches on
# revise-database.sh. This file, rename-database.sh and reinstate-database.sh give each its own script,
# named the way the connector names it, so /mmry:database and the connector offer the same set.
#
# ONE CODE PATH. It hands straight to revise-database.sh --retire, which owns the request, the
# refusals and the output ("It still holds N entries." then what retiring means). Nothing is
# restated here, so the two can never disagree.
#
# NOTHING IS DELETED. A retired database keeps every entry; they stay readable and searchable and
# stay in the user's export. reinstate-database.sh starts it collecting again.
#
# Usage: bash retire-database.sh --id ID

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --id|--database-id)
            [[ $# -ge 2 ]] || { echo "Error: --id needs the database's id." >&2; exit 1; }
            ID="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$ID" ]]; then
    echo "Error: --id is required. Run list-databases.sh to find it." >&2
    exit 1
fi

exec bash "${HERE}/revise-database.sh" --id "$ID" --retire
