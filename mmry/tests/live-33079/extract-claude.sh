#!/usr/bin/env bash
# extract-claude.sh OUTDIR - per prompt: the additionalContext of each UserPromptSubmit hook that spoke.
set -u; source "$(dirname "$0")/common.sh" || exit 1
D="$1"
for p in p1 p2; do
  "$LIVE_JQ" -s '[.[]|select(.type=="system" and .subtype=="hook_response" and .hook_event=="UserPromptSubmit" and (.stdout|length)>0)|(.stdout|fromjson|.hookSpecificOutput.additionalContext)]' "$D/$p.jsonl" > "$D/$p-delivered.json"
done
