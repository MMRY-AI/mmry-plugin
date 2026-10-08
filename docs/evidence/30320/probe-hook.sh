#!/usr/bin/env bash
payload="$(cat)"
printf '%s\n' "$payload" > "E:/mmry-wt/probe-agent/sessionstart-payload.json"
agent="$(printf '%s' "$payload" | sed -n 's/.*"agent_type":"\([^"]*\)".*/\1/p')"
printf 'CLAUDE_ENV_FILE=%s\n' "${CLAUDE_ENV_FILE:-<unset>}" > "E:/mmry-wt/probe-agent/envfile-path.txt"
[ -n "${CLAUDE_ENV_FILE:-}" ] && printf "export PROBE_SESSION_AGENT='%s'\n" "$agent" >> "$CLAUDE_ENV_FILE"
exit 0
