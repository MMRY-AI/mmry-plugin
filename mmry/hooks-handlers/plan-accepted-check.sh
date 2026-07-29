#!/usr/bin/env bash
# plan-accepted-check.sh — PostToolUse hook: sends accepted plan context to MMRY AI API.

set -euo pipefail

# Authored with REAL newlines so the model sees clean formatting on stderr. Variable
# references are intentionally literal - the model expands them when it runs the command.
CONTEXT='REQUIRED: You just accepted an implementation plan. Write a summary of the plan and send it to the MMRY AI API.

Call the process endpoint:

bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/process-context.sh" \
  --hook-type "planAccepted" \
  --context "<summary of the accepted plan: what will be built, key design decisions, chosen approach>" \
  --working-dir "$PWD" \
  --session-id "$CLAUDE_SESSION_ID"

The server will decide how to classify and store this. Just provide a thorough summary of the decision.

Run in background (run_in_background: true).'

# #30642: deliver the directive on stderr and exit 2. On exit 2 Claude Code discards stdout and
# feeds the hook's stderr to the model (confirmed by the docs for PostToolUse), so we emit ONLY
# to stderr - no JSON. Emitting as JSON previously forced escaping that leaked literal
# backslash-n / backslash-quote markers into the model-visible text; stderr-only avoids that.
# This hook does not block (the tool already ran); the model receives the directive and acts.
# The user-only systemMessage is dropped.
printf '%s\n' "$CONTEXT" >&2
exit 2
