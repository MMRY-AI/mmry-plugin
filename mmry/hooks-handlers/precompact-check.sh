#!/usr/bin/env bash
# precompact-check.sh — PreCompact hook: sends session continuity context to MMRY AI API.
# Uses temp marker file to debounce (120-second window).

set -euo pipefail

TMPDIR="${TMPDIR:-/tmp}"
MARKER="${TMPDIR}/.mmry-precompact-checked"

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
        rm -f "$MARKER"
        exit 0
    fi
fi

touch "$MARKER"

CONTEXT='REQUIRED: Context compression is imminent. Write a concise briefing of your current session state so you can resume after compression. Then send it to the MMRY AI API.\n\nCall the process endpoint:\n\nbash \"${CLAUDE_PLUGIN_ROOT}/hooks-handlers/process-context.sh\" \\\n  --hook-type \"precompact\" \\\n  --context \"<your session continuity briefing>\" \\\n  --working-dir \"$PWD\" \\\n  --session-id \"$CLAUDE_SESSION_ID\"\n\nInclude: (1) what task you are working on, (2) what step you are on, (3) key decisions or findings so far, (4) what to do next.\n\nRun in background (run_in_background: true).'

# #30642: deliver the directive on stderr, which Claude Code feeds to the model on exit 2;
# keep exit 2 so PreCompact still pauses compaction; drop the user-only systemMessage. The
# stdout decision:block/reason is retained for clarity and in case the harness parses it.
printf '%s\n' "$CONTEXT" >&2
printf '{"decision":"block","reason":"%s"}' "$CONTEXT"
exit 2
