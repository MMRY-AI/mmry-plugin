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

# Authored with REAL newlines (single-quoted heredoc-style literal) so the model sees clean
# formatting on stderr. Variable references ($PWD, $CLAUDE_SESSION_ID, ${CLAUDE_PLUGIN_ROOT})
# are intentionally literal - the model expands them when it runs the command.
CONTEXT='REQUIRED: Context compression is imminent. Write a concise briefing of your current session state so you can resume after compression. Then send it to the MMRY AI API.

Call the process endpoint:

bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/process-context.sh" \
  --hook-type "precompact" \
  --context "<your session continuity briefing>" \
  --working-dir "$PWD" \
  --session-id "$CLAUDE_SESSION_ID"

Include: (1) what task you are working on, (2) what step you are on, (3) key decisions or findings so far, (4) what to do next.

Run in background (run_in_background: true).'

# #30642: deliver the directive on stderr and exit 2. On exit 2 Claude Code discards stdout
# entirely and feeds the hook's stderr to the model, so we emit ONLY to stderr - no JSON.
# Emitting the text as JSON previously forced backslash-n / backslash-quote escaping that then
# leaked into the model-visible stderr as literal markers; stderr-only avoids that. exit 2 also
# keeps PreCompact pausing compaction. The user-only systemMessage is dropped.
#
# Delivery note (req 3): the docs confirm stderr reaches the model on exit 2 for Stop and
# PostToolUse but are silent for PreCompact specifically. We rely on the same mechanism by
# analogy - accepted low risk: worst case is no regression versus the prior broken state, and
# exit 2 still blocks compaction regardless. Empirical /compact confirmation is the follow-up.
printf '%s\n' "$CONTEXT" >&2
exit 2
