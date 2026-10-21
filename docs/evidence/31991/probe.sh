#!/usr/bin/env bash
out="$(dirname "$0")/payloads.jsonl"
payload="$(cat)"
printf '{"env_session":"%s","env_agent":"%s","payload":%s}\n' "${CLAUDE_CODE_SESSION_ID:-}" "${CLAUDE_CODE_AGENT:-}" "${payload:-null}" >> "$out"
exit 0
