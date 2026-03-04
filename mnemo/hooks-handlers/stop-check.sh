#!/usr/bin/env bash
# stop-check.sh — Stop hook: prompts to save memories before session exit.
# Uses temp marker file to debounce (120-second window).

set -euo pipefail

TMPDIR="${TMPDIR:-/tmp}"
MARKER="${TMPDIR}/.mnemo-stop-checked"

if [[ -f "$MARKER" ]]; then
    # Check file age — cross-platform
    now=$(date +%s)
    if stat --version &>/dev/null 2>&1; then
        # GNU stat
        mtime=$(stat -c %Y "$MARKER" 2>/dev/null || echo 0)
    else
        # BSD stat (macOS)
        mtime=$(stat -f %m "$MARKER" 2>/dev/null || echo 0)
    fi
    age=$(( now - mtime ))
    if (( age < 120 )); then
        exit 0
    fi
fi

touch "$MARKER"
printf '{"decision":"block","reason":"Mnemo saved any decisions, issues, or conventions as memories. Skipped if nothing needed saving."}'
exit 2
